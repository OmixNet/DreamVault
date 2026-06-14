# DreamVault P3-8 金标评测报告

评测时间: 2026-06-14T04:35:44Z
评测 case 数: 25

## 总计

- Accuracy: **96.0%** (24/25)
- P = R = F1 = **96.0%** (binary 评测, 见下 TODO)
- Ambiguous 预测数: 0 (LLM 返模糊响应, 当错算)

## 按 phase 拆

### verify 闸

- 样本数: 0
- Accuracy: **nan%**
- Ambiguous: 0

### contradiction 闸

- 样本数: 25
- Accuracy: **96.0%**
- Ambiguous: 0

## 按 category 拆

### verifiedTrue (0 case)

- Accuracy: **nan%**
- Ambiguous: 0

### hallucinated (0 case)

- Accuracy: **nan%**
- Ambiguous: 0

### contradictionPair (25 case)

- Accuracy: **96.0%**
- Ambiguous: 0

## 错 case 详情 (1)

| ID | Category | Expected | Predicted | 错因 |
|----|----------|----------|-----------|------|
| C-25 | contradictionPair | OK | CONFLICT | 主题相关但不矛盾 — A 说同 source file 内 Adamic-Adar, B 说跨 source file embedding. 两个独立信号互补. 应 OK. |

## 全 case 结果

| ID | Phase | Category | Expected | Predicted | ✓ |
|----|-------|----------|----------|-----------|---|
| C-01 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-02 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-03 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-04 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-05 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-06 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-07 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-08 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
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
