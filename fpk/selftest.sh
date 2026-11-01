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
# 开发机（Git Bash / macOS）也可直接跑：脚本会自动把 TMPDIR 转成无盘符形式
# （否则 TRIM_DATA_SHARE_PATHS 会被盘符里的冒号截断），并用 PATH 里的 node 起 stub。
# 要指定特定 node 时：DSH_TEST_NODE="$(command -v node)" bash selftest.sh
# ============================================================================

set -u

HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
ROOT="${TMPDIR:-/tmp}/dsh-selftest-$$"

# Git Bash 的 TMPDIR 常是 C:\Users\...，而 TRIM_DATA_SHARE_PATHS 用 ':' 分隔多路径，
# 盘符里的冒号会把共享目录切成 "C"，install_callback 于是判定「没有共享目录」，
# 后面一串「dsh-home 在共享目录里 / Key 写入副本 / 会话存活」全部假失败。
# 转成 MSYS 形式 /c/Users/...，冒号消失，测试与真机（Linux 路径）语义一致。
if command -v cygpath >/dev/null 2>&1; then
  ROOT="$(cygpath -u "$ROOT" 2>/dev/null || printf '%s' "$ROOT")"
fi
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

# 开发机上自动用 PATH 里的 node 起 stub：find_node 只认 bundled 运行时与 fnOS 的
# nodejs_v24，不查 PATH；不指定的话 start 会报「未找到 Node 运行时」。
# 只在非 Linux 上自动填 —— NAS 的 PATH node 是 v22，不满足 dsh 的 >=24.9。
if [ "$LINUX" = "no" ] && [ -z "${DSH_TEST_NODE:-}" ] && command -v node >/dev/null 2>&1; then
  DSH_TEST_NODE="$(command -v node)"
  export DSH_TEST_NODE
fi

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
    TRIM_DATA_ACCESSIBLE_PATHS="${TEST_ACCESSIBLE_PATHS-$ROOT/shares/workspace:$ROOT/shares/photos:$ROOT/shares/not-there}" \
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
mkdir -p "$ROOT/target" "$ROOT/var" "$ROOT/etc" "$ROOT/home" "$ROOT/shares/workspace" \
         "$ROOT/shares/photos" || {
  say "无法创建 $ROOT"
  exit 1
}
# fpk 里 app/ 的内容会被装到 target/ 根下
cp -a "$HERE/app/." "$ROOT/target/" || { say "复制 app/ 失败"; exit 1; }

# 沙箱必须从「骨架模式」起步。
# 源码树里可能残留上一次 full 构建的运行时（app/runtime/app 与 app/runtime/node），
# 它们是 .gitignore 的，git pull 不会帮你清掉。只要 app/ 里带着 dsh 包，
# detect_mode 就判成 dsh 模式 → 跳转器占住 service_port、GET / 变成 302，
# 而这一段（安装/启停/端口/HTTP）是按骨架模式写的，断言会全线错位：
# 现象就是「GET / 返回 200（期望 200，实际 302）」，看着像入口坏了，实际是模式错了。
# 只删沙箱里的副本，源码树不动（build.sh 第 4 步会自己重建）。
if [ -e "$ROOT/target/runtime/app" ]; then
  rm -rf "$ROOT/target/runtime/app"
  say "沙箱内已移除残留的 dsh 运行时——本段按骨架模式判定"
fi

