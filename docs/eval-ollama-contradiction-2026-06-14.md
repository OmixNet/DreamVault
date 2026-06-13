# DreamVault P3-8 金标评测报告

评测时间: 2026-06-13T23:54:36Z
评测 case 数: 25

## 总计

- Accuracy: **92.0%** (23/25)
- P = R = F1 = **92.0%** (binary 评测, 见下 TODO)
- Ambiguous 预测数: 1 (LLM 返模糊响应, 当错算)

## 按 phase 拆

### verify 闸

- 样本数: 0
- Accuracy: **nan%**
- Ambiguous: 0

### contradiction 闸

- 样本数: 25
- Accuracy: **92.0%**
- Ambiguous: 1

## 按 category 拆

### verifiedTrue (0 case)

- Accuracy: **nan%**
- Ambiguous: 0

### hallucinated (0 case)

- Accuracy: **nan%**
- Ambiguous: 0

### contradictionPair (25 case)

- Accuracy: **92.0%**
- Ambiguous: 1

## 错 case 详情 (2)

| ID | Category | Expected | Predicted | 错因 |
|----|----------|----------|-----------|------|
| C-19 | contradictionPair | CONFLICT | AMBIGUOUS | 同主题 (fast effectiveStaleDays), 27 vs 90 不可调和. P3-7 修复后 fast=27, 老代码=90. 应 conflict. |
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
| C-19 | contradiction | contradictionPair | CONFLICT | AMBIGUOUS | ❌ |
| C-20 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-21 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-22 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-23 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-24 | contradiction | contradictionPair | CONFLICT | CONFLICT | ✅ |
| C-25 | contradiction | contradictionPair | OK | CONFLICT | ❌ |
