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
- ⬆️ **跟着上游走**：构建时自动取 npm 上的最新 dsh；仓库每天定时核查，上游一发版就自动重建发版
- 🔍 **App 内更新核查**：打开 App 时后台核查，发现新版 dsh 就地热更新（下次启动生效），App 壳有新版会提示打开发布页
- 🚫 **不抢浏览器**：启动时既传 `--no-open`，又挂了浏览器闸门兜底，双击 App 不会弹出浏览器标签

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
| `version.json` | 本次构建记录（App 版本 / 内置 dsh 版本 / 构建时间），供更新核查与排查用 |

## ⬆️ 版本跟随与自动更新

桌面端内置的 dsh 版本**不会**靠"用户重新下载 App"来更新，分两层自动跟进：

**第一层：构建端（仓库自动跟随上游）**

- `scripts/bundle-runtime.sh` 默认不再写死版本号，而是实时查询 npm 上 `@deepseek-ai/dsh` 的 `latest`（可用 `DSH_CHANNEL` 切到 `next` / `alpha`），把那一版打进 App
- `.github/workflows/upstream-watch.yml` 每天定时核查：一旦上游版本高于"上次发布的内置版本"，就自动升一个 App 补丁版本、打 tag、触发构建发布。整个过程无需人工介入
- 每次构建都会把版本信息写进 `Contents/Resources/version.json`，并作为 Release 资产发布，作为下一轮核查的判据

**第二层：App 端（打开时就地热更新）**

打开 App 时，启动壳会在后台跑一次版本核查（默认 12 小时一次，避免频繁联网）：

- 发现更新的 dsh：用 App 内置的 node/npm 把新版本装到用户可写的覆盖运行时（`~/Library/Application Support/DeepSeek Harness/runtime/`），**装完先跑验收测试**（首页必须无 cookie 直接 200，且全程不调用 `open`），通过才原子替换，然后下次启动生效。安装失败或验收不过，就原样保留旧运行时，绝不影响当前使用
- 发现 App 壳本身有新版本：因为是 ad-hoc 签名、没有公证，无法安静地自我替换，所以弹一次提示，点"打开发布页"跳转到 Releases
- 覆盖运行时与内置运行时会**比版本**，谁新用谁；用户换了新版 App 后，过期的覆盖运行时会自动清理

相关开关：

| 环境变量 | 作用 | 默认 |
| --- | --- | --- |
| `DSH_DESKTOP_CHANNEL` | 跟随渠道（`latest` / `next` / `alpha`） | `latest` |
| `DSH_DESKTOP_AUTO_UPDATE=0` | 只核查并提示，不自动热更新 | 自动更新开启 |
| `DSH_DESKTOP_NO_NOTIFY=1` | 完全静默，只写日志 | 会通知 |
| `DSH_DESKTOP_CHECK_HOURS` | 核查间隔小时数 | `12` |
| `DSH_DESKTOP_ALLOW_BROWSER=1` | 关掉浏览器闸门（调试用） | 闸门开启 |

手动核查一次（不装、只看）：

```bash
"/Applications/DeepSeek Harness.app/Contents/Resources/runtime/bin/node" \
  "/Applications/DeepSeek Harness.app/Contents/Resources/scripts/update-check.js" check --force
```

## ❓ 常见问题

