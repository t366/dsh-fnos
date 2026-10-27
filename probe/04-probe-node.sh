#!/usr/bin/env bash
# 04-probe-node.sh — 只读探查：飞牛 fnOS 的 Node 应用是怎么装、怎么被用的
#
# 用途：回答「飞牛提供的 nodejs_v24 到底是什么形态、其他应用怎么引用它、
#       能不能被第三方应用安全复用」这三个问题。
# 特性：不改任何系统状态、不装任何包、不需要外网。root 跑最完整，普通用户也能跑。
#
# 用法：
#   bash 04-probe-node.sh              # 报告写到 ~/
#   bash 04-probe-node.sh /vol1/xxx    # 指定报告目录

set -u

RPT=()
out()  { RPT+=("$1"); }
sec()  { out ""; out "## $1"; out ""; }
kv()   { out "- **$1**：$2"; }
code() {
  out '```'
  local s="${1:-}"
  if [ -n "$s" ]; then
    while IFS= read -r __l; do out "$__l"; done <<< "$s"
  fi
  out '```'
}
brief() { printf '%s' "${1:-}" | tr '\n' ' ' | cut -c1-240; }

TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${1:-$HOME}"
[ -d "$OUTDIR" ] || mkdir -p "$OUTDIR" 2>/dev/null
REPORT="$OUTDIR/dsh-node-probe-$TS.md"

A24=/var/apps/nodejs_v24
A22=/var/apps/nodejs_v22