# ---- 假 pnpm / 假 npm：验证「把 runtime/node/bin 前置进 PATH」这条链（F28 / F29）----
# dsh 装插件时 spawn 的是裸命令名 "pnpm"，而 pnpm 的 view/config 又 spawn 裸命令名
# "npm" 转发 —— 两个都只认 PATH，缺一个就断链。真包加起来 30MB，自测不需要它们装包，
# 只需要「能被找到 + 版本读得出来」的可执行文件。
# 这里只验证 cmd/main 有没有做前置；wrapper 自身能不能定位到入口文件由下面那段
# 「按真实布局跑模板」负责（沙箱里的 runtime/node/bin 没有真 node）。
for fb in pnpm npm; do
  mkdir -p "$ROOT/target/runtime/node/bin" "$ROOT/target/runtime/$fb/node_modules/$fb"
  printf '{"name":"%s","version":"9.9.9-selftest"}\n' "$fb" \
    >"$ROOT/target/runtime/$fb/node_modules/$fb/package.json"
  cat >"$ROOT/target/runtime/node/bin/$fb" <<'EOP'
#!/bin/sh
# 自测专用假 wrapper：真实版本由 build.sh 生成并自检
printf '9.9.9-selftest\n'
EOP
  chmod +x "$ROOT/target/runtime/node/bin/$fb" 2>/dev/null || true
done

# ---- wrapper 模板的路径深度（F28 / F29 回归）----
# build.sh 里的两个 wrapper 都是从 runtime/node/bin 往上找 ../<pkg>/node_modules 的，
# 层数写错不会在本地暴露，只会在 NAS 上白等一轮 full 构建（0.6.9 发布前踩过：
# 写成 ../pnpm，落到了 runtime/node/pnpm 这个不存在的目录）。
# 这里把 build.sh 的 heredoc 原样抽出来，按真实布局在沙箱里跑一遍，
# 并用 shim 顶替 node（沙箱没有 v24 二进制，只要能把入口文件跑起来就够）。
WRAPCHK="$ROOT/wrapcheck"
mkdir -p "$WRAPCHK/runtime/node/bin"
printf '#!/bin/sh\nexec node "$@"\n' >"$WRAPCHK/runtime/node/bin/node"
chmod +x "$WRAPCHK/runtime/node/bin/node"
# 入口文件名两个包不同：pnpm → bin/pnpm.cjs，npm → bin/npm-cli.js
wrap_entry() { case "$1" in pnpm) echo pnpm.cjs ;; npm) echo npm-cli.js ;; esac; }
# 只取**第一个** heredoc：两个块的结束标记都是 WRAP，不 exit 的话第二段会被追加进来。
# 用 index() 而不是正则首行匹配：build.sh 里这行有缩进（模式设 ^ 会一条都抽不到）。
extract_wrap() {
  awk -v pat="cat >app/runtime/node/bin/$1 <<" '
    index($0, pat) > 0 { f = 1; next }
    f && /^WRAP$/ { exit }
    f' "$HERE/build.sh"
}
if command -v awk >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  for wb in pnpm npm; do
    ENTRY="$(wrap_entry "$wb")"
    mkdir -p "$WRAPCHK/runtime/$wb/node_modules/$wb/bin"
    printf 'console.log("9.9.9-wrapcheck")\n' \
      >"$WRAPCHK/runtime/$wb/node_modules/$wb/bin/$ENTRY"
    extract_wrap "$wb" >"$WRAPCHK/runtime/node/bin/$wb"
    chmod +x "$WRAPCHK/runtime/node/bin/$wb"
    # 抽空了就等于没测 —— awk 的模式对不上时会安静地输出空文件，然后「通过」
    check "从 build.sh 抽到了 $wb 的 wrapper 模板" "yes" \
      "$([ -s "$WRAPCHK/runtime/node/bin/$wb" ] && echo yes || echo no)"
    # 故意换到 $ROOT 调用：证明它找的是自己旁边的文件，而不是 cwd 里的东西
    check "$wb wrapper 能找到 $ENTRY（换 cwd 调用）" "9.9.9-wrapcheck" \
      "$(cd "$ROOT" && "$WRAPCHK/runtime/node/bin/$wb" 2>&1)"
  done
else
  SKIP=$((SKIP + 4))
  printf '  \033[33mSKIP\033[0m  wrapper 模板提取与路径解析（缺 awk 或 node）\n'
fi

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

