import SwiftUI

/// 窗口顶部的标签栏。只负责展示和转发用户意图，标签的实际关闭/切换由 WindowController 处理。
struct TabBarView: View {
    @ObservedObject var session: WindowSession
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNew: () -> Void

    var body: some View {
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
            }

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

            Spacer(minLength: 0)
        }
        .frame(height: 36)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .disabled(!session.isInteractionEnabled)
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
