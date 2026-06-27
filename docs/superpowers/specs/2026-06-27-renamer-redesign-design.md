# Renamer 重新设计文档

**日期**：2026-06-27  
**主题**：基于内容感知的 macOS 文件自动整理工具  
**目标读者**：开发者、设计者、未来的自己  
**状态**：已通过 brainstorming，待实现规划

---

## 1. 背景与目标

原 Renamer 项目已具备基础的文件扫描、分类、重命名建议能力，但智能化程度和易用性尚未达到"开箱即用"的水平。本次重新设计的目标是将 Renamer 改造为类似 Hazel 的半自动文件整理助手，但更轻量、更智能，重点解决：

- 基于文件内容（尤其是 PDF 文档）自动生成重命名和分类建议。
- 支持动态子目录结构，用户可在执行前预览和编辑。
- 文档类文件可一键导出到 DEVONthink 进行归档管理。
- 本地优先保护隐私，同时支持国产/聚合云端大模型增强理解能力。

---

## 2. 产品定位

**产品名**：Renamer  
**平台**：macOS 14+ 原生桌面应用  
**形态**：菜单栏小工具 + 独立主窗口  
**触发方式**：半自动/手动触发，不支持后台实时监控  
**核心用户旅程**：

1. 从菜单栏或主窗口选择源文件夹/任务。
2. App 扫描文件并提取内容/元数据。
3. 本地 AI 优先生成标签、分类、文件名组件。
4. （可选）云端大模型增强理解。
5. 用户预览、编辑、确认整理方案。
6. 执行复制或移动，可选导出到 DEVONthink。
7. 操作记录支持一键回滚。

---

## 3. 架构设计

### 3.1 技术栈

- 语言：Swift 6
- UI 框架：SwiftUI
- 构建工具：Swift Package Manager
- 状态管理：`@Observable`
- 并发：`async/await`、`actor`、`TaskGroup`
- 最低系统：macOS 14

### 3.2 模块结构

```
Renamer/
├── App/
│   ├── RenamerApp.swift          # @main 入口、WindowGroup、Settings
│   └── MenuBarController.swift   # 菜单栏快速触发
├── Models/
│   ├── FileItem.swift            # 文件实体
│   ├── FileAnalysis.swift        # AI 分析结果
│   ├── NamingTemplate.swift      # 命名模板
│   ├── OrganizationTask.swift    # 可保存的整理任务
│   ├── OrganizationPlan.swift    # 一次执行计划
│   ├── PlanOperation.swift       # 单条整理操作
│   ├── FileOperationRecord.swift # 操作记录（回滚用）
│   └── DuplicateGroup.swift      # 重复文件组
├── Services/
│   ├── FileScanner.swift         # 递归扫描
│   ├── LocalAnalyzer.swift       # 本地内容分析
│   ├── CloudAnalyzer.swift       # 云端 API 客户端
│   ├── NamingEngine.swift        # 模板组合与重名处理
│   ├── DuplicateDetector.swift   # 重复文件检测
│   ├── Organizer.swift           # 执行复制/移动
│   ├── RollbackService.swift     # 回滚
│   └── PluginManager.swift       # 导出插件管理
├── Plugins/
│   ├── ExportPluginProtocol.swift
│   └── DEVONthinkPlugin.swift
├── ViewModels/
│   ├── MainViewModel.swift
│   ├── TaskListViewModel.swift
│   └── SettingsViewModel.swift
└── Views/
    ├── ContentView.swift
    ├── PlanPreviewView.swift
    ├── TaskEditorView.swift
    ├── SettingsView.swift
    └── MenuBarPopover.swift
```

### 3.3 AI 策略

- **本地层**：PDFKit 提取文本、Vision OCR、NaturalLanguage 提取关键词/实体、ImageIO/AVFoundation 读元数据。
- **云端层**：兼容 OpenAI API 格式，支持自定义 Base URL、API Key、Model Name。默认提供 DeepSeek、Kimi、OpenRouter、硅基流动等模板。只上传本地提取的文本片段和元数据，不上传原始文件。
- **模板层**：AI 输出结构化标签（title/date/category/tags/source），再由用户模板组合成最终路径和文件名。

