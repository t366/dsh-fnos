#!/bin/bash
# ============================================================================
# 在飞牛 NAS 上打包 fpk。
#
#   bash build.sh              # 骨架包（不含 dsh 运行时，约 100KB）
#   bash build.sh full         # 完整包（捆绑 node + dsh + pnpm + npm；包内约 1GB、fpk 约 208MB）
#
# 默认行为（都是为了少记命令）：
#   · 先跑 selftest.sh，失败就中止          → DSH_SKIP_SELFTEST=1 跳过
#   · 打完把 fpk 复制到应用共享目录，供前端「手动安装」选取 → DSH_STAGE=0 跳过
#
# 为什么必须在 NAS 上跑：
#   - fnpack 只装在那台机器上（/usr/local/bin/fnpack）
#   - cmd/* 需要可执行位，Windows 上 scp 过去会丢
#   - full 模式要现场 npm install，且要复用系统的 nodejs_v24
# ============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

MODE="${1:-skeleton}"
# 钉版本，永不写 @latest：dsh 的 npm dist-tags 与 GitHub 发布不同步
# （latest 曾落后三个 RC），不写版本号装到的是旧版，见 PLAN §3.2。
# 0.7.1 起跟到 rc.5：rc.4 是「无变更重发」（内容与 rc.3 逐字节相同），
# rc.5 的改动是对话里思考内容的展示优化（纯前端）。rc.3→rc.5 依赖集完全一致
# （86 个包，只有版本号变），没有新增原生件或新引擎要求。
# 0.9.0 起跟到 0.2.2-rc.1：0.2.2 线首个 RC，npm 实测 latest = next = 0.2.2-rc.1
# （alpha = 0.2.2-alpha.3）。自带 skill-office，--patch 挂载链路依赖仍在；
# 发布包声明 engines.node >= 24.9.0（0.2.1-rc.5 没有，门槛检查从此处起真正生效）。
# 已知事故：桌面端 rc.5→rc.1 有插件配置丢失案例，升级前快照（0.7.2 起）兜底。
DSH_VERSION="${DSH_VERSION:-0.2.2-rc.1}"
# dsh 自己不实现包管理：插件安装/查询全部转发给 pnpm（`pnpm view`、`pnpm add`），
# 而且只认 PATH 上的裸命令 "pnpm" → 不带 pnpm 时 Web 界面报 `spawn pnpm ENOENT`。
# 钉 10.x 的理由：dsh 的引导文案让用户改 pnpm-workspace.yaml 里的 allowBuilds，
# 这个字段 10.26 才有（v11 起只认它）；10.34.9 是 10.x 的最新维护版，仍支持 node 18+。
DSH_PNPM_VERSION="${DSH_PNPM_VERSION:-10.34.9}"
# 只带 pnpm 不够：pnpm 的 `view` / `config` 子命令自己没有实现，直接 spawn 裸命令
# "npm" 转发（pnpm/dist/pnpm.cjs 里的 run-npm：`const npm = npmPath ?? "npm"`）。
# PATH 上找不到 npm 时会落到系统那份 —— 飞牛自带 npm 10.9.3，而 dsh 强制用自带
# node 24 去跑它，在 minizlib 里 `Class extends value undefined`（F29）。
# 钉 11.x：node 24 发行版自带的就是 npm 11，engines ^20.17 || >=22.9 与 v24 相容。
DSH_NPM_VERSION="${DSH_NPM_VERSION:-11.21.1}"
NODE_SRC="${NODE_SRC:-/var/apps/nodejs_v24/target}"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 1. 归一化
step "归一化换行与权限"
# Windows 上编辑过的脚本会带 CRLF，bash 会报 $'\r': command not found
find cmd -type f -exec sed -i 's/\r$//' {} + 2>/dev/null || true

