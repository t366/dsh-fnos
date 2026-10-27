#!/bin/bash
# ============================================================================
# 05-verify-fpk.sh — 安装后验收（**只读**：不启停、不写任何文件）
#
#   bash 05-verify-fpk.sh
#
# 它回答的不是「装上了吗」（appcenter-cli 会说），而是「装出来的东西对不对」：
#   1. app/ 的内容到底有没有落进 target/     → 决定 cmd/main 能不能找到运行时
#   2. fnpack 有没有弄丢 cmd/* 的执行位        → 丢了应用中心一调就失败
#   3. 应用用户 / 数据目录 / 共享目录是否建对   → 决定能不能写、备份有没有覆盖
#   4. 三处端口是否一致                        → 不一致的现象是「能启动但图标打不开」
#   5. 现在在不在跑、绑在哪个 IP、HTTP 通不通
#
# 这些都属于「不报错但静默失败」的类别，必须逐条看。
# ============================================================================
set -u

APP="${APP:-dsh}"
PORT_EXPECT="${PORT_EXPECT:-3080}"
ROOT="${ROOT:-/var/apps/$APP}"

PASS=0; FAIL=0; WARN=0

ok()   { printf 'PASS  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; FAIL=$((FAIL + 1)); }
warn() { printf 'WARN  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; WARN=$((WARN + 1)); }
sec()  { printf '\n== %s\n' "$*"; }
hr()   { printf -- '----------------------------------------------------------------\n'; }

printf 'dsh on fnOS — 安装验收（只读）\n'
printf '时间：%s\n' "$(date '+%F %T')"
printf '身份：%s (uid=%s)\n' "$(id -un 2>/dev/null)" "$(id -u 2>/dev/null)"

# ---------------------------------------------------------------- 1
sec "1. 安装目录"
if [ ! -d "$ROOT" ]; then
  bad "未找到 $ROOT" "应用没装上，或 manifest 里的 appname 不是 $APP"
  printf '\n无法继续，先确认已执行：appcenter-cli install-fpk <file.fpk>\n'
  exit 1
fi
ok "$ROOT 存在"
echo "--- $ROOT ---"
ls -la "$ROOT" 2>/dev/null | sed -n '1,24p'

# ---------------------------------------------------------------- 2
sec "2. app/ → target/ 映射（决定运行时能否被找到）"
TARGET="$(readlink -f "$ROOT/target" 2>/dev/null || true)"
printf 'target 解析为：%s\n' "${TARGET:-<空>}"
if [ -n "${TARGET:-}" ] && [ -d "$TARGET" ]; then
  ok "target 是有效目录" "$TARGET"
else
  bad "target 无法解析" "$(ls -ld "$ROOT/target" 2>/dev/null)"
fi

if [ -n "${TARGET:-}" ] && [ -d "$TARGET" ]; then
  for f in ui/config ui/images/icon_64.png; do
    if [ -e "$TARGET/$f" ]; then
      ok "target/$f 存在"
    else
      bad "target/$f 缺失" "说明包内 app/ 没有原样落到 target/，cmd/main 会找不到入口"
    fi
  done
  if [ -f "$TARGET/runtime/app/node_modules/@deepseek-ai/dsh/package.json" ]; then
    ok "检测到捆绑的 dsh" "模式 = dsh（完整包）"
    DV="$(node -e 'try{console.log(require(process.argv[1]).version)}catch(e){}' \
          "$TARGET/runtime/app/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null)"
    printf '      dsh 版本：%s\n' "${DV:-?}"
    if [ -x "$TARGET/runtime/node/bin/node" ]; then
      ok "捆绑的 node" "$("$TARGET/runtime/node/bin/node" -v 2>/dev/null)"
    else
      warn "没有捆绑 node" "会回退到 /var/apps/nodejs_v24（需 >= 24.9）"
    fi
  elif [ -f "$TARGET/runtime/stub/server.mjs" ]; then
    warn "骨架包（stub）" "未捆绑 dsh，只验证安装链路"
  else
    bad "运行时缺失" "target/runtime 下既没有 dsh，也没有 stub，cmd/main 会直接失败"
  fi
fi

# ---------------------------------------------------------------- 3
sec "3. cmd/ 可执行位（fnpack 是否保留 +x）"
MISSING_X=0
for s in install_init install_callback main upgrade_init upgrade_callback \
         uninstall_init uninstall_callback config_init config_callback; do
  p="$ROOT/cmd/$s"
  if [ ! -f "$p" ]; then
    bad "cmd/$s 缺失"
    continue
  fi
  m="$(stat -c '%a' "$p" 2>/dev/null)"
  if [ -x "$p" ]; then
    ok "cmd/$s（mode=$m）"
  else
    bad "cmd/$s 无执行位（mode=$m）" "应用中心调用会失败：chmod +x 后需重新打包安装"
    MISSING_X=1
  fi
done
[ "$MISSING_X" = "1" ] && printf '\n提示：fnpack 若丢了执行位，build.sh 里的 chmod +x 需要改到打包之后再补，或改用 install_callback 里 chmod。\n'

# ---------------------------------------------------------------- 4
sec "4. 应用用户与目录归属"
if id "$APP" >/dev/null 2>&1; then
  ok "用户 $APP 存在" "$(id "$APP" 2>/dev/null)"
else
  bad "用户 $APP 不存在" "config/privilege 的 username 可能没生效"
fi
echo "--- 关键目录（解析后的实际路径与归属）---"
for d in target etc var tmp home; do
  l="$ROOT/$d"
  [ -e "$l" ] || continue
  printf '  %-7s -> %-40s %s\n' "$d" "$(readlink -f "$l" 2>/dev/null)" "$(stat -c '%U:%G %a' "$l" 2>/dev/null)"
done
# 0.2.0 起 dsh-home 迁到共享目录（@appdata 卸载即删，见 PLAN §2.8）
HOME_SHARE="$ROOT/shares/workspace/.dsh-home"
HOME_VAR="$ROOT/var/dsh-home"
if [ -d "$HOME_SHARE" ]; then
  ok "dsh-home 在共享目录（跨卸载存活）" "$(stat -c '%U:%G %a' "$HOME_SHARE" 2>/dev/null)"
  [ -f "$HOME_SHARE/settings.conf" ] \
    && ok "配置副本存在" "$(stat -c '%U:%G %a' "$HOME_SHARE/settings.conf" 2>/dev/null)" \
    || warn "配置副本缺失" "重装后无法恢复绑定地址与 API Key"
elif [ -d "$HOME_VAR" ]; then
  warn "dsh-home 仍在 var/（旧版布局）" "卸载重装会丢会话；0.2.0 起应迁到共享目录"
else
  warn "dsh-home 不存在" "install_callback 可能没执行或提前失败，看 var/info.log"
fi

echo "--- 共享目录（resource.data-share）---"
SHARE=""
for d in "$ROOT/share/workspace" "$ROOT/shares/workspace" "$ROOT/share" "$ROOT/shares"; do
  [ -d "$d" ] && { SHARE="$d"; break; }
done
if [ -n "$SHARE" ]; then
  ok "共享目录存在" "$SHARE  $(stat -c '%U:%G %a' "$SHARE" 2>/dev/null)"
  ls -ld "$SHARE"/* 2>/dev/null | sed -n '1,5p'
else
  warn "未找到 dsh/workspace 共享目录" "resource 声明未生效时，工作目录会回落到 var/dsh-home"
fi

# ---------------------------------------------------------------- 5
sec "5. 配置与端口一致性"

# 安装后 fnOS 会**重写** manifest（实测源文件 649B → 安装后 942B），
# 键名可能被加引号 / 补空格 / 重排。直接 grep '^service_port=' 会静默取空，
# 于是「三处不一致」这种假失败就冒出来了。所以先归一化键再比。
mval() { # $1=key
  local line k v
  [ -f "$ROOT/manifest" ] || return 1
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
    k="${line%%=*}"
    v="${line#*=}"
    k="${k//\"/}"; k="${k//\'/}"; k="${k// /}"; k="${k//$'\t'/}"; k="${k//$'\r'/}"
    v="${v//\"/}"; v="${v//\'/}"; v="${v//$'\r'/}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$k" = "$1" ] && { printf '%s' "$v"; return 0; }
  done <"$ROOT/manifest"
  return 1
}

S="$ROOT/etc/settings.conf"
if [ -f "$S" ]; then
  ok "settings.conf 存在" "$(stat -c '%U:%G %a' "$S" 2>/dev/null)"
  echo "--- 内容（API Key 已打码）---"
  sed -E 's/^(DSH_API_KEY=).*/\1<略>/' "$S" 2>/dev/null
else
  bad "settings.conf 缺失" "install_callback 没成功，main start 会退回默认端口"
fi

MPORT="$(mval service_port || true)"
UPORT=""
if [ -n "${TARGET:-}" ] && [ -f "$TARGET/ui/config" ]; then
  UPORT="$(grep -oE '"port"[[:space:]]*:[[:space:]]*"[0-9]+"' "$TARGET/ui/config" 2>/dev/null | grep -oE '[0-9]+' | head -n1)"
fi
CPORT="$(grep -E '^DSH_PORT=' "$S" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r')"
printf '  manifest service_port = %s\n  桌面入口 port         = %s\n  settings DSH_PORT     = %s\n' \
  "${MPORT:-?}" "${UPORT:-?}" "${CPORT:-?}"
if [ -z "${MPORT:-}" ]; then
  echo "--- 解析不到 service_port，原样打印安装后的 manifest ---"
  sed -n '1,80p' "$ROOT/manifest" 2>/dev/null | sed 's/^/  /'
fi
if [ -n "${MPORT:-}" ] && [ "$MPORT" = "${UPORT:-}" ] && [ "$UPORT" = "${CPORT:-}" ]; then
  ok "三处端口一致（$MPORT）"
else
  bad "三处端口不一致" "症状是「能启动但点图标打不开」，且 checkport 会检查错端口"
fi

# 目录遍历位：fnOS 装完后 config/ wizard/ 的 mode 会变成 644（丢了 +x）。
# 实测无害：向导由安装器（root）读，钩子只在 cmd/ 下执行，两处都不需要穿这两个目录。
# 所以这里只陈述，不告警——避免每次验收都出现两条永远不变的 WARN。
for d in config wizard cmd; do
  [ -d "$ROOT/$d" ] || continue
  m="$(stat -c '%a' "$ROOT/$d" 2>/dev/null)"
  case "$m" in
    *[1357]) printf '  %-7s %s（可遍历）\n' "$d/" "$m" ;;
    *) printf '  %-7s %s（无 +x，安装器造成，实测无碍）\n' "$d/" "$m" ;;
  esac
