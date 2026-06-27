# Renamer - AI 编码助手项目指南

本文件面向不熟悉本项目的 AI 编码助手，记录项目结构、构建方式、代码约定与已知限制。所有内容均基于当前仓库实际文件与运行结果。

## 项目概述

**Renamer** 是一款纯原生 macOS 桌面应用，用于对单个或多个文件夹内的文件进行智能扫描、内容分析、命名建议与分类整理。

核心功能：

- 拖拽文件夹（或通过 `NSOpenPanel` 选择）到主窗口即可开始分析；也可从菜单栏图标快速触发。
- 递归并发扫描目录，跳过隐藏文件、包后代与常见系统目录，生成 `FileItem` 列表。
- 本地优先分析：文档用 `NaturalLanguage` 提取标题/实体；PDF 用 `PDFKit`、RTF 用 `NSAttributedString`、docx/iWork 用 Spotlight（`mdls`）回退提取文本；图片用 `ImageIO` 读取 EXIF/TIFF/GPS；视频用 `AVFoundation` 读取时长与元数据。
- 可选接入 OpenAI 兼容的云端大模型（DeepSeek / Kimi / OpenRouter / SiliconFlow）增强分析结果。
- 通过 SHA-256 内容哈希检测重复文件，预览中可选择每组保留项。
- 基于命名模板生成目标路径，支持 `{title}` `{date}` `{date:格式}` `{category}` `{source}` 令牌与动态子目录。
- 在 `PlanPreviewView` 中逐条预览、编辑目标路径、启用/禁用单项后执行复制或移动。
- 每次整理写入操作记录（`FileOperationRecord`），`RollbackService` 支持按记录回滚（当前无独立 UI 入口，记录用于安全留存与未来扩展）。
- 通过 `ExportPlugin` 协议预留导出能力，内置 `DEVONthinkPlugin`（AppleScript 桥接）。

## 技术栈

| 项目 | 说明 |
|------|------|
| 语言 | Swift 6（`Package.swift` 声明 `swift-tools-version: 6.0`） |
| UI 框架 | SwiftUI，适配 macOS 14+ |
| 构建工具 | Swift Package Manager（SPM） |
| 状态管理 | `@Observable`（Observation 框架） |
| 并发模型 | `async/await`、`TaskGroup`、`actor`、严格并发（`StrictConcurrency`） |
| 文档分析 | `NaturalLanguage`、`PDFKit` |
| 图片元数据 | `ImageIO` / CoreGraphics |
| 视频元数据 | `AVFoundation` |
| 哈希 | `CryptoKit`（SHA-256） |
| 系统元数据回退 | `/usr/bin/mdls`（Spotlight） |
| 最低系统 | macOS 14 |

## 项目结构

```
Renamer/
├── Package.swift                 # SPM 包配置
├── VERSION                       # 当前版本号（语义化版本）
├── README.md                     # 用户面向的中文说明
├── AGENTS.md                     # 本文件
├── .gitignore                    # 忽略 .build、dist 等
├── scripts/
│   └── package.sh                # 打包脚本：release → Renamer.app → .dmg
├── Sources/
│   ├── App/
│   │   ├── RenamerApp.swift      # @main 入口，WindowGroup + Settings + AppDelegate
│   │   └── MenuBarController.swift# 菜单栏状态项与弹出框
│   ├── Models/
│   │   ├── FileItem.swift        # 扫描得到的文件实体
│   │   ├── FileAnalysis.swift    # 单文件分析结果（标题/日期/分类/标签/来源/摘要/置信度）
│   │   ├── OrganizationPlan.swift # 整理计划（analyses + operations + duplicateGroups）
│   │   ├── PlanOperation.swift   # 单条整理操作（源/目标/导出目标/启用状态）
│   │   ├── OrganizationTask.swift # 可保存复用的任务定义
│   │   ├── NamingTemplate.swift  # 命名模板（文件夹模板 + 文件名模板）
│   │   ├── CloudConfiguration.swift # 云端服务配置
│   │   ├── DuplicateGroup.swift  # 一组内容相同的文件及保留项
│   │   ├── FileOperationRecord.swift # 整理操作记录（用于回滚）
│   │   └── SharedEnums.swift     # CopyOrMove / ExportTarget / AnalysisError
│   ├── Services/
│   │   ├── FileScanner.swift     # 递归并发扫描（actor，扫描逻辑 nonisolated）
│   │   ├── LocalAnalyzer.swift   # 设备端文本/图片/视频分析（nonisolated 并发）
│   │   ├── CloudAnalyzer.swift   # OpenAI 兼容云端增强
│   │   ├── DuplicateDetector.swift # SHA-256 重复检测（受限并发）
│   │   ├── NamingEngine.swift    # 模板解析与计划构建
│   │   ├── Organizer.swift       # 执行复制/移动并调度导出（actor）
│   │   ├── RollbackService.swift # 操作记录持久化与回滚（actor）
│   │   └── PluginManager.swift   # 导出插件调度（actor）
│   ├── ViewModels/
│   │   ├── MainViewModel.swift   # 主流程编排（@MainActor @Observable）
│   │   ├── SettingsViewModel.swift # 模板与云端设置，持久化到 Application Support
│   │   └── TaskListViewModel.swift # 已保存任务的增删改查
│   ├── Views/
│   │   ├── ContentView.swift     # 主界面：拖放区、整理方式、预览入口、任务列表
│   │   ├── PlanPreviewView.swift # 计划预览：重复组、逐条操作、执行
│   │   ├── TaskEditorView.swift  # 新建任务表单
│   │   ├── SettingsView.swift    # 设置（通用 / 模板 / AI 三个 Tab）
│   │   └── MenuBarPopover.swift  # 菜单栏弹出框 + 通知名定义
│   └── Plugins/
│       ├── ExportPluginProtocol.swift # 导出插件协议
│       └── DEVONthinkPlugin.swift     # DEVONthink AppleScript 导出
├── Tests/
│   └── RenamerTests/             # XCTest 单元与集成测试
└── dist/                         # 打包产物（gitignored）：Renamer.app / *.dmg
```

