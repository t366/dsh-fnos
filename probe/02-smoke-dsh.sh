#!/usr/bin/env bash
# dsh on fnOS —— 阶段二：真机冒烟（装到临时目录，跑完即清理，不动系统）
# 前提：01-preflight.sh 无 FAIL 项
#
# 用法：
#   bash 02-smoke-dsh.sh                      # 自动选绑定地址、端口 3089
#   BIND_IP=192.168.0.114 bash 02-smoke-dsh.sh
#   NODE_BIN=/var/apps/nodejs_v24/target/bin/node bash 02-smoke-dsh.sh
#   PKG=@deepseek-ai/dsh@0.2.1-rc.2 bash 02-smoke-dsh.sh
#   WORKDIR=/vol1/dsh-probe CLEAN=1 bash 02-smoke-dsh.sh
#
# 产出：<WORKDIR>/dsh-smoke-<时间>.md
#
# v2 变更：
#   - 优先复用 fnOS 自带的 nodejs_v24（若满足 ≥24.9），并在报告里标明用的是哪个运行时
#   - 沙箱探测改为 **完全复刻 dsh 的探测参数**（bwrap 优先、landlock 兜底）
#   - 以 root 运行时，额外用 setpriv 降权到 nobody 再探一次 bwrap（fpk 应用不是 root，这是关键假阳性来源）
#   - 记录 DSH_HOME 实际落位、启动耗时、监听地址、安装体积（用于 fpk 体积估算）

set -u
set -o pipefail

WORKDIR="${WORKDIR:-$HOME/dsh-probe}"
PORT="${PORT:-3089}"
CLEAN="${CLEAN:-0}"
PKG="${PKG:-@deepseek-ai/dsh}"
NODE_FLOOR="24.9.0"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$WORKDIR/dsh-smoke-$STAMP.md"

OK=0; WARN=0; FAIL=0
RPT=()            # 不要用 LINES / COLUMNS（bash 内置终端尺寸变量）
line() { RPT+=("$1"); }

push() {
  if [ -n "${1:-}" ]; then
    while IFS= read -r l; do line "$l"; done <<< "$1"
  else
    line "(无输出)"
  fi
}
cap() { push "$(eval "$*" 2>/dev/null)"; }
verdict() {
  case "$1" in
    OK)   OK=$((OK+1));   line "- \`OK\`   **$2** — ${3:-}" ;;
    WARN) WARN=$((WARN+1)); line "- \`WARN\` **$2** — ${3:-}" ;;
    *)    FAIL=$((FAIL+1)); line "- \`FAIL\` **$2** — ${3:-}" ;;
  esac
}
have() { command -v "$1" >/dev/null 2>&1; }
ver_ge() {
  [ "$1" = "$2" ] && return 0
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}
finish() { { printf '%s\n' "${RPT[@]}"; } > "$REPORT"; printf '%s\n' "${RPT[@]}"; echo ""; echo "报告已写入：$REPORT"; }

mkdir -p "$WORKDIR" || { echo "无法创建 $WORKDIR"; exit 1; }
cd "$WORKDIR" || exit 1

line "# dsh on fnOS — 冒烟测试报告"
line ""
line "- 时间：\`$(date '+%Y-%m-%d %H:%M:%S')\`"
line "- 工作目录：\`$WORKDIR\`"
line "- 端口：\`$PORT\`"
line "- 目标包：\`$PKG\`"
line "- 执行身份：\`$(id -un)\` (uid=$(id -u))"
line ""

# ---------- 0. 绑定地址 ----------
line "## 0. 绑定地址"
line ""
BIND_IP="${BIND_IP:-}"
if [ -z "$BIND_IP" ] && have ip; then
  BIND_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
fi
BIND_IP="${BIND_IP:-127.0.0.1}"
line "- 使用：\`$BIND_IP\`（dsh 拒绝 0.0.0.0，必须是具体网卡地址）"
line ""

# ---------- 1. Node 运行时 ----------
line "## 1. Node 运行时"
line ""
line "> 顺序：命令行指定 → fnOS 自带 nodejs_* → 下载官方二进制。用哪个会写在下面。"
line ""

