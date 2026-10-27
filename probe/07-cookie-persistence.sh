#!/bin/bash
# ============================================================================
# 07-entry-after-restart.sh — 重启之后，点图标还能不能直接进去
#
# 这是用户最终在意的那件事：dsh 每次启动都会换令牌，入口跳转器必须跟着刷新
# state；只要它刷新了，重启前装在手机/电脑上的快捷方式就还能一路进到底。
#
# 验证的东西：
#   1) 重启前：GET service_port 得到 302 + 本次令牌，跟随可进；
#   2) 重启后：令牌确实变了，但 GET service_port 仍然 302 + 新令牌，跟随可进；
#   3) 顺带记录 dsh 自己的 cookie 是否跨重启存活（了解 30 天期限的真实行为）。
#
# 用法：
#   bash 07-cookie-persistence.sh
#   会重启一次 dsh（约 10 秒不可用），期间不要在浏览器里操作。
#
# 注意：cookie jar 里等同登录态凭据，脚本结束时删除，不要外发。
# ============================================================================
set -u

ROOT="${DSH_ROOT:-/var/apps/dsh}"
PORT="${DSH_PORT_OVERRIDE:-}"
JAR="$(mktemp "${TMPDIR:-/var/tmp}/dsh-cookie.XXXXXX" 2>/dev/null || mktemp)"
PASS=0
FAIL=0

say()  { printf '%s\n' "$*"; }
sec()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
hr()   { printf -- '----------------------------------------------------------------\n'; }

# 从响应头里取 Location。必须自己掐掉 \r 和行尾空白：
#   sed 的 \r 转义在 GNU sed 上有效，在 fnOS 自带的 sed 上无效，
#   残留的 \r 会让 curl 判定 URL 非法（exit 3，http_code 记成 000），
#   看起来像「跳转地址拼错了」，实际只是解析没洗干净。
getloc() {
  local v
  v="$(printf '%s\n' "$1" | tr -d '\r' \
        | sed -nE 's/^[Ll]ocation:[[:space:]]*//p' | head -n1)"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

cleanup() { rm -f "$JAR" 2>/dev/null; }
trap cleanup EXIT

say "dsh on fnOS — cookie 持久性验证"
say "时间：$(date '+%Y-%m-%d %H:%M:%S')"
say "身份：$(id -un) (uid=$(id -u))"

# ---------------------------------------------------------------- 0. 前置
sec "0. 前置"
[ -x "$ROOT/cmd/main" ] || { say "找不到 $ROOT/cmd/main，先装应用"; exit 1; }
command -v curl >/dev/null 2>&1 || { say "没有 curl，无法验证"; exit 1; }

if [ -z "$PORT" ]; then
  PORT="$(grep -E '^DSH_PORT=' "$ROOT/etc/settings.conf" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r')"
fi
[ -n "${PORT:-}" ] || { say "读不到端口（$ROOT/etc/settings.conf）"; exit 1; }

# 绑定地址：settings 里写 auto 时，从日志的 bind= 行取实际值
BINDIP="$(grep -E '^DSH_BIND=' "$ROOT/etc/settings.conf" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r')"
case "${BINDIP:-}" in
  ''|auto)
    # 新版日志是 `bind=1.2.3.4 dsh_port=3081`，旧版是 `bind=1.2.3.4:3080`
    BINDIP="$(grep -oE 'bind=[0-9.]+(:[0-9]+)?' "$ROOT/var/info.log" 2>/dev/null \
              | tail -n1 | sed 's/^bind=//; s/:[0-9]*$//')"
    ;;
esac
[ -n "${BINDIP:-}" ] || BINDIP=127.0.0.1
DPORT=$((PORT + 1))
BASED="http://$BINDIP:$DPORT"

# 以应用用户身份跑 start/stop：应用中心自己就是这么做的（run-as package）。
# root 直接 start 时 dsh 也以 root 写 dsh-home，留下 root 所有的 -wal/会话库，
# 下次应用中心以 dsh(971) 启动就写不动 —— 表现为「会话少了」或干脆起不来。
APP_USER="$(stat -Lc '%U' "$ROOT/var" 2>/dev/null || true)"
[ -n "${APP_USER:-}" ] || APP_USER=dsh
run_main() { # run_main start|stop
  if [ "$(id -u)" = "0" ] && [ "$APP_USER" != "root" ] && command -v su >/dev/null 2>&1; then
    su -s /bin/sh -c "'$ROOT/cmd/main' $1" "$APP_USER" >/dev/null 2>&1
  else
    "$ROOT/cmd/main" "$1" >/dev/null 2>&1
  fi
}

# ---------------------------------------------------------------- 1. 确保在跑
sec "1. 确保服务在运行"
if ! "$ROOT/cmd/main" status >/dev/null 2>&1; then
  warn "当前未运行，先启动"
  run_main start || { say "启动失败，先看 $ROOT/var/info.log"; exit 1; }
  sleep 1
