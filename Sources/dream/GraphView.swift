// P2-2: 知识图谱可视化视图
import SwiftUI
import DreamEngine

/// P2-2: 节点状态 (renderer 内部用, 跟 layout 分离)
public struct GraphNodeVisual: Identifiable, Equatable {
    public let id: String
    public let label: String
    public let size: CGFloat  // 节点半径 (按 decay class 区分)
    public let color: Color   // 节点颜色 (按 kind 区分)
    public init(id: String, label: String, size: CGFloat, color: Color) {
        self.id = id
        self.label = label
        self.size = size
        self.color = color
    }
}

/// P2-2: 图谱画布. 接受 nodes + edges + 选中的 id, SwiftUI Canvas 绘制
/// 60fps 没问题 (200 节点, 一次 layout 10ms, 渲染 Canvas 用 Metal 加速)
@MainActor
public struct GraphRenderer: View {
    public let nodes: [GraphNodeVisual]
    public let edges: [GraphEdge]
    public let area: CGSize
    @Binding public var selectedID: String?
    @Binding public var hoveredID: String?
    public let onTap: (String) -> Void

    public init(nodes: [GraphNodeVisual],
                edges: [GraphEdge],
                area: CGSize,
                selectedID: Binding<String?>,
                hoveredID: Binding<String?>,
                onTap: @escaping (String) -> Void) {
        self.nodes = nodes
        self.edges = edges
        self.area = area
        self._selectedID = selectedID
        self._hoveredID = hoveredID
        self.onTap = onTap
    }

    public var body: some View {
        let positions = ForceLayout.layout(
            nodes: nodes.map { $0.id },
            edges: edges,
            area: area
        )

        Canvas { ctx, _ in
            // 边
            for edge in edges {
                guard let pu = positions[edge.u], let pv = positions[edge.v] else { continue }
                let highlight: Color = {
                    if let sel = selectedID, (sel == edge.u || sel == edge.v) {
                        return .blue
                    }
                    if let hov = hoveredID, (hov == edge.u || hov == edge.v) {
                        return .orange
                    }
                    return Color.gray.opacity(0.3)
                }()
                var path = Path()
                path.move(to: pu)
                path.addLine(to: pv)
                ctx.stroke(path, with: .color(highlight), lineWidth: 1.0)
            }

            // 节点
            for node in nodes {
                guard let p = positions[node.id] else { continue }
                let r = node.size
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                let dim: Color = {
                    if let sel = selectedID, sel == node.id {
                        return node.color.opacity(1.0)
                    }
                    if let sel = selectedID, sel != node.id {
                        return node.color.opacity(0.4)
                    }
                    if let hov = hoveredID, hov == node.id {
                        return node.color.opacity(0.9)
                    }
                    return node.color.opacity(0.7)
                }()
                ctx.fill(Circle().path(in: rect), with: .color(dim))
                // 标签
                if node.label.count < 30 {
                    let txt = Text(node.label)
                        .font(.system(size: 9))
                        .foregroundColor(.primary)
                    ctx.draw(txt, at: CGPoint(x: p.x, y: p.y + r + 8))
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    // hit-test: 找最近的节点
                    let p = value.location
                    if let hit = hitTest(point: p, positions: positions) {
                        onTap(hit)
                    }
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hoveredID = hitTest(point: location, positions: positions)
            case .ended:
                hoveredID = nil
            }
        }
    }

    /// 找离 point 最近的节点 (返回 nil if 距离 > 30pt)
    private func hitTest(point: CGPoint, positions: [String: CGPoint]) -> String? {
        var bestID: String? = nil
        var bestDist: CGFloat = 30  // hit radius
        for (id, p) in positions {
            let dx = p.x - point.x
            let dy = p.y - point.y
            let d = sqrt(dx * dx + dy * dy)
            if d < bestDist {
                bestDist = d
                bestID = id
            }
        }
        return bestID
    }
}

/// P2-2: 图谱窗口 (sheet/inspector), 包含 GraphRenderer + 选中节点详情
@MainActor
public struct GraphWindow: View {
    public let graph: KnowledgeGraph
    public let memories: [String: Memory]  // id -> Memory
    public let onTap: (Memory) -> Void
    public let onDismiss: () -> Void

    @State private var selectedID: String? = nil
    @State private var hoveredID: String? = nil

    public init(graph: KnowledgeGraph,
                memories: [Memory],
                onTap: @escaping (Memory) -> Void,
                onDismiss: @escaping () -> Void) {
        self.graph = graph
        self.onTap = onTap
        self.onDismiss = onDismiss
        var map: [String: Memory] = [:]
        for m in memories { map[m.id] = m }
        self.memories = map
    }

    private var nodeVisuals: [GraphNodeVisual] {
        graph.nodes.sorted().map { id in
            let mem = memories[id]
            let size: CGFloat = {
                switch mem?.decayClass {
                case .slow: return 8
                case .normal: return 6
                case .fast: return 4
                case .none: return 5
                }
            }()
            let color: Color = {
                switch mem?.kind {
                case .entity: return .orange
                case .concept: return .blue
                case .synthesis: return .purple
                case .none: return .gray
                }
            }()
            let label = String((mem?.text ?? id).prefix(30))
            return GraphNodeVisual(id: id, label: label, size: size, color: color)
        }
    }

    private var edgeList: [GraphEdge] {
        var edges: [GraphEdge] = []
        for (u, neighbors) in graph.adjacency {
            for v in neighbors where u < v {
                edges.append(GraphEdge(u, v))
            }
        }
        return edges
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Knowledge Graph")
                        .font(AppFont.title3)
                    Text("\(graph.nodes.count) nodes · \(edgeList.count) edges")
                        .font(AppFont.caption)
                        .foregroundColor(AppColor.textSecondary)
                }
                Spacer()
                Button("Close") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Spacing.md)
            Divider()
            // Canvas
            GraphRenderer(
                nodes: nodeVisuals,
                edges: edgeList,
                area: CGSize(width: 760, height: 480),
                selectedID: $selectedID,
                hoveredID: $hoveredID
            ) { id in
                selectedID = id
                if let m = memories[id] { onTap(m) }
            }
            .frame(minWidth: 760, minHeight: 480)
            Divider()
            // Footer: 选中节点详情
            if let id = selectedID, let m = memories[id] {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(m.text)
                            .font(AppFont.body)
                            .lineLimit(3)
                        Text("id: \(m.id) · kind: \(m.kind.rawValue) · decay: \(m.decayClass.rawValue)")
                            .font(AppFont.caption2)
                            .foregroundColor(AppColor.textSecondary)
                    }
                    Spacer()
                    Button("Open") { onTap(m) }
                        .controlSize(.small)
                }
                .padding(Spacing.md)
            } else {
                HStack {
                    Text("Click a node to open it")
                        .font(AppFont.caption)
                        .foregroundColor(AppColor.textSecondary)
                    Spacer()
                }
                .padding(Spacing.md)
            }
        }
        .frame(width: 800, height: 600)
    }
}