case "$(uname -m)" in
  x86_64|amd64)  NA=linux-x64 ;;
  aarch64|arm64) NA=linux-arm64 ;;
  *) echo "不支持的架构：$(uname -m)"; exit 1 ;;
esac

NODE_BIN="${NODE_BIN:-}"
NODE_SRC=""

if [ -n "$NODE_BIN" ] && [ -x "$NODE_BIN" ]; then
  NODE_SRC="命令行指定"
else
  NODE_BIN=""
  # 1) fnOS 自带：把所有候选连同版本列出来，避免"为什么没用上系统 Node"无从追溯
  BEST=""
  CAND=""
  while IFS= read -r nb; do
    [ -z "$nb" ] && continue
    nv="$("$nb" -v 2>/dev/null)"
    if [ -z "$nv" ]; then
      CAND="${CAND}(不可执行)  $nb"$'\n'
      continue
    fi
    if ver_ge "${nv#v}" "$NODE_FLOOR"; then
      CAND="${CAND}${nv}  ${nb}  <= 采用"$'\n'
      [ -z "$BEST" ] && BEST="$nb"
    else
      CAND="${CAND}${nv}  ${nb}  <= 低于 v${NODE_FLOOR}"$'\n'
    fi
  done <<< "$(find /var/apps -maxdepth 6 -name node \( -type f -o -type l \) 2>/dev/null | sort -r | head -n 12)"

  if [ -n "$CAND" ]; then
    line "fnOS 自带 Node 候选："
    line ""
    line '```'
    push "$CAND"
    line '```'
    line ""
  else
    line "- \`/var/apps\` 下未发现 node 可执行文件（直接进下载分支）"
    line ""
  fi

  if [ -n "$BEST" ]; then
    NODE_BIN="$BEST"; NODE_SRC="fnOS 自带应用（R1b 路线）"
  fi
fi

if [ -z "$NODE_BIN" ]; then
  NODE_DIR="$WORKDIR/node"
  if [ -x "$NODE_DIR/bin/node" ]; then
    NODE_BIN="$NODE_DIR/bin/node"; NODE_SRC="复用已下载"
  else
    # 解析 latest-v24.x 的真实版本号（避免硬编码一个可能不存在的版本）
    NODE_VER="${NODE_VER:-}"
    if [ -z "$NODE_VER" ]; then
      for u in "https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt" \
               "https://registry.npmmirror.com/-/binary/node/latest-v24.x/SHASUMS256.txt"; do
        NODE_VER="$(curl -fsSL -m 20 "$u" 2>/dev/null | grep -oE "node-v24\.[0-9]+\.[0-9]+-$NA\.tar\.xz" | head -n1 | sed -E 's/^node-(v24\.[0-9]+\.[0-9]+)-.*/\1/')"
        [ -n "$NODE_VER" ] && break
      done
    fi
    NODE_VER="${NODE_VER:-v24.9.0}"
    TARBALL="node-$NODE_VER-$NA.tar.xz"
    line "- 解析到的 Node 版本：\`$NODE_VER\`"
    got=0
    for u in "https://registry.npmmirror.com/-/binary/node/$NODE_VER/$TARBALL" \
             "https://nodejs.org/dist/$NODE_VER/$TARBALL"; do
      line "  - 尝试 $(echo "$u" | cut -d/ -f3)"
      if curl -fL --retry 2 -m 300 -o "$TARBALL" "$u" 2>/dev/null; then got=1; break; fi
    done
    if [ "$got" -ne 1 ]; then
      verdict FAIL "Node 下载失败" "两个源都不可达，检查出站网络/代理"
      finish; exit 1
    fi
    tar -xJf "$TARBALL" || { verdict FAIL "解包失败" "$TARBALL"; finish; exit 1; }
    rm -rf "$NODE_DIR"; mv "node-$NODE_VER-$NA" "$NODE_DIR"; rm -f "$TARBALL"
    NODE_BIN="$NODE_DIR/bin/node"; NODE_SRC="官方二进制 $NODE_VER"
  fi
fi