# 只处理「我们自己写的、可能在 Windows 上编辑过」的文本文件。
# 绝不要遍历 app/runtime/app/node_modules：full 模式下那是 6 万多个文件，
# sed -i 会逐个重写（改 mtime、耗时数分钟），而 npm 装出来的本来就是 LF。
for f in app/ui/config wizard/* manifest; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null || true
done
for f in app/runtime/stub/server.mjs app/runtime/launcher/server.mjs app/runtime/relay/server.mjs app/runtime/profile/office.patch.yml; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null || true
done

chmod +x cmd/* 2>/dev/null || true

# 但 cmd/lib-home 是被 source 的库、*.mjs 是 node 调用的，两个都不需要执行位。
# 给它们 +x 会让 git 看到 mode 变化（100644 → 100755）：工作区变脏，
# 下次 `git pull` 遇到同名文件的新提交就会被「本地改动会被覆盖」挡住（2026-11-01 实际发生）。
chmod a-x cmd/lib-home 2>/dev/null || true
chmod a-x cmd/*.mjs 2>/dev/null || true

# 目录必须可遍历（有 +x）。fnOS 装完后 config/ wizard/ 的 mode 会变成 644，
# 见 probe/05-verify-fpk.sh 第 5 节的告警；打包前先钉死，排除「源目录本来就没 +x」
# 这一种可能。只处理包内的少量目录，不碰 node_modules。
find . -maxdepth 3 -type d -not -path './app/runtime/app/*' -exec chmod 755 {} + 2>/dev/null || true
say "cmd/ 已 chmod +x（lib-home 与 *.mjs 保持 644），目录已 chmod 755，自写文本已清 CRLF（node_modules 不动）"

# ---------------------------------------------------------------- 1.2 自测
# 把 selftest 串进打包流程：用户在 NAS 上只需要记一条 `bash build.sh full`，
# 而不是「先 selftest 再 build」。自测失败直接中止 —— 打一个起不来的包更浪费时间。
if [ "${DSH_SKIP_SELFTEST:-0}" = "1" ]; then
  say "已按 DSH_SKIP_SELFTEST=1 跳过自测"
elif [ -f selftest.sh ]; then
  step "安装前自测（失败会中止打包）"
  if ! bash selftest.sh; then
    die "自测未通过，已中止打包。修完再跑；确认与本次改动无关可 DSH_SKIP_SELFTEST=1 跳过。"
  fi
fi

# ---------------------------------------------------------------- 1.5 版本守卫
# 踩过的坑（2026-10-27）：版本号没变时 `appcenter-cli install-fpk` 只打印
# 「Application [dsh] is installed.」就返回 0，**既不替换 target/，也不跑升级钩子**，
# 看起来像装成功，实际什么都没发生。这种静默跳过必须在这里挡住。
step "版本"
mval() { # $1=文件 $2=键 —— 安装后的 manifest 会被 fnOS 重写，键可能带引号/空格，
         # 且字段顺序可能变化，所以先归一化「键」再比，不能用一条正则捞值
         # （changelog 正文里出现 version= 就会被误取）。
  local line k v
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    k="${k//\"/}"; k="${k//\'/}"; k="${k// /}"; k="${k//$'\t'/}"; k="${k//$'\r'/}"
    v="${v//\"/}"; v="${v//\'/}"; v="${v//$'\r'/}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$k" = "$2" ] && { printf '%s' "$v"; return 0; }
  done <"$1"
  return 1
}
PKG_APP="$(mval manifest appname)"
PKG_VER="$(mval manifest version)"

# ---------------------------------------------------------------- 2b. 架构
# manifest 的 platform 是安装期门禁，而这个包的 node 与 node_modules 都是
# 「就地取宿主」的：node 从 $NODE_SRC 复制、依赖用本机 npm 装。所以只能在目标
# 架构上打包。声明与实际不一致时，产出的包要么被应用中心拒绝，要么装上了
# 「跑不起来」——两种都比打包期失败难查。参考项目里双架构都是各自 CI 任务，
# 同一份产物不可能两边通用；这里至少把「在 x86 上打出 arm 包」这种事挡住。
step "架构"
HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
case "$HOST_ARCH" in
  x86_64|amd64)  EXPECT_PLATFORM=x86 ;;
  aarch64|arm64) EXPECT_PLATFORM=arm ;;
  *)             EXPECT_PLATFORM="" ;;   # 其它架构不猜，只提示
esac
DECL_PLATFORM="$(mval manifest platform 2>/dev/null || true)"
if [ -n "$EXPECT_PLATFORM" ] && [ "${DECL_PLATFORM:-}" != "$EXPECT_PLATFORM" ]; then
  die "架构不一致：manifest 的 platform=\"${DECL_PLATFORM:-<空>}\"，当前机器是 $HOST_ARCH（应为 $EXPECT_PLATFORM）。
本包的 node 与 node_modules 都取自本机，跨架构打出来的包在目标机上跑不起来。
把 manifest 的 platform 改成 $EXPECT_PLATFORM 后重打；要同时支持两种架构，请在各自架构的机器上各打一次。"
fi
say "ok：$HOST_ARCH → platform=${DECL_PLATFORM:-未声明}"

# 已装版本的来源不能只看 /var/apps/<app>。
# 2026-10-27 23:44 实测：应用明明在跑（3080/healthz 200），但 /var/apps/dsh 不存在，
# 于是这里读到空值 → 版本守卫**静默失效**（同版本也能打出来，装上去是空操作）。
# 所以按「平台软链 → 实体目录 → 元数据目录」三处依次找，任一命中即可。
INST_VER=""
INST_PATH=""
for _m in "/var/apps/$PKG_APP/manifest" \
          "/vol1/@appcenter/$PKG_APP/manifest" \
          "/vol1/@appmeta/$PKG_APP/manifest"; do
  if [ -f "$_m" ]; then
    INST_VER="$(mval "$_m" version || true)"
    if [ -n "$INST_VER" ]; then INST_PATH="$_m"; break; fi
  fi
done
say "包：$PKG_APP $PKG_VER    已安装：${INST_VER:-<无>}${INST_PATH:+（读自 $INST_PATH）}"

# 读不到就明说，别让守卫悄悄变成空转。平台自己知道装没装，用它当旁证。
if [ -z "$INST_VER" ] && command -v appcenter-cli >/dev/null 2>&1; then
  if appcenter-cli check "$PKG_APP" 2>/dev/null | grep -qi 'is installed'; then
    say ""
    say "⚠ 平台说 $PKG_APP 已安装，但上面三处都读不到它的 manifest。"
    say "   本次版本守卫无法生效——请确认你要装的版本确实高于已装版本。"
    say "   现场：ls -l /var/apps/$PKG_APP /vol1/@appcenter/$PKG_APP 2>&1"
    say ""
  fi
fi
if [ -n "$INST_VER" ] && [ "$PKG_VER" = "$INST_VER" ]; then
  if [ "${DSH_ALLOW_SAME_VERSION:-0}" = "1" ]; then
    say ""
    say "⚠ 版本号与已安装的相同，按 DSH_ALLOW_SAME_VERSION=1 继续。"
    say "   注意：应用中心会把它们当成同一个包，装上去不会替换 target/。"
    say ""
  else
    die "包版本与已安装的相同（$PKG_VER）。侧载包没有覆盖升级通道：同版本装上去
       应用中心只回一句 is installed，target/ 不会更新。
       处理办法：把 manifest 的 version 改成更高值后重打；
       确实要做同版本对照实验时，显式加 DSH_ALLOW_SAME_VERSION=1。"
  fi
fi

# ---------------------------------------------------------------- 2. 必需文件
step "检查必需文件"
for f in manifest ICON.PNG ICON_256.PNG config/privilege config/resource \
         app/ui/config app/ui/images/icon_64.png app/ui/images/icon_256.png \
         cmd/main cmd/lib-home cmd/ensure-default-workspace.mjs wizard/install; do
  [ -e "$f" ] || die "缺少必需文件：$f"
done
say "ok"

# 图标尺寸/大小不符合规范时，应用中心可能不显示图标（不是报错，是静默不显示）
if command -v node >/dev/null 2>&1; then
  node -e '
const fs=require("fs");
// 图标校验。2026-10-28 起四处图标都直接用 DeepSeek 官方仓库的成品图标
// （apps/web/public/icon-512.png，512×512），原样复制、不缩放不调色，四个文件
// 的 SHA-256 完全一致。所以这里不再限定具体边长，只守三条底线：
//   正方形 / 边长 64~1024 / ≤1024KB
//
// 为什么不再固定 64 或 256：
//  - 官方规范写 ICON.PNG=64×64，但那是 fnpack build 的校验（MAA-FnOS 构建指南原文
//    写过），我们用自研 build.sh 打 tar，不受这条限制；
//  - 社区同款项目里 ICON.PNG 有 640×640（yuexps，113★）和 128×128（techysy，77★），
//    甚至把 ICON.PNG 与 ICON_256.PNG 放成同一个文件，照样能装能用；
//  - 详情页实际按 ~96 物理像素显示图标，源图小于这个值必然发虚。
const files=["ICON.PNG","ICON_256.PNG","app/ui/images/icon_64.png","app/ui/images/icon_256.png"];
let bad=0;
for(const f of files){
  const b=fs.readFileSync(f);
  if(b.subarray(1,4).toString()!=="PNG"){console.log("✗ "+f+" 不是 PNG");bad=1;continue;}
  const w=b.readUInt32BE(16),h=b.readUInt32BE(20),kb=Math.round(b.length/1024);
  const ok=w===h&&w>=64&&w<=1024&&b.length<=1024*1024;
  console.log((ok?"ok  ":"✗   ")+f+"  "+w+"x"+h+"  "+kb+"KB");
  if(!ok)bad=1;
}
process.exit(bad);
' || die "图标不符合规范：需正方形 PNG、边长 64~1024、≤1024KB"
fi

# ---------------------------------------------------------------- 3. JSON 校验
step "校验 JSON"
if command -v node >/dev/null 2>&1; then
  for f in config/privilege config/resource app/ui/config; do
    node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$f" \
      || die "JSON 格式错误：$f"
    say "ok  $f"
  done

  # 向导除了「是合法 JSON」还有内容约束，而 fnpack 只会甩一句
  #   File "xxx" is not valid due to JSON format or content validation failure.
  # 不说是哪个字段。实测踩到的第一个坑就是 initValue 写成布尔值（必须字符串）。
  # 这里把已知约束提前检查掉，报错能精确到第几步第几项。
  LINT="$(mktemp)"
  trap 'rm -f "$LINT"' EXIT
  cat >"$LINT" <<'JSEOF'
const fs = require("fs");
const TYPES = ["text", "password", "radio", "checkbox", "select", "switch", "tips"];
const file = process.argv[2];
let doc;
try {
  doc = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (e) {
  console.log("× " + file + "：JSON 语法错误 — " + e.message);
  process.exit(1);
}
const errs = [];
if (!Array.isArray(doc) || doc.length === 0) {
  errs.push("顶层必须是非空数组");
} else {
  doc.forEach((step, si) => {
    const s = "第" + (si + 1) + "步";
    if (!step || typeof step !== "object") { errs.push(s + " 不是对象"); return; }
    if (typeof step.stepTitle !== "string" || !step.stepTitle) errs.push(s + " 缺少 stepTitle");
    if (!Array.isArray(step.items) || step.items.length === 0) {
      errs.push(s + " 的 items 必须是非空数组");
      return;
    }
    step.items.forEach((it, ii) => {
      const at = s + "第" + (ii + 1) + "项";
      if (!it || typeof it !== "object") { errs.push(at + " 不是对象"); return; }
      if (typeof it.type !== "string") { errs.push(at + " 缺少 type"); return; }
      if (TYPES.indexOf(it.type) < 0) errs.push(at + " 的 type 非法：" + it.type);
      if (it.type === "tips") {
        if (typeof it.helpText !== "string" || !it.helpText) errs.push(at + "（tips）缺少 helpText");
      } else if (typeof it.field !== "string" || !it.field) {
        errs.push(at + " 缺少 field");
      }
      if (typeof it.field === "string" && /^TRIM_/.test(it.field)) {
        errs.push(at + " 的 field 不能用 TRIM_ 前缀（系统保留）");
      }
      // 关键约束：fnpack 要求 initValue 是字符串，布尔/数字一律 content validation failure
      if (it.initValue !== undefined && typeof it.initValue !== "string") {
        errs.push(at + " 的 initValue 必须是字符串（当前是 " + typeof it.initValue + "）");
      }
      if (["radio", "select", "checkbox"].indexOf(it.type) >= 0) {
        if (!Array.isArray(it.options) || it.options.length === 0) {
          errs.push(at + " 缺少 options");
        } else {
          it.options.forEach((o, oi) => {
            if (!o || typeof o.label !== "string" || typeof o.value !== "string") {
              errs.push(at + " 的 options[" + oi + "] 需要字符串 label 与 value");
            }
          });
          if (typeof it.initValue === "string" &&
              !it.options.some((o) => o && o.value === it.initValue)) {
            errs.push(at + " 的 initValue 不在 options 里");
          }
        }
      }
      if (it.rules !== undefined) {
        if (!Array.isArray(it.rules)) {
          errs.push(at + " 的 rules 必须是数组");
        } else {
          it.rules.forEach((r, ri) => {
            if (!r || typeof r !== "object") { errs.push(at + " 的 rules[" + ri + "] 必须是对象"); return; }
            if (Object.keys(r).filter((k) => k !== "message").length === 0) {
              errs.push(at + " 的 rules[" + ri + "] 没有规则键（只有 message）");
            }
            if (typeof r.message !== "string") errs.push(at + " 的 rules[" + ri + "] 缺少 message");
          });
        }
      }
    });
  });
}
if (errs.length) {
  console.log("× " + file);
  errs.forEach((e) => console.log("    " + e));
  process.exit(1);
}
console.log("ok  " + file);
JSEOF

  for f in wizard/*; do
    [ -f "$f" ] || continue
    node "$LINT" "$f" || die "向导内容不合规：$f（见上面的具体字段）"
  done
else
  say "跳过（没有 node）"
fi

# ---------------------------------------------------------------- 4. 运行时
step "运行时（mode=$MODE）"
if [ "$MODE" != "full" ]; then
  # 骨架模式的陷阱（0.9.0 首次踩中）：上一轮 full 构建留下的 runtime 在盘上
  # （目录被 .gitignore，但文件都在），fnpack 打包时不区分，会把这份**过期
  # 运行时**原样塞进包里 —— manifest 是新版本，引擎还是旧版。守卫：要么走
  # full 重装，要么显式确认清掉。
  if [ -d app/runtime/app/node_modules ] || [ -d app/runtime/node/bin ]; then
    die "骨架模式但检测到残留的 full 运行时（app/runtime/app、app/runtime/node）。
骨架包不该带引擎：这样打出来的包会拿旧引擎冒充新版本（0.9.0 事故）。
处理：bash build.sh full 重装引擎；或确认丢弃后 rm -rf app/runtime/app app/runtime/node 再打骨架包。"
  fi
fi
if [ "$MODE" = "full" ]; then
  [ -x "$NODE_SRC/bin/node" ] || die "找不到 node：$NODE_SRC/bin/node（可用 NODE_SRC 指定）"
  NODE_VER="$("$NODE_SRC/bin/node" -v)"
  say "node: $NODE_VER ($NODE_SRC)"

  # 引擎门槛：dsh 从 0.2.2 起在**发布出去的包里**声明 engines.node >= 24.9.0
  # （0.2.1-rc.5 的包里没有这个字段，所以这条门槛是新加的约束，不是老问题）。
  # npm 默认只对 engines 告警、不失败，于是"能装上"不等于"跑得起来"——
  # 这里在打包阶段就拦，避免打出一个装得上但运行期炸的包。
  NODE_MAJ="${NODE_VER#v}"; NODE_MAJ="${NODE_MAJ%%.*}"
  NODE_MIN="${NODE_VER#v*.}"; NODE_MIN="${NODE_MIN%%.*}"
  case "$NODE_MAJ" in ''|*[!0-9]*) die "无法解析 node 版本：$NODE_VER" ;; esac
  case "$NODE_MIN" in ''|*[!0-9]*) NODE_MIN=0 ;; esac
  if [ "$NODE_MAJ" -lt 24 ] || { [ "$NODE_MAJ" -eq 24 ] && [ "$NODE_MIN" -lt 9 ]; }; then
    die "node $NODE_VER 低于 dsh 要求的 >=24.9.0；升级飞牛的 nodejs_v24 应用，或用 NODE_SRC 指向 >=24.9 的 node"
  fi
  say "node 满足 dsh 引擎要求（>=24.9.0）"

  # 只清运行时产物，保留 stub：npm 一旦失败，包还能以骨架模式打出来，
  # 不至于把 NAS 上这份源码目录弄成「两种模式都打不了」。
  rm -rf app/runtime/node app/runtime/app
  mkdir -p app/runtime/node/bin app/runtime/app

  # 只拷二进制本身；npm/npx 是软链，运行 dsh 用不到
  cp "$NODE_SRC/bin/node" app/runtime/node/bin/node
  chmod +x app/runtime/node/bin/node

  ( cd app/runtime/app
    say "安装 @deepseek-ai/dsh@$DSH_VERSION ..."
    say "npm registry: $("$NODE_SRC/bin/npm" config get registry 2>/dev/null)"
    "$NODE_SRC/bin/npm" init -y >/dev/null 2>&1 || true
    # 显式 --prefix：飞牛的 npm 全局 prefix 指向 /usr/local，不能让它污染系统盘
    "$NODE_SRC/bin/npm" install --omit=dev --no-audit --no-fund \
      --prefix "$PWD" "@deepseek-ai/dsh@$DSH_VERSION" \
      >/tmp/dsh-npm-install.log 2>&1 || { tail -n 30 /tmp/dsh-npm-install.log; die "npm install 失败"; }

    # 回读实际装进来的版本并校验。
    # 起因：dsh 的 npm dist-tags 与 GitHub 发布不同步（latest 落后两个 RC，
    # 另有只存在于 npm、无 GitHub release 的重发版），见 PLAN §3.2。
    # 不校验的话，一个"看起来是 rc.3 实际是 rc.2"的包会被直接打进 fpk，
    # 而这类差异只有在真机上跑起来才暴露。
    PKGJSON="node_modules/@deepseek-ai/dsh/package.json"
    [ -f "$PKGJSON" ] || die "安装后找不到 $PKGJSON，npm 没有真正装成功"
    GOT="$(sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$PKGJSON" | head -n1)"
    if [ -z "$GOT" ]; then   # 压缩成一行的 package.json：退回用 node 解析
      GOT="$("$NODE_SRC/bin/node" -p "JSON.parse(require('fs').readFileSync('$PKGJSON','utf8')).version" 2>/dev/null || true)"
    fi
    [ "$GOT" = "$DSH_VERSION" ] || die "版本不符：请求 $DSH_VERSION，实际装到 ${GOT:-未知}"
    say "dsh 版本校验通过：$GOT"

    # ---- Office 补丁的静态校验（用 dsh 自己带的 yaml 解析器，不引入新依赖）----
    # 这份补丁只在命令行上生效一次，写错了会让 dsh 在解析阶段直接退出——
    # 那意味着"应用装好了但打不开"。所以在打包期就用真实的解析器过一遍，
    # 校验不过就别出包，而不是等用户装机后发现起不来。
    "$NODE_SRC/bin/node" -e '
      const { createRequire } = require("node:module");
      const [patchFile, appDir0] = process.argv.slice(1);
      const appDir = require("node:path").resolve(appDir0);
      const req = createRequire(appDir + "/package.json");
      let YAML;
      try { YAML = req("yaml"); } catch { console.log("SKIP: 安装树里没有 yaml 解析器"); process.exit(0); }
      const text = require("node:fs").readFileSync(patchFile, "utf8");
      const doc = YAML.parse(text, { customTags: [{ tag: "tag:yaml.org,2002:js", resolve: v => v }] });
      const fail = m => { console.error("FAIL: " + m); process.exit(1); };
      if (!Array.isArray(doc) || doc.length === 0) fail("顶层必须是 patch 数组");
      const row = (doc[0].insert || [])[0];
      if (!row) fail("缺少 insert 行");
      if (row.id !== "skill-office") fail("行 id 应为 skill-office，实际 " + JSON.stringify(row.id));
      if (row.name !== "@deepseek-ai/dsh-skill-office") fail("行 name 不对");
      for (const k of ["assetRoot", "cli", "node"]) {
        if (!row.config || !(k in row.config)) fail("config 缺 " + k);
      }
      console.log("OK: Office 补丁可解析");
    ' ../profile/office.patch.yml "$PWD" || die "Office 补丁校验失败（见上）"
  )

  # ---- 运行时瘦身：删 node_modules 里运行时永不读的文件（0.9.2 性能优化）----
  # 只删两类，均有实证依据：
  #   · *.map 源映射——只有 --enable-source-maps 时才读，NAS 上没人开；
  #   · 测试/示例/文档目录——test(s)/__tests__/example(s)/docs/.github。
  # 明确不删的（都论证过，见 DEVLOG 37.9）：
  #   · *.md——技能体系是 Markdown 驱动的，assets/*/SKILL.md 是运行时数据；
  #   · @deepseek-ai/dsh-experimental-*——0.2.2 的新能力（worktree/agent-team/
  #     voice-input/inspector）都在里面，懒加载，删了 UI 一开就断；
  #   · libreoffice-kit-wasm 下的一切——Office 三技能的本体（146M）。
  _R=app/runtime/app/node_modules
  _before="$(du -sm "$_R" 2>/dev/null | cut -f1)"
  find "$_R" -type f -name '*.map' -delete 2>/dev/null || true
  find "$_R" -type d \( -name test -o -name tests -o -name __tests__ \
      -o -name example -o -name examples -o -name docs -o -name .github \) \
      -not -path '*libreoffice-kit-wasm*' -prune -exec rm -rf {} + 2>/dev/null || true
  _after="$(du -sm "$_R" 2>/dev/null | cut -f1)"
  say "运行时瘦身：node_modules ${_before:-?}M -> ${_after:-?}M"

  # ---- pnpm：dsh 装插件时唯一的包管理器（版本理由见文件头 DSH_PNPM_VERSION）----
  # 放在 runtime/pnpm 而不是 app/node_modules：dsh 每次 full 构建都会整棵树重装，
  # 混进去会让「这是 dsh 的依赖还是我们的工具」说不清，也容易被一起清掉。
  rm -rf app/runtime/pnpm
  mkdir -p app/runtime/pnpm
  say "安装 pnpm@$DSH_PNPM_VERSION ..."
  printf '{"name":"dsh-runtime-pnpm","private":true}\n' >app/runtime/pnpm/package.json
  "$NODE_SRC/bin/npm" install --omit=dev --no-audit --no-fund \
    --prefix "$PWD/app/runtime/pnpm" "pnpm@$DSH_PNPM_VERSION" \
    >/tmp/dsh-npm-pnpm.log 2>&1 || { tail -n 30 /tmp/dsh-npm-pnpm.log; die "pnpm 安装失败"; }
  PNPM_JS="app/runtime/pnpm/node_modules/pnpm/bin/pnpm.cjs"
  [ -f "$PNPM_JS" ] || die "安装后找不到 $PNPM_JS，pnpm 没有真正装成功"

  # 用 sh wrapper 而不是软链：
  #   · spawn 找的是裸命令名 "pnpm"，所以必须有一个可执行文件进 PATH；
  #   · pnpm 自带的 shebang 是 `#!/usr/bin/env node`，会命中系统 PATH 里的 v22，
  #     而 dsh 跑在自带 v24 上 —— 版本错位时 pnpm 的引擎检查/子脚本行为都会跑偏；
  #   · 软链在 fpk 解包或复制时容易断（F20 就是路径假设踩的），wrapper 不依赖 inode。
  cat >app/runtime/node/bin/pnpm <<'WRAP'
