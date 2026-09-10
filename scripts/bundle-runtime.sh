#!/bin/bash
# ============================================================
# bundle-runtime.sh — 把 Node.js + dsh 打包成 App 内置运行时
#
# 产物: runtime/ 目录(universal,Intel + Apple Silicon 通用):
#   runtime/bin/node                    —— lipo 合并的通用 Node 二进制
#   runtime/bin/npm、npx                —— npm 命令软链(供 dsh 子进程使用)
#   runtime/lib/node_modules/npm        —— npm 本体
#   runtime/node_modules/@deepseek-ai/dsh —— dsh 及其全部依赖(含双架构原生模块)
#   runtime/version.json                —— 本次构建记录(版本/时间/来源),供 App 内更新核查与发布资产使用
#
# 用法: ./scripts/bundle-runtime.sh [node版本] [dsh版本]
#   dsh 版本留空（或写 latest）时 **自动跟随 npm 上的最新版**，这是默认行为：
#     渠道默认 DSH_CHANNEL=latest，可用 DSH_CHANNEL=next / alpha 切换。
#   npm 查询失败时回退到仓库里的 dsh-version.txt。
#
# 在 GitHub Actions(macos-15, arm64)和本地(x86_64)均可运行。
# ============================================================
set -euo pipefail

# dsh 依赖树很大,CI 上 npm install 曾因 V8 堆不足 OOM(exit 134),
# 显式放宽 Node 老生代堆即可(GitHub macOS runner 约 7GB 内存)。
export NODE_OPTIONS="--max-old-space-size=6144"

NODE_VERSION="${1:-v22.23.2}"
DSH_VERSION="${2:-}"
DSH_CHANNEL="${DSH_CHANNEL:-latest}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/runtime"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { echo "[bundle-runtime] $*"; }

rm -rf "$RUNTIME_DIR"
mkdir -p "$RUNTIME_DIR"

# ---------- 1. 下载 Node 两个架构的官方包 ----------
log "下载 Node $NODE_VERSION (arm64 + x64) ..."
for ARCH in arm64 x64; do
  TARBALL="$WORK/node-$NODE_VERSION-darwin-$ARCH.tar.gz"
  curl -fsSL --retry 3 -o "$TARBALL" \
    "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-darwin-$ARCH.tar.gz"
  tar -xzf "$TARBALL" -C "$WORK"
done

# ---------- 2. lipo 合并成通用 Node 二进制 ----------
log "lipo 合并通用 node 二进制 ..."
lipo -create \
  "$WORK/node-$NODE_VERSION-darwin-arm64/bin/node" \
  "$WORK/node-$NODE_VERSION-darwin-x64/bin/node" \
  -output "$WORK/node-universal"

# ---------- 3. 组装运行时目录骨架 ----------
log "组装 runtime 目录 ..."
NODE_SRC="$WORK/node-$NODE_VERSION-darwin-arm64"
mkdir -p "$RUNTIME_DIR/bin" "$RUNTIME_DIR/lib/node_modules"
cp -R "$NODE_SRC/lib/node_modules/npm" "$RUNTIME_DIR/lib/node_modules/npm"
cp "$NODE_SRC/LICENSE" "$RUNTIME_DIR/LICENSE" 2>/dev/null || true
cp "$WORK/node-universal" "$RUNTIME_DIR/bin/node"
chmod +x "$RUNTIME_DIR/bin/node"
# npm / npx 软链(bin 目录在 PATH 里,供 dsh 及其子进程调用)
ln -sf ../lib/node_modules/npm/bin/npm-cli.js "$RUNTIME_DIR/bin/npm"
ln -sf ../lib/node_modules/npm/bin/npx-cli.js "$RUNTIME_DIR/bin/npx"

NPM="$RUNTIME_DIR/lib/node_modules/npm/bin/npm-cli.js"
NPM_CACHE="$WORK/npm-cache"
NPM_FLAGS=(--cache "$NPM_CACHE" --no-audit --no-fund --loglevel=error)

