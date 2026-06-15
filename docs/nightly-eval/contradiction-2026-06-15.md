# DreamVault P3-8 金标评测报告

评测时间: 2026-06-15T15:57:53Z
评测 case 数: 25

## 总计

- Accuracy: **88.0%** (22/25)
- P = R = F1 = **88.0%** (binary 评测, 见下 TODO)
- Ambiguous 预测数: 2 (LLM 返模糊响应, 当错算)

## 按 phase 拆

### verify 闸

- 样本数: 0
- Accuracy: **nan%**
- Ambiguous: 0

### contradiction 闸

- 样本数: 25
- Accuracy: **88.0%**
- Ambiguous: 2

## 按 category 拆

### verifiedTrue (0 case)

- Accuracy: **nan%**
- Ambiguous: 0

### hallucinated (0 case)

- Accuracy: **nan%**
- Ambiguous: 0

### contradictionPair (25 case)

- Accuracy: **88.0%**
- Ambiguous: 2

## 错 case 详情 (3)

| ID | Category | Expected | Predicted | 错因 |
|----|----------|----------|-----------|------|
| C-02 | contradictionPair | CONFLICT | AMBIGUOUS | 同一主题 (同质合并阈值), 不可调和 (0.6 vs 0.85 不同方法). 应 conflict (评审: 评审发现阈值不同时也矛盾). |
| C-08 | contradictionPair | CONFLICT | AMBIGUOUS | 同一主题 (矛盾检测复杂度), 不可调和 (O(N×M) vs O(top-k)). 应 conflict. |
| C-25 | contradictionPair | OK | CONFLICT | 主题相关但不矛盾 — A 说同 source file 内 Adamic-Adar, B 说跨 source file embedding. 两个独立信号互补. 应 OK. |

## 全 case 结果

| ID | Phase | Category | Expected | Predicted | ✓ |
|----|-------|----------|----------|-----------|---|
| C-01 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-02 | contradiction | contradictionPair | CONFLICT | AMBIGUOUS | ❌ |
| C-03 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-04 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-05 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-06 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-07 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-08 | contradiction | contradictionPair | CONFLICT | AMBIGUOUS | ❌ |
| C-09 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-10 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-11 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-12 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-13 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-14 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-15 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-16 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-17 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-18 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-19 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-20 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-21 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-22 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-23 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-24 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-25 | contradiction | contradictionPair | OK | CONFLICT | ❌ |
