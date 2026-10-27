#!/bin/bash
# ============================================================================
# 07-cookie-persistence.sh — 令牌换来的 cookie 能不能活过一次重启
#
# 为什么值得单独测：
#   dsh 每次启动 mint 新 token，令牌只能换一次 30 天 cookie。
#   如果 cookie 的签名密钥存在 $DSH_HOME（持久），那用户每台设备只需粘一次令牌，
#   「每次都要取令牌」就只是错觉；如果密钥是进程内的随机值，每次重启都得重新取，
#   那么必须加一层跳转器才能解决入口体验。
#
# 用法：
#   bash 07-cookie-persistence.sh
#   会重启一次 dsh（约 10 秒不可用），期间不要在浏览器里操作。
#
# 注意：cookie jar 里是同等于登录态的凭据，脚本结束时删除，不要外发。
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

# ---------------------------------------------------------------- 1. 确保在跑
sec "1. 确保服务在运行"
if ! "$ROOT/cmd/main" status >/dev/null 2>&1; then
  warn "当前未运行，先启动"
  "$ROOT/cmd/main" start >/dev/null 2>&1 || { say "启动失败，先看 $ROOT/var/info.log"; exit 1; }
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
  URL="$(grep -oE 'https?://[^ "'"'"']*token=[A-Za-z0-9_-]+' "$ROOT/var/info.log" 2>/dev/null | tail -n1)"
fi
if [ -n "$URL" ]; then
  ok "拿到入口 URL：$(printf '%s' "$URL" | sed -E 's/(token=)[A-Za-z0-9_-]+/\1***/')"
else
  bad "拿不到带 token 的 URL"
  say "  日志尾部："
  tail -n 8 "$ROOT/var/info.log" 2>/dev/null | sed 's/^/    /'
  hr; printf '结果：PASS %s / FAIL %s\n' "$PASS" "$FAIL"
  exit 1
fi
TOKEN1="$(printf '%s' "$URL" | sed -nE 's/.*token=([A-Za-z0-9_-]+).*/\1/p')"
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
say "  带 cookie 访问 $BASE/ → HTTP $CODE2（期望 200）"
[ "$CODE2" = "200" ] && ok "cookie 有效" || bad "cookie 无效（HTTP $CODE2）"

# ---------------------------------------------------------------- 4. 重启
sec "4. 重启应用"
"$ROOT/cmd/main" stop >/dev/null 2>&1
"$ROOT/cmd/main" start >/dev/null 2>&1
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

# ---------------------------------------------------------------- 5. 判读
sec "5. 重启后：旧 cookie 还有效吗"
CODE3="$(curl -s -m 10 -b "$JAR" -o /dev/null -w '%{http_code}' "$BASED/" 2>/dev/null)"
say "  用重启前的 cookie 访问 $BASE/ → HTTP $CODE3"

URL2=""
[ -s "$ROOT/var/dsh-url.txt" ] && URL2="$(head -n1 "$ROOT/var/dsh-url.txt")"
TOKEN2="$(printf '%s' "${URL2:-}" | sed -nE 's/.*token=([A-Za-z0-9_-]+).*/\1/p')"
if [ -n "$TOKEN2" ]; then
  say "  token 是否变了：$([ "$TOKEN1" = "$TOKEN2" ] && echo '没变（意外）' || echo '变了（符合预期，每次启动重新 mint）')"
else
  warn "重启后没抓到新 URL，无法比较 token"
fi

if [ "$CODE3" = "200" ]; then
  ok "cookie 跨重启存活"
  VERDICT="persist"
else
  bad "cookie 已失效（HTTP $CODE3）"
  VERDICT="volatile"
fi

# ---------------------------------------------------------------- 6. 结论
sec "6. 结论"
if [ "$VERDICT" = "persist" ]; then
  cat <<'TXT'
  cookie 持久 → 「每次取令牌」只是重装导致的错觉。

  每台设备只需要粘一次令牌：
    1) cat /var/apps/dsh/var/dsh-url.txt  （或用 05 第 7 节打印的地址）
    2) 浏览器打开一次，换成 30 天 cookie
  之后点应用中心的「打开」按钮即可直接进入，重启应用、重启 NAS 都不影响。

  唯一需要重来的情况：换浏览器/换设备、清 cookie、或超过 30 天。
TXT
else
  cat <<'TXT'
  cookie 不持久 → 每次重启都要重新粘令牌，当前入口体验确实不可接受。

  两条改法（详细的取舍见聊天里的对比）：
    A. 跳转器直接放行：3080 由跳转服务占用，点图标即进；等于对局域网关闭令牌。
    B. 跳转器 + 设备白名单：新设备首次粘一次令牌，之后靠长期 cookie 直接进；
       令牌栅栏保留。
TXT
fi

hr
printf '结果：PASS %s / FAIL %s（判读：%s）\n' "$PASS" "$FAIL" "$VERDICT"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