#!/bin/sh
# 由 build.sh 生成，勿手改。
# 布局：runtime/node/bin/pnpm  ->  ../../pnpm/node_modules/pnpm/bin/pnpm.cjs
# 注意这里是两级向上：$here 已经是 runtime/node/bin，上一级是 runtime/node。
here=$(cd "$(dirname "$0")" && pwd)
pnpm_js="$here/../../pnpm/node_modules/pnpm/bin/pnpm.cjs"
if [ ! -f "$pnpm_js" ]; then
  printf 'pnpm: 找不到 %s（运行时安装不完整，请重装应用）\n' "$pnpm_js" >&2
  exit 127
fi
exec "$here/node" "$pnpm_js" "$@"
WRAP
  chmod +x app/runtime/node/bin/pnpm

  # 自检：wrapper 必须真能跑。装不起来的 pnpm 比没有 pnpm 更糟 —— 它会把
  # 「命令不存在」伪装成插件不兼容，用户只会回去查包名。
  # 这条自检必须从 **别的目录** 调用：在 fpk/ 下调用时相对路径恰好也能解析对
  # （cwd 与脚本位置重合），只有换 cwd 才能证明 wrapper 找的是自己旁边的文件。
  PNPM_BIN_DIR="$PWD/app/runtime/node/bin"
  PNPM_GOT="$(cd / && PATH="$PNPM_BIN_DIR:$PATH" pnpm --version 2>&1)" \
    || die "pnpm wrapper 无法运行：$PNPM_GOT"
  [ "$PNPM_GOT" = "$DSH_PNPM_VERSION" ] \
    || die "pnpm 版本不符：期望 $DSH_PNPM_VERSION，实际 $PNPM_GOT"
  say "pnpm 自检通过：$PNPM_GOT（app/runtime/pnpm $(du -sh app/runtime/pnpm 2>/dev/null | awk '{print $1}')）"

  # ---- npm：pnpm 的子命令会把请求转发给它，缺了就会拿系统那份（F29）----
  # 放在 runtime/npm，布局与 pnpm 完全对称；wrapper 同样进 runtime/node/bin，
  # 让「PATH 前置一次，两个包管理器都用自带 node 跑」这条承诺成立。
  rm -rf app/runtime/npm
  mkdir -p app/runtime/npm
  say "安装 npm@$DSH_NPM_VERSION ..."
  printf '{"name":"dsh-runtime-npm","private":true}\n' >app/runtime/npm/package.json
  "$NODE_SRC/bin/npm" install --omit=dev --no-audit --no-fund \
    --prefix "$PWD/app/runtime/npm" "npm@$DSH_NPM_VERSION" \
    >/tmp/dsh-npm-npm.log 2>&1 || { tail -n 30 /tmp/dsh-npm-npm.log; die "npm 安装失败"; }
  NPM_JS="app/runtime/npm/node_modules/npm/bin/npm-cli.js"
  [ -f "$NPM_JS" ] || die "安装后找不到 $NPM_JS，npm 没有真正装成功"

  cat >app/runtime/node/bin/npm <<'WRAP'