# ---------- 3b. 确定要内置的 dsh 版本(默认跟随上游最新版) ----------
# 放在这里是因为解析要用刚组装好的 node;显式传入版本号时完全跳过网络查询。
if [ -z "$DSH_VERSION" ] || [ "$DSH_VERSION" = "latest" ]; then
  log "查询 npm 上 @deepseek-ai/dsh 的 dist-tag($DSH_CHANNEL) ..."
  if RESOLVED="$("$RUNTIME_DIR/bin/node" "$SCRIPT_DIR/dsh-versions.js" latest "$DSH_CHANNEL" 2>"$WORK/resolve.err")"; then
    DSH_VERSION="$RESOLVED"
    log "上游最新版: $DSH_VERSION"
  else
    FALLBACK="$(tr -d '[:space:]' < "$ROOT_DIR/dsh-version.txt" 2>/dev/null || true)"
    if [ -z "$FALLBACK" ]; then
      echo "bundle-runtime: 无法查询 npm($(cat "$WORK/resolve.err"))，且 dsh-version.txt 为空" >&2
      exit 1
    fi
    DSH_VERSION="$FALLBACK"
    log "npm 查询失败($(cat "$WORK/resolve.err"))，回退到 dsh-version.txt: $DSH_VERSION"
  fi
fi

# ---------- 4. 安装 dsh(非全局 --prefix,依赖平铺在 runtime/node_modules) ----------
log "安装 @deepseek-ai/dsh@$DSH_VERSION ..."
"$RUNTIME_DIR/bin/node" "$NPM" install --prefix "$RUNTIME_DIR" \
  "${NPM_FLAGS[@]}" "@deepseek-ai/dsh@$DSH_VERSION"

# 记账：记录实际落地的版本，避免 tag 与真实版本不一致时记录失真
DSH_VERSION="$("$RUNTIME_DIR/bin/node" -e "console.log(require('$RUNTIME_DIR/node_modules/@deepseek-ai/dsh/package.json').version)")"
log "实际安装版本: $DSH_VERSION"

# ---------- 5. 补齐另一个架构的原生模块(保证通用) ----------
# dsh 依赖里按平台/架构拆分的原生包:
#   @img/sharp-darwin-{arm64,x64} + @img/sharp-libvips-darwin-{arm64,x64}
#   @koromix/koffi-darwin-{arm64,x64}
#   node-addon-require-builtin-darwin-{arm64,x64}
# 宿主架构的版本随第 4 步装好,这里读取其版本号,再 --force 补装另一架构。
# node-pty 的 prebuilds 自带 darwin-arm64/x64,无需额外处理。
NM="$RUNTIME_DIR/node_modules"
HOST_ARCH="$(uname -m)"                     # arm64 或 x86_64
case "$HOST_ARCH" in
  x86_64) HOST_NPM_ARCH="x64"; OTHER_NPM_ARCH="arm64" ;;
  arm64)  HOST_NPM_ARCH="arm64"; OTHER_NPM_ARCH="x64" ;;
  *) echo "不支持的架构: $HOST_ARCH"; exit 1 ;;
esac

ver() { "$RUNTIME_DIR/bin/node" -e "console.log(require('$NM/$1/package.json').version)"; }

log "宿主架构: $HOST_NPM_ARCH,补装: $OTHER_NPM_ARCH 原生模块 ..."
EXTRA_PKGS=()
for base in \
  "@img/sharp-darwin-$OTHER_NPM_ARCH@$(ver @img/sharp-darwin-$HOST_NPM_ARCH)" \
  "@img/sharp-libvips-darwin-$OTHER_NPM_ARCH@$(ver @img/sharp-libvips-darwin-$HOST_NPM_ARCH)" \
  "@koromix/koffi-darwin-$OTHER_NPM_ARCH@$(ver @koromix/koffi-darwin-$HOST_NPM_ARCH)" \
  "node-addon-require-builtin-darwin-$OTHER_NPM_ARCH@$(ver node-addon-require-builtin-darwin-$HOST_NPM_ARCH)"; do
  EXTRA_PKGS+=("$base")
done

"$RUNTIME_DIR/bin/node" "$NPM" install --prefix "$RUNTIME_DIR" \
  --force "${NPM_FLAGS[@]}" "${EXTRA_PKGS[@]}"

# ---------- 6. 瘦身: 删除非 macOS 平台的预编译产物 ----------
log "清理非 macOS 平台文件 ..."
# node-pty: 只保留 darwin 预编译
find "$NM/node-pty/prebuilds" -maxdepth 1 -type d \
  ! -name 'prebuilds' ! -name 'darwin-*' -exec rm -rf {} + 2>/dev/null || true
