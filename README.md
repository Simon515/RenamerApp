# Renamer

半自动 macOS 文件整理助手。

- 拖拽文件夹（或点击选择）即可分析内容。
- 本地优先提取 PDF / 图片 / 视频 / 文档的元数据与文本。
- 通过 SHA-256 内容哈希检测重复文件。
- 支持自定义命名模板与动态子目录分类。
- 整理前可逐条预览、编辑目标路径、启用/停用。
- 可选接入 DeepSeek / Kimi / OpenRouter / 硅基流动等 OpenAI 兼容云端大模型。
- 内置 DEVONthink 导出（AppleScript）。
- 菜单栏图标随时快速整理。

## 安装

下载 `dist/Renamer_v<版本>.dmg`，打开后将 `Renamer.app` 拖入「应用程序」。

应用尚未代码签名/公证，首次打开若被拦截，请在 **系统设置 → 隐私与安全性** 中点「仍要打开」。要求 macOS 14 或更高版本。

## 使用

1. 启动后，将一个或多个文件夹拖到主窗口的虚线区域，或点击「选择文件夹」。
2. 选择整理方式（默认「复制」，更安全；也可选「移动」）。
3. 分析完成后点击「预览」查看整理计划：可逐条修改目标路径、停用某项，并为每组重复文件选择保留项。
4. 点击「执行整理」。文件按命名模板被复制/移动到目标目录（主窗口默认 `~/Documents/Renamer`）。

进阶：用「新建任务」可保存来源/目标/模板/云端开关等组合，便于重复使用；在设置中可管理命名模板与云端服务。

### 命名模板令牌

| 令牌 | 含义 |
|------|------|
| `{title}` | 推断或云端生成的标题 |
| `{date}` | 文件日期，格式 `yyyyMMdd` |
| `{date:格式}` | 自定义日期格式，如 `{date:yyyy}/{date:MM}` |
| `{category}` | 分类（如 Documents / Images / Videos） |
| `{source}` | 来源（如相机型号） |

文件夹模板中的 `/` 会生成子目录。

## 构建与开发

```bash
swift build          # 调试构建
swift run Renamer    # 运行
swift test           # 测试（需完整 Xcode，非仅 CommandLineTools）
swift build -c release
```

详见 [AGENTS.md](AGENTS.md)。

## 打包发布

```bash
./scripts/package.sh
```

生成 `dist/Renamer.app` 与 `dist/Renamer_v<版本>.dmg`。版本号取自 `VERSION`。

## 版本号规则

遵循语义化版本 **MAJOR.MINOR.PATCH**：

- **MAJOR**：不兼容的行为或数据格式变更。
- **MINOR**：向后兼容的新功能。
- **PATCH**：向后兼容的缺陷修复。

首个正式版本为 **v1.0.0**。