done

# ---------------------------------------------------------------- 6
sec "6. 运行状态"
HAS_DSH="no"
[ -f "${TARGET:-/nonexistent}/runtime/app/node_modules/@deepseek-ai/dsh/package.json" ] && HAS_DSH="yes"
RPORT="$PORT_EXPECT"          # 图标、checkport 用的端口：归入口跳转器
DPORT=$((PORT_EXPECT + 1))    # dsh 本体：内部端口

RC=0
"$ROOT/cmd/main" status >/dev/null 2>&1 || RC=$?
FPID="$(cut -d' ' -f1 "$ROOT/var/dsh.pid" 2>/dev/null || true)"
LPID="$(cut -d' ' -f1 "$ROOT/var/launcher.pid" 2>/dev/null || true)"
case "$RC" in
  0) ok "status = 0（运行中）" "dsh pid=${FPID:-?}$([ "$HAS_DSH" = "yes" ] && printf '，跳转器 pid=%s' "${LPID:-?}")" ;;
  3) warn "status = 3（未运行）" "刚装完未自动启动属正常，可在应用中心点启动" ;;
  1) bad "status = 1（进程异常）" "dsh 在跑但跳转器不在：点图标会打不开，应重新 start" ;;
  *) bad "status = $RC" "契约只允许 0/1/3" ;;