export PATH="$(dirname "$NODE_BIN"):$PATH"
NPM_BIN="$(dirname "$NODE_BIN")/npm"
# fnOS 的 nodejs_* 应用不一定自带 npm；退回 PATH 里的 npm（它只是个 JS 脚本，会用我们的 node 跑）
if [ ! -x "$NPM_BIN" ]; then NPM_BIN="$(command -v npm 2>/dev/null || true)"; fi
NODE_V="$("$NODE_BIN" -v 2>/dev/null)"
line "- 使用运行时：\`$NODE_BIN\`（来源：$NODE_SRC）"
if ver_ge "${NODE_V#v}" "$NODE_FLOOR"; then
  verdict OK "Node 可用" "$NODE_V ≥ v$NODE_FLOOR"
else
  verdict FAIL "Node 版本不足" "$NODE_V < v$NODE_FLOOR"
fi
line "- npm：\`$([ -x "${NPM_BIN:-}" ] && "$NPM_BIN" -v 2>/dev/null || echo '?')\`"
if [ -z "${NPM_BIN:-}" ] || [ ! -x "$NPM_BIN" ]; then
  verdict FAIL "npm 不可用" "该运行时目录下没有 npm，PATH 里也没有"
  finish; exit 1
fi
line ""

# ---------- 2. 安装 dsh ----------
line "## 2. 安装 $PKG"
line ""
line "> ⚠️ **已发布的 \`@deepseek-ai/dsh\` 没有声明 \`engines\`**，所以 npm 不会拦旧 Node，"
line "> 失败会推迟到运行时才暴露。下面的 dump-config / 启动步骤才是真正的判定点。"
line ""

APP="$WORKDIR/app"
if [ -e "$APP/node_modules/@deepseek-ai/dsh" ]; then
  line "- 复用已有安装"
