#!/usr/bin/env bash
# dsh on fnOS —— 阶段一：只读环境体检
# 不改任何系统状态，不需要 root（部分项缺 root 会降级为 SKIP）。
# 用法：bash 01-preflight.sh [输出目录]
# 产出：<输出目录>/dsh-preflight-<时间>.md
#
# v2 变更（基于 2026-10-27 FNOS 首次真机结果）：
#   - 修：报告首行会多出一个数字（LINES 是 bash 内置的终端行数变量，被误当数组名）
#   - 修：DeepSeek API 返回 401 被判 WARN（应算可达）
#   - 修：Node 版本比较改为点分版本号比较，不再用 case 通配
#   - 增：扫描 /var/apps/nodejs_* 里 fnOS 自带的 Node 运行时（可能省掉 400MB 自带运行时）
#   - 增：非特权 user namespace / AppArmor userns 限制检查（决定 bwrap 能否为普通用户工作）
#   - 增：已发布版本探测

set -u
set -o pipefail

OUT_DIR="${1:-$PWD}"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$OUT_DIR/dsh-preflight-$STAMP.md"

OK=0; WARN=0; FAIL=0; SKIP=0
RPT=()            # 不要用 LINES / COLUMNS：它们是 bash 内置的终端尺寸变量

line() { RPT+=("$1"); }

# 把一条命令的输出整段收进报告（不要用裸命令，否则会漏到终端）
cap() {
  local out
  out="$(eval "$*" 2>/dev/null)"
  if [ -z "$out" ]; then
    line "(无输出)"
  else
    while IFS= read -r l; do line "$l"; done <<< "$out"
  fi
}

verdict() { # verdict <OK|WARN|FAIL|SKIP> <标题> <详情>
  local v="$1" t="$2" d="${3:-}"
  case "$v" in
    OK)   OK=$((OK+1));     line "- \`OK\`   **$t** — $d" ;;
    WARN) WARN=$((WARN+1)); line "- \`WARN\` **$t** — $d" ;;
    FAIL) FAIL=$((FAIL+1)); line "- \`FAIL\` **$t** — $d" ;;
    *)    SKIP=$((SKIP+1)); line "- \`SKIP\` **$t** — $d" ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# ver_ge 24.9.0 24.19.3 -> true 表示 $1 >= $2
ver_ge() {
  [ "$1" = "$2" ] && return 0
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

NODE_FLOOR="24.9.0"

line "# dsh on fnOS — 环境体检报告"
line ""
line "- 时间：\`$(date '+%Y-%m-%d %H:%M:%S')\`"
line "- 主机：\`$(hostname 2>/dev/null || echo unknown)\`"
line "- 执行身份：\`$(id -un 2>/dev/null)\` (uid=$(id -u 2>/dev/null))"
line "- 脚本版本：\`preflight v2\`"
line ""

line "## 1. 系统与内核"
line ""

OS_PRETTY="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
KREL="$(uname -r)"
MACH="$(uname -m)"
line "- 发行版：\`$OS_PRETTY\`"
line "- 内核：\`$KREL\`"
line "- 架构：\`$MACH\`"

case "$MACH" in
  x86_64|amd64)  NODE_ARCH=linux-x64 ;;
  aarch64|arm64) NODE_ARCH=linux-arm64 ;;
  *)             NODE_ARCH="unknown" ;;
esac
line "- 对应 Node 产物：\`$NODE_ARCH\`"
line ""

verdict OK "内核版本" "$KREL"
if [ "$NODE_ARCH" = "unknown" ]; then
  verdict FAIL "架构受支持" "$MACH 不在 dsh 发布矩阵内（需 x64 / arm64）"
else
  verdict OK "架构受支持" "$MACH"
fi