esac

listen_of() { ss -ltnp 2>/dev/null | grep -E ":$1[[:space:]]" | head -n1 || true; }

SS_LINE="$(listen_of "$RPORT")"
SSPID="$(printf '%s' "${SS_LINE:-}" | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2)"
echo "--- 监听 $RPORT（图标 / checkport）---"
if [ -n "$SS_LINE" ]; then
  printf '%s\n' "$SS_LINE"
  BINDIP="$(printf '%s' "$SS_LINE" | awk '{print $4}' | sed 's/:[0-9]*$//')"
  case "$BINDIP" in
    0.0.0.0|\*|"[::]") BINDIP=127.0.0.1 ;;
  esac
  ok "端口 $RPORT 已监听" "绑定地址 $BINDIP"
  if [ "$HAS_DSH" = "yes" ] && [ -n "${LPID:-}" ] && [ "$SSPID" != "$LPID" ]; then
    bad "占着 $RPORT 的不是入口跳转器" "监听 pid=$SSPID，launcher.pid=$LPID（旧进程没退干净？）"
  fi
else
  echo "(没有进程监听 $RPORT)"
  BINDIP=""
fi

if [ "$HAS_DSH" = "yes" ]; then
  echo "--- 监听 $DPORT（dsh 本体，内部端口）---"
  SS2="$(listen_of "$DPORT")"
  if [ -n "$SS2" ]; then
    printf '%s\n' "$SS2"
    ok "端口 $DPORT 已监听" "dsh 本体在跑"
  else
    warn "端口 $DPORT 未监听" "dsh 没起来或还在启动；此时点图标会看到跳转器的等待页"
  fi