out "# fnOS Node 应用探查报告"
out ""
kv "时间" "\`$(date '+%Y-%m-%d %H:%M:%S %Z')\`"
kv "主机" "\`$(hostname 2>/dev/null)\`"
kv "身份" "\`$(id -un 2>/dev/null)\` (uid=$(id -u 2>/dev/null))"
kv "系统" "\`$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")\` / 内核 \`$(uname -r)\`"

# ---------------------------------------------------------------- 1
sec "1. 当前 shell 里的 node 从哪来"

kv "PATH" "\`${PATH:-}\`"
for b in node npm npx corepack bun; do
  kv "which -a $b" "\`$(type -a "$b" 2>/dev/null | sed 's/^[^ ]* is //' | tr '\n' ' ')\`"
done
kv "node -v" "\`$(node -v 2>&1 | head -n1)\`"
kv "npm -v" "\`$(npm -v 2>&1 | head -n1)\`"

# ---------------------------------------------------------------- 2
sec "2. 应用落位与结构"

for A in "$A24" "$A22"; do
  out ""
  out "### \`$A\`"
  out ""
  if [ -d "$A" ]; then
    kv "存在" "是"
    kv "体积" "\`$(du -sh "$A" 2>/dev/null | awk '{print $1}')\`"
    kv "普通文件数" "\`$(find "$A" -type f 2>/dev/null | wc -l)\`"
    kv "顶层属主/权限" "\`$(stat -c '%U:%G %a' "$A" 2>/dev/null)\`"
    out ""
    out "顶层内容："
    code "$(ls -la "$A" 2>&1 | head -n 25)"
    out "两层目录骨架："
    code "$(find "$A" -mindepth 1 -maxdepth 2 -type d 2>/dev/null | sort | head -n 30)"
  else
    kv "存在" "**否**（该应用未装在此卷，或未挂载）"
  fi
done

# ---------------------------------------------------------------- 2b
sec "2b. 真实路径：/vol*/@appcenter 与 /var/apps 的关系"

out "这是最容易被文档误导的一点：官方口径是装在 \`/vol{N}/@appcenter/nodejs_v{X}\`，"
out "而 \`/var/apps\` 只是另一个视图。两者关系直接决定 fpk 里该怎么写路径。"
out ""
kv "/var/apps/nodejs_v24 解析后" "\`$(readlink -f /var/apps/nodejs_v24 2>/dev/null)\`"
kv "ls -ld" "\`$(ls -ld /var/apps /var/apps/nodejs_v24 2>&1 | tr '\n' '|')\`"
code "$(mount 2>/dev/null | grep -E 'appcenter|/var/apps' | head -n 10)"

out "所有卷上的 nodejs 应用："
code "$(ls -d /vol*/@appcenter/nodejs_v* 2>/dev/null)"

while IFS= read -r D; do
  [ -n "$D" ] || continue
  out ""
  out "### \`$D\`"
  kv "体积" "\`$(du -sh "$D" 2>/dev/null | awk '{print $1}')\`"
  kv "文件数" "\`$(find "$D" -type f 2>/dev/null | wc -l)\`"
  kv "属主/权限" "\`$(stat -c '%U:%G %a' "$D" 2>/dev/null)\`"
  out "顶层："
  code "$(ls -la "$D" 2>/dev/null | head -n 12)"
  out "\`bin/\`："
  code "$(ls -la "$D/bin" 2>/dev/null | head -n 15)"
done <<< "$(ls -d /vol*/@appcenter/nodejs_v* 2>/dev/null | head -n 6)"

# ---------------------------------------------------------------- 3
sec "3. node 二进制实体（是否符号链接、链接到哪）"

NODE24=""
# 优先真实安装路径
for p in /vol*/@appcenter/nodejs_v24/bin/node /var/apps/nodejs_v24/bin/node; do
  [ -x "$p" ] && { NODE24="$p"; break; }
done
FOUND_ANY=0
N24ROOT="$(dirname "$(dirname "$(readlink -f "$NODE24" 2>/dev/null)")")"
[ -n "$N24ROOT" ] || N24ROOT="$A24"
while IFS= read -r n; do
  [ -n "$n" ] || continue
  FOUND_ANY=1
  real="$(readlink -f "$n" 2>/dev/null)"
  ver="$("$n" -v 2>&1 | head -n1)"
  kv "候选" "\`$n\`"
  kv "　解析后" "\`$real\`"
  kv "　版本" "\`$ver\`"
  kv "　类型" "\`$(file -b "$real" 2>/dev/null | cut -c1-100)\`"
  kv "　属主/权限" "\`$(stat -c '%U:%G %a %s' "$real" 2>/dev/null)\`"
  [ -z "$NODE24" ] && NODE24="$n"
done <<< "$(find "$N24ROOT" -maxdepth 4 \( -type f -o -type l \) -name node 2>/dev/null | head -n 10)"

[ "$FOUND_ANY" = "0" ] && kv "候选" "**在 $N24ROOT 下没找到名为 node 的可执行文件**"

out ""
out "nodejs_v24 下所有 bin 目录："
code "$(find "$N24ROOT" -maxdepth 5 -type d -name bin 2>/dev/null | head -n 10 | while read -r d; do echo "== $d"; ls -la "$d" 2>/dev/null | head -n 12; done)"

# ---------------------------------------------------------------- 4
sec "4. npm 的全局视图（决定全局装的包落在哪、升级会不会丢）"

if [ -n "$NODE24" ]; then
  NB="$(dirname "$(readlink -f "$NODE24" 2>/dev/null)")"
  kv "npm 路径" "\`$NB/npm\`"
  kv "npm 版本" "\`$("$NB/npm" -v 2>&1 | head -n1)\`"
  kv "npm prefix" "\`$("$NB/npm" config get prefix 2>&1 | head -n1)\`"
  kv "npm root -g" "\`$("$NB/npm" root -g 2>&1 | head -n1)\`"
  kv "npm cache" "\`$("$NB/npm" config get cache 2>&1 | head -n1)\`"
  kv "registry" "\`$("$NB/npm" config get registry 2>&1 | head -n1)\`"
  out ""
  out "全局包目录内容："
  code "$(ls -la "$("$NB/npm" root -g 2>/dev/null)" 2>&1 | head -n 15)"
else
  kv "npm" "跳过（没找到 node）"
fi

# ---------------------------------------------------------------- 5
sec "5. PATH 是怎么被注入的（谁把 /var/apps 加进环境）"

out "shell 启动文件里的引用："
code "$(grep -rn "nodejs_v2[24]" \
  /etc/profile /etc/profile.d/ /etc/environment /etc/bash.bashrc \
  "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" 2>/dev/null | head -n 20)"

out "系统配置里的引用（限时 25s）："
code "$(timeout 25 grep -rlI "nodejs_v2[24]" /etc /usr/trim /usr/local/bin 2>/dev/null | head -n 20)"

out "\`/usr/local/bin\` 下的 node 相关入口："
code "$(ls -la /usr/local/bin 2>/dev/null | grep -iE 'node|npm|npx|bun' )"

# ---------------------------------------------------------------- 6
sec "6. 应用元数据（manifest / 依赖声明 / 运行身份）"

out "nodejs_v24 顶层文件："
code "$(find "$A24" -maxdepth 1 -type f 2>/dev/null | head -n 20)"

for f in manifest manifest.json app.json info.json config.json; do
  if [ -f "$A24/$f" ]; then
    out "\`$f\`："
    code "$(head -c 4000 "$A24/$f" 2>/dev/null)"
  fi
done

out "任何 \`*manifest*\` / \`*.json\`（深度 2）："
code "$(find "$A24" -maxdepth 2 \( -name '*manifest*' -o -name '*.json' \) 2>/dev/null | head -n 15)"

# ---------------------------------------------------------------- 7
sec "7. 谁在引用它（这决定它是不是「公共运行时」）"

SEC7SCOPE="/var/apps"
for d in /vol*/@appcenter; do [ -d "$d" ] && SEC7SCOPE="$SEC7SCOPE $d"; done

out "其他应用目录里引用 nodejs_v2x 的文件（限时 40s，跳过二进制）："
code "$(timeout 40 grep -rlI "nodejs_v2[24]" $SEC7SCOPE 2>/dev/null \
        | grep -vE '/(var/apps|@appcenter)/nodejs_v2' | head -n 25)"

out "其他应用 manifest 里声明 install_dep_apps 的情况："
code "$(timeout 30 grep -rnI "install_dep_apps" \
        /var/apps/*/manifest /var/apps/*/*.json \
        /vol*/@appcenter/*/manifest /vol*/@appcenter/*/*.json 2>/dev/null | head -n 20)"

out "其他应用里对 node 的直接引用（cmd/main 等脚本）："
code "$(timeout 30 grep -rnI -E '(^|[^a-zA-Z])node( |$)' \
        /var/apps/*/cmd /vol*/@appcenter/*/cmd 2>/dev/null \
        | grep -v nodejs_v2 | head -n 15)"

if [ -d /var/apps/bunjs ]; then
  out ""
  out "\`bunjs\`（同门应用，可对照它的提供方式）："
  code "$(ls -la /var/apps/bunjs 2>/dev/null | head -n 15)"
fi

# ---------------------------------------------------------------- 8
sec "8. 系统级 node 的来源"

for p in /usr/local/bin/node /usr/bin/node /bin/node; do
  if [ -e "$p" ] || [ -L "$p" ]; then
    kv "$p" "\`$(ls -l "$p" 2>/dev/null | sed 's/  */ /g')\`"
    kv "　解析后" "\`$(readlink -f "$p" 2>/dev/null)\`"
    kv "　版本" "\`$("$p" -v 2>&1 | head -n1)\`"
  else
    kv "$p" "不存在"
  fi
done
kv "dpkg 归属" "\`$(dpkg -S /usr/local/bin/node /usr/bin/node 2>&1 | head -n3 | tr '\n' ' ')\`"

# ---------------------------------------------------------------- 9
sec "9. 非 root 能不能用（fpk 应用不会是 root）"

if [ -n "$NODE24" ] && [ "$(id -u)" = "0" ]; then
  out "以 nobody(65534) 身份执行 node -v："
  code "$(setpriv --reuid=65534 --regid=65534 --clear-groups "$NODE24" -v 2>&1 | head -n 5)"
  out "以 nobody 身份读取全局包目录："
  GB="$("$(dirname "$(readlink -f "$NODE24")")/npm" root -g 2>/dev/null)"
  code "$(setpriv --reuid=65534 --regid=65534 --clear-groups ls -la "$GB" 2>&1 | head -n 6)"
else
  kv "跳过" "非 root（或没找到 node），权限侧需另测"
fi

kv "$A24 属主/权限" "\`$(stat -c '%U:%G %a' "$A24" 2>/dev/null)\`"
kv "node 文件属主/权限" "\`$(stat -c '%U:%G %a' "$(readlink -f "${NODE24:-/nonexistent}" 2>/dev/null)" 2>/dev/null)\`"

# ---------------------------------------------------------------- 10
sec "10. 自动判定"

J() { if [ "$1" = "1" ]; then out "- \`YES\` **$2** — $3"; else out "- \`NO \` **$2** — $3"; fi; }

if [ -n "$NODE24" ]; then
  V="$("$NODE24" -v 2>/dev/null | sed 's/^v//')"
  if [ -z "$V" ]; then
    out "- \`FAIL\` **node 无法执行** — 见第 3 节"
  elif [ "$(printf '%s\n24.9.0\n' "$V" | sort -V | head -n1)" = "24.9.0" ]; then
    J 1 "版本达标" "$V ≥ 24.9.0，可跑 dsh"
  else
    J 0 "版本不足" "$V < 24.9.0"
  fi
  if [ -L "$NODE24" ]; then J 1 "是符号链接" "解析到 $(readlink -f "$NODE24")"; else J 0 "不是符号链接" "实体文件"; fi
else
  out "- \`FAIL\` **没找到 node** — 无法判定，见第 2/3 节"
fi

if [ -n "${GB:-}" ]; then
  case "$GB" in
    /var/apps/*) J 1 "全局包在应用目录内" "$GB（应用升级/卸载可能清空）" ;;
    *)           J 0 "全局包在应用目录外" "$GB（可能不受应用生命周期影响）" ;;
  esac
fi

out ""
out "---"
out ""
kv "报告路径" "\`$REPORT\`"

mkdir -p "$OUTDIR" 2>/dev/null
printf '%s\n' "${RPT[@]}" >"$REPORT"

echo "报告已写入：$REPORT"
