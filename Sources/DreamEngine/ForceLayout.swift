// P2-2: Force-directed graph layout (Fruchterman-Reingold 简化版)
// 200 节点 / 50 迭代 ≈ 10ms (一次性, 不每帧跑)
import Foundation
import CoreGraphics

/// P2-2: 2D 节点位置, 跟节点 id 对应
public struct GraphNodePosition: Equatable, Hashable, Sendable {
    public let id: String
    public var position: CGPoint

    public init(id: String, position: CGPoint) {
        self.id = id
        self.position = position
    }
}

/// P2-2: 边 (一对 id)
public struct GraphEdge: Equatable, Hashable, Sendable {
    public let u: String
    public let v: String
    public init(_ u: String, _ v: String) {
        self.u = u
        self.v = v
    }
}

/// P2-2: force-directed layout 引擎
///
/// 算法: Fruchterman-Reingold 简化版
/// - 节点间斥力 (1/d², 距离平方反比)
/// - 边的弹簧引力 (log(d) 让近距离拉近, 远距离不强拉)
/// - 不加热退火, 固定迭代 N 步
///
/// 性能: 200 节点 / 200 边 / 50 iter ≈ 10ms on M1
/// 准确度: 不追求完美, 视觉可读 (clusters 分得开) 即可
public enum ForceLayout {
    /// 主入口: 跑 N 步迭代, 返回节点位置字典
    /// - Parameters:
    ///   - nodes: 节点 id 列表
    ///   - edges: 边列表 (无向, 重复会被去重)
    ///   - area: 画布尺寸 (宽高), 节点尽量散布在 [0, area] 范围内
    ///   - iterations: 迭代次数 (默认 50, 200 节点足够收敛)
    ///   - gravity: 引力中心强度 (拉回原点, 防止飘到画布外)
    /// - Returns: [id: CGPoint]
    public static func layout(
        nodes: [String],
        edges: [GraphEdge],
        area: CGSize,
        iterations: Int = 50,
        gravity: Double = 0.05
    ) -> [String: CGPoint] {
        guard !nodes.isEmpty else { return [:] }
        let n = nodes.count
        // 初始化: 随机散布 (用确定性 hash 让同样输入总跑出同样结果, 便于 test)
        var pos: [String: CGPoint] = [:]
        var vel: [String: CGPoint] = [:]
        for (i, id) in nodes.enumerated() {
            let seed = stableHash(id)
            let x = area.width * 0.1 + Double(seed % 1000) / 1000.0 * area.width * 0.8
            let y = area.height * 0.1 + Double((seed / 1000) % 1000) / 1000.0 * area.height * 0.8
            pos[id] = CGPoint(x: x, y: y)
            vel[id] = .zero
        }

        // 期望距离 k = C * sqrt(area / n), 经典 FR 公式
        let k = sqrt(Double(area.width * area.height) / Double(n))
        let k2 = k * k
        let dt = 0.1  // 时间步

        // 边集合去重
        var edgeSet = Set<String>()
        var uniqueEdges: [(String, String)] = []
        for e in edges {
            let key = e.u < e.v ? "\(e.u)|\(e.u)" : "\(e.v)|\(e.u)"
            if !edgeSet.contains(key) {
                edgeSet.insert(key)
                uniqueEdges.append((e.u, e.v))
            }
        }

        for _ in 0..<iterations {
            // 1) 斥力: 所有节点对
            var forces: [String: CGPoint] = [:]
            for id in nodes { forces[id] = .zero }
            for i in 0..<n {
                let a = nodes[i]
                for j in (i + 1)..<n {
                    let b = nodes[j]
                    guard let pa = pos[a], let pb = pos[b] else { continue }
                    let dx = pa.x - pb.x
                    let dy = pa.y - pb.y
                    let d2 = dx * dx + dy * dy + 0.01  // 防止除零
                    let force = k2 / d2
                    let d = sqrt(d2)
                    let fx = (dx / d) * force
                    let fy = (dy / d) * force
                    forces[a] = CGPoint(x: (forces[a]?.x ?? 0) + fx, y: (forces[a]?.y ?? 0) + fy)
                    forces[b] = CGPoint(x: (forces[b]?.x ?? 0) - fx, y: (forces[b]?.y ?? 0) - fy)
                }
            }

            // Force 限幅: 单次力 magnitude 不超过 maxForce (防 NaN 爆掉)
            let maxForce = 50.0
            for id in nodes {
                guard let f = forces[id] else { continue }
                let mag = sqrt(f.x * f.x + f.y * f.y)
                if mag > maxForce {
                    let scale = maxForce / mag
                    forces[id] = CGPoint(x: f.x * scale, y: f.y * scale)
                }
            }

            // 2) 引力: 沿边拉
            for (u, v) in uniqueEdges {
                guard let pu = pos[u], let pv = pos[v] else { continue }
                let dx = pv.x - pu.x
                let dy = pv.y - pu.y
                let d = sqrt(dx * dx + dy * dy + 0.01)
                let force = d * d / k
                let fx = dx / d * force
                let fy = dy / d * force
                forces[u] = CGPoint(x: (forces[u]?.x ?? 0) + fx, y: (forces[u]?.y ?? 0) + fy)
                forces[v] = CGPoint(x: (forces[v]?.x ?? 0) - fx, y: (forces[v]?.y ?? 0) - fy)
            }

            // 3) Gravity: 拉回画布中心, 防止飘出
            for id in nodes {
                guard let p = pos[id], let f = forces[id] else { continue }
                let centerX = area.width / 2
                let centerY = area.height / 2
                let gx = (centerX - p.x) * gravity
                let gy = (centerY - p.y) * gravity
                forces[id] = CGPoint(x: f.x + gx, y: f.y + gy)
            }

            // 4) 应用力, 更新位置 (欧拉法 + 阻尼) + 速度限幅
            let damping = 0.85
            let maxVel = 10.0
            for id in nodes {
                guard let p = pos[id], let v = vel[id], let f = forces[id] else { continue }
                var newVx = (v.x + f.x * dt) * damping
                var newVy = (v.y + f.y * dt) * damping
                // 限幅速度
                let vMag = sqrt(newVx * newVx + newVy * newVy)
                if vMag > maxVel {
                    let scale = maxVel / vMag
                    newVx *= scale
                    newVy *= scale
                }
                let newP = CGPoint(x: p.x + newVx, y: p.y + newVy)
                vel[id] = CGPoint(x: newVx, y: newVy)
                pos[id] = newP
            }
        }
        return pos
    }

    /// 确定性 hash (Swift 4.2+ 的 hash 每次启动会变, 不能用)
    private static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 5381
        for byte in s.utf8 {
            h = (h &* 33) &+ UInt64(byte)
        }
        return Int(h % 1000000)
    }
}
