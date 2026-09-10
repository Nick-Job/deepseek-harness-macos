#!/bin/bash
# ============================================================
# launcher-smoke-test.sh —— 启动壳（用户双击的那一层）的行为验收
#
# smoke-test.sh 验的是"内置运行时本身不弹浏览器、首页直接可用"；
# 这个脚本验的是**启动壳**：用户双击 App 时真正跑的那段逻辑。
#
# 做法：拿构建好的 .app 搭一个"假 App"——运行时和脚本用软链指过去，
# 把真正会开窗口的二进制换成一个立刻退出的桩，于是整条启动链路能在
# CI 里跑完，而不会弹出任何窗口。
#
# 断言：
#   1. 启动壳确实选中了内置运行时，并且 dsh web 在指定端口就绪（首页 200）
#   2. 全程没有任何"打开浏览器"的尝试（浏览器闸门没被触发、日志没有 opening the default browser）
#   3. App 本体退出后，本次启动的 dsh web 一起被收掉，端口释放、不留后台进程
#
# 用法: ./scripts/launcher-smoke-test.sh --app "DeepSeek Harness.app" [--port N]
# ============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP=""
PORT="3291"

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "[launcher-smoke-test] ✗ $*" >&2; exit 1; }
pass() { echo "[launcher-smoke-test] ✓ $*"; }

[ -n "$APP" ] || fail "需要 --app 指定构建好的 .app"
[ -d "$APP" ] || fail "找不到 App: $APP"
[ -x "$APP/Contents/MacOS/pake-deepseekharness" ] || fail "App 里没有启动壳"
[ -d "$APP/Contents/Resources/scripts" ] || fail "App 里没有注入辅助脚本（scripts/）"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FAKE="$WORK/Fake.app"
mkdir -p "$FAKE/Contents/MacOS" "$FAKE/Contents/Resources"
cp "$APP/Contents/MacOS/pake-deepseekharness" "$FAKE/Contents/MacOS/pake-deepseekharness"
chmod +x "$FAKE/Contents/MacOS/pake-deepseekharness"
# 运行时只有几百 MB，用软链指回真实 App 避免复制；
# 脚本目录必须是"真文件"——更新核查脚本靠自身路径定位 Resources，
# 软链会让它解析到真实 App 那边，测的就不是这个假 App 了。
cp -R "$APP/Contents/Resources/scripts" "$FAKE/Contents/Resources/scripts"
ln -s "$(cd "$APP/Contents/Resources" && pwd)/runtime" "$FAKE/Contents/Resources/runtime"

# App 本体换成桩：跑 5 秒就退出（正常退出路径，触发启动壳的清理逻辑）
cat > "$FAKE/Contents/MacOS/pake-deepseekharness-bin" <<'STUB'
#!/bin/bash
echo "[stub] fake app binary running"
sleep 5
exit 0
STUB
chmod +x "$FAKE/Contents/MacOS/pake-deepseekharness-bin"

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "端口 $PORT 已被占用，无法测试"
fi

LOG="$WORK/launcher.log"
export DSH_DESKTOP_PORT="$PORT"
export DSH_DESKTOP_LOG="$LOG"
export DSH_DESKTOP_SUPPORT_DIR="$WORK/support"
export DSH_DESKTOP_NO_NOTIFY=1
export DSH_DESKTOP_AUTO_UPDATE=0
# dsh 的 profile/会话都在 DSH_HOME 下：测试用独立目录，绝不碰用户真实的 ~/.dsh
export DSH_HOME="$WORK/dsh-home"
mkdir -p "$DSH_DESKTOP_SUPPORT_DIR" "$DSH_HOME"

echo "[launcher-smoke-test] 启动假 App（端口 ${PORT}，日志 ${LOG}）..."
"$FAKE/Contents/MacOS/pake-deepseekharness" > "$WORK/stdout.log" 2>&1
LAUNCHER_CODE=$?

# ---- 断言 1：运行时选择 + 服务就绪 ----
grep -q "运行时: 内置运行时" "$LOG" || { cat "$LOG" >&2; fail "启动壳没有选中内置运行时"; }
pass "选中内置运行时"
grep -q "dsh web 就绪" "$LOG" || { cat "$LOG" >&2; fail "dsh web 没有就绪（首页未返回 200）"; }
pass "dsh web 就绪（首页无 cookie 返回 200）"

# ---- 断言 2：全程没开浏览器 ----
if grep -q "opening the default browser" "$LOG"; then
  cat "$LOG" >&2
  fail "dsh web 试图打开默认浏览器"
fi
if grep -q "open-guard: 已拦截" "$LOG"; then
  cat "$LOG" >&2
  fail "有代码试图用浏览器打开本机界面（被闸门拦下，但不该发生）"
fi
pass "全程没有打开浏览器的尝试"

# ---- 断言 3：退出后收干净 ----
grep -q "启动 App 二进制" "$LOG" || { cat "$LOG" >&2; fail "启动壳没有拉起 App 本体"; }
grep -q "App 二进制已退出 (code=0)" "$LOG" || { cat "$LOG" >&2; fail "App 本体异常退出"; }
pass "App 本体被正常拉起并退出 (code=$LAUNCHER_CODE)"

sleep 2
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  cat "$LOG" >&2
  fail "退出后 dsh web 仍在 $PORT 上监听，后台进程没清干净"
fi
pass "退出后端口已释放，无残留后台进程"

echo "[launcher-smoke-test] 全部通过"
