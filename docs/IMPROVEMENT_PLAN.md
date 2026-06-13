# DreamVault v0.5–v0.7 整改方案（产品视角）

> 定位：个人/小圈子 Mac 原生工具。不上 App Store，不做合规项，一切以「日常真用得爽」为唯一验收标准。
> 基线：v0.4.0（2026-06-12 审核通过：8 项内核能力齐备、可编译、有 DMG）。
> 原则：先修「每天都碰到的痛」，再做「看得见的美」，最后做「锦上添花」。任何一项没有可量化验收标准就不进排期。

---

## 0. 现状一句话评估

内核算法骨架完整且超出同类业余项目水准，但有三类债：**成本债**（矛盾检测 O(N×M) LLM 调用，规模化必炸）、**回路债**（衰减算法的"强化"信号没接到真实使用行为）、**体验债**（GUI 是工程师审美，"扔文件进来"这一核心承诺甚至没有拖拽入口）。

---

## 1. P0 — 不修就别发 v0.5（预计 1.5 周）

### P0-1 后端｜矛盾检测成本失控

- **问题**：`ContradictionDetector.link` 对每条新教训 × 每条 durable 各打一次 LLM。durable 到 300 条、一晚 10 条新教训时 = 3000 次调用，本地 Ollama 跑一夜跑不完。
- **方案**：两级漏斗。第一级零成本预筛——仅当两条记忆共享 KnowledgeGraph 邻居、或文本关键词（实体名）有交集时才进第二级；第二级才调 LLM。预筛逻辑放进 `ContradictionDetector`，加 `maxPairsPerNight` 上限（默认 50，超出写入 report 提示「未比对完，明晚继续」）。
- **验收**：durable=500、新教训=10 时，单晚 LLM 比对调用 ≤ 50 次；现有矛盾检测单测全绿，新增预筛单测 ≥ 6 个。

### P0-2 后端｜「强化重置曲线」回路未闭环

- **问题**：spec 核心思想是"被访问、被确认即重置衰减曲线"，但 `reinforceCount`/`lastAccess` 目前没有任何 UI 行为会更新——衰减只有下坡没有上坡，跑两个月所有记忆都会滑向 archive。
- **方案**：三个强化触发点回写 ledger：① 编辑器打开某条 durable 的 wiki 页；② 搜索结果点击命中；③ dream 时新教训引用了同一 raw 源。统一走一个 `Reinforcer` 类型，防抖（同一天多次访问只记 1 次）。
- **验收**：打开 wiki 页后 `ledger.json` 中该条 `lastAccess` 更新、`reinforceCount` +1；同日重复打开不重复计数；集成测试覆盖三个触发点。

### P0-3 后端｜回读校验防不住「编造 excerpt」

- **问题**：三段 CoT 的来源真实性闸只校验 `sourceFile` 文件名相同，不校验 `sourceExcerpt` 是否真的出现在该文件里。LLM 可以引用真文件 + 假片段，verify 自我校验时再骗自己一次。
- **方案**：加一道**确定性**闸门（不调 LLM）：`sourceExcerpt` 归一化空白后必须是 raw 源文件内容的子串，否则丢弃该 draft 并计入 report 的 `rejected_fabricated` 计数。
- **验收**：构造假 excerpt 的单测必须被拦截；真实 Ollama 跑 20 个候选，report 中可见该计数字段。

### P0-4 前端｜核心承诺缺失：拖拽进 raw/

- **问题**：架构文档说 GUI 三件事之首是「扔文件进来」，但 VaultBrowser 没有任何导入入口——用户得开 Finder 手动拷贝。
- **方案**：① VaultBrowser 接受 `.md/.txt` 拖拽，落到 `raw/` 并自动加 `processed: false` frontmatter；② 菜单 File → Import to raw…（Cmd-I）；③ 拖入重名文件自动加日期后缀，绝不覆盖。
- **验收**：从 Finder 拖 3 个文件进侧栏，raw/ 出现 3 个带正确 frontmatter 的文件，文件树即时刷新；重名不覆盖。

### P0-5 前端｜Rollback 无确认

- **问题**：DreamPanel 的 Rollback 是 destructive 按钮，一键就 revert 上一次 dream commit，误触即丢当晚成果，且无任何对话框。
- **方案**：confirmationDialog 列出将被回滚的 commit message + 影响文件数，二次确认才执行。
- **验收**：点击 Rollback 必先弹确认；取消无副作用。

---

## 2. P1 — v0.5 主体（预计 3 周）

### 后端算法

| # | 项 | 问题与方案 | 验收标准 |
|---|---|---|---|
| P1-1 | 三段 CoT 默认值矛盾 | `productionDefault` 注释称"3 段 + 4 并发"，实际 `useThreeStepCoT=false, concurrency=2`。产品决策：接真实 LLM（Ollama/云）时默认**开**三段，mock 走两段；修正注释 | 配置真实 provider 后首次 dream 即走三段，report 标注所用流水线 |
| P1-2 | 图谱信号 1/4 → 3/4 | 现仅「来源重叠」连边。补：① wiki 正文 `[[wikilink]]` 显式链接（WikilinkIndex 已有解析，接上即可）；② 类型亲和度（同 kind 边权 ×1.2）。边引入权重，Adamic-Adar 改加权版 | 同一记忆的 topRelated 在加信号前后可对比（写进 report）；单测覆盖加权打分 |
| P1-3 | 脱敏误伤治理 | 信用卡规则加 Luhn 校验、身份证加校验位验证、IP 白名单 127.0.0.1/0.0.0.0、版本号上下文豁免（前缀 v/version） | 误伤回归集（20 条正常文本 0 命中、20 条敏感文本全命中）进单测 |
| P1-4 | LLM JSON 输出加约束 | analyze/generate 步对 Ollama 启用 structured output（`format` + JSON schema），从源头减少解析失败而非靠 fallback | 真实模型 50 次调用解析失败率 < 5%（现状先测出基线写进 report） |
| P1-5 | wiki 页 diff-aware 写入 | 现在每晚全量重写所有 durable 页，git log 全是噪音 commit diff。改为内容无变化不落盘 | 连续两晚无新输入时，第二晚 commit 仅含 ledger/report，无 wiki 页变更 |

