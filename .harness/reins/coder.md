# Reins: Coder

> DreamVault Swift/SwiftPM 实现 rein. 处理生产代码改动 / 评审修复 / 重构.

## Scope

- `Sources/DreamEngine/` (引擎, 跨文件 dedup, 矛盾检测, 衰减, 图谱, 评测, embedding)
- `Sources/dream/` (CLI + GUI, 仅当用户明确同意或修编译错误)
- `Tests/DreamEngineTests/` + `Tests/DreamTests/`
- `Makefile` / `scripts/`
- **不**碰 `docs/changelog/` (那是 release rein)

## 工作流

1. **任何改动走 worktree**, 不直接在 main 编辑:
   ```
   git worktree add /private/tmp/dv-p<N> -b feat/p<N>-<topic> main
   ```
2. 创建 wrappers:
   ```
   cp /tmp/dv_p15_build /tmp/dv_p<N>_build
   cp /tmp/dv_p15_test /tmp/dv_p<N>_test
   sed -i '' 's|/tmp/dv-p15|/tmp/dv-p<N>|g' /tmp/dv_p<N>_build /tmp/dv_p<N>_test
   chmod +x /tmp/dv_p<N}_build /tmp/dv_p<N}_test
   ```
3. 编辑 (worktree 绝对路径) + build + test + 改到全 pass
4. `git add` + `git commit -m "..."` + merge to main
5. `git worktree prune` (P0/P1/P2 早期 worktree 走这个)

## Swift/SwiftPM gotchas

- **mavis bash shim corrupts `swift <cmd>`** — 必须走 wrappers
- **worktree 编辑必须用 worktree 路径** — Edit 工具不感知 worktree
- **Swift 6 Set 迭代顺序非确定** — 测试断言双边
- **Swift 6 closure + labeled tuple** — 解构 tuple, 别用 `$0.a` 严格匹配
- **mavis-trash 一次一文件** + 绝对路径
- **NLEmbeddingProvider dim=0 (不可用) → 走 P3-6 老 token/AA 路径自动降级**
- **EmbeddingProvider 阈值 0.85** (vs 0.7 — NLEmbedding 整体偏高)

## 重要 invariant (不能破坏)

- `DecayConfig` / `EmbeddingProvider` / `LLMProvider` 协议不变
- `Memory` init 字段签名: `inboundLinks: Int = 0`, `MemoryStatus` 无 `.draft` (用 `.candidate`)
- `ProductionReadinessTests` 全绿 (ship 门槛)
- 0 退化: 改前后 `swift test` 数一致 (623 baseline)
- `make eval` (mock) 100 case 跑通

## 不要做

- 不要 `git push --force` / `git reset --hard` (除非用户明确要求)
- 不要 amend 老 commit (除非用户明确要求或 pre-commit hook auto-modify)
- 不要 `--no-verify` 跳过 hooks
- 不要直接编辑 `Sources/dream/` 当 user uncommit 改动还在时 (会撞车)
- 不要把 8h 用户改动混进 Mavis commit (走 biomatrix 身份)

## 接收任务 (典型)

- 评审修复 (P3-N) → 走 worktree → 改 + 测试 → commit → merge → tag
- 8h 用户 review 漏的 bug → 走 worktree → fix + test → commit (用户身份) → merge
- frontend 整理 (跟 GlobalOptions.llmProvider() 协调) → 走 worktree
- 重构 (RuntimeContext 等) → 走 worktree, 保持向后兼容 (老 API 不破)

## 汇报格式

完成后给用户:
- tag 编号 (v0.X.Y)
- 测试数 (e.g. 623/623 pass)
- 真量化数字 (如跑了)
- 踩坑 (memory 写一条)
- 提交 commit 链接 (git log --oneline)
