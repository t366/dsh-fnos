#!/bin/bash
# ============================================================================
# selftest.sh — 在飞牛 NAS 上模拟一次完整安装
#
# 目的：在 appcenter-cli install-fpk 之前，先把 cmd/ 的全部逻辑验证掉。
#       直接装 fpk 一旦失败，能拿到的信息很少；这个脚本能精确定位是哪一步。
#
# 特点：不需要 root、不碰 /var/apps、不占 3080 端口、退出时清理干净。
#
#   bash selftest.sh              # 默认 127.0.0.1:13080
#   TEST_PORT=13081 bash selftest.sh
#
# 在 fnOS 上跑不需要任何参数（会用 /var/apps/nodejs_v24 的 node）。
# 在开发机（Git Bash / macOS）上跑，建议指定 node，否则 start 会报「未找到 Node」：
#   TMPDIR=/e/tmp DSH_TEST_NODE="$(command -v node)" bash selftest.sh
# 注意 TMPDIR 路径不要带盘符冒号（E:/xxx）—— TRIM_DATA_SHARE_PATHS 用 ':' 分隔多路径，
# 盘符会把它切成 "E"，共享目录就解析不到。
# ============================================================================

set -u

HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
ROOT="${TMPDIR:-/tmp}/dsh-selftest-$$"
PORT="${TEST_PORT:-}"

port_free() { # $1=port
  ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

if [ -z "$PORT" ]; then
  # 上一次测试残留的监听会让本轮全线失败（start 会 EADDRINUSE），自动换一个空闲端口
  for p in 13080 13081 13082 13083 13084 13085; do
    if port_free "$p"; then PORT="$p"; break; fi
  done
  PORT="${PORT:-13080}"
fi

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=""

# 权限位、/proc、进程组回收在 Windows/macOS 上语义不同：
# 这类断言在开发机上只会刷屏失败，掩盖真正的问题 → 一律 SKIP，等 fnOS 上跑才判定。
LINUX=no
case "$(uname -s 2>/dev/null)" in Linux) LINUX=yes ;; esac

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