# 把「本段跑的是哪个模式」直接断言出来。
# 残留运行时会让本段悄悄变成 dsh 模式，症状是后面 GET / 期望 200 实际 302，
# 很容易被误判成入口坏掉。单独断言模式，出问题一眼能分清是「模式错位」还是「HTTP 坏了」。
check "本段跑的是骨架模式" "yes" \
  "$(grep -q 'start: mode=stub' "$ROOT/var/info.log" 2>/dev/null && echo yes || echo no)"

# F28 / F29：插件管理靠 PATH 上的 pnpm，pnpm 的 view/add 又靠 PATH 上的 npm。
# 这里断言三件事：
#   ① cmd/main 认出了两个 wrapper（而不是回落到 WARN）；
#   ② 版本各自取自自己的包元数据（只断言「最后一个 version=」会把 npm 的当成 pnpm 的）；
#   ③ 它真的把该目录前置进了子进程环境（只看日志会被「写了日志但没 export」骗过）。
check "启动日志记录了 pnpm 路径" "yes" \
  "$(grep -qF "pnpm=$ROOT/target/runtime/node/bin/pnpm" "$ROOT/var/info.log" 2>/dev/null && echo yes || echo no)"
check "启动日志记录了 npm 路径" "yes" \
  "$(grep -qF "npm=$ROOT/target/runtime/node/bin/npm" "$ROOT/var/info.log" 2>/dev/null && echo yes || echo no)"
check "pnpm 版本取自包元数据" "9.9.9-selftest" \
  "$(grep 'start: pnpm=' "$ROOT/var/info.log" 2>/dev/null | grep -o 'version=[^（]*' | tail -n1 | cut -d= -f2-)"
check "npm 版本取自包元数据" "9.9.9-selftest" \
  "$(grep 'start: npm=' "$ROOT/var/info.log" 2>/dev/null | grep -o 'version=[^（]*' | tail -n1 | cut -d= -f2-)"
SPID="$(cut -d' ' -f1 "$ROOT/var/dsh.pid" 2>/dev/null || true)"
if [ "$LINUX" = "yes" ] && [ -n "${SPID:-}" ] && [ -r "/proc/$SPID/environ" ]; then
  check_linux "子进程 PATH 已前置 runtime/node/bin" "yes" \
    "$(tr '\0' '\n' <"/proc/$SPID/environ" 2>/dev/null | grep -m1 '^PATH=' | grep -qF "$ROOT/target/runtime/node/bin" && echo yes || echo no)"
else
  SKIP=$((SKIP + 1))
  printf '  \033[33mSKIP\033[0m  子进程 PATH 已前置 runtime/node/bin（非 Linux 或无 /proc）\n'
fi

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

step "默认工作区（F22：文档目录 / 注册表）"
# dsh 的默认工作区 = <文档目录>/deepseek-harness/default-workspace，
# 而 linux 上文档目录靠 xdg-user-dir 读 $HOME/.config/user-dirs.dirs。
# 缺这个文件时它回显 $HOME，dsh 判定「文档目录不可用」→ 首启建不出默认工作区。
# 这一段盯住我们补写的那份文件，以及注册表补登记的幂等性。
XDG_FILE="$HOME_DIR/.config/user-dirs.dirs"
check "user-dirs.dirs 已写" "yes" "$([ -f "$XDG_FILE" ] && echo yes || echo no)"
XDG_VAL="$(grep -E '^XDG_DOCUMENTS_DIR=' "$XDG_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"\r')"
check "文档目录 = 共享目录" "$ROOT/shares/workspace" "$XDG_VAL"
check "文档目录不是 HOME（dsh 才认）" "yes" \
  "$([ -n "$XDG_VAL" ] && [ "$XDG_VAL" != "$HOME_DIR" ] && echo yes || echo no)"
check "默认工作区目录已建" "yes" \
  "$([ -d "$ROOT/shares/workspace/deepseek-harness/default-workspace" ] && echo yes || echo no)"

