#!/bin/bash
# ============================================================
# DeepSeek Harness 启动壳
# 双击 App → 自动启动 dsh web(若 3080 未运行) → 打开界面
# 退出 App → 自动停止本次启动的 dsh web
# 优先使用 App 内置运行时(零终端依赖); 找不到时回退到系统 dsh。
# 日志: ~/Library/Logs/deepseek-harness-dsh.log
# ============================================================

# launchd 启动的 App PATH 很精简,补上 node/dsh 所在目录
export PATH="/usr/local/bin:/opt/homebrew/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/pake-deepseekharness-bin"
PORT=3080
LOG="$HOME/Library/Logs/deepseek-harness-dsh.log"
mkdir -p "$HOME/Library/Logs"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
trap 'log "wrapper 退出 (code=$? pid=$$)"' EXIT

# ---------------- 定位 dsh 运行入口 ----------------
# 优先: App 内置运行时(runtime/bin/node + runtime/node_modules/@deepseek-ai/dsh)
RUNTIME="$DIR/../Resources/runtime"
NODE="$RUNTIME/bin/node"
DSH_JS="$RUNTIME/node_modules/@deepseek-ai/dsh/lib/bin.js"

if [ -x "$NODE" ] && [ -f "$DSH_JS" ]; then
  DSH_CMD=("$NODE" "$DSH_JS")
  export PATH="$RUNTIME/bin:$PATH"
  log "使用内置运行时: $RUNTIME"
else
  # 回退: 系统 dsh 命令
  DSH=""
  for c in "$(command -v dsh 2>/dev/null)" "$HOME/.npm-global/bin/dsh" "$HOME/.local/bin/dsh" /usr/local/bin/dsh /opt/homebrew/bin/dsh /usr/bin/dsh; do
    if [ -n "$c" ] && [ -x "$c" ]; then DSH="$c"; break; fi
  done
  if [ -z "$DSH" ]; then
    log "未找到 dsh 命令,也无内置运行时"
    osascript -e 'display dialog "未找到 dsh 命令,且 App 内无内置运行时。\n请重新下载最新版 App,或在终端运行:\n  npm install -g @deepseek-ai/dsh\n然后重新打开本 App。" buttons {"好"} default button "好" with icon caution' >/dev/null 2>&1
    exit 1
  fi
  DSH_CMD=("$DSH")
  log "使用系统 dsh: $DSH"
fi

# ---------------- 启动 dsh web(若 3080 未运行) ----------------
port_open() { lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; }

if port_open; then
  log "dsh web 已在 127.0.0.1:$PORT 运行,直接打开 App"
  DSH_PID=""
else
  log "启动 dsh web (后台): ${DSH_CMD[*]} web --port $PORT"
  cd "$HOME" || exit 1
  nohup "${DSH_CMD[@]}" web --port "$PORT" >> "$LOG" 2>&1 &
  DSH_PID=$!
  # 等待端口就绪,最多 60 秒(首次运行会初始化 web profile,稍慢)
  for _ in $(seq 1 120); do
    port_open && break
    sleep 0.5
  done
  if port_open; then
    log "dsh web 就绪 (pid=$DSH_PID)"
  else
    log "警告: 等待 dsh web 超时,详见上方日志"
  fi
fi

# ---------------- 启动 App 本体 ----------------
# 清理可能残留的单实例 socket(仅当无进程持有时删除,避免与运行中的 App 冲突)
SI_SOCK="/tmp/com_dsh_web_si.sock"
if [ -S "$SI_SOCK" ] && ! lsof "$SI_SOCK" >/dev/null 2>&1; then
  rm -f "$SI_SOCK"
  log "清理了残留的单实例 socket: $SI_SOCK"
fi

log "启动 App 二进制: $BIN"
"$BIN"
BIN_CODE=$?
log "App 二进制已退出 (code=$BIN_CODE)"

# ---------------- 退出后清理 ----------------
# 停掉我们这次启动的 dsh web(若端口本来就有服务则不动)
if [ -n "$DSH_PID" ]; then
  if kill -0 "$DSH_PID" 2>/dev/null; then
    pkill -P "$DSH_PID" 2>/dev/null
    sleep 1
    if kill -0 "$DSH_PID" 2>/dev/null; then kill -9 "$DSH_PID" 2>/dev/null; fi
    log "App 已退出,dsh web (pid=$DSH_PID) 已停止"
  fi
fi
exit 0