check() { # $1=描述 $2=期望 $3=实际
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  \033[32mPASS\033[0m  %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES="$FAILED_NAMES\n  - $1（期望 $2，实际 $3）"
    printf '  \033[31mFAIL\033[0m  %s（期望 %s，实际 %s）\n' "$1" "$2" "$3"
  fi
}

check_linux() { # 只在 Linux 上判定的断言（权限位、/proc、进程组）
  if [ "$LINUX" = "yes" ]; then
    check "$@"
  else
    SKIP=$((SKIP + 1))
    printf '  \033[33mSKIP\033[0m  %s（非 Linux：权限位/进程语义不同）\n' "$1"
  fi
}

lc() { # 用伪造的 TRIM_* 环境执行生命周期脚本
  # DSH_TEST_DEST 可覆盖 TRIM_APPDEST，用来模拟「同一个目录的另一种写法」
  env \
    TRIM_APPNAME="dsh" \
    TRIM_APPVER="0.1.0-selftest" \
    TRIM_OLD_APPVER="0.0.9" \
    TRIM_APPDEST="${DSH_TEST_DEST:-$ROOT/target}" \
    TRIM_PKGVAR="$ROOT/var" \
    TRIM_PKGETC="$ROOT/etc" \
    TRIM_PKGHOME="$ROOT/home" \
    TRIM_APPDEST_VOL="$ROOT" \
    TRIM_TEMP_LOGFILE="$ROOT/trim-err.txt" \
    TRIM_USERNAME="$(id -un)" \
    TRIM_GROUPNAME="$(id -gn)" \
    TRIM_DATA_SHARE_PATHS="$ROOT/shares/workspace" \
    dsh_bind="${TEST_BIND-127.0.0.1}" \
    dsh_port="$PORT" \
    dsh_apikey="${TEST_API_KEY:-}" \
    DSH_NODE="${DSH_TEST_NODE:-}" \
    bash "$@"
}

cleanup() {
  lc "$HERE/cmd/main" stop >/dev/null 2>&1
  rm -rf "$ROOT" 2>/dev/null
}
trap cleanup EXIT

# ---------------------------------------------------------------- 准备
step "准备沙箱目录"
mkdir -p "$ROOT/target" "$ROOT/var" "$ROOT/etc" "$ROOT/home" "$ROOT/shares/workspace" || {
  say "无法创建 $ROOT"
  exit 1
}
# fpk 里 app/ 的内容会被装到 target/ 根下
cp -a "$HERE/app/." "$ROOT/target/" || { say "复制 app/ 失败"; exit 1; }
say "工作目录：$ROOT"

# ---------------------------------------------------------------- install
step "install_init"
lc "$HERE/cmd/install_init"
check "install_init 退出码" "0" "$?"

step "install_callback"
lc "$HERE/cmd/install_callback"
check "install_callback 退出码" "0" "$?"

if [ -f "$ROOT/etc/settings.conf" ]; then
  MODE="$(stat -c %a "$ROOT/etc/settings.conf" 2>/dev/null)"
else
  MODE="missing"
fi
check_linux "settings.conf 已创建" "600" "$MODE"

# dsh-home 必须落在共享目录（data-share）里：@appdata 会被卸载连根删掉
HOME_DIR="$ROOT/shares/workspace/.dsh-home"
check "dsh-home 在共享目录里" "yes" "$([ -d "$HOME_DIR" ] && echo yes || echo no)"
check_linux "dsh-home 权限" "700" "$(stat -c %a "$HOME_DIR" 2>/dev/null)"
check_linux "配置副本（跨卸载用）" "600" "$(stat -c %a "$HOME_DIR/settings.conf" 2>/dev/null)"

if [ -f "$ROOT/etc/settings.conf" ]; then
  say "  settings.conf:"
  sed 's/^/    /' "$ROOT/etc/settings.conf" | sed 's/\(DSH_API_KEY=\).*/\1<略>/'
fi

# ---------------------------------------------------------------- start
step "main start"
lc "$HERE/cmd/main" start
START_RC=$?
check "start 退出码" "0" "$START_RC"

if [ "$START_RC" != "0" ] && [ -s "$ROOT/trim-err.txt" ]; then
  say "  用户在应用中心会看到："
  sed 's/^/    /' "$ROOT/trim-err.txt"
fi

# 工作目录必须来自 resource.data-share（TRIM_DATA_SHARE_PATHS），
# 不能回落到 /var/apps/dsh/... —— 那会把测试写进真实安装目录，
# 也会让「共享目录没建对」这个问题在测试里被掩盖。
if grep -qF "cwd=$ROOT/shares/workspace" "$ROOT/var/info.log" 2>/dev/null; then
  check "工作目录取自 data-share" "yes" "yes"
else
  check "工作目录取自 data-share" "yes" "$(grep -o 'cwd=[^ ]*' "$ROOT/var/info.log" 2>/dev/null | tail -n1 || echo '<无 cwd 行>')"
fi

step "main status（应为运行中）"
lc "$HERE/cmd/main" status
check_linux "status 退出码 = 0（运行中）" "0" "$?"

PID1="$(awk '{print $1}' "$ROOT/var/dsh.pid" 2>/dev/null)"
PGID1="$(awk '{print $2}' "$ROOT/var/dsh.pid" 2>/dev/null)"
say "  pid=$PID1 pgid=$PGID1"

step "status 的路径写法（软链 vs 真实路径）"
# 真机踩到的坑：start 由应用中心触发（TRIM_APPDEST=/vol1/@appcenter/dsh），
# 而手工/脚本调 status 没有 TRIM_*，算出 /var/apps/dsh/target（软链）。
# 两种写法指向同一目录，命令行里出现的却是不同字符串 → 旧逻辑认不出，
# 结局是「进程在跑，status 却返回 3」。这里用软链复现这条路径。
if ln -sfn "$ROOT/target" "$ROOT/target-link" 2>/dev/null && [ -L "$ROOT/target-link" ]; then
  DSH_TEST_DEST="$ROOT/target-link" lc "$HERE/cmd/main" status >/dev/null 2>&1
  check_linux "经软链路径调 status 仍 = 0" "0" "$?"
else
  say "  跳过（当前文件系统建不了真软链）"
fi

step "HTTP 探测"
if command -v curl >/dev/null 2>&1; then
  CODE="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null)"
  check "GET / 返回 200" "200" "$CODE"
  BODY="$(curl -s -m 5 "http://127.0.0.1:$PORT/healthz" 2>/dev/null)"
  case "$BODY" in
    *'"ok":true'*) check "GET /healthz 正常" "ok" "ok" ;;
    *)             check "GET /healthz 正常" "ok" "${BODY:-空}" ;;
  esac