# ---- 注册表补登记：老用户升级时 dsh 自己不会再建，只能我们补 ----
N2="${DSH_TEST_NODE:-$(command -v node 2>/dev/null || true)}"
if [ -z "${N2:-}" ]; then
  SKIP=$((SKIP + 7))
  printf '  \033[33mSKIP\033[0m  注册表补登记（没有 node 可用于跑 helper）\n'
else
  WS="$HOME_DIR/storages/workspace.json"
  OLD_ID="11111111-1111-4111-8111-111111111111"
  mkdir -p "$HOME_DIR/storages" "$HOME_DIR/Project"
  cat >"$WS" <<JSON
{
 "unit": { "name": "workspace", "version": 2 },
 "global": {
  "initialized": true,
  "workspaceIds": ["$OLD_ID"],
  "archivedSessionIds": [],
  "pinnedSessionIds": []
 },
 "tables": {
  "workspaces": {
   "$OLD_ID": {
    "path": "$HOME_DIR/Project",
    "title": "Project",
    "sessionIds": ["session-keep-me"],
    "createdAt": "2026-10-27T10:56:17.687Z",
    "updatedAt": "2026-10-28T05:27:18.454Z"
   }
  }
 }
}
JSON

  # 在 JSON 上取一个字段（只在测试里用 eval，别处不要学）
  ws_get() { # $1=js 表达式，变量名 d
    "$N2" -e 'const fs=require("fs");const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));let v;try{v=eval(process.argv[2])}catch(e){v="ERR:"+e.message};console.log(typeof v==="object"?JSON.stringify(v):String(v))' "$WS" "$1"
  }

  OUT1="$("$N2" "$HERE/cmd/ensure-default-workspace.mjs" --registry "$WS" \
           --dir "$ROOT/shares/workspace/deepseek-harness/default-workspace" 2>&1)"
  check "helper 首次运行成功" "yes" "$(case "$OUT1" in created\ *) echo yes ;; *) echo no ;; esac)"
  check "已写入 defaultWorkspaceId" "true" "$(ws_get '!!d.global.defaultWorkspaceId')"
  check "新条目 title 用 dsh 的英文常量" "default-workspace" \
    "$(ws_get 'd.tables.workspaces[d.global.defaultWorkspaceId].title')"
  check "新条目路径名正确" "default-workspace" \
    "$(ws_get 'String(d.tables.workspaces[d.global.defaultWorkspaceId].path).split(/[\\\\/]/).pop()')"
  check "原有会话未被破坏" "session-keep-me" \
    "$(ws_get "d.tables.workspaces[\"$OLD_ID\"].sessionIds[0]")"
  check "新登记排在首位（与 createCanonical 一致）" "true" \
    "$(ws_get 'd.global.workspaceIds[0]===d.global.defaultWorkspaceId')"

  # 幂等：再跑一次不能产生第二条，也不能改掉已有默认项
  OUT2="$("$N2" "$HERE/cmd/ensure-default-workspace.mjs" --registry "$WS" \
           --dir "$ROOT/shares/workspace/deepseek-harness/default-workspace" 2>&1)"
  check "重复运行不新增（幂等）" "2" "$(ws_get 'd.global.workspaceIds.length')"
  case "$OUT2" in
    skip:*) : ;;
    *) say "    期望 skip，实际：$OUT2" ;;
  esac
fi

step "授权目录（F23：访问权限 → 可当工作区）"
# dsh 是通用工作台：用户必须能把「我的文件」里的任意文件夹授权给应用、再当工作区用。
# manifest 的 disable_authorization_path 一旦关掉，应用设置里连「访问权限」页都没有，
# 这条路就断了（0.6.6 及以前就是关着的）。这里同时盯住开关与启动时对授权路径的记录：
# 日志是排错的第一现场 —— 没授权 / 平台没传 / ACL 没生效，三种情况分得开。
check "manifest 保留了授权目录设置" "yes" \
  "$(grep -qE '^[[:space:]]*disable_authorization_path[[:space:]]*=[[:space:]]*"?false"?[[:space:]]*$' "$HERE/manifest" && echo yes || echo no)"