GLIBC="$(ldd --version 2>/dev/null | awk '/GLIBC|glibc|GNU libc/{print $NF; exit}')"
if [ -n "${GLIBC:-}" ]; then
  if ver_ge "$GLIBC" "2.28"; then
    verdict OK "glibc 版本" "$GLIBC（要求 ≥ 2.28）"
  else
    verdict FAIL "glibc 过低" "$GLIBC < 2.28"
  fi
else
  verdict SKIP "glibc 版本" "ldd 不可用"
fi

if have systemctl; then
  verdict OK "systemd" "存在（可自建 unit）"
else
  verdict WARN "systemd" "未检测到，只能用 nohup/自建守护"
fi

line ""

line "## 2. 沙箱能力（dsh 的硬依赖）"
line ""
line "> dsh 在 Linux 上的后端链是 **bwrap 优先、landlock 兜底**，两者都是功能性探测。"
line ""

LSM_LIST=""
for f in /sys/kernel/security/lsm /sys/module/landlock/parameters/*; do
  [ -r "$f" ] && LSM_LIST="$LSM_LIST $(cat "$f" 2>/dev/null)"
done
LSM_LIST="$(echo "$LSM_LIST" | tr -s ' ')"

if echo "$LSM_LIST" | grep -q landlock; then
  verdict OK "Landlock 已启用" "lsm 列表:$LSM_LIST"
else
  if (zcat /proc/config.gz 2>/dev/null || cat "/boot/config-$KREL" 2>/dev/null) | grep -q '^CONFIG_SECURITY_LANDLOCK=y'; then
    verdict WARN "Landlock 编入内核但未激活" "CONFIG_SECURITY_LANDLOCK=y，但 lsm 列表未见（检查 lsm= 启动参数）"
  else
    verdict FAIL "Landlock 不可用" "既非 lsm 激活，也未见内核配置；dsh 沙箱兜底路径也没了"
  fi
fi

if have bwrap; then
  verdict OK "bubblewrap 存在" "$(bwrap --version 2>/dev/null)"
else
  verdict WARN "bubblewrap 缺失" "可接受：会回落到 Landlock（前提是上一项 OK）"
fi

# 非特权 userns：bwrap 在非 setuid 安装下完全依赖它。fpk 应用不是 root，这项不过就是真不过。
UNPRIV=""
[ -r /proc/sys/kernel/unprivileged_userns_clone ] && UNPRIV="$(cat /proc/sys/kernel/unprivileged_userns_clone)"
MAXNS=""
[ -r /proc/sys/user/max_user_namespaces ] && MAXNS="$(cat /proc/sys/user/max_user_namespaces)"
AA_USERNS=""
[ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] && AA_USERNS="$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns)"

line ""
line "- \`unprivileged_userns_clone\`：\`${UNPRIV:-（无此项）}\`"
line "- \`max_user_namespaces\`：\`${MAXNS:-（无此项）}\`"
line "- \`apparmor_restrict_unprivileged_userns\`：\`${AA_USERNS:-（无此项）}\`"
line ""

if [ "${UNPRIV:-1}" = "0" ]; then
  verdict FAIL "非特权 user namespace 被禁用" "普通用户跑不了 bwrap，只能靠 Landlock 兜底"
elif [ "${AA_USERNS:-0}" = "1" ]; then
  verdict WARN "AppArmor 限制非特权 userns" "可能拦截 bwrap；阶段二会以 nobody 身份实测"
elif [ -n "${MAXNS:-}" ] && [ "${MAXNS}" -gt 0 ] 2>/dev/null; then
  verdict OK "非特权 user namespace 可用" "max_user_namespaces=$MAXNS"
else
  verdict SKIP "非特权 user namespace" "未暴露相关 sysctl，阶段二实测"
fi

line ""

line "## 3. 终端 / pty（agent 跑命令要用）"
line ""

if [ -e /dev/ptmx ]; then
  verdict OK "/dev/ptmx" "$(ls -l /dev/ptmx 2>/dev/null)"
else
  verdict FAIL "/dev/ptmx" "缺失，node-pty 无法工作"
fi

if grep -qs ' /dev/pts ' /proc/mounts; then
  verdict OK "/dev/pts 已挂载" "$(grep ' /dev/pts ' /proc/mounts | head -n1)"
else
  verdict FAIL "/dev/pts" "未挂载"
fi

line ""

line "## 4. 运行时"
line ""

SYS_NODE_OK=0
if have node; then
  NODE_V="$(node -v 2>/dev/null)"
  line "- 系统 node：\`$NODE_V\` @ \`$(command -v node)\`"
  NODE_VN="${NODE_V#v}"
  if ver_ge "$NODE_VN" "$NODE_FLOOR"; then
    SYS_NODE_OK=1
    verdict OK "系统 Node 满足 ≥$NODE_FLOOR" "$NODE_V"
  else
    verdict WARN "系统 Node 版本不足" "$NODE_V < v$NODE_FLOOR"
  fi
else
  verdict WARN "系统无 Node" "预期之内：需自带或复用 fnOS 的 nodejs 应用"
fi

if have pnpm; then line "- pnpm：\`$(pnpm -v 2>/dev/null)\`"; else line "- pnpm：未安装（只有 git 源码路线才需要）"; fi
if have npm;  then line "- npm：\`$(npm -v 2>/dev/null)\`";  fi
if have git;  then line "- git：\`$(git --version 2>/dev/null)\`"; fi
# Office 作者类技能（docx/xlsx/pptx）要 Python 库；web 形态没有 workspace-dependencies
# 工具可借，只能落到宿主环境。这里只"报告"，不判定失败——缺了不影响核心功能。
if have python3; then
  PYV="$(python3 -V 2>&1)"
  PYLIB="$(python3 - <<'PY' 2>/dev/null
mods = [('docx', 'python-docx'), ('openpyxl', 'openpyxl'), ('pptx', 'python-pptx')]
ok = []
for m, name in mods:
    try:
        __import__(m); ok.append(name)
    except Exception:
        pass
print(','.join(ok) or '无')
PY
)"
  line "- python3：\`$PYV\`；Office 库：\`${PYLIB:-?}\`"
else
  line "- python3：未安装（Office 作者类技能不可用，操作类不受影响）"
fi
# Office 转 PDF / 渲染在 Linux 上走 WASM，而 WASM "只用导入的字体，
# 找不到可用字体就以 unavailable 拒绝"。飞牛是最小化 Debian，很可能只有西文字体——
# 那样 PDF 能出但中文缺字。这里只报告，判定留给人：有 CJK 才能说"中文导出没问题"。
if [ -d /usr/share/fonts ] || [ -d "$HOME/.fonts" ]; then
  FCNT="$(find /usr/share/fonts "$HOME/.fonts" "$HOME/.local/share/fonts" -type f \
            \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \) 2>/dev/null | wc -l | tr -d ' ')"
  CJK="$(find /usr/share/fonts "$HOME/.fonts" "$HOME/.local/share/fonts" -type f \
            \( -iname '*cjk*' -o -iname '*noto*sans*sc*' -o -iname '*wqy*' -o -iname '*droidsansfallback*' \) 2>/dev/null | head -3 | tr '\n' ' ')"
  if [ -n "$CJK" ]; then
    line "- 字体：\`${FCNT:-0}\` 个，含中文字体：\`$CJK\`"
  else
    line "- 字体：\`${FCNT:-0}\` 个，**未发现中文字体**（Office 导出的中文 PDF 可能缺字）"
  fi
fi

line ""
line "### 4b. fnOS 自带 Node 应用（可能省掉整套自带运行时）"
line ""

APPS_NODE_OK=0
APPS_NODE_BEST=""
if [ -d /var/apps ]; then
  NODEBINS="$(find /var/apps -maxdepth 6 -type f -name node -perm -u+x 2>/dev/null | head -n 12)"
  if [ -z "$NODEBINS" ]; then
    verdict SKIP "/var/apps 内未找到 node 二进制" "可能未装 nodejs_* 应用，或路径更深"
  else
    line '```'
    while IFS= read -r nb; do
      [ -z "$nb" ] && continue
      nv="$("$nb" -v 2>/dev/null)"
      line "$nv  $nb"
      if [ -n "$nv" ] && ver_ge "${nv#v}" "$NODE_FLOOR"; then
        APPS_NODE_OK=1
        [ -z "$APPS_NODE_BEST" ] && APPS_NODE_BEST="$nb"
      fi
    done <<< "$NODEBINS"
    line '```'
    line ""
    if [ "$APPS_NODE_OK" -eq 1 ]; then
      verdict OK "fnOS 自带 Node 可用" "版本 ≥ $NODE_FLOOR，可考虑由 fpk 声明依赖而非自带运行时"
      line ""
      line "> ⚠️ 注意：fnOS 应用升级可能替换或移除该运行时，**依赖它等于依赖系统**。"
      line "> 决策前提是阶段二能证明它跑得起 dsh（含原生模块 ABI）。"
    else
      verdict WARN "fnOS 自带 Node 均不满足" "版本 < $NODE_FLOOR，必须自带运行时"
    fi
  fi
else
  verdict SKIP "/var/apps 不存在" "非标准 fnOS 或权限不足"
fi

line ""

line "## 5. 资源"
line ""

if have free; then
  MEM_MB="$(free -m | awk '/^Mem:/{print $2}')"
  AVAIL_MB="$(free -m | awk '/^Mem:/{print $7}')"
  line "- 内存：总计 ${MEM_MB}MB / 可用 ${AVAIL_MB}MB"
  if [ "${MEM_MB:-0}" -ge 7600 ]; then
    verdict OK "内存够跑 fpk/npm 路线" "${MEM_MB}MB"
    if [ "${MEM_MB:-0}" -ge 9000 ]; then
      line "  - 也够做 git 源码构建（构建脚本硬编码 \`--max-old-space-size=8192\`）"
    fi
  elif [ "${MEM_MB:-0}" -ge 3500 ]; then
    verdict WARN "内存偏紧" "${MEM_MB}MB：跑 dsh 可以，但**不要**在机内做 git 源码构建"
  else
    verdict FAIL "内存不足" "${MEM_MB}MB"
  fi
else
  verdict SKIP "内存" "free 不可用"
fi

line "- CPU：$(nproc 2>/dev/null || echo '?') 核"
line ""
line "### 磁盘与挂载"
line ""
line '```'
cap 'df -h | head -n 12'
line '```'
line ""

NOEXEC="$(grep -E ' /vol[0-9]+' /proc/mounts 2>/dev/null | grep -c 'noexec')"
if [ "${NOEXEC:-0}" -gt 0 ]; then
  verdict FAIL "数据卷带 noexec" "存在 /vol* 以 noexec 挂载，无法在数据卷上运行 node 二进制"
  line ""
  line '```'
  cap "grep -E ' /vol[0-9]+' /proc/mounts"
  line '```'
else
  verdict OK "数据卷可执行" "/vol* 未使用 noexec"
fi

line ""

line "## 6. 网络"
line ""

probe_url() { # probe_url <url> <标签>
  local url="$1" label="$2"
  if ! have curl; then verdict SKIP "$label" "curl 不可用"; return; fi
  local r
  r="$(curl -sS -m 8 -o /dev/null -w '%{http_code} %{time_total}s' "$url" 2>&1)"
  case "$r" in
    2*|3*|401*|403*) verdict OK "$label" "$url → $r" ;;
    *)               verdict WARN "$label" "$url → $r" ;;
  esac
}

probe_url "https://api.deepseek.com/" "DeepSeek API 可达（401/403 也算可达）"
probe_url "https://registry.npmmirror.com/" "npm 镜像可达"
probe_url "https://registry.npmjs.org/" "npm 官方源可达"
probe_url "https://github.com/" "GitHub 可达"

line ""
PUB="$(curl -s -m 8 https://registry.npmmirror.com/@deepseek-ai/dsh/latest 2>/dev/null | grep -o '"version":"[^"]*"' | head -n1 | cut -d'"' -f4)"
if [ -n "${PUB:-}" ]; then
  line "- npm 上 \`@deepseek-ai/dsh\` 当前 latest：\`$PUB\`"
else
  line "- 未能取得 npm 上的 dsh 版本（npmmirror 可能未同步 scoped 包）"
fi

line ""

line "## 7. 绑定地址与端口"
line ""

DEF_SRC=""
if have ip; then
  DEF_SRC="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
fi

V4_COUNT="$(ip -4 -o addr show 2>/dev/null | awk '$2!="lo"' | wc -l)"

if [ -n "${DEF_SRC:-}" ]; then
  verdict OK "默认路由源地址" "$DEF_SRC"
fi

line ""
line "全部本机地址（**括号内是接口名，dsh 的 --host 必须填其中之一**）："
line '```'
cap "ip -4 -o addr show | awk '{print \$2, \$4}'"
line '```'
line ""

if [ "${V4_COUNT:-0}" -gt 1 ]; then
  verdict WARN "多网卡 / 桥接环境" "检测到 $V4_COUNT 个非 lo IPv4（含 OVS/docker 网桥）；默认路由源地址未必等于客户端实际访问的地址，**必须从客户端实测**"
else
  verdict OK "单一业务网卡" "绑定地址无歧义"
fi

for p in 3080 3081 3089; do
  if have ss && ss -ltn 2>/dev/null | grep -q ":$p "; then
    verdict WARN "端口 $p 已被占用" "$(ss -ltn 2>/dev/null | grep ":$p " | head -n1)"
  else
    verdict OK "端口 $p 空闲" ""
  fi
done

line ""

line "## 8. fnOS 应用体系"
line ""

if [ -d /var/apps ]; then
  verdict OK "/var/apps 存在" "已装应用 $(ls /var/apps 2>/dev/null | wc -l) 个"
  line ""
  line '```'
  cap 'ls /var/apps | head -n 24'
  line '```'
else
  verdict WARN "/var/apps 不存在" "可能不是标准 fnOS，或权限不足"
fi

if have appcenter-cli; then
  verdict OK "appcenter-cli 可用" "$(command -v appcenter-cli)"
else
  verdict WARN "appcenter-cli 不可用" "无法在机内直接装 fpk（可在 Web 界面装）"
fi

if have fnpack; then verdict OK "fnpack" "$(command -v fnpack)"; else verdict SKIP "fnpack" "打包在开发机做即可"; fi

if [ -d "${HOME:-/root}/.dsh" ]; then
  verdict WARN "已存在 \$DSH_HOME" "$HOME/.dsh —— 同一台机器上多种部署方式会互相污染，只能选一种"
fi

if [ "$(id -u)" -eq 0 ]; then
  line "- 当前为 root（阶段二会额外以 nobody 身份复测沙箱）"
else
  if sudo -n true 2>/dev/null; then line "- sudo：免密可用"; else line "- sudo：不可用或需密码"; fi
fi

line ""

line "## 9. 结论"
line ""
line "| OK | WARN | FAIL | SKIP |"
line "|---|---|---|---|"
line "| $OK | $WARN | $FAIL | $SKIP |"
line ""

if [ "$FAIL" -eq 0 ]; then
  line "**可以进入阶段二冒烟测试。**"
else
  line "**存在 FAIL 项，先解决再进入阶段二。**"
fi

{
  printf '%s\n' "${RPT[@]}"
} > "$REPORT"

printf '%s\n' "${RPT[@]}"
echo ""
echo "报告已写入：$REPORT"