else
  say "  跳过（没有 curl）"
fi

step "幂等性：重复 start"
lc "$HERE/cmd/main" start
check_linux "重复 start 退出码" "0" "$?"
PID2="$(awk '{print $1}' "$ROOT/var/dsh.pid" 2>/dev/null)"
check_linux "PID 未变化（没有起第二份）" "$PID1" "$PID2"

# ---------------------------------------------------------------- stop
step "main stop"
lc "$HERE/cmd/main" stop
check "stop 退出码" "0" "$?"

step "main status（应为未运行）"
lc "$HERE/cmd/main" status
check_linux "status 退出码 = 3（未运行）" "3" "$?"

step "端口已释放"
if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
  check_linux "端口 $PORT 已释放" "closed" "still open"
else
  check_linux "端口 $PORT 已释放" "closed" "closed"
fi

step "幂等性：重复 stop"
lc "$HERE/cmd/main" stop
check "重复 stop 退出码" "0" "$?"

# ---------------------------------------------------------------- 卸载重装
step "模拟卸载重装（@appdata / @appconf 被清空）"
# 真机实测：fnOS 卸载会把 @appdata / @appconf / @apphome 连根删掉，
# 只有 data-share 活着。这里删掉 var/ 与 etc/ 复现那一幕。
echo marker >"$HOME_DIR/.keep-test"
rm -rf "$ROOT/var" "$ROOT/etc"
mkdir -p "$ROOT/var" "$ROOT/etc"
# 第一次：带 Key 与自定义绑定装一遍（这两项会被写进共享目录里的副本）
TEST_API_KEY="sk-selftest-1234" TEST_BIND="10.9.8.7" lc "$HERE/cmd/install_callback"
check_linux "重装后 settings.conf 重建" "600" "$(stat -c %a "$ROOT/etc/settings.conf" 2>/dev/null)"
check "Key 已写入副本" "sk-selftest-1234" \
  "$(grep -E '^DSH_API_KEY=' "$HOME_DIR/settings.conf" 2>/dev/null | cut -d= -f2-)"

# 第二次：完全空白安装（不带 Key、binding 留空 = 保留旧值）
rm -rf "$ROOT/var" "$ROOT/etc"
mkdir -p "$ROOT/var" "$ROOT/etc"
TEST_API_KEY="" TEST_BIND="" lc "$HERE/cmd/install_callback"
check "API Key 从副本恢复" "sk-selftest-1234" \
  "$(grep -E '^DSH_API_KEY=' "$ROOT/etc/settings.conf" 2>/dev/null | cut -d= -f2-)"
check "绑定地址从副本恢复" "10.9.8.7" \
  "$(grep -E '^DSH_BIND=' "$ROOT/etc/settings.conf" 2>/dev/null | cut -d= -f2-)"
check "会话目录跨卸载存活" "yes" \
  "$([ -f "$HOME_DIR/.keep-test" ] && echo yes || echo no)"

