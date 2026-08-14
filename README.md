# DeepSeek Harness macOS

![Build](https://github.com/Nick-Job/deepseek-harness-macos/actions/workflows/pake-macos.yml/badge.svg)

使用 [Pake](https://github.com/tw93/Pake)（Rust/Tauri）把 DeepSeek Harness 网页端 dsh web 打包成 macOS 桌面 App。

App 启动后会在独立窗口中打开 `http://127.0.0.1:3080`，使用前需要先启动 dsh web 服务。

## 快速开始

1. **安装 dsh**：`npm install -g @deepseek-ai/dsh`（需要 Node.js ≥ 20）
2. **终端启动服务**：`dsh web`（默认监听 `http://127.0.0.1:3080`，保持终端运行）
3. **打开 App**：双击 `DeepSeek Harness.app`（或从 DMG 安装）

📖 详细图文教程见 [使用教程.md](使用教程.md)

## 构建产物

每次构建都会产出两个文件：

- `DeepSeek Harness.app`：可以直接运行的 App 文件夹
- `DeepSeek Harness.dmg`：macOS 安装包

也可以在 [Releases](https://github.com/Nick-Job/deepseek-harness-macos/releases) 页面直接下载已构建好的产物。

## 使用说明

1. 先启动 dsh web：确认 `http://127.0.0.1:3080` 可以正常访问。
2. 打开 `DeepSeek Harness.app`，或双击 `DeepSeek Harness.dmg` 安装。
3. 如果 macOS 提示无法验证开发者，请在 Dock 或 Finder 中右键 App，选择“打开”。

## GitHub Actions

本仓库内置了 `.github/workflows/pake-macos.yml`，支持两种触发方式：

- 手动触发：打开 Actions 页面，选择 `Build DeepSeek Harness macOS App`，点击 `Run workflow`。
- 标签触发：推送 `v*` 标签，例如 `git tag v1.0.0 && git push origin v1.0.0`。

工作流会在 macOS 上完成以下操作：

1. 安装 Rust 工具链和 Pake CLI（`pake-cli@3.15.6`，版本已锁定，可随时升级）。
2. 根据 `app.json` 一次编译产出 `.app` 和 `.dmg`（universal 通用版）。
3. 压缩 `.app` 为 `.app.zip`。
4. 上传 `.app.zip` 和 `.dmg` 到 workflow artifacts。
5. 标签触发时，自动把产物附加到 GitHub Release（重复运行同一标签会覆盖旧资产）。

## 本地构建

```bash
# 安装 Pake CLI（推荐 npm 版本，与 CI 保持一致；brew install pake 亦可）
npm install -g pake-cli@3.15.6

# 一次编译产出 .app 和 .dmg（universal 通用版）
pake --config app.json --json
```

## 配置

主要配置在 `app.json`：

- `url`：要打包的网页地址，默认 `http://127.0.0.1:3080`
- `name`：应用名称，默认 `DeepSeek Harness`
- `icon`：应用图标，默认使用仓库里的 `icon.png`
- `width` / `height`：默认窗口大小
- `minWidth` / `minHeight`：窗口最小尺寸
- `multiArch`：macOS 通用版（同时包含 Intel 与 Apple Silicon 两套原生代码），默认 `false`

## 常见问题

- 打开后是空白页：确认 dsh web 已经启动，并且 `127.0.0.1:3080` 可访问。
- 提示“无法打开”：当前构建为 ad-hoc 签名，右键 App 选择“打开”即可。
- Apple Silicon 能用吗：`app.json` 已启用 `multiArch: true`，构建产物为 universal 通用版，Intel 与 Apple Silicon 均可原生运行，无需 Rosetta 转译。

