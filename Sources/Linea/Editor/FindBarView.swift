import AppKit

/// 编辑器内查找栏（Xcode 风格）。
///
/// 只负责 UI 与输入事件；匹配、导航和替换由 `EditorViewController` 驱动。
/// 按钮使用简短符号（Aa / wd / S* / R→ / R*），完整名称放在 tooltip 与
/// accessibilityLabel 中，避免长文案挤占查找栏宽度。
final class FindBarView: NSView, NSTextFieldDelegate {
    struct Options: Equatable {
        var matchCase = false
        var wholeWord = false
    }

    /// 查找行高度；替换行出现时追加一行（含行间距）。
    private static let rowHeight: CGFloat = 28
    private static let padding: CGFloat = 6
    private static let rowSpacing: CGFloat = 4

    var preferredHeight: CGFloat {
        Self.padding * 2
            + Self.rowHeight * (isReplaceRowVisible ? 2 : 1)
            + (isReplaceRowVisible ? Self.rowSpacing : 0)
    }

    var onQueryChanged: ((String) -> Void)?
    var onOptionsChanged: ((Options) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSelectAllMatches: (() -> Void)?
    var onReplace: ((String) -> Void)?
    var onReplaceAll: ((String) -> Void)?
    var onClose: (() -> Void)?

    var query: String { searchField.stringValue }

    /// 当前开关状态；切换大小写/全字匹配后据此通知控制器重算匹配。
    private var options: Options {
        Options(
            matchCase: caseButton.state == .on,
            wholeWord: wholeWordButton.state == .on
        )
    }

    var isReplaceRowVisible = false {
        didSet {
            guard isReplaceRowVisible != oldValue else { return }
            replaceRow.isHidden = !isReplaceRowVisible
        }
    }

    private let searchField = NSTextField()
    private let replaceField = NSTextField()
    private let caseButton = NSButton()
    private let wholeWordButton = NSButton()
    private let selectAllButton = NSButton()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let replaceButton = NSButton()
    private let replaceAllButton = NSButton()
    private let findRow = NSStackView()
    private let replaceRow = NSStackView()
    private let contentStack = NSStackView()

    private var totalMatches = 0
    private var currentMatch: Int?

    // MARK: - 初始化

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private func configure() {
        wantsLayer = true

        configureSearchField()
        configureReplaceField()
        configureToggle(
            caseButton,
            title: "Aa",
            underlined: false,
            tooltip: "Match Case"
        )
        configureToggle(
            wholeWordButton,
            title: "wd",
            underlined: true,
            tooltip: "Whole Word"
        )
        configureTextButton(
            selectAllButton,
            title: "S*",
            tooltip: "Select All Matches"
        )
        configureSymbolButton(
            previousButton,
            symbol: "chevron.left",
            tooltip: "Previous Match"
        )
        configureSymbolButton(
            nextButton,
            symbol: "chevron.right",
            tooltip: "Next Match"
        )
        configureTextButton(
            replaceButton,
            title: "R→",
            tooltip: "Replace"
        )
        configureTextButton(
            replaceAllButton,
            title: "R*",
            tooltip: "Replace All"
        )

        caseButton.action = #selector(toggleMatchCase(_:))
        wholeWordButton.action = #selector(toggleWholeWord(_:))
        selectAllButton.action = #selector(selectAllMatches(_:))
        previousButton.action = #selector(findPrevious(_:))
        nextButton.action = #selector(findNext(_:))
        replaceButton.action = #selector(replaceCurrent(_:))
        replaceAllButton.action = #selector(replaceAll(_:))

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

        let searchContainer = makeFieldContainer(
            icon: "magnifyingglass",
            field: searchField,
            trailingButtons: [caseButton, wholeWordButton]
        )
        let replaceContainer = makeFieldContainer(
            icon: nil,
            field: replaceField,
            trailingButtons: []
        )
        findRow.orientation = .horizontal
        findRow.alignment = .centerY
        findRow.spacing = 6
        findRow.addArrangedSubview(searchContainer)
        findRow.addArrangedSubview(selectAllButton)
        findRow.addArrangedSubview(previousButton)
        findRow.addArrangedSubview(nextButton)
        findRow.addArrangedSubview(countLabel)
        searchContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        replaceRow.orientation = .horizontal
        replaceRow.alignment = .centerY
        replaceRow.spacing = 6
        replaceRow.addArrangedSubview(replaceContainer)
        replaceRow.addArrangedSubview(replaceButton)
        replaceRow.addArrangedSubview(replaceAllButton)
        replaceRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        replaceRow.isHidden = true

        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.spacing = Self.rowSpacing
        contentStack.addArrangedSubview(findRow)
        contentStack.addArrangedSubview(replaceRow)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        // 不把两行输入框强行等宽：查找行多出 S*/‹/›/计数，替换行按钮更少，
        // 等宽会把替换行整体挤到中间。让替换框自然拉伸到行尾，两行左边缘对齐。
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(
                equalTo: topAnchor,
                constant: Self.padding
            ),
            contentStack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: 10
            ),
            contentStack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -10
            ),
            contentStack.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -Self.padding
            ),
            findRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            replaceRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
        ])

        updateToggleAppearance()
        refreshButtonStates()
        countLabel.stringValue = ""
        countLabel.isHidden = true
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        // 与编辑器内容之间用一条分隔线收口。
        NSColor.separatorColor.setFill()
        NSRect(
            x: 0,
            y: bounds.height - 1,
            width: bounds.width,
            height: 1
        ).fill()
    }

    // MARK: - 对外状态

    func setQuery(_ text: String, selectAll: Bool) {
        searchField.stringValue = text
        if selectAll, window?.firstResponder === searchField.currentEditor() {
            searchField.currentEditor()?.selectAll(nil)
        }
    }

    func setOptions(_ options: Options) {
        caseButton.state = options.matchCase ? .on : .off
        wholeWordButton.state = options.wholeWord ? .on : .off
        updateToggleAppearance()
    }

    func focusSearchField(selectAll: Bool) {
        guard let window else { return }
        window.makeFirstResponder(searchField)
        if selectAll {
            searchField.currentEditor()?.selectAll(nil)
        }
    }

    /// 更新计数与按钮可用性。`current` 从 1 开始；为 nil 时只显示总数。
    func updateResult(current: Int?, total: Int) {
        totalMatches = total
        currentMatch = current
        if query.isEmpty {
            countLabel.stringValue = ""
            countLabel.isHidden = true
        } else if total == 0 {
            countLabel.stringValue = "No Results"
            countLabel.isHidden = false
        } else if let current {
            countLabel.stringValue = "\(current)/\(total)"
            countLabel.isHidden = false
        } else {
            countLabel.stringValue = "\(total)"
            countLabel.isHidden = false
        }
        refreshButtonStates()
    }

    // MARK: - 控件配置

    private func configureSearchField() {
        searchField.placeholderString = "Find"
        searchField.font = .systemFont(ofSize: 13)
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
    }

    private func configureReplaceField() {
        replaceField.placeholderString = "Replace"
        replaceField.font = .systemFont(ofSize: 13)
        replaceField.isBordered = false
        replaceField.drawsBackground = false
        replaceField.focusRingType = .none
        replaceField.delegate = self
        replaceField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func configureToggle(
        _ button: NSButton,
        title: String,
        underlined: Bool,
        tooltip: String
    ) {
        button.isBordered = false
        button.target = self
        button.setButtonType(.toggle)
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.title = title
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func configureTextButton(
        _ button: NSButton,
        title: String,
        tooltip: String
    ) {
        button.isBordered = false
        button.target = self
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.title = title
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func configureSymbolButton(
        _ button: NSButton,
        symbol: String,
        tooltip: String
    ) {
        button.isBordered = false
        button.target = self
        button.bezelStyle = .inline
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: tooltip
        )
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.imagePosition = .imageOnly
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    /// 查找输入框：圆角容器 + 放大镜 + 文本框 + 内嵌的 Aa/wd 开关。
    private func makeFieldContainer(
        icon: String?,
        field: NSTextField,
        trailingButtons: [NSButton]
    ) -> NSView {
        let container = FindFieldContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true

        var leadingAnchor = container.leadingAnchor
        var leadingInset: CGFloat = 8
        if let icon {
            let imageView = NSImageView()
            imageView.image = NSImage(
                systemSymbolName: icon,
                accessibilityDescription: nil
            )
            imageView.contentTintColor = .secondaryLabelColor
            imageView.imageScaling = .scaleProportionallyDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: leadingInset),
                imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 14),
                imageView.heightAnchor.constraint(equalToConstant: 14),
            ])
            leadingAnchor = imageView.trailingAnchor
            leadingInset = 6
        }

        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)

        var trailingAnchor = container.trailingAnchor
        var trailingInset: CGFloat = -10
        if let first = trailingButtons.first {
            for button in trailingButtons {
                button.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(button)
                NSLayoutConstraint.activate([
                    button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                ])
            }
            // 从右到左依次排列，按钮之间保留 2pt 视觉间距。
            var currentTrailing = container.trailingAnchor
            var inset: CGFloat = -4
            for button in trailingButtons.reversed() {
                NSLayoutConstraint.activate([
                    button.trailingAnchor.constraint(equalTo: currentTrailing, constant: inset),
                ])
                currentTrailing = button.leadingAnchor
                inset = -2
            }
            // 文本框必须停在最左侧按钮之前，不能压住开关。
            trailingAnchor = first.leadingAnchor
            trailingInset = -4
        }

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: trailingInset),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    // MARK: - 状态刷新

    private func updateToggleAppearance() {
        applyToggleStyle(
            caseButton,
            title: "Aa",
            underlined: false,
            isOn: caseButton.state == .on
        )
        applyToggleStyle(
            wholeWordButton,
            title: "wd",
            underlined: true,
            isOn: wholeWordButton.state == .on
        )
    }

    private func applyToggleStyle(
        _ button: NSButton,
        title: String,
        underlined: Bool,
        isOn: Bool
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: isOn
                ? NSColor.controlAccentColor
                : NSColor.secondaryLabelColor,
        ]
        if underlined {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: attributes
        )
        button.setAccessibilityValue(isOn ? "On" : "Off")
    }

    private func refreshButtonStates() {
        let hasMatches = totalMatches > 0
        nextButton.isEnabled = hasMatches
        previousButton.isEnabled = hasMatches
        selectAllButton.isEnabled = hasMatches
        replaceButton.isEnabled = hasMatches
        replaceAllButton.isEnabled = hasMatches
    }

    // MARK: - 动作

    @objc private func toggleMatchCase(_ sender: Any?) {
        updateToggleAppearance()
        onOptionsChanged?(options)
    }

    @objc private func toggleWholeWord(_ sender: Any?) {
        updateToggleAppearance()
        onOptionsChanged?(options)
    }

    @objc private func selectAllMatches(_ sender: Any?) {
        onSelectAllMatches?()
    }

    @objc private func findPrevious(_ sender: Any?) {
        onPrevious?()
    }

    @objc private func findNext(_ sender: Any?) {
        onNext?()
    }

    @objc private func replaceCurrent(_ sender: Any?) {
        onReplace?(replaceField.stringValue)
    }

    @objc private func replaceAll(_ sender: Any?) {
        onReplaceAll?(replaceField.stringValue)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === searchField
        else {
            return
        }
        onQueryChanged?(field.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc 关闭查找栏，与菜单/编辑器焦点下的行为一致。
            onClose?()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField {
                onReplace?(replaceField.stringValue)
            } else if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        default:
            return false
        }
    }
}

/// 圆角输入框背景；用动态系统颜色在 draw 时解析，自动跟随浅色/深色外观。
private final class FindFieldContainerView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: 7,
            yRadius: 7
        )
        NSColor.textBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
