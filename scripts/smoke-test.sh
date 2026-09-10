#!/bin/bash
# ============================================================
# smoke-test.sh —— 打包产出前的行为验收
#
# 只验证两件"用户会立刻感觉到"的事：
#   1. 内置 dsh web 能在 --no-open 下起来，且**不打开任何浏览器**；
#   2. 首页在无 cookie 情况下直接返回 200（说明浏览器信任认证补丁生效，
#      Pake 窗口不会撞 401）。
#
# 两件事都靠真实进程验证，而不是 grep 源码——上游改了实现也一样能测出来。
#
# 用法: ./scripts/smoke-test.sh [--runtime-dir DIR] [--port N]
#   默认 runtime 目录: ./runtime  端口: 自动挑一个空闲的
# ============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/runtime"
PORT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --runtime-dir) RUNTIME_DIR="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

NODE="$RUNTIME_DIR/bin/node"
DSH_JS="$RUNTIME_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js"

fail() { echo "[smoke-test] ✗ $*" >&2; exit 1; }
pass() { echo "[smoke-test] ✓ $*"; }

[ -x "$NODE" ] || fail "找不到可执行的内置 node: $NODE"
[ -f "$DSH_JS" ] || fail "找不到内置 dsh 入口: $DSH_JS"

WORK="$(mktemp -d)"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  sleep 1
  for pid in "${PIDS[@]:-}"; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------- 浏览器闸门探针 ----------
# 把 open 换成记录器：真的有人想开浏览器，就会在这里留下 traces。
SHIM_DIR="$WORK/open-shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/open" <<'SHIM'
#!/bin/bash
echo "$*" >> "$OPEN_PROBE_FILE"
exit 0
SHIM
chmod +x "$SHIM_DIR/open"

# ---------- 挑端口 ----------
pick_port() {
  if [ -n "$PORT" ]; then echo "$PORT"; return; fi
  local candidate
  for candidate in 3280 3281 3282 3283 3284 3285; do
    if ! lsof -nP -iTCP:"$candidate" -sTCP:LISTEN >/dev/null 2>&1; then echo "$candidate"; return; fi
  done
  fail "找不到空闲端口用于冒烟测试"
}
PORT="$(pick_port)"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "端口 $PORT 已被占用，无法进行冒烟测试"
fi

# 用独立的 DSH_HOME：不碰用户真实的 ~/.dsh（dsh 会自己脚手架出 web profile）
export DSH_HOME="$WORK/dsh-home"
mkdir -p "$DSH_HOME"
export OPEN_PROBE_FILE="$WORK/open-calls.log"
export PATH="$SHIM_DIR:$PATH"

LOG="$WORK/dsh.log"
"$NODE" "$DSH_JS" web --no-open --port "$PORT" > "$LOG" 2>&1 &
PIDS+=($!)

# ---------- 等首页真的可用（端口 listen != 首页可服务，必须等 200）----------
STATUS=""
for _ in $(seq 1 120); do
  STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/" 2>/dev/null)"
  [ "$STATUS" = "200" ] && break
  kill -0 "${PIDS[0]}" 2>/dev/null || break
  sleep 1
done

if [ "$STATUS" = "200" ]; then
  pass "首页无 cookie 直接 200（浏览器信任认证已关闭）"
elif [ "$STATUS" = "401" ]; then
  echo "----- dsh web 输出 -----" >&2; tail -20 "$LOG" >&2
  fail "首页返回 401：浏览器信任认证补丁没生效，Pake 壳会撞 'dsh web authentication required'"
else
  echo "----- dsh web 输出 -----" >&2; tail -20 "$LOG" >&2
  fail "首页拿不到 200（实际: ${STATUS:-无响应}）"
fi

# ---------- 断言没人打开浏览器 ----------
if [ -s "$OPEN_PROBE_FILE" ]; then
  echo "被打开的地址: $(cat "$OPEN_PROBE_FILE")" >&2
  fail "dsh web --no-open 仍然试图打开浏览器"
fi
pass "全程未调用 open（--no-open 生效）"

if grep -q "opening the default browser" "$LOG"; then
  fail "dsh web 日志出现 'opening the default browser'"
fi
pass "日志中无自动开浏览器记录"

echo "[smoke-test] 全部通过"
