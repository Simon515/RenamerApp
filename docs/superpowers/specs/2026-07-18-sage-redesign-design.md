# Sage 设计文档 — 类 Hazel 的 LLM 文件自动化应用

日期：2026-07-18
状态：已与用户逐节确认，待最终审阅
前身：Renamer v1.x（手动批处理流程），本次为**完全推倒重写**，旧代码仅作参考

## 1. 定位与核心决策

**Sage** 是一款原生 macOS 应用：后台持续监控本地文件夹与 DEVONthink 位置，按用户定义的规则自动处理文件；LLM 作为规则引擎中的一等公民，既可做条件判断（语义分类），也可做动作（提取元数据、语义命名）。

经确认的关键决策：

| 决策点 | 结论 |
|---|---|
| 自动化模式 | 监控自动执行 + 手动批处理并存，共用同一条管线 |
| LLM 角色 | 条件与动作均可用；引擎本身是声明式的，LLM 只是条件/动作类型之一 |
| DEVONthink | 更强的导入动作（库/组/标签/备注/元数据）+ 监控 DT 内部条目并处理 |
| 界面组织 | 规则中心式：全局规则库，每条规则自行声明适用范围（非 Hazel 的文件夹中心式） |
| 确认机制 | 每规则可选「自动执行」或「先入确认队列」；删除类动作强制入队 |
| 重构策略 | 完全重写；架构方案为「声明式规则引擎 + 事件驱动流水线」 |
| 应用形态 | 菜单栏常驻 + 按需打开的主窗口，支持登录时启动 |
| LLM 接入 | OpenAI 兼容协议统一抽象，云端（DeepSeek/Kimi/OpenRouter/SiliconFlow）与本地（Ollama/LM Studio）同一实现；API Key 入 Keychain |
| 命名 | Sage（与 Hazel 同为植物名的致敬 +「智者」双关），Bundle ID `com.jiyuliang.Sage` |

后续版本方向（明确不在 v2.0 范围）：自然语言建规则（LLM 把一句话转译为结构化规则，用户可查看修正）、嵌套条件组。

## 2. 技术栈

Swift 6（StrictConcurrency）、SwiftUI、SPM、`@Observable`、macOS 14+。内容提取沿用系统框架：PDFKit、NaturalLanguage、ImageIO、AVFoundation、CryptoKit、mdls 回退。DT 交互经 NSAppleScript。

## 3. 总体架构

```
事件源层                 规则引擎               执行层
─────────               ─────────             ─────────
FolderWatcher(FSEvents) ┐
DTWatcher(轮询)          ├→ FileEvent → RuleEngine → ActionPlan ─┬→ 自动执行 ┐
ManualIntake(拖入/批量)  ┘             (作用域过滤→               └→ 确认队列 ┼→ ActionRunner
                                       条件按成本梯度求值)                     │  (本地FS / DTActions)
                                                                             └→ Journal(日志+回滚)
```

### 模块划分

```
Sources/
├── App/            # @main、AppDelegate、菜单栏常驻、登录启动
├── Domain/         # 纯数据模型：Rule、Condition、Action、RuleScope、FileEvent、
│                   #   FileFacts、ActionPlan、JournalRecord。全部 Codable + Sendable，
│                   #   零 I/O 依赖 —— 引擎求值可纯函数式单测
├── Engine/
│   ├── RuleEngine       # 事件 → 匹配规则 → ActionPlan
│   ├── ConditionEval    # 条件求值器，按成本梯度排序执行
│   └── ActionResolver   # 动作参数解析（模板令牌、LLM 提取结果填充）
├── Watchers/
│   ├── FolderWatcher    # FSEvents，含防抖与写入完成检测
│   ├── DTWatcher        # AppleScript 轮询 DT 指定组（默认 60s，可调）
│   └── ManualIntake     # 手动拖入 → 一次性批量 FileEvent
├── Extraction/     # 内容提取能力层：文本(PDFKit/NL/mdls)、图片 EXIF、视频元数据、
│                   #   SHA-256 哈希；结果按内容哈希缓存
├── LLM/
│   ├── LLMProvider      # OpenAI 兼容协议抽象（云端与本地端点同一实现）
│   ├── LLMGateway       # 限速、每日预算、按哈希缓存、失败降级；全部 LLM 调用唯一入口
│   └── Prompts          # 语义判断/元数据提取/命名的结构化 prompt（JSON 输出）
├── Execution/
│   ├── ActionRunner     # 本地 FS 动作（actor，串行写）
│   ├── DTActions        # DT 动作执行（AppleScript，字符串转义防注入）
│   ├── ConfirmQueue     # 待确认队列，持久化，崩溃不丢
│   └── Journal          # 操作日志 + 回滚（本版含 UI 入口）
├── Store/          # 规则库/设置/队列/日志持久化（Application Support）；API Key 入 Keychain
├── ViewModels/
└── Views/          # 规则中心、规则编辑器、确认队列、日志、设置、菜单栏 Popover
```

### 架构约束

- **Domain 无依赖**：条件匹配只依赖 `FileFacts`（描述文件的值类型，由 Extraction 填充），引擎测试不碰文件系统。
- **Watcher 只产事件不做判断**：三个事件源输出统一 `FileEvent`；手动批处理 = 一批事件，不是独立流程。
- **LLM 全部经 LLMGateway**：条件求值与动作解析不直接碰网络，限速/缓存/预算/降级集中一处。

