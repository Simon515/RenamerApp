# Renamer - AI 编码助手项目指南

本文件面向不熟悉本项目的 AI 编码助手，记录项目结构、构建方式、代码约定与已知问题。所有内容均基于当前仓库实际文件与运行结果，不包含未实现的规划功能。

## 项目概述

**Renamer** 是一款纯原生 macOS 桌面应用，用于对单个或多个文件夹内的文件进行智能扫描、重命名建议和分类整理。

核心功能：

- 拖拽或 `NSOpenPanel` 选择多个文件夹。
- 递归扫描目录，生成文件列表并自动分类。
- 对文档类文件使用设备端 `NaturalLanguage` 框架提取主题关键词，生成重命名建议。
- 对图片/视频文件使用 `ImageIO` / `AVFoundation` 提取 EXIF、拍摄日期、相机型号、时长等元数据。
- 重命名前在 UI 中预览，支持逐条确认、拒绝或手动编辑。
- 批量重命名后可按分类（Documents / Images / Videos / Archives / Applications / Others）自动整理到子目录。
- 预留导出插件协议与 AppleScript 桥接，用于未来对接 DEVONthink、Photos.app 等外部应用。

> 注意：项目 README 和部分注释中提到的功能（例如完全可用的回滚、导出到 DEVONthink、自动监控等）可能尚未完整实现，当前实现状态请直接阅读源码。

## 技术栈

| 项目 | 说明 |
|------|------|
| 语言 | Swift 6.3（Package.swift 声明 `swift-tools-version: 6.0`） |
| UI 框架 | SwiftUI，适配 macOS 14+ |
| 构建工具 | Swift Package Manager（SPM） |
| 状态管理 | Swift 6 `@Observable`（Observation 框架） |
| 并发模型 | `async/await`、`TaskGroup`、`actor`、严格并发模式（`StrictConcurrency`） |
| 文件类型识别 | `UniformTypeIdentifiers`（UTType）+ 扩展名回退 |
| 文档分析 | `NaturalLanguage`、`PDFKit` |
| 图片元数据 | `ImageIO` / CoreGraphics（EXIF/TIFF/GPS） |
| 视频元数据 | `AVFoundation` |
| 系统元数据回退 | `/usr/bin/mdls`（Spotlight） |
| 最低系统 | macOS 14 |

## 项目结构

```
Renamer/
├── Package.swift                 # SPM 包配置
├── README.md                     # 用户面向的中文说明
├── AGENTS.md                     # 本文件
├── .gitignore                    # 忽略 .build、dist、.kunsdd、Xcode 产物等
├── Sources/
│   ├── App/
│   │   └── RenamerApp.swift      # @main 入口，WindowGroup + Settings
│   ├── Models/
│   │   ├── FileItem.swift        # 文件实体（Identifiable、Sendable、Hashable）
│   │   ├── RenameSuggestion.swift # 重命名建议（原名、建议名、置信度、理由、确认/拒绝状态）
│   │   ├── FileCategory.swift    # 文件分类枚举
│   │   └── ProcessingResult.swift # 批量处理结果 + 导出目标描述
│   ├── Services/
│   │   ├── FileScanner.swift     # 递归并发扫描目录
│   │   ├── FileTypeDetector.swift # 基于 UTI 与扩展名判定分类并过滤系统文件
│   │   ├── MetadataService.swift # 图片/视频/通用元数据提取与重命名建议生成
│   │   ├── AIRenameService.swift # 文档文本提取 + NL 主题/实体/关键词分析
│   │   ├── RenameEngine.swift    # 校验、执行重命名与回滚（actor）
│   │   ├── ClassificationService.swift # 按分类移动/复制文件到子目录（actor）
│   │   └── BatchProcessor.swift  # 编排扫描 → 分析 → 生成建议的流水线
│   ├── ViewModels/
│   │   └── MainViewModel.swift   # @MainActor @Observable 主视图状态
│   ├── Views/
│   │   ├── ContentView.swift     # 主界面：拖拽区、预览列表、结果页
│   │   └── SettingsView.swift    # 设置面板（当前为占位 Tab）
│   ├── Plugins/
│   │   ├── ExportPluginProtocol.swift # 导出插件协议 + 内置 FolderSortPlugin
│   │   └── AppleScriptBridge.swift    # AppleScript 通用执行器
│   └── Resources/                # 资源目录（当前仅 .gitkeep）
├── Tests/
│   └── RenamerTests/
│       └── RenamerTests.swift    # 单元测试（依赖 XCTest）
└── dist/
    ├── Renamer.app/              # 已构建的 macOS 应用包（v0.0.1）
    └── Renamer_v0.0.1.dmg        # 已生成的分发镜像
```

## 构建与运行

### 命令行

```bash
# 调试构建
swift build

# 运行
swift run Renamer

# 发布构建（生成 .app 与 .dmg 需要额外打包步骤）
swift build -c release
```

构建产物位于 `.build/debug/` 或 `.build/release/`。

### Xcode

可直接通过 Xcode 打开 `Package.swift` 进行开发、运行和测试。

### 已发布产物

仓库 `dist/` 目录下已包含：

- `dist/Renamer.app` —— 构建好的 macOS 应用。
- `dist/Renamer_v0.0.1.dmg` —— 用于分发的磁盘镜像。