## 构建与运行

```bash
swift build              # 调试构建
swift run Renamer        # 命令行运行（GUI 在 .app 包内体验最完整）
swift build -c release   # 发布构建
./scripts/package.sh     # 打包为 dist/Renamer.app 与 dist/Renamer_v<版本>.dmg
```

也可用 Xcode 直接打开 `Package.swift` 开发、运行、测试。

## 测试

测试目标 `RenamerTests` 使用 `XCTest`。

```bash
swift test
```

**环境限制**：仅安装 CommandLineTools（未安装完整 Xcode）的机器上，`swift test` 会报 `no such module 'XCTest'`。需安装完整版 Xcode，或在 Xcode 中按 `⌘U` 运行。主程序 `swift build` 不受影响。

## 核心数据流

```
用户拖拽/选择文件夹
        │
        ▼
FileScanner.scan(folders:) ──► 并发扫描，返回 [FileItem]
        │
        ▼
LocalAnalyzer（并发，每文件）──► extractText + analyze ──► [FileAnalysis]
        │
        ├─（任务启用云端时）CloudAnalyzer.enhance ──► 限速增强 FileAnalysis
        ▼
DuplicateDetector.detectDuplicates ──► [DuplicateGroup]
        │
        ▼
NamingEngine.buildPlan ──► OrganizationPlan（跳过重复组中未保留项）
        │
        ▼
MainViewModel.plan ──► PlanPreviewView 预览（编辑/启停/选保留项）
        │
        ▼
Organizer.execute ──► 复制/移动 + 导出 ──► FileOperationRecord
        │
        ▼
RollbackService.save ──► 持久化记录（最多保留 50 条）
```

## 代码风格与约定

- **语言**：注释与文档以中文为主；标识符、类型名、API 用英文。
- **并发**：可变状态用 `actor` 隔离；纯计算/IO 标 `nonisolated` 以实现真正并发；模型普遍 `Sendable`。
- **错误处理**：自定义错误类型一律遵循 `LocalizedError` 并实现 `errorDescription`，以确保通过 `Error` 协议访问 `localizedDescription` 时能返回中文消息（普通 `Error` 的 `localizedDescription` 计算属性会被 NSError 桥接忽略）。
- **目录约定**：按职责分层（App / Models / Services / ViewModels / Views / Plugins），业务逻辑不写在 View 中。
- **持久化**：设置、任务、回滚记录统一存放于 `~/Library/Application Support/Renamer/`。

## 安全与权限注意事项

1. **文件系统权限**：应用未启用沙盒，通过 `NSOpenPanel`/拖放获得用户授权目录的访问权限。若未来启用沙盒，需使用安全书签（security-scoped bookmark）。
2. **写操作**：`Organizer` 为 `actor`，复制/移动串行执行；目标已存在的文件会被跳过并提示，不会覆盖。默认操作为「复制」，更安全。
3. **回滚**：`RollbackService.rollback(record:)` 已实现，但当前没有 UI 入口；记录用于安全留存与后续扩展。`.move` 操作目前需用户自行从目标目录移回。
4. **AppleScript**：`DEVONthinkPlugin` 通过 `NSAppleScript` 执行，所有插入脚本的字符串都经 `appleScriptEscape` 转义，避免脚本注入。
5. **API Key**：云端 API Key 目前以明文保存在 `Application Support/Renamer/settings.json`，后续应迁移到 Keychain。
6. **外部进程**：docx/iWork 文本提取调用 `/usr/bin/mdls`，设有 5 秒超时兜底，避免进程挂起。

## 已知限制与待完善项

- 回滚功能无独立 UI 入口（逻辑已就绪）。
- 云端 API Key 未进 Keychain。
- 主窗口拖放分析使用固定目标目录 `~/Documents/Renamer`；自定义目标需通过「新建任务」设置。
- `swift test` 在仅 CommandLineTools 环境下不可用。
- 应用包暂无自定义图标与代码签名/公证；首次打开需在「系统设置 → 隐私与安全性」中允许。

## 版本号规则

遵循语义化版本 **MAJOR.MINOR.PATCH**（见 `VERSION` 文件）：

- **MAJOR**：不兼容的行为或数据格式变更。
- **MINOR**：向后兼容的新功能。
- **PATCH**：向后兼容的缺陷修复。

发布流程：更新 `VERSION` → `./scripts/package.sh` → 提交并打 `vMAJOR.MINOR.PATCH` 标签。

## 添加新功能时的建议

- 新增文件分类：扩展 `LocalAnalyzer.inferLocalCategory(for:)`。
- 新增元数据源：在 `LocalAnalyzer.analyze(item:text:)` 的分支中扩展。
- 新增命名令牌：在 `NamingEngine.resolve(_:analysis:)` 中处理，并注意 `sanitize` 对路径分隔符的保留语义。
- 新增导出目标：实现 `ExportPlugin` 并注册到 `PluginManager`，同时扩展 `ExportTarget`。
- 修改文件系统写入逻辑后，补充测试或手动验证大目录、重名文件、目标已存在等边界。