else
  mkdir -p "$APP"
  ( cd "$APP" && "$NPM_BIN" init -y >/dev/null 2>&1 )
  START=$(date +%s)
  INSTALLED=0
  if ( cd "$APP" && "$NPM_BIN" install --omit=dev --no-audit --no-fund "$PKG" >"$WORKDIR/npm-install.log" 2>&1 ); then
    INSTALLED=1
  else
    line "- 默认源失败，改用 registry.npmjs.org 重试"
    if ( cd "$APP" && "$NPM_BIN" install --omit=dev --no-audit --no-fund \
           --registry=https://registry.npmjs.org "$PKG" >>"$WORKDIR/npm-install.log" 2>&1 ); then
      INSTALLED=1
    fi
  fi
  END=$(date +%s)
  if [ "$INSTALLED" -eq 1 ]; then
    verdict OK "npm 安装成功" "耗时 $((END-START))s"
  else
    verdict FAIL "npm 安装失败" "见 $WORKDIR/npm-install.log 末尾"
    line ""
    line '```'
    cap "tail -n 25 '$WORKDIR/npm-install.log'"
    line '```'
    finish; exit 1
  fi
fi

DSH_BIN=""
for c in "$APP/node_modules/.bin/dsh" "$APP/node_modules/@deepseek-ai/dsh/lib/bin.js"; do
  [ -e "$c" ] && DSH_BIN="$c" && break
done
if [ -z "$DSH_BIN" ]; then
  verdict FAIL "未找到 dsh 入口" "检查包结构"
  finish; exit 1
fi
verdict OK "dsh 入口" "$DSH_BIN"
line "- 实际版本：\`$(grep -o '\"version\": *\"[^\"]*\"' "$APP/node_modules/@deepseek-ai/dsh/package.json" 2>/dev/null | head -n1)\`"

DU_MB="$(du -sm "$APP" 2>/dev/null | awk '{print $1}')"
FC="$(find "$APP" -type f 2>/dev/null | wc -l)"
line "- 安装体积：\`${DU_MB:-?} MB\` / 文件数：\`$FC\`（fpk 体积基线）"
line ""

# ---------- 3. 沙箱探测（复刻 dsh 的真实探测） ----------
line "## 3. 沙箱功能探测"
line ""
line "> dsh 的 Linux 后端链是 **bwrap 优先、landlock 兜底**，且 bwrap 是功能性探测。"
line "> 下面用的参数与 \`bwrapProfileArgs({mode:'read-only', workspaceRoot:'/'})\` 完全一致。"
line ""

BW_ARGS=(--ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent)

if have bwrap; then
  BW_OUT="$(bwrap "${BW_ARGS[@]}" -- /bin/true 2>&1)"; BW_RC=$?
  if [ $BW_RC -eq 0 ]; then
    verdict OK "bwrap 探测通过（当前身份 $(id -un)）" "$(bwrap --version 2>/dev/null)"
  else
    verdict WARN "bwrap 探测失败（当前身份 $(id -un)）" "rc=$BW_RC $(echo "$BW_OUT" | head -n2 | tr '\n' ' ')"
  fi

  # 关键：fpk 应用以非 root 运行，root 通过不代表装上能跑
  if [ "$(id -u)" -eq 0 ] && have setpriv; then
    NB_OUT="$(setpriv --reuid=65534 --regid=65534 --clear-groups bwrap "${BW_ARGS[@]}" -- /bin/true 2>&1)"; NB_RC=$?
    if [ $NB_RC -eq 0 ]; then
      verdict OK "bwrap 探测通过（降权 nobody）" "非特权 userns 可用，fpk 场景成立"
    else
      verdict FAIL "bwrap 仅 root 可用" "nobody 下 rc=$NB_RC $(echo "$NB_OUT" | head -n2 | tr '\n' ' ')；安装后沙箱将降级到 Landlock"
    fi
  fi
else
  verdict WARN "bwrap 不存在" "直接依赖 Landlock 兜底"
fi

LL_BIN="$(find "$APP/node_modules" -type f \( -name 'landlock-run' -o -name 'landlock-run-*' \) 2>/dev/null | head -n1)"
if [ -n "$LL_BIN" ]; then
  chmod +x "$LL_BIN" 2>/dev/null
  # landlock-run <grant args> -- <cmd>；readOnly ['/'] + readWrite ['/dev/null']
  "$LL_BIN" --ro / --rw /dev/null -- /bin/true >/dev/null 2>&1; LL_RC=$?
  LL_OUT=""
  if [ $LL_RC -ne 0 ]; then
    # 参数形态可能与本脚本假设不同，退一步用 --help 记录真实契约
    LL_OUT="$("$LL_BIN" --ro / --rw /dev/null -- /bin/true 2>&1 | head -n3 | tr '\n' ' ')"
    LL_OUT="$LL_OUT | help: $(timeout 5 "$LL_BIN" --help 2>&1 | head -n 6 | tr '\n' ' ')"
  fi
  if [ $LL_RC -eq 0 ]; then
    verdict OK "landlock-run 可用" "$(basename "$LL_BIN")"
  else
    verdict WARN "landlock-run 参数形态未知" "rc=$LL_RC $LL_OUT"
  fi
  line "- 路径：\`$LL_BIN\`"
else
  verdict WARN "包内未找到 landlock-run" "可能改由 @deepseek-ai/node-addon-system 分发预编译件，检查 node_modules 结构"
fi

RG_BIN="$(find "$APP/node_modules" -type f -name 'rg' 2>/dev/null | head -n1)"
if [ -n "$RG_BIN" ] && "$RG_BIN" --version >/dev/null 2>&1; then
  verdict OK "ripgrep 可用" "$("$RG_BIN" --version | head -n1)"
else
  verdict WARN "ripgrep 未找到" "搜索类工具可能降级"
fi

PTY_NODE="$(find "$APP/node_modules" -type f -name 'pty.node' 2>/dev/null | head -n1)"
if [ -n "$PTY_NODE" ]; then
  if "$NODE_BIN" -e "process.dlopen({exports:{}},process.argv[1])" "$PTY_NODE" >/dev/null 2>&1; then
    verdict OK "node-pty 原生件可加载" "$(basename "$(dirname "$PTY_NODE")")"
  else
    verdict OK "node-pty 原生件存在" "$PTY_NODE（ABI 校验见启动日志）"
  fi
else
  verdict WARN "node-pty 原生件未找到" "终端类工具可能不可用"
fi
line ""

# ---------- 4. 配置合成 ----------
line "## 4. 配置合成（不启动服务）"
line ""
export DSH_HOME="$WORKDIR/dsh-home"
mkdir -p "$DSH_HOME"

if "$NODE_BIN" "$DSH_BIN" --profile web --dump-config >"$WORKDIR/dump-config.yml" 2>"$WORKDIR/dump-config.err"; then
  ROWS="$(grep -c 'name:' "$WORKDIR/dump-config.yml" 2>/dev/null)"
  verdict OK "profile web 合成成功" "约 ${ROWS:-?} 个插件行"
  line ""
  line '```'
  cap "head -n 22 '$WORKDIR/dump-config.yml'"
  line '```'
else
  verdict FAIL "profile web 合成失败" "见 dump-config.err"
  line ""
  line '```'
  cap "tail -n 20 '$WORKDIR/dump-config.err'"
  line '```'
fi
line ""

# ---------- 5. 启动并访问 ----------
line "## 5. 启动 Web 并验证访问"
line ""

LOG="$WORKDIR/dsh-run.log"
: > "$LOG"
T0=$(date +%s)
"$NODE_BIN" "$DSH_BIN" --profile web --host "$BIND_IP" --port "$PORT" --no-open >"$LOG" 2>&1 &
PID=$!

URL=""
for i in $(seq 1 90); do
  sleep 1
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  URL="$(grep -oE 'https?://[^ "'"'"']*token=[A-Za-z0-9_-]+' "$LOG" 2>/dev/null | head -n1)"
  [ -n "$URL" ] && break
done
T1=$(date +%s)

if [ -z "$URL" ]; then
  verdict FAIL "未取得启动 URL" "进程存活=$(kill -0 "$PID" 2>/dev/null && echo yes || echo no)，耗时 $((T1-T0))s"
  line ""
  line '```'
  cap "tail -n 30 '$LOG'"
  line '```'
else
  verdict OK "启动并打印 URL" "耗时 $((T1-T0))s，$(echo "$URL" | sed 's/token=.*/token=***/')"
  line ""
  line "### 5.1 监听与 HTTP"
  line ""
  if have ss; then
    line '```'
    cap "ss -ltnp 2>/dev/null | grep ':$PORT '"
    line '```'
  fi
  line ""

  COOKIE="$WORKDIR/cookies.txt"
  CODE1="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null)"
  line "- 带 token 首次请求：\`$CODE1\`（期望 3xx 换 cookie）"
  CODE2="$(curl -s -L -m 10 -c "$COOKIE" -b "$COOKIE" -o "$WORKDIR/index.html" -w '%{http_code}' "$URL" 2>/dev/null)"
  SIZE="$(wc -c < "$WORKDIR/index.html" 2>/dev/null | tr -d ' ')"
  line "- 跟随重定向后：\`$CODE2\`，落地页面 \`${SIZE:-0}\` 字节"
  if [ "$CODE2" = "200" ] && [ "${SIZE:-0}" -gt 500 ]; then
    verdict OK "Web UI 可访问" "HTTP 200 / ${SIZE} 字节"
  else
    verdict FAIL "Web UI 不可访问" "code=$CODE2 size=${SIZE:-0}"
  fi

  line ""
  line "### 5.2 认证与 Host/Origin 栅栏"
  line ""
  line "> 栅栏挂在 \`/api\` 上（\`admit()\` 先查信任再查认证）：不信任 → **403**，信任但未认证 → **401**。"
  line "> 根路径 \`/\` 走的是先验 cookie 的索引路由，未认证就是 401，**不能用它测栅栏**。"
  line ""
  BASE="$(echo "$URL" | sed 's#\(https\?://[^/]*\).*#\1#')"

  R_ROOT="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$BASE/" 2>/dev/null)"
  R_API="$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$BASE/api/" 2>/dev/null)"
  R_EVILHOST="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H 'Host: evil.example' "$BASE/api/" 2>/dev/null)"
  R_EVILORIGIN="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H 'Origin: http://evil.example' "$BASE/api/" 2>/dev/null)"
  R_API_CK="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -b "$COOKIE" "$BASE/api/" 2>/dev/null)"

  line "| 请求 | 结果 | 期望 |"
  line "|---|---|---|"
  line "| \`GET /\`（无 cookie） | \`$R_ROOT\` | 401 |"
  line "| \`GET /api/\`（无 cookie，正常 Host） | \`$R_API\` | 401 |"
  line "| \`GET /api/\`（**伪造 Host**） | \`$R_EVILHOST\` | **403** |"
  line "| \`GET /api/\`（**伪造 Origin**） | \`$R_EVILORIGIN\` | **403** |"
  line "| \`GET /api/\`（带 cookie） | \`$R_API_CK\` | 非 401/403 |"
  line ""
  if [ "$R_EVILHOST" = "403" ] && [ "$R_EVILORIGIN" = "403" ] && [ "$R_API" = "401" ] && [ "$R_ROOT" = "401" ]; then
    verdict OK "Host/Origin 栅栏按设计生效" "伪造 Host/Origin 均 403，未认证 401"
  else
    verdict FAIL "Host/Origin 栅栏与设计不符" "evilHost=$R_EVILHOST evilOrigin=$R_EVILORIGIN noCookieApi=$R_API root=$R_ROOT"
  fi
  if [ "$R_API_CK" = "401" ] || [ "$R_API_CK" = "403" ]; then
    verdict WARN "cookie 未被接受" "带 cookie 访问 /api/ 仍返回 $R_API_CK，cookie 可能未保存（检查 redirect 链）"
  else
    verdict OK "cookie 有效" "带 cookie 访问 /api/ 返回 $R_API_CK（非认证错误即通过）"
  fi
