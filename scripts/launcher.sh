#!/bin/bash
# ============================================================
# DeepSeek Harness 启动壳
#
# 双击 App 时依次做四件事：
#   1. 选运行时：优先用"热更新"装上的覆盖运行时，其次 App 内置运行时
#      （两者取版本更高者，避免旧覆盖压住新版内置），都没有才回退系统 dsh；
#   2. 起 dsh web —— 永远带 --no-open，并且 PATH 最前面挂着 open-guard，
#      双保险确保不会弹出浏览器；
#   3. 等首页真的可用（不是"端口开了"就算），Pake 窗口才不会扑空；
#   4. 后台核查上游版本：有新 dsh 就静默装进覆盖运行时，下次启动生效。
#
# 退出 App 时停掉本次启动的 dsh web，不留后台进程。
# 日志: ~/Library/Logs/deepseek-harness-dsh.log
# ============================================================

DIR="$(cd "$(dirname "$0")" && pwd)"
RES="$(cd "$DIR/../Resources" && pwd)"
BIN="$DIR/pake-deepseekharness-bin"
SCRIPTS="$RES/scripts"
PORT="${DSH_DESKTOP_PORT:-3080}"
LOG="${DSH_DESKTOP_LOG:-$HOME/Library/Logs/deepseek-harness-dsh.log}"
# support 目录放热更新运行时与更新状态；可用环境变量覆盖以便测试隔离
SUPPORT="${DSH_DESKTOP_SUPPORT_DIR:-$HOME/Library/Application Support/DeepSeek Harness}"
export DSH_DESKTOP_SUPPORT_DIR="$SUPPORT"
mkdir -p "$HOME/Library/Logs"
export DSH_DESKTOP_PORT="$PORT"
export DSH_DESKTOP_LOG="$LOG"

# launchd 启动的 App PATH 很精简,补上 node/dsh 所在目录
export PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# 日志超过 2MB 就轮转一次，避免长期使用后无限膨胀
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
  mv -f "$LOG" "$LOG.1" 2>/dev/null || true
fi

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
trap 'log "wrapper 退出 (code=$? pid=$$)"' EXIT

# ---------------- 1. 选运行时 ----------------
RUNTIME=""
RUNTIME_SOURCE=""
NODE=""
DSH_JS=""
HELPER_NODE="$RES/runtime/bin/node"
HELPER_JS="$SCRIPTS/update-check.js"

# 覆盖运行时优先由 helper 判定（谁版本高用谁）；helper 不可用时退回内置运行时
if [ -x "$HELPER_NODE" ] && [ -f "$HELPER_JS" ]; then
  RESOLVED="$("$HELPER_NODE" "$HELPER_JS" resolve-runtime 2>>"$LOG")"
  if [ -n "$RESOLVED" ] && [ -x "$RESOLVED/bin/node" ]; then
    RUNTIME="$RESOLVED"
  fi
fi
if [ -z "$RUNTIME" ] && [ -x "$RES/runtime/bin/node" ]; then
  RUNTIME="$RES/runtime"
fi

if [ -n "$RUNTIME" ]; then
  NODE="$RUNTIME/bin/node"
  DSH_JS="$RUNTIME/node_modules/@deepseek-ai/dsh/lib/bin.js"
  # 用 inode 比较判断"是不是 App 自带的那份"：路径可能被软链绕一圈，字符串比不可靠
  if [ "$RUNTIME" -ef "$RES/runtime" ]; then
    RUNTIME_SOURCE="内置运行时"
  else
    RUNTIME_SOURCE="热更新运行时"
  fi
else
  # 回退: 系统 dsh 命令
  DSH=""
  for c in "$(command -v dsh 2>/dev/null)" "$HOME/.npm-global/bin/dsh" "$HOME/.local/bin/dsh" /usr/local/bin/dsh /opt/homebrew/bin/dsh /usr/bin/dsh; do
    if [ -n "$c" ] && [ -x "$c" ]; then DSH="$c"; break; fi
  done
  if [ -z "$DSH" ]; then
    log "未找到 dsh 命令,也无内置运行时"
    osascript -e 'display dialog "未找到 dsh 命令,且 App 内无内置运行时。\n请重新下载最新版 App,或在终端运行:\n  npm install -g @deepseek-ai/dsh\n然后重新打开本 App。" buttons {"好"} default button "好" with icon caution' >/dev/null 2>&1 &
    exit 1
  fi
  DSH_JS=""
  RUNTIME_SOURCE="系统 dsh"
fi
export PATH="$RES/runtime/bin:$PATH"
# 浏览器闸门放最前面：本机 3080 的"打开浏览器"请求会被静默拦掉，
# 其它 URL 原样转给 /usr/bin/open，不影响正常使用。
if [ -x "$SCRIPTS/open-guard/open" ]; then
  export PATH="$SCRIPTS/open-guard:$PATH"
fi

