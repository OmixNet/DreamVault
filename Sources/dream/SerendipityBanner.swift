// P2-4: 偶然唤回 banner — 顶部 1 行, 唤起老记忆
import SwiftUI
import DreamEngine

/// P2-4: 偶然唤回 banner
/// - 黄色背景, lightbulb 图标
/// - 1 行: "💡 N 天前你看到: <memory 摘录>"
/// - "Open" 按钮 → 调 onOpen; "×" 按钮 → 调 onDismiss
@MainActor
public struct SerendipityBanner: View {
    public let pick: SerendipityPick
    public let onOpen: (Memory) -> Void
    public let onDismiss: () -> Void

    public init(pick: SerendipityPick,
                onOpen: @escaping (Memory) -> Void,
                onDismiss: @escaping () -> Void) {
        self.pick = pick
        self.onOpen = onOpen
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "lightbulb.fill")
                .foregroundColor(AppColor.warning)
                .font(AppFont.body)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("\(pick.daysSinceAccess) 天前你看到")
                    .font(AppFont.caption2)
                    .foregroundColor(AppColor.textSecondary)
                Text(pick.memory.text)
                    .font(AppFont.body)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                onOpen(pick.memory)
            } label: {
                Label("Open", systemImage: "arrow.right.circle")
                    .labelStyle(.titleAndIcon)
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppColor.textSecondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(Spacing.sm)
        .bannerStyle(.warning)
    }
}