fi

# status 与端口互相矛盾 = 进程校验（/proc 路径比对）和 start 时不一致。
# 这类 bug 不报错，只会让应用中心误判「没起来」→ 重复 start / 拒绝 stop。
if [ "$RC" -ne 0 ] && [ -n "$SSPID" ]; then
  if [ -z "${LPID:-}" ] || [ "$SSPID" = "$LPID" ]; then
    bad "status=$RC 但 $RPORT 被 pid=$SSPID 监听（自相矛盾）" \
        "status 的运行时路径比对没认出 start 时的路径写法"
  fi
fi

if [ -n "$BINDIP" ]; then
  if [ "$HAS_DSH" = "yes" ]; then
    CODE="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$BINDIP:$RPORT/" 2>/dev/null)"
    case "$CODE" in
      200) ok "跳转器返回配对页（HTTP 200）" "未配对的设备看到粘贴页，符合预期" ;;
      302|303) ok "跳转器直接跳转（HTTP $CODE）" "curl 没带 cookie 却跳了？核对一下是否 state 指向了裸地址" ;;
      503) warn "跳转器提示「正在启动」（HTTP 503）" "state 文件缺失或 dsh 未就绪" ;;
      000|"") bad "跳转器无响应" "端口在听但不回包，看 var/info.log" ;;
      *) warn "跳转器返回 HTTP $CODE" "非预期状态码" ;;
    esac

    CODE2="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$BINDIP:$DPORT/" 2>/dev/null)"
    case "$CODE2" in
      401) ok "dsh 在 $DPORT 上仍然要求令牌（HTTP 401）" "认证栅栏没有因为加跳转器而失效" ;;
      200) warn "dsh 直接返回 200" "该版本可能不再强制令牌，确认是否符合预期" ;;
      000|"") warn "dsh 端口无响应" "dsh 可能还在启动" ;;
      *) warn "dsh 返回 HTTP $CODE2" "预期 401" ;;
    esac
  else
    CODE="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$BINDIP:$RPORT/" 2>/dev/null)"
    case "$CODE" in
      200) ok "HTTP 200" "stub 服务可用" ;;
      401) ok "HTTP 401" "认证门在生效（未带 cookie 属正常）" ;;
      000|"") bad "HTTP 无响应" "端口在听但不回包，看 var/info.log" ;;
      *) warn "HTTP $CODE" "非预期状态码" ;;
    esac
  fi

  LANIP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')"
  if [ -n "$LANIP" ] && [ "$LANIP" != "$BINDIP" ]; then
    LCODE="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$LANIP:$RPORT/" 2>/dev/null)"
    if [ "$LCODE" = "000" ]; then
      warn "从默认路由地址 $LANIP 连不上" "服务绑在 $BINDIP；从 $LANIP 访问飞牛桌面时点图标会打不开（改绑地址即可）"
    else
      ok "从默认路由地址 $LANIP 可达（HTTP $LCODE）"
    fi
  fi
fi

