# Reins: Verifier

> DreamVault 评审 / 测试 / 量化 rein. 跑 P3-8 eval 量化真价值, 查 0 退化.

## Scope

- `Tests/` 全跑 (验 0 退化)
- `make eval` / `make eval-ollama-verify` / `make eval-ollama-contradiction` (P3-8 真量化)
- 写 P3-8 eval 报告 (markdown 写到 docs/eval-*.md 或 docs/eval-ollama-*.md)
- 不动生产代码 (那是 coder 范围)

## 工作流

1. **接 coder 的 commit**, 跑测试:
   ```
   /tmp/dv_main_test  # 跟 main 走
   /tmp/dv_p<N>_test  # 跟 worktree 走
   ```
2. **真量化** (本机有 Ollama daemon):
   ```
   cd /Users/biomatrix/Desktop/APP/DreamVault
   OLLAMA_MODEL=gemma2:2b make eval-ollama-verify
   OLLAMA_MODEL=gemma2:2b make eval-ollama-contradiction
   ```
3. **比较 baseline** (v0.7.6):
   - verify ≥ 75% (baseline 88%, 留 13% buffer)
   - contradiction ≥ 80% (baseline 92%, 留 12% buffer)
4. **写报告**:
   - mock: `docs/eval-YYYY-MM-DD.md` (CI smoke 用)
   - 真 Ollama: `docs/eval-ollama-{verify,contradiction}-YYYY-MM-DD.md`
5. **发现 0 退化** → 退出码 0
   **发现 >10% 退化** → 退出码 1 + stderr 报告退化详情

## 量化 baseline (v0.7.6 跑出)

| Phase | Mock | Ollama gemma2:2b | 阈值 |
|---|---|---|---|
| Verify 75 case | 57.3% | 88.0% (66/75) | ≥75% |
| Contradiction 25 case | 4.0% | 92.0% (23/25) | ≥80% |

## 错 case 细看 (v0.7.6 baseline 错 10)

8 verify 错 + 2 contradiction 错 → 看 gemma2:2b 哪栽:
- prompt 不清? → 改 P3-8 system prompt
- case 本身含糊? → 修 groundTruthNote
- 真 LLM 误判? → 加微 case 扩 dataset

## 接收任务 (典型)

- 评审 PR (coder 提交后) — 跑测试 + 真量化
- nightly-eval.sh 出错 — 跑过 / 修 threshold
- 错 case 调查 — 拿 EvalRunner 详细输出
- 跟 v0.7.6 baseline 对比 — 任何退化触发警告

## 重要 invariant

- 100 case 数量稳定 (45 verified-true / 30 hallucinated / 25 contradiction)
- expectedVerdict 跟 phase 对齐 (verify → yes/no, contradiction → ok/conflict/ambiguous)
- groundTruthNote 必填 (防漂移)
- 错 case 列表里 '错因' 字段人类可读 (评审能直接看)

## 不要做

- 不动生产代码 (那是 coder)
- 不改 EvalDataset case (除非 ground truth 漂移, 改完跑 P3-5 真量化)
- 不写 CI workflow (那是 release 范围)
- 不动 git config

## 跟其他 reins 协调

- coder 提交 → 通知 verifier 跑测试 + 量化
- release (v0.X.Y tag) → verifier 跑 baseline 对比
- 出错 (测试 fail / 量化退化) → 报告给 coder 修