fi
line ""

# ---------- 6. 运行时观测 ----------
line "## 6. 运行时观测"
line ""

if kill -0 "$PID" 2>/dev/null; then
  RSS_KB="$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')"
  line "- 主进程 RSS：\`$(( ${RSS_KB:-0} / 1024 )) MB\`"
  KIDS="$(pgrep -P "$PID" 2>/dev/null | wc -l)"
  line "- 直接子进程数：\`$KIDS\`"
  THREADS="$(ps -o nlwp= -p "$PID" 2>/dev/null | tr -d ' ')"
  line "- 线程数：\`${THREADS:-?}\`"
else
  line "- 进程已退出，跳过观测"
fi
line ""
line "### DSH_HOME 落位（决定 fpk 的数据目录映射）"
line ""
line '```'
cap "find '$DSH_HOME' -maxdepth 2 -printf '%y %m %p\n' 2>/dev/null | head -n 25"
line '```'
line ""
line "### 启动日志（前 35 行）"
line ""
line '```'
cap "head -n 35 '$LOG'"
line '```'
line ""
line "### 沙箱相关日志行"
line ""
SB="$(grep -inE 'sandbox|landlock|bwrap|SANDBOX_UNAVAILABLE|confine' "$LOG" 2>/dev/null | head -n 10)"
line '```'
if [ -n "$SB" ]; then push "$SB"; else line "(启动阶段未出现 sandbox 字样，沙箱通常在首次执行命令时才解析)"; fi
line '```'
line ""

# ---------- 7. 收尾 ----------
line "## 7. 收尾"
line ""
kill -TERM "$PID" 2>/dev/null
for i in $(seq 1 10); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
kill -KILL "$PID" 2>/dev/null
verdict OK "进程已停止" ""

line ""
line "## 8. 结论"
line ""
line "| OK | WARN | FAIL |"
line "|---|---|---|"
line "| $OK | $WARN | $FAIL |"
line ""
if [ "$FAIL" -eq 0 ]; then
  line "**冒烟通过，可以进入 fpk 打包（M1）。**"
else
  line "**存在 FAIL 项，需先处理。**"
fi
line ""
line "复查用文件："
line "- 启动日志：\`$LOG\`（含 token，**外发前先脱敏**）"
line "- 合成配置：\`$WORKDIR/dump-config.yml\`"
line "- npm 日志：\`$WORKDIR/npm-install.log\`"

finish

if [ "$CLEAN" = "1" ]; then
  echo "清理 $APP 与 $WORKDIR/node ..."
  rm -rf "$APP" "$WORKDIR/node"
fi