#!/bin/sh
# 由 build.sh 生成，勿手改。
# 布局：runtime/node/bin/npm  ->  ../../npm/node_modules/npm/bin/npm-cli.js
# 两级向上：$here 已是 runtime/node/bin，上一级是 runtime/node（不是 runtime）。
here=$(cd "$(dirname "$0")" && pwd)
npm_js="$here/../../npm/node_modules/npm/bin/npm-cli.js"
if [ ! -f "$npm_js" ]; then
  printf 'npm: 找不到 %s（运行时安装不完整，请重装应用）\n' "$npm_js" >&2
  exit 127
fi
exec "$here/node" "$npm_js" "$@"
WRAP
  chmod +x app/runtime/node/bin/npm

  NPM_GOT="$(cd / && PATH="$PNPM_BIN_DIR:$PATH" npm --version 2>&1)" \
    || die "npm wrapper 无法运行：$NPM_GOT"
  [ "$NPM_GOT" = "$DSH_NPM_VERSION" ] \
    || die "npm 版本不符：期望 $DSH_NPM_VERSION，实际 $NPM_GOT"
  say "npm 自检通过：$NPM_GOT（app/runtime/npm $(du -sh app/runtime/npm 2>/dev/null | awk '{print $1}')）"

  # ---- 端到端：把失败的那条命令本身跑一遍 ----
  # 前两条自检只证明「两个 wrapper 各自能跑」，证明不了 pnpm 转发 npm 这条链路。
  # 这个 bug 正是这样漏到真机的：两个包管理器都在，串起来却是坏的。
  # 判据 = 输出非空的一行版本号；用 lodash（长期稳定、体积小）避免镜像同步问题。
  # 无外网时可用 DSH_SKIP_NETCHECK=1 跳过，但跳过就少了一层保障。
  if [ "${DSH_SKIP_NETCHECK:-0}" = "1" ]; then
    say "⚠️  已按 DSH_SKIP_NETCHECK=1 跳过 pnpm view 联网自检"
  else
    say "端到端自检：pnpm view lodash version（会真的走 pnpm → npm 转发）..."
    VIEW_GOT="$(cd / && PATH="$PNPM_BIN_DIR:$PATH" \
      pnpm view lodash version --registry=https://registry.npmmirror.com/ \
      --config.fetch-retries=0 2>&1)" || true
    # 判据是「拿到了一行版本号」，不是「整段输出就是版本号」：
    # npm 11 会对 dsh 固定传的 --config.fetch-retries 打一行 warn（走 stderr），
    # 输出于是变成「warn + 版本号」。按首字符判会误杀——2026-11-01 就这么拦了一次
    # 明明成功的构建。这里取最后一行「长得像版本号」的，错误输出里不会有这种整行。
    # 末尾 || true：build.sh 是 set -euo pipefail，grep 一条都没匹配上时管道非零，
    # 不加就会让脚本在「没有版本号」这个正确分支上静默退出（而不是走到下面的 die）。
    VIEW_VER="$(printf '%s\n' "$VIEW_GOT" | grep -E '^[0-9]+(\.[0-9]+)+$' | tail -n1 || true)"
    if [ -n "$VIEW_VER" ]; then
      say "端到端自检通过：pnpm view lodash version -> $VIEW_VER"
    else
      die "pnpm view 走不通（pnpm 会把 view 转发给 npm，两者必须成套）：$VIEW_GOT"
    fi
  fi
  say "运行时就绪"