step "模拟 dsh 模式（进程编排：跳转器占 service_port、dsh 退到 +1）"
# 为什么用假的 dsh：真运行时 866MB，不可能进 selftest。
# 但「检测到 dsh 模式」「跳转器占 service_port」「抓 token URL」这些只有 dsh 模式才跑，
# 而入口是用户唯一的进门方式。这一段验证进程编排，下一段单独验证跳转器的 HTTP 行为。
TEST_BIND="127.0.0.1" lc "$HERE/cmd/install_callback" >/dev/null 2>&1
FAKE="$ROOT/target/runtime/app/node_modules/@deepseek-ai/dsh"
mkdir -p "$FAKE/bin"
cat >"$FAKE/package.json" <<'JSON'
{ "name": "@deepseek-ai/dsh", "version": "0.0.0-fake", "bin": { "dsh": "bin/dsh.js" } }
JSON
cat >"$FAKE/bin/dsh.js" <<'JS'
// 假 dsh：按 --host/--port 监听，并打印带 token 的入口 URL
const http = require('http');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const host = opt('--host', '127.0.0.1');
const port = Number(opt('--port', '0'));
http.createServer((req, res) => { res.writeHead(200); res.end('fake-dsh'); })
  .listen(port, host, () => {
    console.log(`dsh web: http://${host}:${port}/?token=faketoken_1234567890`);
  });
JS

