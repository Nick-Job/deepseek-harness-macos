# DeepSeek Harness macOS

<p align="center">
  <img src="icon.png" width="160" alt="DeepSeek Harness 图标">
</p>

![Build](https://github.com/Nick-Job/deepseek-harness-macos/actions/workflows/pake-macos.yml/badge.svg)

**双击即用，零终端依赖** —— 一个打包好的 macOS 桌面 App，把 [DeepSeek Harness（dsh）](https://www.npmjs.com/package/@deepseek-ai/dsh) 网页版完整地装进了 App 里。

> 无需安装 Node.js、无需安装 dsh、无需打开终端。下载 → 双击 → 开始使用。

## ✨ 特点

- 🚀 **开箱即用**：App 内置了 Node.js 运行时和 dsh 本体，任何 Mac（Intel 或 Apple Silicon）双击就能用
- 🔄 **自动启停**：打开 App 时自动启动 dsh web 服务（`127.0.0.1:3080`），退出 App 时自动停止，不留后台进程
- 🖥️ **独立窗口**：基于 [Pake](https://github.com/tw93/Pake)（Rust/Tauri）封装，比浏览器标签更轻、更专注
- 💾 **通用版**：Intel 与 Apple Silicon 均原生运行，无需 Rosetta

## 🚀 快速开始

1. 去 [Releases](https://github.com/Nick-Job/deepseek-harness-macos/releases) 页面下载最新版本
   - 二选一：`DeepSeek Harness.app.zip`（解压即用）或 `DeepSeek Harness.dmg`（拖入应用程序）
2. **双击打开 App**
3. 首次打开 macOS 可能提示"无法验证开发者"——在 App 上**右键 → 打开 → 再点打开**即可（见下方常见问题）
4. App 会自动完成初始化，稍等片刻即可看到界面 🎉

> 💡 第一次启动会初始化 dsh 的配置目录（在你的用户目录下），所以会比平时稍慢几秒，属正常现象。

## 📥 下载

所有安装包都发布在 **Releases** 页面：

<https://github.com/Nick-Job/deepseek-harness-macos/releases>

| 文件 | 说明 |
| --- | --- |
| `DeepSeek Harness.app.zip` | 解压后得到 App，双击即用 |
| `DeepSeek Harness.dmg` | 安装包，拖进"应用程序"即可 |

## ❓ 常见问题

| 问题 | 解决办法 |
| --- | --- |
| 提示"无法验证开发者" | App 是 ad-hoc 签名，未做苹果公证。右键 App → **打开** → 再点一次"打开"即可（只需一次） |
| 提示"已损坏" | 和上一条同理，右键 → 打开；或在「系统设置 → 隐私与安全性」里允许 |
| 打开后等待较久 | 首次启动要初始化 dsh 配置，之后会很快 |
| 打开后是空白页 | 等待几秒让服务就绪；仍不行就退出重开，或在 [Issues](https://github.com/Nick-Job/deepseek-harness-macos/issues) 反馈 |
| 打开后提示 `dsh web authentication required` | 新版 dsh web 的浏览器信任认证与 Pake 壳不兼容，App 打包时已内置补丁关闭该认证。请**彻底退出并重启 App**；若仍有该提示，确认没有其它 `dsh web` 占用 `3080` 端口（如终端里另开的），先停掉再开 App |
| 想用浏览器访问 | 保持 App 开着时，浏览器访问 `http://127.0.0.1:3080` 效果相同 |

## 🛠️ 原理

App 由两部分组成：

1. **内置运行时**（`Contents/Resources/runtime/`）：lipo 合并的通用 Node.js 二进制 + 完整安装的 dsh 及其全部依赖
2. **启动壳**（`Contents/MacOS/pake-deepseekharness`）：负责自动启动/停止 dsh web 服务，再拉起真正的 App 二进制

所以它完全独立于你的电脑环境——不依赖系统里的 Node.js、npm 或任何全局安装。

## 👨‍💻 本地构建（可选）

一般用户不需要构建，直接下载 Release 即可。想自己构建请看下面：

```bash
# 1. 安装 Pake CLI（与 CI 保持一致的版本）
npm install -g pake-cli@3.15.6

# 2. 编译 App（只产出 .app，之后再注入运行时）
pake --config app.json --targets app --json

# 3. 生成内置运行时（下载 Node 并安装 dsh，需要网络）
./scripts/bundle-runtime.sh

# 4. 注入运行时 + 启动壳 + 重新签名
APP="DeepSeek Harness.app"
mkdir -p "$APP/Contents/Resources/runtime"
cp -R runtime/. "$APP/Contents/Resources/runtime/"
mv "$APP/Contents/MacOS/pake-deepseekharness" "$APP/Contents/MacOS/pake-deepseekharness-bin"
cp scripts/launcher.sh "$APP/Contents/MacOS/pake-deepseekharness"
chmod +x "$APP/Contents/MacOS/pake-deepseekharness"
codesign --force --deep --sign - "$APP"

# 5. 打包（可选）
hdiutil create -volname "DeepSeek Harness" -srcfolder "$APP" -ov -format UDZO "DeepSeek Harness.dmg"
```

完整流程由 `.github/workflows/pake-macos.yml` 自动执行，仓库的 [Actions](https://github.com/Nick-Job/deepseek-harness-macos/actions) 页面可手动触发（`Run workflow`），推送 `v*` 标签会自动发布 Release。

## 📄 配置

主要配置在 `app.json`：

- `url`：App 窗口加载的地址，默认 `http://127.0.0.1:3080`
- `name`：应用名称，默认 `DeepSeek Harness`
- `icon`：应用图标，默认使用仓库里的 `icon.png`
- `width` / `height`：默认窗口大小
- `minWidth` / `minHeight`：窗口最小尺寸
- `multiArch`：macOS 通用版（同时包含 Intel 与 Apple Silicon 两套原生代码）
- `appVersion`：版本号，发布时与 Git tag 保持一致

运行时相关参数在 `scripts/bundle-runtime.sh` 顶部：

- `NODE_VERSION`：内置 Node.js 版本，默认 `v22.23.2`
- `DSH_VERSION`：内置 dsh 版本，默认 `0.1.2-rc.1`
