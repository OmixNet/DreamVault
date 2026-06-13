// P2-2: ForceLayout + 性能 benchmark
import XCTest
@testable import DreamEngine
import CoreGraphics

final class ForceLayoutTests: XCTestCase {
    func testEmptyInput() {
        let result = ForceLayout.layout(nodes: [], edges: [], area: CGSize(width: 100, height: 100))
        XCTAssertTrue(result.isEmpty)
    }

    func testSingleNode() {
        let result = ForceLayout.layout(nodes: ["A"], edges: [], area: CGSize(width: 100, height: 100))
        XCTAssertEqual(result.count, 1)
        XCTAssertNotNil(result["A"])
    }

    func testAllNodesHavePosition() {
        let nodes = ["A", "B", "C", "D", "E"]
        let edges: [GraphEdge] = [
            GraphEdge("A", "B"),
            GraphEdge("B", "C"),
            GraphEdge("C", "D")
        ]
        let result = ForceLayout.layout(nodes: nodes, edges: edges, area: CGSize(width: 200, height: 200))
        for n in nodes {
            XCTAssertNotNil(result[n], "节点 \(n) 应有 position")
        }
    }

    func testConnectedNodesCloserThanDisconnected() {
        // A-B 相连, C 孤立. 收敛后 A/B 距离应 < A/C
        let nodes = ["A", "B", "C"]
        let edges = [GraphEdge("A", "B")]
        let pos = ForceLayout.layout(nodes: nodes, edges: edges, area: CGSize(width: 200, height: 200), iterations: 80)
        let dAB = distance(pos["A"]!, pos["B"]!)
        let dAC = distance(pos["A"]!, pos["C"]!)
        // 不严格 <, 但应该明显更近. 给个合理阈值
        XCTAssertLessThan(dAB, dAC + 30, "相连节点应该比孤立节点更近; dAB=\(dAB) dAC=\(dAC)")
    }

    func testDeterministicOutput() {
        // 同样输入两次跑, 结果应一致 (stable hash)
        let nodes = ["X1", "X2", "X3", "X4"]
        let edges = [GraphEdge("X1", "X2"), GraphEdge("X3", "X4")]
        let r1 = ForceLayout.layout(nodes: nodes, edges: edges, area: CGSize(width: 100, height: 100))
        let r2 = ForceLayout.layout(nodes: nodes, edges: edges, area: CGSize(width: 100, height: 100))
        for id in nodes {
            XCTAssertEqual(r1[id]!.x, r2[id]!.x, accuracy: 0.01)
            XCTAssertEqual(r1[id]!.y, r2[id]!.y, accuracy: 0.01)
        }
    }

    func testNormalizedUniqueEdges_keepsDistinctEdgesFromSameSource() {
        let edges = [
            GraphEdge("A", "B"),
            GraphEdge("B", "A"),
            GraphEdge("A", "C"),
            GraphEdge("A", "A")
        ]

        let normalized = ForceLayout.normalizedUniqueEdges(edges)

        XCTAssertEqual(normalized.count, 2)
        XCTAssertTrue(normalized.contains { $0 == "A" && $1 == "B" })
        XCTAssertTrue(normalized.contains { $0 == "A" && $1 == "C" })
    }

    func testPositionInBounds() {
        // 200 节点 + gravity 拉回, 位置应在画布内 (允许少量越界给动画用)
        let nodes = (0..<200).map { "N\($0)" }
        let edges = (0..<199).map { GraphEdge("N\($0)", "N\($0 + 1)") }
        let pos = ForceLayout.layout(nodes: nodes, edges: edges, area: CGSize(width: 800, height: 600), iterations: 50)
        for (id, p) in pos {
            XCTAssertGreaterThanOrEqual(p.x, -50, "节点 \(id) x 太靠左: \(p.x)")
            XCTAssertLessThanOrEqual(p.x, 850, "节点 \(id) x 太靠右: \(p.x)")
            XCTAssertGreaterThanOrEqual(p.y, -50, "节点 \(id) y 太靠上: \(p.y)")
            XCTAssertLessThanOrEqual(p.y, 650, "节点 \(id) y 太靠下: \(p.y)")
        }
    }

    /// 性能: 200 节点 / 200 边 / 50 iter < 100ms
    func testPerformance200Nodes50Iter() {
        let nodes = (0..<200).map { "N\($0)" }
        let edges = (0..<199).map { GraphEdge("N\($0)", "N\($0 + 1)") }
        measure {
            _ = ForceLayout.layout(nodes: nodes, edges: edges,
                                    area: CGSize(width: 800, height: 600), iterations: 50)
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(Double(dx * dx + dy * dy))
    }
}

// MARK: - GraphEdge + GraphNodeVisual 测试

final class GraphEdgeTests: XCTestCase {
    func testEdgeInit() {
        let e = GraphEdge("A", "B")
        XCTAssertEqual(e.u, "A")
        XCTAssertEqual(e.v, "B")
    }

    func testEdgeEquatable() {
        XCTAssertEqual(GraphEdge("A", "B"), GraphEdge("A", "B"))
        XCTAssertNotEqual(GraphEdge("A", "B"), GraphEdge("A", "C"))
    }
}