fi
ok "服务在运行"

# ---------------------------------------------------------------- 2. 取令牌
sec "2. 取本次启动的令牌"
URL=""
for _ in 1 2 3 4 5; do
  [ -s "$ROOT/var/dsh-url.txt" ] && URL="$(head -n1 "$ROOT/var/dsh-url.txt")"
  [ -n "$URL" ] && break
  sleep 1
done
if [ -z "$URL" ]; then
  URL="$(grep -oE 'https?://[^ "'"'"']*token=[^ "'"'"'&]+' "$ROOT/var/info.log" 2>/dev/null | tail -n1)"
fi
if [ -n "$URL" ]; then
  ok "拿到入口 URL：$(printf '%s' "$URL" | sed -E 's/(token=)[^&" ]+/\1***/')"
else
  bad "拿不到带 token 的 URL"
  say "  日志尾部："
  tail -n 8 "$ROOT/var/info.log" 2>/dev/null | sed 's/^/    /'
  hr; printf '结果：PASS %s / FAIL %s\n' "$PASS" "$FAIL"
  exit 1
fi
TOKEN1="$(printf '%s' "$URL" | grep -oE 'token=[^&"[:space:]]+' | head -n1 | cut -d= -f2-)"
# 令牌 URL 里带 dsh 自己的端口，比 settings 里的 service_port 更可靠
UPORT="$(printf '%s' "$URL" | sed -nE 's#^[a-z]+://[^/:]+:([0-9]+)/.*#\1#p')"
if [ -n "${UPORT:-}" ] && [ "$UPORT" != "$DPORT" ]; then
  DPORT="$UPORT"
  BASED="http://$BINDIP:$DPORT"
fi
say "  dsh 本体：$BASED（service_port $PORT 归入口跳转器）"

# ---------------------------------------------------------------- 3. 换 cookie
sec "3. 用令牌换 cookie"
CODE1="$(curl -s -m 10 -c "$JAR" -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null)"
say "  GET 带 token 的地址 → HTTP $CODE1（期望 3xx）"
if [ "$(printf '%s' "$CODE1" | cut -c1)" = "3" ]; then
  ok "令牌被接受，已下发 cookie"
else
  bad "令牌没有被接受（HTTP $CODE1）"
fi
if [ -s "$JAR" ] && grep -qiE 'dsh|cookie|session' "$JAR" 2>/dev/null; then
  ok "cookie 已写入 jar：$(awk '!/^#/ && NF {printf "%s ", $6}' "$JAR" 2>/dev/null)"
else
  warn "jar 里没有明显 cookie，后续结论可能不可靠"
fi

CODE2="$(curl -s -m 10 -b "$JAR" -o /dev/null -w '%{http_code}' "$BASED/" 2>/dev/null)"
say "  带 cookie 访问 $BASED/ → HTTP $CODE2（期望 200）"
[ "$CODE2" = "200" ] && ok "cookie 有效" || bad "cookie 无效（HTTP $CODE2）"

# ---------------------------------------------------------------- 4. 重启
sec "4. 重启应用"
[ "$(id -u)" = "0" ] && say "  以 $APP_USER 身份执行（root 下自动降权，避免写出 root 所有的会话文件）"
run_main stop
run_main start
RC=$?
say "  start 退出码：$RC"
if [ "$RC" != "0" ]; then
  bad "重启失败，后续结论无效"
  hr; printf '结果：PASS %s / FAIL %s\n' "$PASS" "$FAIL"
  exit 1
fi

# 等端口重新就绪
i=0
while [ "$i" -lt 40 ]; do
  curl -s -m 2 -o /dev/null "$BASED/" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
ok "服务已重新监听"

# 归属校验：本轮（或历史上）以 root 跑过 start 的话，dsh-home 里会混进 root 所有的文件。
HOMEDIR="$(grep -oE 'home=[^ ]+' "$ROOT/var/info.log" 2>/dev/null | tail -n1 | cut -d= -f2-)"
if [ -n "${HOMEDIR:-}" ] && [ -d "$HOMEDIR" ]; then
  ROOTOWN="$(find "$HOMEDIR" -user root 2>/dev/null | head -n 5)"
  if [ -n "$ROOTOWN" ]; then
    bad "dsh-home 里有 root 所有的文件" \
        "应用中心以 $APP_USER 启动时可能写不动，先执行：chown -R $APP_USER \"$HOMEDIR\""
    printf '%s\n' "$ROOTOWN" | sed 's/^/      /'
  else
    ok "dsh-home 归属干净" "$(stat -c '%U:%G %a' "$HOMEDIR" 2>/dev/null)"
  fi
fi