### 前端体验

| # | 项 | 问题与方案 | 验收标准 |
|---|---|---|---|
| P1-6 | 文件树性能与正确性 | `rawFiles()/wikiFiles()` 在 body 里同步做磁盘 IO，每次重绘都扫盘；外部改文件不刷新。改为 FSEventStream 监听 + 缓存模型 | 1000 文件 vault 下侧栏滚动不掉帧；终端里 touch 新文件 1s 内出现在树中 |
| P1-7 | Report 阅读体验 | dream-report 用等宽纯文本展示。改用已有 MarkdownRenderer 渲染，关键数字（accepted/archived/needsReview）做成顶部彩色统计卡片 | report 标题/列表/链接正常渲染，统计卡片与 report 数字一致 |
| P1-8 | 矛盾裁决重做 | ConflictResolutionView 挤在 340pt 右栏。改独立 sheet：左右并排两条记忆 + 各自来源 excerpt + 三按钮（保留 A / 保留 B / 都保留并解除链接），可点击跳转 raw 源 | 一次裁决 ≤ 3 次点击；裁决后 ledger 双向 contradicts 同步清理 |
| P1-9 | 中英文案统一 | UI 当前中英混杂（"raw 候选" vs "Run Dream"）。建 Localizable.strings，zh-Hans 全量 + en 全量，默认跟系统 | 全部用户可见字符串走本地化表；切系统语言后无残留混杂 |
| P1-10 | 侧栏右键菜单 | 文件行无上下文菜单。加：在 Finder 中显示 / 重命名 / 复制相对路径 / 移到废纸篓（raw 文件除外，灰显并提示只读层） | raw 文件的删除项灰显；其余操作可用且文件树即时刷新 |

---

## 3. P2 — v0.6/v0.7 亮点（预计 3–4 周，按价值排序）

1. **菜单栏常驻 + 夜间通知**（个人工具最高频触点）：menu bar extra 显示月亮图标 + 上次 dream 状态；夜间跑完发系统通知「3 条新教训，1 条待裁决」，点击直达 DreamPanel。验收：通知点击深链正确。
2. **知识图谱可视化**：SwiftUI Canvas 力导向图，节点按 kind 着色、边粗细 = Adamic-Adar 分、点节点开对应 wiki 页。先做只读，不做编辑。验收：200 节点 60fps。
3. **编辑器升级**：source 模式 wikilink/标题/代码块语法高亮（NSTextStorage delegate 即可，不引第三方）；`[[` 触发 wiki 页名自动补全（WikilinkIndex 已有数据）。
4. **偶然唤回（serendipity）**：dream 报告尾部抽 1 条 archived 记忆「你可能忘了这个」，spec 里的趣味功能，成本一行随机数。
5. **视觉系统统一**：定义 spacing/字号/图标 token（一个 `DesignTokens.swift`），统一 SF Symbols 风格（现 fill/outline 混用）；暗色模式逐屏走查。
6. **搜索升级**：mdfind 依赖 Spotlight、搜不到 .dream 隐藏目录。改 ripgrep 子进程或内置简易倒排索引，结果片段高亮关键词，支持 frontmatter 字段过滤（`kind:concept`）。

---

## 4. 明确不做（个人工具定位的纪律）

沙盒化与 App Store 合规、多人协作/同步服务、iOS 伴生 App、插件系统、主题市场、向量数据库/embedding 检索（除非 P0-1 预筛被证明不够用，再评估本地 embedding）。

---

## 5. 里程碑与度量

- **M1（第 2 周末，v0.5-beta）**：P0 全清。门禁：全测试绿 + 真实 Ollama 连跑 3 晚无失败。
- **M2（第 5 周末，v0.5）**：P1 全清。门禁：自用 vault（≥200 raw 文件）日常使用 1 周，矛盾裁决/拖拽导入/报告阅读三条路径无障碍。
- **M3（第 9 周末，v0.6）**：P2 前 3 项。门禁：菜单栏通知点击率（自用统计）、图谱可视化 200 节点性能达标。

**北极星指标**（个人工具就一条）：每周打开 MEMORY.md / wiki 页查阅的次数。整改若不能让这个数字上升，说明做的是伪需求，砍掉重排。

## 6. 风险

最大风险是 P1-2/P2-2 这类「工程师觉得酷」的图谱功能挤占 P0 排期——严格按本文件顺序执行，P0 未清不开 P1。其次是真实 LLM 行为与 mock 偏差（P1-4 的失败率基线先测再改）。回滚保障已有（git 事务边界），所有整改不改变该机制。