else
  [ -f app/runtime/stub/server.mjs ] || die "骨架模式下缺少 app/runtime/stub/server.mjs"
  say "骨架模式：使用占位服务"
fi

# 入口链路的两个组件在两种模式下都必须存在：缺 launcher 就点不开图标，
# 缺 relay 则多网卡机器只有一个地址能用（不致命，但登录体验会退化成旧版）。
for f in app/runtime/launcher/server.mjs app/runtime/relay/server.mjs; do
  [ -f "$f" ] || die "缺少入口组件：$f"
done

# Office 补丁只在 dsh 模式用得上（骨架包里没有 dsh），所以只在 full 模式下强制。
if [ "$MODE" = "full" ]; then
  [ -f app/runtime/profile/office.patch.yml ] || die "缺少 Office 补丁：app/runtime/profile/office.patch.yml"
fi

# ---------------------------------------------------------------- 5. 体积统计
step "包内统计（安装体验按文件数计费）"
FILES="$(find app -type f 2>/dev/null | wc -l | tr -d ' ')"
SIZE="$(du -sh app 2>/dev/null | awk '{print $1}')"
say "app/ 文件数：$FILES"
say "app/ 体积：  $SIZE"
if [ "$FILES" -gt 40000 ]; then
  say "⚠️  文件数超过 4 万，fnpack 打包与安装会明显变慢（见 PLAN §6.1）"