# 记下版本，用户看日志就能知道桌面端到底跑的是哪一版
VERSION_HINT="未知"
if [ -f "$RUNTIME/version.json" ] && [ -x "$HELPER_NODE" ]; then
  VERSION_HINT="$("$HELPER_NODE" -e '
    const fs = require("fs");
    try {
      const info = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      console.log(`${info.dshVersion ?? "?"} (App ${info.appVersion ?? "?"})`);
    } catch { console.log("未知"); }
  ' "$RUNTIME/version.json" 2>/dev/null || echo "未知")"
fi
log "运行时: $RUNTIME_SOURCE ($RUNTIME), dsh $VERSION_HINT"

# ---------------- 2. 启动 dsh web（若 3080 未运行） ----------------
port_open() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; }
http_status() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/" 2>/dev/null; }

DSH_PID=""

start_dsh() {
  if [ "$RUNTIME_SOURCE" = "系统 dsh" ]; then
    log "启动 dsh web (后台,系统 dsh): $DSH web --no-open --port $PORT"
    cd "$HOME" || exit 1
    nohup "$DSH" web --no-open --port "$PORT" >> "$LOG" 2>&1 &
  else
    log "启动 dsh web (后台,$RUNTIME_SOURCE): $NODE $DSH_JS web --no-open --port $PORT"
    cd "$HOME" || exit 1
    nohup "$NODE" "$DSH_JS" web --no-open --port "$PORT" >> "$LOG" 2>&1 &
  fi
  DSH_PID=$!
}

# 等到首页真的能服务为止（端口 listen 并不等于能出页面）
wait_ready() {
  local deadline="${1:-90}" i status
  for i in $(seq 1 "$deadline"); do
    status="$(http_status)"
    [ "$status" = "200" ] && { echo "200"; return 0; }
    [ "$status" = "401" ] && { echo "401"; return 0; }
    sleep 1
  done
  echo "timeout"
}

if port_open; then
  EXISTING="$(http_status)"
  case "$EXISTING" in
    200) log "dsh web 已在 127.0.0.1:$PORT 运行,直接打开 App" ;;
    401) log "警告: 127.0.0.1:$PORT 上的服务要求浏览器认证(多半是终端里另起的 dsh web)。App 窗口可能显示认证提示,建议先退出那个实例"
         osascript -e "display notification \"端口 $PORT 已被另一个 dsh 实例占用且要求浏览器认证，建议先退出它\" with title \"DeepSeek Harness\"" >/dev/null 2>&1 & ;;
    *)   log "127.0.0.1:$PORT 已被其它程序占用(HTTP $EXISTING),窗口可能无法正常加载" ;;
  esac
else
  start_dsh
  READY="$(wait_ready 90)"
  # 热更新运行时若起不来（依赖不兼容等），废弃它并立刻用内置运行时重试
  if [ "$READY" != "200" ] && ! [ "$RUNTIME" -ef "$RES/runtime" ]; then
    log "热更新运行时未就绪(HTTP $READY)，废弃它并回退内置运行时"
    [ -n "$DSH_PID" ] && { kill "$DSH_PID" 2>/dev/null; sleep 1; kill -9 "$DSH_PID" 2>/dev/null; }
    # 只在"这份运行时确实位于 support 目录内"时才搬走它。
    # 绝不能动 App bundle 里的东西：那里是签名过的应用本体，且搬走后就再也回不来了。
    case "$(cd "$RUNTIME" 2>/dev/null && pwd -P)" in
      "$(cd "$SUPPORT" 2>/dev/null && pwd -P)"/*)
        mv "$RUNTIME" "$SUPPORT/runtime.broken-$(date +%s)" 2>/dev/null \
          || log "警告: 搬走有问题的覆盖运行时失败,已忽略" ;;
      *) log "该运行时不在 support 目录内,只切换不搬运: $RUNTIME" ;;
    esac
    RUNTIME="$RES/runtime"; NODE="$RUNTIME/bin/node"; DSH_JS="$RUNTIME/node_modules/@deepseek-ai/dsh/lib/bin.js"
    RUNTIME_SOURCE="内置运行时(热更新回退)"
    start_dsh
    READY="$(wait_ready 90)"
  fi
  case "$READY" in
    200) log "dsh web 就绪 (pid=$DSH_PID)" ;;
    401) log "警告: 首页返回 401,浏览器信任认证补丁未生效(详见日志上方)" ;;
    *)   log "警告: 等待 dsh web 超时,详见上方日志" ;;
  esac
fi

# ---------------- 3. 后台核查版本更新 ----------------
# 不阻塞启动；发现新 dsh 会静默装进覆盖运行时，下次打开就是新版。
if [ -x "$HELPER_NODE" ] && [ -f "$HELPER_JS" ]; then
  ( "$HELPER_NODE" "$HELPER_JS" auto >>"$LOG" 2>&1 & ) 2>/dev/null
  log "已在后台核查上游 dsh 版本"
fi

# ---------------- 4. 启动 App 本体 ----------------
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