### 3.4 导出插件

- 协议化设计，DEVONthink 通过 AppleScript 实现。
- DEVONthink 作为可选导出目标之一，不是默认行为。

---

## 4. 数据模型

### 4.1 FileItem

```swift
struct FileItem: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let name: String
    let pathExtension: String
    let size: Int64
    let creationDate: Date?
    let modificationDate: Date?
    let contentType: UTType?
}
```

### 4.2 FileAnalysis

```swift
struct FileAnalysis: Sendable {
    let fileID: UUID
    var title: String?
    var date: Date?
    var category: String?
    var tags: [String]
    var source: String?
    var summary: String?
    var confidence: Double
}
```

### 4.3 NamingTemplate

```swift
struct NamingTemplate: Codable, Identifiable {
    let id: UUID
    var name: String
    var folderTemplate: String
    var fileNameTemplate: String
}
```

### 4.4 OrganizationTask

```swift
struct OrganizationTask: Codable, Identifiable {
    let id: UUID
    var name: String
    var sourceFolders: [URL]
    var templateID: UUID
    var destinationFolder: URL
    var operation: CopyOrMove
    var exportTargets: [ExportTarget]
    var useCloudAI: Bool
}
```

### 4.5 OrganizationPlan

```swift
struct OrganizationPlan: Sendable {
    let taskID: UUID?
    let analyses: [FileAnalysis]
    let operations: [PlanOperation]
    let duplicateGroups: [DuplicateGroup]
}
```

### 4.6 PlanOperation

```swift
struct PlanOperation: Identifiable, Sendable {
    let id: UUID
    let source: URL
    let destination: URL
    let exportTargets: [ExportTarget]
    var isEnabled: Bool
}
```

### 4.7 FileOperationRecord

```swift
struct FileOperationRecord: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let taskName: String
    let moves: [(source: URL, destination: URL)]
    let exports: [(pluginID: String, details: String)]
}
```

### 4.8 DuplicateGroup

```swift
struct DuplicateGroup: Sendable, Identifiable {
    let id: UUID
    let hash: String
    let items: [FileItem]
    var keepIndex: Int?
}
```

---

## 5. 主要流程

### 5.1 扫描

- 递归扫描源文件夹，跳过隐藏文件、系统目录、包内容。
- 输出 `[FileItem]`。

### 5.2 本地分析

- 按文件类型选择提取器：PDFKit、Vision OCR、ImageIO、AVFoundation、mdls。
- NaturalLanguage 提取关键词、实体。
- 输出 `FileAnalysis`。

### 5.3 云端增强（可选）

- 若任务开启云端 AI 且已配置 Provider，将文本片段发送给大模型。
- 要求返回结构化 JSON，覆盖/补充本地分析。

### 5.4 去重分析

- 计算文件哈希，生成 `DuplicateGroup`。
- 默认每组保留一份，用户可在预览中调整。

### 5.5 生成整理计划

- `NamingEngine` 用模板和 `FileAnalysis` 生成目标路径和文件名。
- 自动处理重名（追加 `_01`）。
- 输出 `OrganizationPlan`。

### 5.6 预览与编辑

- 展示建议列表，支持启用/禁用、编辑路径/文件名、查看标签和置信度。
- 展示重复文件组，支持保留策略调整。

### 5.7 执行整理

- `Organizer`（actor）串行执行复制/移动。
- 生成 `FileOperationRecord`。

### 5.8 导出到 DEVONthink（可选）

- 对启用导出的文件，调用 `DEVONthinkPlugin` 通过 AppleScript 导入。

### 5.9 回滚

- `RollbackService` 读取操作记录，将文件从目标路径移回源路径。
- DEVONthink 导出无法自动回滚，只记录日志。

---

## 6. UI 结构

### 6.1 菜单栏弹窗

- 整理选中的文件夹
- 最近任务列表
- 打开主窗口 / 设置 / 退出