if [ "$LINUX" = "yes" ]; then
  DBIND=127.0.0.1
  DPORT=$((PORT + 1))

  lc "$HERE/cmd/main" start
  check "dsh 模式 start 退出码" "0" "$?"
  check "dsh 模式被识别" "yes" \
    "$(grep -q 'start: mode=dsh' "$ROOT/var/info.log" 2>/dev/null && echo yes || echo no)"

  LPIDF="$ROOT/var/launcher.pid"
  check "跳转器 pidfile 已写" "yes" "$([ -s "$LPIDF" ] && echo yes || echo no)"
  check "跳转器进程存活" "yes" \
    "$(p="$(cut -d' ' -f1 "$LPIDF" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo yes || echo no)"

  check "入口 URL 已落到 dsh-url.txt" "yes" \
    "$([ -s "$ROOT/var/dsh-url.txt" ] && echo yes || echo no)"
  check_linux "dsh-url.txt 权限" "600" "$(stat -c %a "$ROOT/var/dsh-url.txt" 2>/dev/null)"
  check "URL 指向内部端口 $DPORT" "yes" \
    "$(grep -q ":$DPORT/" "$ROOT/var/dsh-url.txt" 2>/dev/null && echo yes || echo no)"
  check "URL 里带 token" "yes" \
    "$(grep -q 'token=faketoken_1234567890' "$ROOT/var/dsh-url.txt" 2>/dev/null && echo yes || echo no)"
  check "跳转器 state 已写" "yes" \
    "$([ -s "$ROOT/var/launcher.json" ] && echo yes || echo no)"
  check "state 里的 host 正确" "$DBIND" \
    "$(sed -nE 's/.*"host":"([^"]*)".*/\1/p' "$ROOT/var/launcher.json" 2>/dev/null)"
  check "state 里的端口是内部端口" "$DPORT" \
    "$(sed -nE 's/.*"port":([0-9]+).*/\1/p' "$ROOT/var/launcher.json" 2>/dev/null)"
  # 跳转器不再需要人粘令牌，全靠这个字段
  check "state 里带 token" "faketoken_1234567890" \
    "$(sed -nE 's/.*"token":"([^"]*)".*/\1/p' "$ROOT/var/launcher.json" 2>/dev/null)"

  # 幂等：重复 start 不该重启 dsh（会打断会话），也不该换 token
  UTOK1="$(cat "$ROOT/var/dsh-url.txt" 2>/dev/null)"
  lc "$HERE/cmd/main" start >/dev/null 2>&1
  check "重复 start 不换 token" "$UTOK1" "$(cat "$ROOT/var/dsh-url.txt" 2>/dev/null)"

  lc "$HERE/cmd/main" stop >/dev/null 2>&1
  check "stop 后跳转器已退出" "yes" \
    "$(p="$(cut -d' ' -f1 "$LPIDF" 2>/dev/null)"; if [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null; then echo yes; else echo no; fi)"
  check "stop 后 state 已删" "yes" \
    "$([ -f "$ROOT/var/launcher.json" ] && echo no || echo yes)"

  # 重启必须重新抓（新 token），不能把旧 URL 当作现役
  printf 'http://127.0.0.1:%s/?token=stale_old_token\n' "$DPORT" >"$ROOT/var/dsh-url.txt"
  lc "$HERE/cmd/main" start >/dev/null 2>&1
  check "重启后 URL 被刷新（不是旧 token）" "yes" \
    "$(grep -q 'faketoken_1234567890' "$ROOT/var/dsh-url.txt" 2>/dev/null && echo yes || echo no)"
  lc "$HERE/cmd/main" stop >/dev/null 2>&1
else
  SKIP=$((SKIP + 13))
  printf '  \033[33mSKIP\033[0m  dsh 模式进程编排（Windows 上 stop 杀不掉原生进程，会串到下一段）\n'
fi
rm -rf "$ROOT/target/runtime/app"

step "入口跳转器（自动进入 + 配对，跨平台）"
# 这一段不依赖 main：直接起一个假的 dsh 上游 + 跳转器，验证 HTTP 行为。
# 之所以要单独测：入口是用户唯一的进门动作，错了就是「装好了但进不去」，
# 而且这类错在真机上只能靠人去点，代价很高。
NODE_FOR_TEST="${DSH_TEST_NODE:-$(command -v node 2>/dev/null || true)}"
if [ -z "${NODE_FOR_TEST:-}" ]; then
  SKIP=$((SKIP + 11))
  printf '  \033[33mSKIP\033[0m  入口跳转器（没有 node 可用于起测试进程）\n'
else
  G="$ROOT/gate"
  mkdir -p "$G"

  free_port() { # $1=端口：能 bind 就算空闲
    "$NODE_FOR_TEST" -e 'const n=require("net");const s=n.createServer();
      s.on("error",()=>process.exit(1));
      s.listen(Number(process.argv[1]),"127.0.0.1",()=>s.close(()=>process.exit(0)));' "$1" 2>/dev/null
  }

  GP=""
  for i in 1 2 3 4 5 6 7 8; do
    free_port $((13280 + i)) && { GP=$((13280 + i)); break; }
  done
  UP=""
  for i in 1 2 3 4 5 6 7 8; do
    free_port $((13300 + i)) && { UP=$((13300 + i)); break; }
  done

  if [ -z "$GP" ] || [ -z "$UP" ]; then
    SKIP=$((SKIP + 8))
    printf '  \033[33mSKIP\033[0m  入口跳转器（找不到空闲端口）\n'
  else
    TOK="TESTTOKEN123456"
    cat >"$G/up.cjs" <<'JS'
// 假 dsh 上游：只认一个 token，认得就 303，否则 401
const http = require('http');
const args = process.argv.slice(2);
const port = Number(args[args.indexOf('--port') + 1]);
const TOK = args[args.indexOf('--token') + 1];
http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.searchParams.get('token') === TOK) { res.writeHead(303, { location: '/' }); res.end(); }
  else { res.writeHead(401); res.end('denied'); }
}).listen(port, '127.0.0.1', () => console.log('up ready'));
JS

    # 故意把 url 的主机名写成 localhost:9999：真实的 dsh 会打印它自己监听的回环
    # 地址，跳转器必须用「绑定 IP + 内部端口」重建，照抄就把浏览器送到用户自己的
    # 电脑上。这一段就是在验证那件事。
    mkstate() { # $1=token $2=since
      printf '{"url":"http://localhost:9999/?token=%s","token":"%s","host":"127.0.0.1","port":%s,"since":%s}\n' \
        "$1" "$1" "$UP" "${2:-$(date +%s)}" >"$G/launcher.json"
    }
    mkstate "$TOK"

    "$NODE_FOR_TEST" "$G/up.cjs" --port "$UP" --token "$TOK" >"$G/up.log" 2>&1 &
    UP_PID=$!

    # 等假上游真的开始监听再往下走。
    # 不等的话第一发 curl 会在 node 冷启动的窗口里被拒（exit 7），http_code 记成 000，
    # 看起来像「跳转器给了错地址」，实际只是测试跑得比上游快。真机上 node 冷启要几百毫秒，
    # 打包时机器还有别的负载，这个窗口很容易撞上。
    wait_up() {
      local i=0 code
      while [ "$i" -lt 80 ]; do
        code="$(curl -s -m 1 -o /dev/null -w '%{http_code}' \
                 "http://127.0.0.1:$UP/?token=$TOK" 2>/dev/null)"
        [ "$code" = "303" ] && return 0
        sleep 0.25
        i=$((i + 1))
      done
      return 1
    }
    if ! wait_up; then
      printf '  \033[33mWARN\033[0m  假上游 20s 内没就绪（看 %s）\n' "$G/up.log"
    fi

    start_gate() { # $1=auth
      "$NODE_FOR_TEST" "$HERE/app/runtime/launcher/server.mjs" \
        --host 127.0.0.1 --port "$GP" --state "$G/launcher.json" --auth "$1" >"$G/gate.log" 2>&1 &
      G_PID=$!
      i=0
      while [ "$i" -lt 40 ]; do
        if curl -s -m 1 -o /dev/null "http://127.0.0.1:$GP/healthz" 2>/dev/null; then return 0; fi
        sleep 0.25
        i=$((i + 1))
      done
      return 1
    }

    stop_gate() {
      [ -n "${G_PID:-}" ] && kill "$G_PID" 2>/dev/null
      # 等端口真正释放：紧接着要用同一个端口起下一个模式，太快会 EADDRINUSE
      sleep 0.5
    }

    hdr() { curl -s -m 5 -o /dev/null -D - "$@" 2>/dev/null; }
    hcode() { printf '%s' "$1" | sed -nE 's#^HTTP/[0-9.]+ ([0-9]{3}).*#\1#p' | head -n1; }
    hloc() { printf '%s' "$1" | sed -nE 's/^[Ll]ocation: *(.*[^ ]) *\r?$/\1/p' | head -n1; }

    if ! start_gate auto; then
      check "跳转器可启动（auto）" "yes" "no（看 $G/gate.log）"
      SKIP=$((SKIP + 11))
    else
      # ---- auto：点图标直接进（这是用户唯一想做的事）----
      H="$(hdr "http://127.0.0.1:$GP/")"
      LOC="$(hloc "$H")"
      check "auto：点图标直接 302" "302" "$(hcode "$H")"
      check "auto：跳转地址带本次令牌" "yes" \
        "$(printf '%s' "$LOC" | grep -q "token=$TOK" && echo yes || echo no)"
      check "auto：用绑定地址重建，不照抄日志里的 localhost" "yes" \
        "$(printf '%s' "$LOC" | grep -q "http://127.0.0.1:$UP/" && echo yes || echo no)"
      # 令牌拿去请求上游必须是 303（假 dsh 认得它）。这条能抓住 Location 拼错、
      # 端口写错、token 截断之类「看着像 302 但点了进不去」的问题。
      ACODE="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$LOC" 2>/dev/null)"
      if [ "$ACODE" != "303" ]; then
        # 单发 000 多半是瞬时的连接失败（上游刚起、或 accept 队列被别的请求占着），
        # 重试两次；仍然不行才判失败，并把证据打出来，省得又要人肉回传现场。
        for _ in 1 2; do
          sleep 0.4
          ACODE="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$LOC" 2>/dev/null)"
          [ "$ACODE" = "303" ] && break
        done
      fi
      check "auto：上游接受这条令牌（303）" "303" "${ACODE:-无}"
      if [ "$ACODE" != "303" ]; then
        printf '    诊断 LOC=%s\n' "$LOC"
        printf '    诊断 curl：%s\n' \
          "$(curl -s -m 5 -o /dev/null "$LOC" 2>&1 | head -n 2 | tr '\n' ' ')"
        printf '    诊断 上游日志：%s\n' \
          "$(tr '\n' ' ' <"$G/up.log" 2>/dev/null | head -c 300)"
        printf '    诊断 监听：%s\n' \
          "$(ss -ltn 2>/dev/null | grep -E ":$UP " | tr -s ' ')"
      fi
      check "auto：/healthz 自报 auto" "yes" \
        "$(curl -s -m 3 "http://127.0.0.1:$GP/healthz" 2>/dev/null | grep -q '"auto":true' && echo yes || echo no)"
      stop_gate

      # 抓不到令牌时不能把人送到 dsh 的 401 页，要给一个能看懂的说明页
      mkstate "" 0
      if start_gate auto; then
        check "auto：无令牌给说明页而非 302" "200" \
          "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$GP/" 2>/dev/null)"
      fi
      stop_gate

      # ---- pair：老行为，留给不想让内网直接进的用户 ----
      mkstate "$TOK"
      if start_gate pair; then
        BODY="$(curl -s -m 3 "http://127.0.0.1:$GP/" 2>/dev/null)"
        check "pair：未配对访客看到配对页" "yes" \
          "$(printf '%s' "$BODY" | grep -q '配对这台设备' && echo yes || echo no)"
        check "pair：配对页不泄露令牌" "yes" \
          "$(printf '%s' "$BODY" | grep -q "$TOK" && echo no || echo yes)"

        PH="$(curl -s -m 5 -o /dev/null -D - -X POST --data-urlencode "token=$TOK" \
              "http://127.0.0.1:$GP/pair" 2>/dev/null)"
        CK="$(printf '%s' "$PH" | sed -nE 's/^[Ss]et-[Cc]ookie: *(dsh_gate=[^;]+).*/\1/p' | head -n1)"
        check "pair：正确令牌 → 302" "302" "$(hcode "$PH")"
        check "pair：下发 dsh_gate cookie" "yes" "$([ -n "$CK" ] && echo yes || echo no)"

        LH="$(curl -s -m 5 -o /dev/null -D - -H "Cookie: $CK" "http://127.0.0.1:$GP/" 2>/dev/null)"
        check "pair：已配对 → 302" "302" "$(hcode "$LH")"
        check "pair：跳转目标带当前令牌" "yes" \
          "$(printf '%s' "$(hloc "$LH")" | grep -q "token=$TOK" && echo yes || echo no)"

        check "pair：伪造 cookie 不算配对" "200" \
          "$(curl -s -m 5 -o /dev/null -w '%{http_code}' \
             -H "Cookie: dsh_gate=abcdef0123456789.9999999999.deadbeef" \
             "http://127.0.0.1:$GP/" 2>/dev/null)"

        for _ in 1 2 3 4 5; do
          curl -s -m 3 -o /dev/null -X POST --data 'token=deadbeefdeadbeef' "http://127.0.0.1:$GP/pair" 2>/dev/null
        done
        check "pair：连续错误触发限速" "429" \
          "$(curl -s -m 3 -o /dev/null -w '%{http_code}' -X POST --data 'token=deadbeefdeadbeef' \
             "http://127.0.0.1:$GP/pair" 2>/dev/null)"
      fi
      stop_gate
    fi

    kill "$G_PID" "$UP_PID" 2>/dev/null
    sleep 0.3
  fi
fi

step "日志"
if [ -f "$ROOT/var/info.log" ]; then
  sed 's/^/    /' "$ROOT/var/info.log" | tail -n 25
else
  say "    (没有 info.log)"
fi

# ---------------------------------------------------------------- 汇总
step "结果"
say "通过 $PASS / 跳过 $SKIP / 失败 $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '失败项：%b\n' "$FAILED_NAMES"
  say ""
  say "提示：日志在 $ROOT/var/info.log（脚本退出时会被删除，需要保留请先 cp）"
  # 保留现场便于排查
  trap - EXIT
  say "已保留沙箱目录：$ROOT"
  exit 1
fi

say "全部通过，可以进入 fnpack 打包：bash build.sh"
exit 0
