# DeepSeek Harness macOS

使用 [Pake](https://github.com/tw93/Pake) 将 dsh web（`http://127.0.0.1:3080`）打包为 macOS 桌面 App。

## 构建产物

- `DeepSeek Harness.app`：可直接运行的 App
- `DeepSeek Harness.dmg`：安装包

App 启动后打开 `http://127.0.0.1:3080`，使用前需要先启动 dsh web 服务。

## GitHub Actions

- 手动触发：Actions -> Build DeepSeek Harness macOS App -> Run workflow
- 标签触发：推送 `v*` 标签后自动构建并发布 Release

构建产物会以 workflow artifacts 形式保存；标签构建还会自动附加到 GitHub Release。

## 本地构建

```bash
brew install pake
pake --config app.json --json --targets app
pake --config app.json --json --targets dmg
```