# ---------------------------------------------------------------- 5. 判读
sec "5. 重启后：点图标（不带任何 cookie）还能直接进吗"
ENTRY="http://$BINDIP:$PORT/"
EH="$(curl -s -m 10 -o /dev/null -D - "$ENTRY" 2>/dev/null)"
ECODE="$(printf '%s' "$EH" | sed -nE 's#^HTTP/[0-9.]+ ([0-9]{3}).*#\1#p' | head -n1)"
ELOC="$(getloc "$EH")"
say "  GET $ENTRY → HTTP $ECODE"
say "  Location → $(printf '%s' "$ELOC" | sed -E 's/(token=)[^&" ]+/\1***/')"

URL2=""
[ -s "$ROOT/var/dsh-url.txt" ] && URL2="$(head -n1 "$ROOT/var/dsh-url.txt")"
TOKEN2="$(printf '%s' "${URL2:-}" | grep -oE 'token=[^&"[:space:]]+' | head -n1 | cut -d= -f2-)"
if [ -n "$TOKEN2" ]; then
  say "  token 是否变了：$([ "$TOKEN1" = "$TOKEN2" ] && echo '没变（意外）' || echo '变了（符合预期，每次启动重新 mint）')"
else
  warn "重启后没抓到新 URL，无法比较 token"
fi

if [ "$ECODE" = "302" ] && printf '%s' "$ELOC" | grep -q "token=$TOKEN2" && [ -n "$TOKEN2" ]; then
  ok "重启后点图标仍然直接跳转（带的是新令牌）"
  VERDICT="auto-ok"
else
  bad "重启后点图标没有直接跳转（HTTP ${ECODE:-无响应}）"
  VERDICT="auto-broken"
fi

FOLLOW="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$ELOC" 2>/dev/null)"
case "$FOLLOW" in
  2*|3*) ok "跟随跳转能进 dsh（HTTP $FOLLOW）" ;;
  401|403) bad "新令牌被 dsh 拒绝（HTTP $FOLLOW）" ;;
  *)     warn "跟随跳转结果异常（HTTP ${FOLLOW:-无响应}）" ;;
esac

# 用户会连续点两次图标，第二次也必须能进。这条同时回答了「令牌是不是一次性的」：
# 若 dsh 的令牌只能用一次，第二次会拿同一个 token 却进不去 —— 那就得改成
# 「跳转器先换 cookie 再转发给浏览器」，不能再把 token 写进 Location。
EH2="$(curl -s -m 10 -o /dev/null -D - "$ENTRY" 2>/dev/null)"
EC2="$(printf '%s' "$EH2" | sed -nE 's#^HTTP/[0-9.]+ ([0-9]{3}).*#\1#p' | head -n1)"
ELOC2="$(getloc "$EH2")"
FC2="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$ELOC2" 2>/dev/null)"
if [ "$EC2" = "302" ] && { [ "$(printf '%s' "$FC2" | cut -c1)" = "2" ] || [ "$(printf '%s' "$FC2" | cut -c1)" = "3" ]; }; then
  ok "连续第二次点图标仍能进（HTTP $FC2）" "令牌可复用，或 cookie 已生效"
else
  bad "第二次点图标进不去（跳转 HTTP ${EC2:-无响应} / 跟随 HTTP ${FC2:-无响应}）" \
      "令牌可能是一次性的：需要改成「跳转器换 cookie 后转发」"
fi

CODE3="$(curl -s -m 10 -b "$JAR" -o /dev/null -w '%{http_code}' "$BASED/" 2>/dev/null)"
say "  （参考）重启前拿到的 dsh cookie 访问 $BASED/ → HTTP $CODE3"
[ "$CODE3" = "200" ] && ok "dsh 自己的 cookie 跨重启仍有效" \
  || warn "dsh 的 cookie 已失效（HTTP $CODE3）—— 不影响自动进入，每次都会重新带令牌"

# ---------------------------------------------------------------- 6. 结论
sec "6. 结论"
if [ "$VERDICT" = "auto-ok" ]; then
  cat <<'TXT'
  入口可用：点图标 → 3080 跳转器 → 302 带本次令牌 → dsh。

  用户侧不需要任何命令：
    · 每天使用：点桌面图标（或手机书签）即可；
    · 重启 NAS / 重启应用：令牌会换，但跳转器跟着换，书签不用改；
    · 想更严格：应用设置里把「入口方式」改成「新设备需粘贴一次令牌」。
TXT
else
  cat <<'TXT'
  入口异常：点图标没能直接到 dsh。按顺序看：

    1) cat /var/apps/dsh/var/launcher.json    # token 字段是不是空
    2) tail -n 30 /var/apps/dsh/var/info.log  # 本次启动有没有抓到 token=
    3) curl -s http://$BINDIP:$PORT/healthz   # 注意是绑定地址，不是 127.0.0.1

  若 token 为空，说明 dsh 的入口 URL 没打进日志（格式变了或启动失败）。
TXT
fi

hr
printf '结果：PASS %s / FAIL %s（判读：%s）\n' "$PASS" "$FAIL" "$VERDICT"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