check "启动日志记录了授权路径" "yes" \
  "$(grep -q 'auth-paths: ' "$ROOT/var/info.log" 2>/dev/null && echo yes || echo no)"
check "已授权且可写的目录记为读写" "yes" \
  "$(grep -qF "auth-paths: $ROOT/shares/workspace （读写）" "$ROOT/var/info.log" 2>/dev/null && echo yes || echo no)"
check "不存在的授权路径单独标出" "yes" \
  "$(grep -qF "auth-paths: $ROOT/shares/not-there （不存在）" "$ROOT/var/info.log" 2>/dev/null && echo yes || echo no)"
check "授权路径条数已统计" "yes" \
  "$(grep -q 'auth-paths: 共 3 条' "$ROOT/var/info.log" 2>/dev/null && echo yes || echo no)"

# 探测必须切到应用用户身份：root 有 CAP_DAC_OVERRIDE，连 0000 的文件它也读得了。
# 真机上就是这么翻的 —— 日志写「读写」，dsh 进去一个文件都读不了（ISSUES F25）。
# 这里直接单元验 probe_as_app，不依赖 start 的编排。
if [ "$LINUX" = "yes" ] && [ "$(id -u)" = "0" ] && id -u nobody >/dev/null 2>&1; then
  mkdir -p "$ROOT/locked-probe"
  : >"$ROOT/locked-probe/secret.txt"
  chmod 700 "$ROOT/locked-probe"
  chmod 600 "$ROOT/locked-probe/secret.txt"
  _PROBE_WARNED=0
  log() { :; }
  eval "$(sed -n '/^probe_as_app()/,/^}/p' "$HERE/cmd/main")"
  if DSH_USER=nobody probe_as_app -r "$ROOT/locked-probe/secret.txt"; then _probe=readable; else _probe=blocked; fi
  check "权限探测按应用用户算（root 读得了不算数）" "blocked" "$_probe"
  unset -f log
else
  SKIP=$((SKIP + 1))
  printf '  \033[33mSKIP\033[0m  %s（需要 Linux + root + nobody 用户）\n' "权限探测按应用用户算"
fi

step "授权目录的浏览入口（F24：选择工作区目录里点得到）"
# dsh 的选择器只从 $HOME 起步，且把 home 以下压缩成「主目录」一个面包屑，
# 用户点不出去。所以启动时要把授权目录软链进 $HOME/可访问目录/。
LINKS="$HOME_DIR/可访问目录"
# 决策层（挑哪些路径、跳过哪些）在哪个平台都能验，靠日志；
# 软链本身在 Windows 上建不了（需要特权），那部分只做 Linux 断言。
# 注意断言的是「决定挂载」那一行，不是建链成功 —— 后者跟文件系统权限有关，
# 两者混在一起会让 Windows 上靠 WARN 行蒙对、Linux 上反而误报。
check "授权目录已进入待挂载列表" "yes" \
  "$(grep -qF "access-links: 挂载 photos -> $ROOT/shares/photos" "$ROOT/var/info.log" 2>/dev/null && echo yes || echo no)"
# 共享目录包含 .dsh-home，链上去会变成 可访问目录/workspace/.dsh-home/可访问目录… 无限递归
check "包含数据目录的授权路径被跳过（防递归）" "yes" \
  "$(grep -q 'access-links: 跳过.*（包含 dsh 数据目录' "$ROOT/var/info.log" 2>/dev/null && echo yes || echo no)"
check "不存在的授权路径不进列表" "yes" \
  "$(grep -q 'access-links: 跳过.*not-there' "$ROOT/var/info.log" 2>/dev/null && echo yes || echo no)"