# sharp wasm 回退包(darwin 上不需要)
rm -rf "$NM/@img/sharp-wasm32" 2>/dev/null || true
# 其它平台的原生包(按命名规则兜底清理)
find "$NM/@img" "$NM/@koromix" -maxdepth 1 -type d \
  \( -name '*-linux-*' -o -name '*-win32-*' -o -name '*-freebsd-*' \) \
  -exec rm -rf {} + 2>/dev/null || true
find "$NM" -maxdepth 1 -type d \
  \( -name 'node-addon-require-builtin-linux-*' -o -name 'node-addon-require-builtin-win32-*' \) \
  -exec rm -rf {} + 2>/dev/null || true

# ---------- 6b. 禁用浏览器信任认证(适配 Pake 壳) ----------
# 新版 dsh web 用"每进程启动令牌"做认证: 只有打开它打印的带 ?token= 的 URL
# 才会种下签名 cookie,否则首页与 /api 都回 401 "dsh web authentication required;
# reopen the URL printed by dsh web"。而 Pake 壳的 URL 是编译时写死的无 token 地址,
# 直连必然 401。对"零终端、双击即用"的本地桌面封装,这里关掉内建认证。
# 实现见 scripts/patch-dsh-auth.js（按方法体注入，跨版本更稳，自带幂等与复核）。
log "禁用浏览器信任认证(适配 Pake 壳) ..."
"$RUNTIME_DIR/bin/node" "$SCRIPT_DIR/patch-dsh-auth.js" "$RUNTIME_DIR"

# ---------- 6c. 写入构建记录(供 App 内版本核查与发布资产使用) ----------
APP_VERSION="$("$RUNTIME_DIR/bin/node" -e "
const fs = require('fs');
try { console.log(JSON.parse(fs.readFileSync('$ROOT_DIR/app.json', 'utf8')).appVersion ?? '0.0.0'); }
catch { console.log('0.0.0'); }
")"
GIT_SHA="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
"$RUNTIME_DIR/bin/node" -e "
const fs = require('fs');
fs.writeFileSync(process.argv[6], JSON.stringify({
  appVersion: process.argv[1],
  dshVersion: process.argv[2],
  nodeVersion: process.argv[3],
  channel: process.argv[4],
  commit: process.argv[5],
  builtAt: new Date().toISOString(),
}, null, 2) + '\n');
" "$APP_VERSION" "$DSH_VERSION" "$NODE_VERSION" "$DSH_CHANNEL" "$GIT_SHA" "$RUNTIME_DIR/version.json"
log "构建记录 runtime/version.json:"
cat "$RUNTIME_DIR/version.json"

# ---------- 7. 验证 ----------
log "验证:"
"$RUNTIME_DIR/bin/node" --version
DSH_PKG="$NM/@deepseek-ai/dsh/package.json"
"$RUNTIME_DIR/bin/node" -e "console.log('dsh 版本:', require('$DSH_PKG').version)"
"$RUNTIME_DIR/bin/node" -e "
const sharp = require('$NM/sharp');
console.log('sharp OK:', typeof sharp !== 'undefined');
const koffi = require('$NM/koffi');
console.log('koffi OK:', typeof koffi !== 'undefined');
const nar = require('$NM/node-addon-require-builtin');
console.log('node-addon-require-builtin OK:', typeof nar.requireBuiltin);
" 2>&1 | tail -5
# 双架构原生文件齐备检查
log "双架构文件检查(应同时看到 darwin-arm64 与 darwin-x64):"
find "$NM" -name "*.node" -path "*darwin-*" 2>/dev/null | sed "s|$NM/||" | sed 's|/.*||' | sort -u | head -20

# ---------- 8. 行为级冒烟测试 ----------
# 起真实进程验收: 首页无 cookie 直接 200,且 --no-open 下全程不碰浏览器。
# 这是"用户双击后既不弹浏览器、也看不到 401"的硬门槛。
if [ "${SKIP_SMOKE_TEST:-0}" = "1" ]; then
  log "已跳过冒烟测试(SKIP_SMOKE_TEST=1)"
else
  log "冒烟测试 ..."
  "$SCRIPT_DIR/smoke-test.sh" --runtime-dir "$RUNTIME_DIR"
fi

log "完成! 运行时位于: $RUNTIME_DIR"
du -sh "$RUNTIME_DIR"