这些产物为历史生成，日常开发变更后需重新打包。

## 测试

测试目标 `RenamerTests` 位于 `Tests/RenamerTests/`，使用 `XCTest` 框架。

```bash
swift test
```

**当前问题**：在仅安装 CommandLineTools 的环境下，`swift test` 会报 `no such module 'XCTest'` 错误。需要在完整版 Xcode（而不仅是 CommandLineTools）中运行测试，或在 Xcode 中执行 `⌘+U`。

测试覆盖范围（当前）：

- `FileCategory` 枚举的基本属性。
- `FileTypeDetector` 基于扩展名的分类判定。
- `FileItem` 与 `RenameSuggestion` 模型初始化与计算属性。
- `FileTypeDetector.shouldExclude` 对隐藏文件与系统目录的过滤。
- `ProcessingResult` 初始状态。

## 核心数据流

```
用户选择/拖拽文件夹
        │
        ▼
FileScanner.scanFolders() ──► 并发扫描多个目录
        │
        ▼
FileTypeDetector.detectCategory() ──► 文件分类
        │
        ├── 文档类 ──► AIRenameService.generateSuggestions() ──► RenameSuggestion
        ├── 图片类 ──► MetadataService.extractMetadata() ──► RenameSuggestion
        ├── 视频类 ──► MetadataService.extractMetadata() ──► RenameSuggestion
        └── 其他类 ──► MetadataService 通用处理 ──► RenameSuggestion
        │
        ▼
MainViewModel.suggestions ──► ContentView 预览（可编辑、确认/拒绝）
        │
        ▼
RenameEngine.validateSuggestions() + executeRenames()
        │
        ▼
ClassificationService.classifyFiles() ──► 按分类移动到子目录
```

## 代码风格与约定

- **语言**：源码注释、README、文档以中文为主；标识符、类型名、API 使用英文。
- **并发**：大量类型声明为 `Sendable`，使用 `actor` 隔离可变状态（`RenameEngine`、`ClassificationService`）。
- **Swift 版本功能**：启用 `StrictConcurrency` upcoming feature。
- **错误处理**：服务层使用 `try/throw` 或静默失败 + 日志；UI 层通过 `MainViewModel.errorMessage` 展示 `alert`。
- **命名**：结构体/类首字母大写驼峰；方法与小写属性使用小写驼峰；中文注释使用 `///` 文档注释。
- **目录约定**：按职责分层（Models / Services / ViewModels / Views / Plugins / App），不将业务逻辑写在 View 中。
- **可扩展性**：导出插件通过 `ExportPluginProtocol` 协议预留；服务之间通过组合而非继承协作。

## 安全与权限注意事项

1. **文件系统权限**：
   - 应用通过 `NSOpenPanel` 让用户选择文件夹，自动获得对应目录的访问权限。
   - 若未来启用沙盒，需要正确使用安全书签（security-scoped bookmark）保存授权。

2. **回滚功能局限**：
   - `RenameEngine.rollback()` 当前实现保留了 `rollbackMap`，但尚未正确实现从当前路径恢复到原始路径的逻辑。批量重命名后若出现问题，目前无法保证一键安全回滚，修改前请确保用户数据已备份。

3. **元数据与外部进程**：
   - `MetadataService` 与 `AIRenameService` 会调用 `/usr/bin/mdls` 提取 Spotlight 元数据。
   - `AppleScriptBridge` 通过 `NSAppleScript` 执行脚本，未来若集成第三方应用，需警惕脚本注入风险，不要直接将用户输入拼接到 AppleScript 字符串中。

4. **并发安全**：
   - `RenameEngine` 与 `ClassificationService` 均为 `actor`，文件系统写入串行化执行，避免多线程竞争。
   - 批量读取操作使用 `TaskGroup` 并发，但写操作（移动/复制）不并发，以防冲突。

5. **重命名冲突**：
   - 校验阶段会自动为重复文件名追加 `_01`、`_02` 等序号，但仍建议提醒用户：重命名操作会直接修改原始文件，无法通过撤销菜单还原。

## 已知问题与待完善项

- `RenameEngine.rollback()` 未完整实现，回滚按钮当前不会产生预期效果。
- `SettingsView` 的三个 Tab（命名、导出、AI）目前为占位文本，没有实际设置项。
- `ExportPluginProtocol` 与 `AppleScriptBridge` 仅完成基础设施，未接入真实的外部应用导出流程。
- `swift test` 在 CommandLineTools 环境下不可用，需要完整 Xcode。
- `dist/` 中的 `.app` 与 `.dmg` 是历史构建，重新开发后需要手动更新。

## 添加新功能时的建议

- 若新增文件分类，同步修改 `FileCategory`、`FileTypeDetector.inferFromExtension()` 与 `FileCategory.iconName`。
- 若新增元数据源，优先在 `MetadataService.extractMetadata(for:)` 的分支中扩展。
- 若新增重命名策略，可在 `AIRenameService` 或 `MetadataService` 的 suggestion 生成扩展中实现，保持 ViewModel 只负责状态流转。
- 若新增导出目标，实现 `ExportPluginProtocol` 并在需要的位置调度。
- 修改文件系统写入逻辑后，应补充单元测试或至少手动验证大目录、重名文件、目标文件已存在等边界情况。