fi

# ---------------------------------------------------------------- 6. 打包
step "fnpack build"
command -v fnpack >/dev/null 2>&1 || die "未找到 fnpack。请在飞牛 NAS 上执行，或先安装 fnpack。"
rm -f ./*.fpk 2>/dev/null || true
# 官方两处文档写法不一致：quick-start 用 `fnpack build`，CLI 页用 `--directory`。
# 这里按实际支持情况选，避免因版本差异直接失败。
if fnpack build --help 2>&1 | grep -q -- '--directory'; then
  fnpack build --directory .
else
  fnpack build
fi

FPK="$(ls -1t ./*.fpk 2>/dev/null | head -n1 || true)"
[ -n "$FPK" ] || die "fnpack 没有产出 fpk"
say ""
say "产物：$FPK（$(du -h "$FPK" 2>/dev/null | awk '{print $1}')，版本 $PKG_VER）"

# ---------------------------------------------------------------- 7. 送到共享目录
# 前端「手动安装」只能选本地文件，而包是在 NAS 上打出来的。复制到应用共享目录，
# 在电脑的文件管理里点一下就拿到了，省掉 scp / appcenter-cli 这些命令行步骤。
# 不想占这份空间就 DSH_STAGE=0 bash build.sh。
step "就绪（前端安装用）"
if [ "${DSH_STAGE:-1}" = "0" ]; then
  say "已按 DSH_STAGE=0 跳过复制；包留在 $HERE/$FPK"
else
  SHARE=""
  # 候选按「真的能下载到」排序：
  #   /vol1/@appshare/<app>/workspace 是共享目录实体，卸载后也还在（数据保留）；
  #   /var/apps/<app>/shares/workspace 是指向它的软链入口，应用被平台摘掉时会跟着消失
  #   （2026-10-27 23:44 就是这样：应用在跑，/var/apps/dsh 却没了，包只能落在 /root）。
  for p in "/vol1/@appshare/$PKG_APP/workspace" \
           "/var/apps/$PKG_APP/shares/workspace" \
           "/vol1/@appshare/$PKG_APP" \
           "/var/apps/$PKG_APP/share/workspace" \
           "$HERE/shares/workspace"; do
    [ -d "$p" ] && { SHARE="$p"; break; }
  done
  if [ -z "$SHARE" ]; then
    say "没找到共享目录，包留在 $HERE/$FPK"
    say "想从界面下载，手动复制一行即可（把 <共享目录> 换成文件管理里能看到的位置）："
    say "  cp '$HERE/$FPK' <共享目录>/ && chmod 644 <共享目录>/$FPK"
  else
    if cp -f "$FPK" "$SHARE/$FPK" 2>/dev/null; then
      chmod 644 "$SHARE/$FPK" 2>/dev/null || true
      say "已放到共享目录：$SHARE/$FPK"
      say "电脑上：飞牛 → 文件管理 → 共享目录「dsh / workspace」→ 下载 $(basename "$FPK")"
    else
      say "⚠ 复制到共享目录失败（权限或空间），包留在 $HERE/$FPK"
      say "  手动：cp '$HERE/$FPK' '$SHARE/' && chmod 644 '$SHARE/$FPK'"
    fi
  fi
fi

say ""
say "安装 / 升级（全部在飞牛界面里完成，无需命令行）："
say "  1) 电脑上：文件管理 → 共享目录「dsh / workspace」→ 先把 $(basename "$FPK") 下载下来"
say "     （务必在卸载之前下载：卸载会临时把共享目录权限改成 000）"
say "  2) 应用中心 → 手动安装 → 选这个 fpk，直接装（先不卸载，看它是否真替换）"
say "     若装完版本没变（应用中心只回 is installed），再走：卸载（保留数据）→ 手动安装"
say "  3) 向导里 API Key 留空即沿用旧值，入口方式默认「点图标直接进入」"
say ""
if [ -n "$INST_VER" ] && [ "$PKG_VER" = "$INST_VER" ]; then
  say "注意：版本与已安装的相同，装上去不会替换 target/（本次由 DSH_ALLOW_SAME_VERSION=1 放行）。"
fi