| 问题 | 解决办法 |
| --- | --- |
| 提示"无法验证开发者" | App 是 ad-hoc 签名，未做苹果公证。右键 App → **打开** → 再点一次"打开"即可（只需一次） |
| 提示"已损坏" | 和上一条同理，右键 → 打开；或在「系统设置 → 隐私与安全性」里允许 |
| 打开后等待较久 | 首次启动要初始化 dsh 配置，之后会很快 |
| 打开后是空白页 | 等待几秒让服务就绪；仍不行就退出重开，或在 [Issues](https://github.com/Nick-Job/deepseek-harness-macos/issues) 反馈 |
| 打开后提示 `dsh web authentication required` | 新版 dsh web 的浏览器信任认证与 Pake 壳不兼容，App 打包时（以及热更新时）都会自动打补丁关掉该认证。请**彻底退出并重启 App**；若仍有该提示，确认没有其它 `dsh web` 占用 `3080` 端口（如终端里另开的），先停掉再开 App |
| 双击后弹出了浏览器 | 正常版本不会。日志里搜 `open-guard` 可看到拦截记录；若真被打开，请把 `~/Library/Logs/deepseek-harness-dsh.log` 发到 Issues |
| 想知道当前跑的是哪一版 dsh | 日志开头每行 `运行时: ... dsh x.y.z (App a.b.c)`；或跑上面的"手动核查一次"命令 |
| 想用浏览器访问 | 保持 App 开着时，浏览器访问 `http://127.0.0.1:3080` 效果相同 |
| 更新的 dsh 装失败 | 日志会记 `自动更新失败（不影响当前使用）`，当前版本照常可用；下次打开会重试 |

## 🛠️ 原理

App 由三部分组成：

1. **内置运行时**（`Contents/Resources/runtime/`）：lipo 合并的通用 Node.js 二进制 + 完整安装的 dsh 及其全部依赖 + `version.json` 构建记录
2. **启动壳**（`Contents/MacOS/pake-deepseekharness`）：选运行时（覆盖运行时 / 内置运行时 / 系统 dsh）→ 起 `dsh web --no-open` → 等首页真的可用 → 后台核查版本 → 拉起真正的 App 二进制；退出时停掉自己起的服务
3. **辅助脚本**（`Contents/Resources/scripts/`）：版本查询比较（`dsh-versions.js`）、认证补丁（`patch-dsh-auth.js`）、更新核查与热更新（`update-check.js`）、浏览器闸门（`open-guard/open`）、行为级冒烟测试（`smoke-test.sh`）

所以它完全独立于你的电脑环境——不依赖系统里的 Node.js、npm 或任何全局安装。

## 👨‍💻 本地构建（可选）

一般用户不需要构建，直接下载 Release 即可。想自己构建请看下面：

```bash
# 1. 安装 Pake CLI（与 CI 保持一致的版本）
npm install -g pake-cli@3.15.6

# 2. 编译 App（只产出 .app，之后再注入运行时）
pake --config app.json --targets app --json

# 3. 生成内置运行时（自动跟随 npm 最新版；末尾会跑冒烟测试）
./scripts/bundle-runtime.sh
#    也可以指定版本 / 渠道：
#    ./scripts/bundle-runtime.sh v22.23.2 0.1.5-rc.1
#    DSH_CHANNEL=next ./scripts/bundle-runtime.sh

# 4. 注入运行时 + 启动壳 + 辅助脚本 + 重新签名
APP="DeepSeek Harness.app"
mkdir -p "$APP/Contents/Resources/runtime" "$APP/Contents/Resources/scripts/open-guard"
cp -R runtime/. "$APP/Contents/Resources/runtime/"
cp scripts/dsh-versions.js scripts/patch-dsh-auth.js scripts/update-check.js scripts/smoke-test.sh "$APP/Contents/Resources/scripts/"
cp scripts/open-guard/open "$APP/Contents/Resources/scripts/open-guard/"
chmod +x "$APP/Contents/Resources/scripts/smoke-test.sh" "$APP/Contents/Resources/scripts/open-guard/open"
mv "$APP/Contents/MacOS/pake-deepseekharness" "$APP/Contents/MacOS/pake-deepseekharness-bin"
cp scripts/launcher.sh "$APP/Contents/MacOS/pake-deepseekharness"
chmod +x "$APP/Contents/MacOS/pake-deepseekharness"
codesign --force --deep --sign - "$APP"

# 5. 打包（可选）
hdiutil create -volname "DeepSeek Harness" -srcfolder "$APP" -ov -format UDZO "DeepSeek Harness.dmg"
```

单独跑验收测试（都会真实起一个 dsh web 进程，用的是独立的临时 `DSH_HOME`，不碰你的 `~/.dsh`）：

```bash
# 运行时级：首页无 cookie 必须 200，且 --no-open 下不得调用 open
./scripts/smoke-test.sh --runtime-dir runtime

# 启动壳级：拿构建好的 .app 搭"假 App"，把双击启动那条链路整段跑一遍
./scripts/launcher-smoke-test.sh --app "DeepSeek Harness.app" --port 3291
```

完整流程由 `.github/workflows/pake-macos.yml` 自动执行，仓库的 [Actions](https://github.com/Nick-Job/deepseek-harness-macos/actions) 页面可手动触发（`Run workflow`，可指定 dsh 版本与渠道），推送 `v*` 标签会自动发布 Release；日常跟随上游由 `upstream-watch.yml` 定时完成。

## 📄 配置

主要配置在 `app.json`：

- `url`：App 窗口加载的地址，默认 `http://127.0.0.1:3080`
- `name`：应用名称，默认 `DeepSeek Harness`
- `icon`：应用图标，默认使用仓库里的 `icon.png`
- `width` / `height`：默认窗口大小
- `minWidth` / `minHeight`：窗口最小尺寸
- `multiArch`：macOS 通用版（同时包含 Intel 与 Apple Silicon 两套原生代码）
- `appVersion`：App 壳版本号；`upstream-watch.yml` 每次跟随上游发版时会自动 +1 个补丁位

运行时相关参数在 `scripts/bundle-runtime.sh`：

- `NODE_VERSION`：内置 Node.js 版本，默认 `v22.23.2`（第 1 个参数）
- `DSH_VERSION`：内置 dsh 版本（第 2 个参数）；**留空即自动跟随上游最新版**，这是默认行为
- `DSH_CHANNEL`：跟随渠道，默认 `latest`，可设 `next` / `alpha`
- `SKIP_SMOKE_TEST=1`：跳过结尾的冒烟测试（不建议）
- `dsh-version.txt`：离线时的版本兜底（npm 查询失败才用到）
