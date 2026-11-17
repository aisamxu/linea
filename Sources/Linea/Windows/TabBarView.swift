import SwiftUI

/// 窗口顶部的标签栏。只负责展示和转发用户意图，标签的实际关闭/切换由 WindowController 处理。
struct TabBarView: View {
    @ObservedObject var session: WindowSession
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNew: () -> Void

    /// 标签内容实测宽度；滚动区按它收缩，多余空白交给底层新建按钮。
    @State private var tabContentWidth: CGFloat = 0

    /// 右侧分隔线与加号按钮占用的固定宽度。
    private static let trailingChromeWidth: CGFloat = 33

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // 透明底层：点击标签栏任意空白处与 ⌘T 一样新建标签。
                // 用 Button 承载点击，比 onTapGesture 在 AppKit 宿主中的事件路径更稳定；
                // 标签与加号按钮位于上层，会优先消费各自的点击。
                Button(action: onNew) {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)

                HStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            ForEach(session.tabs) { tab in
                                TabItemView(
                                    tab: tab,
                                    isSelected: tab.id == session.selectedTabID,
                                    onSelect: { onSelect(tab.id) },
                                    onClose: { onClose(tab.id) }
                                )
                            }
                        }
                        .padding(.horizontal, 6)
                        .background {
                            // 只读取标签总宽，不参与布局。
                            GeometryReader { contentProxy in
                                Color.clear.preference(
                                    key: TabContentWidthKey.self,
                                    value: contentProxy.size.width
                                )
                            }
                        }
                    }
                    // 内容不足一屏时滚动区只占内容宽度，让右侧空白可点击；
                    // 标签超出时收缩到可用宽度，保持横向滚动。
                    .frame(width: tabStripWidth(available: proxy.size.width))

                    // 标签与右侧固定控件之间的空白保持透明，
                    // 点击由底层按钮接管。
                    Spacer(minLength: 0)

                    Divider()
                        .frame(height: 20)

                    Button(action: onNew) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 32, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New Tab")
                    .accessibilityLabel("New Tab")
                }
            }
        }
        .onPreferenceChange(TabContentWidthKey.self) { width in
            tabContentWidth = width
        }
        .frame(height: 36)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .disabled(!session.isInteractionEnabled)
    }

    private func tabStripWidth(available: CGFloat) -> CGFloat {
        let capacity = max(0, available - Self.trailingChromeWidth)
        guard tabContentWidth > 0 else { return capacity }
        return min(tabContentWidth, capacity)
    }
}

/// 标签内容宽度上报；用于让滚动区收缩到内容宽度。
private struct TabContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TabItemView: View {
    @ObservedObject var tab: EditorTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .opacity(tab.isDirty ? 1 : 0)

                    Text(tab.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.title)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Tab")
            .accessibilityLabel("Close \(tab.title)")
        }
        .padding(.horizontal, 9)
        .frame(minWidth: 100, maxWidth: 220, minHeight: 26, maxHeight: 26)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.10 : 0.0))
        }
        .contentShape(Rectangle())
    }
}