check_linux "软链目录已创建" "yes" "$([ -d "$LINKS" ] && echo yes || echo no)"
check_linux "软链目录权限" "700" "$(stat -c %a "$LINKS" 2>/dev/null)"
if ln -s "$ROOT/shares/photos" "$ROOT/link-probe" 2>/dev/null && [ -L "$ROOT/link-probe" ]; then
  rm -f "$ROOT/link-probe"
  check "授权目录已挂上来" "yes" "$([ -L "$LINKS/photos" ] && echo yes || echo no)"
  check "软链指向授权路径本身" "$ROOT/shares/photos" "$(readlink "$LINKS/photos" 2>/dev/null)"
  check "指向不存在的授权路径不建链" "no" "$([ -e "$LINKS/not-there" ] && echo yes || echo no)"
  check "包含数据目录的授权路径不建链" "no" "$([ -e "$LINKS/workspace" ] && echo yes || echo no)"
else
  say "  跳过软链本身的断言（该文件系统不允许建软链，Linux 上才有意义）"
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

    start_gate() { # $1=auth  $2=host（默认回环；给非回环地址时才有回环备份监听）
      local h="${2:-127.0.0.1}"
      "$NODE_FOR_TEST" "$HERE/app/runtime/launcher/server.mjs" \
        --host "$h" --port "$GP" --state "$G/launcher.json" --auth "$1" >"$G/gate.log" 2>&1 &
      G_PID=$!
      i=0
      while [ "$i" -lt 40 ]; do
        if curl -s -m 1 -o /dev/null "http://$h:$GP/healthz" 2>/dev/null; then return 0; fi
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

    hdr() { curl -s -m 5 -o /dev/null -D - "$@" 2>/dev/null | tr -d '\r'; }
    hcode() { printf '%s' "$1" | sed -nE 's#^HTTP/[0-9.]+ ([0-9]{3}).*#\1#p' | head -n1; }
    # 解析 Location 时不能指望 sed 的 \r 转义：GNU sed 认，fnOS 自带的 sed 不认，
    # 会把行尾的 \r 原样留在捕获组里。浏览器不介意，但 curl 会判 URL 非法
    # （exit 3，-w 只拿到 000），看起来像「跳转器给了错地址」，实际是解析没洗干净。
    # 所以先用 tr 去掉 CR，再用 bash 自己裁尾随空白。
    hloc() {
      local v
      v="$(printf '%s\n' "$1" | tr -d '\r' \
            | sed -nE 's/^[Ll]ocation:[[:space:]]*//p' | head -n1)"
      v="${v%"${v##*[![:space:]]}"}"
      printf '%s' "$v"
    }

    if ! start_gate auto; then
      check "跳转器可启动（auto）" "yes" "no（看 $G/gate.log）"
      # 起不来时把整段（auto 7 + 无令牌 1 + 双绑 2 + pair 8）都记成跳过，
      # 别让「0 失败」看起来像验过。数量变了就跟着改。
      SKIP=$((SKIP + 18))
    else
      # ---- auto：点图标直接进（这是用户唯一想做的事）----
      H="$(hdr "http://127.0.0.1:$GP/")"
      LOC="$(hloc "$H")"
      check "auto：点图标直接 302" "302" "$(hcode "$H")"
      check "auto：跳转地址带本次令牌" "yes" \
        "$(printf '%s' "$LOC" | grep -q "token=$TOK" && echo yes || echo no)"
      check "auto：用绑定地址重建，不照抄日志里的 localhost" "yes" \
        "$(printf '%s' "$LOC" | grep -q "http://127.0.0.1:$UP/" && echo yes || echo no)"
      # 单独盯一眼「URL 里有没有夹带空白/回车」。这条能一眼区分
      # 「跳转器地址拼错」和「测试解析没洗干净」——后者在真机上排查代价极高。
      check "auto：Location 没有夹带空白或回车" "yes" \
        "$(case "$LOC" in *[[:space:]]*) echo no ;; *) echo yes ;; esac)"
      # 令牌拿去请求上游必须是 303（假 dsh 认得它）。这条能抓住 Location 拼错、
      # 端口写错、token 截断之类「看着像 302 但点了进不去」的问题。
      ACODE="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$LOC" 2>/dev/null)"
      if [ "$ACODE" != "303" ]; then
        # 单发 000 多半是瞬时的连接失败，重试两次；仍然不行才判失败，
        # 并把证据打出来，省得又要人肉回传现场。
        for _ in 1 2; do
          sleep 0.4
          ACODE="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "$LOC" 2>/dev/null)"
          [ "$ACODE" = "303" ] && break
        done
      fi
      check "auto：上游接受这条令牌（303）" "303" "${ACODE:-无}"
      if [ "$ACODE" != "303" ]; then
        # 注意用 -sS：-s 会把 curl 自己的报错（比如 URL rejected）也吞掉
        printf '    诊断 LOC=%s\n' "$LOC"
        printf '    诊断 LOC 字节：%s\n' \
          "$(printf '%s' "$LOC" | od -An -c 2>/dev/null | tr -s ' ' | tr '\n' ' ' | head -c 200)"
        printf '    诊断 curl：%s\n' \
          "$(curl -sS -m 5 -o /dev/null "$LOC" 2>&1 | head -n 2 | tr '\n' ' ')"
        printf '    诊断 上游日志：%s\n' \
          "$(tr '\n' ' ' <"$G/up.log" 2>/dev/null | head -c 300)"
        printf '    诊断 监听：%s\n' \
          "$(ss -ltn 2>/dev/null | grep -E ":$UP " | tr -s ' ')"
      fi
      check "auto：/healthz 自报 auto" "yes" \
        "$(curl -s -m 3 "http://127.0.0.1:$GP/healthz" 2>/dev/null | grep -q '"auto":true' && echo yes || echo no)"
      # 回归：带代理头不能被当成「本机直连」自动放行。
      # 反代会把 remoteAddress 变成 127.0.0.1（isPrivate 会认），只看地址就等于
      # 把公网访客放进带终端与文件工具的 dsh。这条断言守住那个前提。
      PH="$(hdr -H 'X-Forwarded-For: 203.0.113.9' "http://127.0.0.1:$GP/")"
      check "auto：带 X-Forwarded-For 不自动跳转（200 配对页）" "200" "$(hcode "$PH")"
      stop_gate

      # 抓不到令牌时不能把人送到 dsh 的 401 页，要给一个能看懂的说明页
      mkstate "" 0
      if start_gate auto; then
        check "auto：无令牌给说明页而非 302" "200" \
          "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$GP/" 2>/dev/null)"
      fi
      stop_gate

      # 绑非回环地址时必须同时在 127.0.0.1 上监听：应用中心的运行状态判定与本机
      # 自检连的都是回环，只有 LAN 监听时平台会认为「未运行」，卡片上就只剩
      # 「打开 / 卸载」（2026-10-27 真机现象，manifest 里 ctl_stop 是 true 也没用）。
      # 用 127.0.0.2 冒充「非回环」，避免依赖这台机器真实网卡。
      mkstate "$TOK"
      if start_gate auto 127.0.0.2; then
        check "双绑：给 LAN 地址时回环也监听" "yes" \
          "$(curl -s -m 2 -o /dev/null "http://127.0.0.1:$GP/healthz" 2>/dev/null && echo yes || echo no)"
        check "双绑：原地址仍可访问" "yes" \
          "$(curl -s -m 2 -o /dev/null "http://127.0.0.2:$GP/healthz" 2>/dev/null && echo yes || echo no)"
      else
        check "双绑：给 LAN 地址时回环也监听" "yes" "no（launcher 没起来，看 $G/gate.log）"
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