### 6.2 主窗口首页

- 拖拽区域：拖入文件夹立即分析
- 最近任务卡片
- 新建任务按钮

### 6.3 任务编辑器

- 任务名称
- 源文件夹列表
- 目标文件夹
- 操作方式（复制/移动，默认复制）
- 命名模板选择
- 导出目标（DEVONthink 开关）
- 云端 AI 开关

### 6.4 整理预览

- 顶部统计：本地分析数、云端增强数、冲突数
- 建议列表：原文件、建议路径/文件名、标签、置信度、启用开关
- 重复文件组展示
- 执行按钮

### 6.5 设置

- 通用：启动行为、默认操作方式
- 模板管理
- AI：本地 AI 开关、云端 Provider 配置
- 导出：DEVONthink 数据库/组选择

设计风格遵循 macOS 最新设计规范，使用 SwiftUI 原生控件、柔和配色、清晰的信息层级。

---

## 7. 错误处理与边界情况

- **权限错误**：标记文件为不可访问，不影响其他文件。
- **重名冲突**：自动追加序号，用户可手动编辑。
- **AI 失败**：本地失败降级为文件名/元数据；云端失败使用本地结果并提示。
- **DEVONthink 导出失败**：记录失败项，继续执行其他文件。
- **大文件/大目录**：显示进度条，PDF 默认只读前 10 页，图片 OCR 默认关闭。
- **回滚**：移动操作移回原路径；复制操作删除已复制文件。
- **取消**：分析阶段可取消；执行阶段可取消，但已执行的需通过回滚处理。

---

## 8. 去重策略

- 扫描后计算文件哈希（SHA-256 或 xxHash）。
- 完全相同的文件归入 `DuplicateGroup`。
- 默认每组保留一份，其余跳过。
- 用户可在预览中改为"全部保留"或"保留最新"。
- 图片/PDF 支持感知哈希或文本相似度检测，标记"疑似重复"供用户确认。

---

## 9. 测试策略

### 9.1 单元测试

- `FileScanner`：递归、过滤、权限错误。
- `LocalAnalyzer`：PDF 文本、EXIF、关键词。
- `NamingEngine`：模板、重名、日期格式。
- `DuplicateDetector`：哈希、重复组。
- `Organizer`：复制/移动、回滚。
- `CloudAnalyzer`：请求构造、错误降级。

### 9.2 集成测试

- 临时目录完整流程测试：扫描 → 分析 → 计划 → 执行 → 回滚。

### 9.3 UI 测试

- 任务创建、预览列表、设置保存。

### 9.4 手动测试

- 大目录性能。
- 重名、特殊字符、长文件名。
- DEVONthink 未安装时的降级。
- 云端 API Key 无效/网络中断。
- 外部硬盘 / SMB 共享目标目录。

---

## 10. 待决定事项

以下事项在实现前仍需确认或可在实现过程中细化：

1. 默认命名模板集合具体包含哪些模板。
2. 本地 AI 是否引入 MLX 等本地小模型，还是仅使用 Apple 原生框架。
3. 操作记录存储格式（JSON 文件 vs SQLite）。
4. 是否支持多语言文件名（中文路径处理已默认支持）。
5. 是否提供 Quick Look 预览支持。

---

## 11. 设计决策摘要

| 决策项 | 选择 |
|--------|------|
| 触发方式 | 半自动/手动 |
| DEVONthink | 可选导出目标 |
| AI 方式 | 本地优先，云端增强 |
| 分类结构 | AI 动态建议子目录 |
| 文件名生成 | AI 标签 + 模板组合 |
| 整理方式 | 可配置，默认复制 |
| 应用形态 | 菜单栏 + 独立窗口 |
| 任务管理 | 可保存任务 + 临时整理 |
| 系统集成 | Shortcuts/AppleScript 暂不实现 |
| 云端模型 | 兼容 OpenAI API 格式，支持国产/聚合商 |
| 重复文件 | 哈希检测，默认保留一份 |