# ---------------------------------------------------------------- 7
sec "7. 入口、令牌与配对"
if [ "$HAS_DSH" = "yes" ]; then
  if [ -f "$ROOT/var/launcher.json" ]; then
    ok "跳转器 state 就位" "$(sed -E 's/(token=)[A-Za-z0-9_-]+/\1***/g' "$ROOT/var/launcher.json" 2>/dev/null)"
    STOK="$(sed -nE 's/.*"token":"([^"]*)".*/\1/p' "$ROOT/var/launcher.json" 2>/dev/null)"
    if [ -n "$STOK" ] && [ "$STOK" = "$(sed -nE 's/.*token=([A-Za-z0-9_-]+).*/\1/p' "$ROOT/var/dsh-url.txt" 2>/dev/null | head -n1)" ]; then
      ok "state 里的令牌与 dsh-url.txt 一致" "点图标即进靠的就是它"
    else
      warn "state 里的令牌缺失或与 dsh-url.txt 不一致" "自动进入会退化成配对页"
    fi
  else
    warn "缺少 var/launcher.json" "跳转器会一直显示等待页；只在 dsh 模式下才应该存在"
  fi
  if [ -f "$ROOT/var/launcher-secret" ]; then
    SM="$(stat -c '%a' "$ROOT/var/launcher-secret" 2>/dev/null)"
    [ "$SM" = "600" ] && ok "配对密钥存在（600）" "已配对设备的 cookie 靠它验签" \
      || warn "配对密钥权限是 $SM" "建议 600"
  else
    warn "缺少 var/launcher-secret" "首次配对时会自动生成，属正常（重启后也不丢）"
  fi
fi

if [ -f "$ROOT/var/dsh-url.txt" ]; then
  ok "已抓到入口 URL（token 打码）" "$(sed -E 's/(token=)[A-Za-z0-9_-]+/\1***/' "$ROOT/var/dsh-url.txt" 2>/dev/null | head -n1)"
  echo "      完整地址：$ROOT/cmd/main url     （或 cat $ROOT/var/dsh-url.txt）"
elif [ "$HAS_DSH" = "yes" ]; then
  warn "dsh 运行时在，但没有 dsh-url.txt" \
       "看下面日志里有没有 token=；若服务是停着的，start 之后才会生成"
else
  echo "  （stub 模式没有启动令牌，不生成 dsh-url.txt，属预期）"
fi

# 端到端验证入口：这才是用户点图标时真正走的那条路。
#
# auto 模式：GET service_port 应该直接 302 到「绑定 IP + 内部端口 + 本次令牌」，
#           把这条地址再请求一次必须不是 401 —— 401 就是「点了图标进不去」。
# pair 模式：没有 cookie 时给配对页；POST 正确令牌应 302 + dsh_gate。
if [ "$HAS_DSH" = "yes" ] && [ -n "${BINDIP:-}" ]; then
  TOK="$(sed -nE 's/.*token=([A-Za-z0-9_-]+).*/\1/p' "$ROOT/var/dsh-url.txt" 2>/dev/null | head -n1)"
  HJ="$(curl -s -m 6 "http://$BINDIP:$RPORT/healthz" 2>/dev/null)"
  EMODE=unknown
  case "$HJ" in
    *'"mode":"auto"'*) EMODE=auto ;;
    *'"mode":"pair"'*) EMODE=pair ;;
  esac
  if [ "$EMODE" = "unknown" ]; then
    warn "读不到入口模式（/healthz 无响应）" "跳转器可能没起来，或版本低于 0.5.0"
  else
    ok "入口模式：$EMODE"
  fi

  HDR="$(curl -s -m 8 -o /dev/null -D - "http://$BINDIP:$RPORT/" 2>/dev/null)"
  ECODE="$(printf '%s' "$HDR" | sed -nE 's#^HTTP/[0-9.]+ ([0-9]{3}).*#\1#p' | head -n1)"
  LOC="$(printf '%s' "$HDR" | sed -nE 's/^[Ll]ocation: *(.*[^ ]) *\r?$/\1/p' | head -n1)"

  if [ "$EMODE" = "auto" ]; then
    if [ "$ECODE" = "302" ]; then
      ok "点图标直接跳转（HTTP 302）" "$(printf '%s' "$LOC" | sed -E 's/(token=)[A-Za-z0-9_-]+/\1***/')"
    else
      bad "点图标没有直接跳转（HTTP ${ECODE:-无响应}）" "期望 302；出现在这里说明自动取令牌失败"
    fi
    case "$LOC" in
      *"token=$TOK"*) [ -n "$TOK" ] && ok "跳转地址带本次启动的令牌" "令牌与 dsh-url.txt 一致" \
                        || warn "跳转地址的形状对，但 dsh-url.txt 里没有令牌" "看看是不是没抓到" ;;
      *token=*)       bad "跳转地址里的令牌与 dsh-url.txt 不一致" "可能是上一轮遗留的 state" ;;
      *)              warn "跳转地址里没有令牌" "检查 launcher.json 的 token 字段" ;;
    esac
    FCODE="$(curl -s -m 8 -o /dev/null -w '%{http_code}' "$LOC" 2>/dev/null)"
    case "$FCODE" in
      2*|3*) ok "跟随跳转后能进 dsh（HTTP $FCODE）" "这条链路就是用户点图标后看到的" ;;
      401|403) bad "跟随跳转后被 dsh 拒绝（HTTP $FCODE）" "令牌无效：重启后 state 没刷新？" ;;
      *)     warn "跟随跳转结果异常（HTTP ${FCODE:-无响应}）" "手工在浏览器打开一次确认" ;;
    esac
  else
    if [ "$ECODE" = "200" ]; then
      ok "未配对的访客看到配对页" "pair 模式，符合预期"
    else
      warn "pair 模式下首页返回 HTTP ${ECODE:-无响应}" "预期 200 配对页"
    fi
    PHDR="$(curl -s -m 8 -o /dev/null -D - -X POST --data-urlencode "token=$TOK" "http://$BINDIP:$RPORT/pair" 2>/dev/null)"
    PCODE="$(printf '%s' "$PHDR" | sed -nE 's#^HTTP/[0-9.]+ ([0-9]{3}).*#\1#p' | head -n1)"
    if [ "$PCODE" = "302" ] && printf '%s' "$PHDR" | grep -qi 'set-cookie: *dsh_gate='; then
      ok "配对流程可用（HTTP 302 + dsh_gate cookie）" "新设备粘一次令牌即可进入"
    else
      bad "配对流程异常（HTTP ${PCODE:-无响应}）" "检查跳转器日志；cookie 头是否下发也一并确认"
    fi
    PHDR2="$(curl -s -m 8 -o /dev/null -D - -X POST --data 'token=deadbeefdeadbeefdeadbeef' "http://$BINDIP:$RPORT/pair" 2>/dev/null)"
    PCODE2="$(printf '%s' "$PHDR2" | sed -nE 's#^HTTP/[0-9.]+ ([0-9]{3}).*#\1#p' | head -n1)"
    case "$PCODE2" in
      401) ok "错误令牌被拒绝（HTTP 401）" "限速与校验都生效" ;;
      429) ok "错误令牌触发限速（HTTP 429）" "验证了限速分支" ;;
      *)   warn "错误令牌没有按预期被拒（HTTP ${PCODE2:-无响应}）" "预期 401" ;;
    esac
  fi
fi

if [ -f "$ROOT/var/info.log" ]; then
  echo "--- var/info.log 尾部 ---"
  tail -n 12 "$ROOT/var/info.log" 2>/dev/null || true
else
  warn "var/info.log 不存在" "说明 main 从未被调用"
fi

# ---------------------------------------------------------------- 8
hr
printf '结果：PASS %s / WARN %s / FAIL %s\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf '\n安装链路验收通过。\n'
  if [ -f "${TARGET:-/nonexistent}/runtime/app/node_modules/@deepseek-ai/dsh/package.json" ]; then
    printf '下一步：从另一台设备浏览器打开 http://<本机IP>:%s/ ，粘贴一次令牌完成配对，之后点图标即可进入。\n' "$PORT_EXPECT"
  else
    printf '下一步：换 full 包塞入 dsh 运行时：bash build.sh full（版本已钉在 build.sh 里）\n'
  fi
  exit 0
else
  printf '\n有 %s 项失败，先修这些再看其它。\n' "$FAIL"
  exit 1
fi