## 4. 规则模型

```swift
Rule {
    id, name, enabled
    scopes: [RuleScope]        // 本地文件夹（含是否递归）/ DT 位置（库+组）/ 仅手动
    trigger: 监控自动 | 仅手动
    conditionLogic: all | any   // 单层，不做嵌套组
    conditions: [Condition]
    actions: [Action]           // 按序执行
    executionMode: 自动执行 | 先入确认队列
}
```

规则列表整体有序，决定匹配优先级。默认「首个匹配规则执行后停止」，规则可单独放行让后续规则继续匹配。

### 条件类型（三档成本，引擎自动按档排序求值）

| 档次 | 条件 | 说明 |
|---|---|---|
| 零成本 | 名称 / 扩展名 / 大小 / 创建·修改日期 / 种类(UTType) | 匹配方式：是、包含、正则、日期相对范围 |
| 内容提取 | 文本内容包含·正则、是重复文件(哈希)、EXIF 拍摄日期、来源 URL | 提取结果按哈希缓存 |
| LLM | 内容属于「分类」（返回 是/否+置信度）、内容符合自然语言描述 | 经 LLMGateway，结果按哈希缓存 |

零成本条件全部通过后才做内容提取；提取条件通过后才调 LLM——监控模式的成本控制由该结构保证。

### 动作类型

| 类别 | 动作 |
|---|---|
| 本地文件 | 移动到…、复制到…、重命名（模板令牌 `{title}` `{date}` `{date:格式}` `{category}` `{source}`，令牌值可指定由 LLM 提取）、加 Finder 标签、移到废纸篓（强制入确认队列） |
| DEVONthink | 导入到指定库/组（可同时写 DT 标签、备注=LLM 摘要、自定义元数据）、DT 内重命名、DT 内打标签、DT 内移动到组 |
| LLM 专属 | 提取元数据（标题/日期/分类/标签/摘要，供后续动作令牌引用）、语义重命名 |
| 控制 | 停止后续规则匹配（默认行为，可改为继续） |

## 5. DEVONthink 集成

- 所有 DT 动作经 `DTActions` 以 AppleScript 执行，插入脚本的字符串一律转义（沿用旧 `appleScriptEscape` 经验）。
- 导入动作返回 DT 记录 UUID，写入 Journal 供回滚（回滚 = 反向 AppleScript 删除该记录/撤销改动）。
- `DTWatcher` 轮询规则声明的 DT 组，以「已见记录 UUID + 修改时间」集合识别新条目；DT 内条目的 FileFacts 由 DT 记录属性 + 导出纯文本填充。
- DT 未运行：相关规则暂停，菜单栏图标提示，不弹错误；DT 恢复后自动续。

## 6. 界面设计

### 主窗口（规则中心式）

- **左栏导航**：规则（全部/按标签分组）、待确认队列（角标计数）、日志、监控源总览。
- **规则列表**：每行显示名称、作用域摘要、触发方式、最近命中时间；行内启停开关；拖拽排序即优先级；右键复制/导出（JSON）。
- **规则编辑器**（sheet）：Hazel 式条件行 + 动作行堆叠，每行「类型下拉 + 参数控件」；含 LLM 的行带 ✦ 标记；底部**试运行**：选样本文件即时预览匹配结果与动作产物，不实际执行——调试 LLM 规则的核心工具。
- **确认队列**：按规则分组，逐条显示「文件 → 动作 → 目标」；单条可编辑目标名/路径后批准；支持批量批准/拒绝。
- **日志**：全部执行记录，逐条可回滚。

### 菜单栏 Popover

监控总开关、待确认数、最近 10 条活动、拖放热区（拖入文件 → 选一条「仅手动」规则套用）。

## 7. 执行安全

1. 删除类动作强制入确认队列，不受规则设置影响。
2. 目标已存在不覆盖：默认自动加序号后缀，规则可改为「跳过并记日志」。
3. LLMGateway 每日调用预算（默认可关闭），超限后 LLM 相关规则自动暂停并通知。
4. FolderWatcher 写入完成检测：文件大小稳定 2 秒后才触发，避免处理下载中文件。
5. 新建含 LLM 动作的规则默认 executionMode 为「先入确认队列」。
6. 本地移动/重命名与 DT 导入均可从 Journal 回滚。

## 8. 错误处理

- LLM 失败（网络/超时/输出格式错误）：该文件挂起重试 3 次，仍失败进「需要注意」列表，不阻塞其他规则与文件。
- DT 未运行：相关规则暂停（见 §5）。
- 所有错误进日志，不弹窗轰炸；错误类型遵循 `LocalizedError` 返回中文消息（沿用旧仓库约定）。

## 9. 测试策略

- **Domain + Engine**：纯值类型，条件求值与动作解析 XCTest 全覆盖，伪造 FileFacts，不碰文件系统。
- **Extraction / Execution**：临时目录集成测试（沿用旧仓库测试经验）。
- **LLM**：`LLMProvider` 协议 mock，测 Gateway 的限速/缓存/降级逻辑。
- **DT 交互**：手动验证清单（DT 为外部应用，不做自动化测试）。

## 10. 持久化

`~/Library/Application Support/Sage/`：规则库（JSON）、设置、确认队列、Journal、提取与 LLM 结果缓存。API Key 存 Keychain。规则文件格式带版本号字段，为将来迁移留余地。
