#!/bin/bash
# ============================================================================
# 在飞牛 NAS 上打包 fpk。
#
#   bash build.sh              # 骨架包（不含 dsh 运行时，约 100KB）
#   bash build.sh full         # 完整包（捆绑 node + dsh，约 990MB）
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
DSH_VERSION="${DSH_VERSION:-0.2.1-rc.3}"
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
for f in app/runtime/stub/server.mjs app/runtime/launcher/server.mjs; do
  [ -f "$f" ] && sed -i 's/\r$//' "$f" 2>/dev/null || true
done

chmod +x cmd/* 2>/dev/null || true

# 目录必须可遍历（有 +x）。fnOS 装完后 config/ wizard/ 的 mode 会变成 644，
# 见 probe/05-verify-fpk.sh 第 5 节的告警；打包前先钉死，排除「源目录本来就没 +x」
# 这一种可能。只处理包内的少量目录，不碰 node_modules。
find . -maxdepth 3 -type d -not -path './app/runtime/app/*' -exec chmod 755 {} + 2>/dev/null || true
say "cmd/ 已 chmod +x，目录已 chmod 755，自写文本已清 CRLF（node_modules 不动）"

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
INST_VER=""
[ -n "$PKG_APP" ] && [ -f "/var/apps/$PKG_APP/manifest" ] && INST_VER="$(mval "/var/apps/$PKG_APP/manifest" version)"
say "包：$PKG_APP $PKG_VER    已安装：${INST_VER:-<无>}"
if [ -n "$INST_VER" ] && [ "$PKG_VER" = "$INST_VER" ]; then
  say ""
  say "⚠ 版本号与已安装的相同。侧载包没有「覆盖升级」通道："
  say "   版本不变时应用中心认为还是同一个包，装上去 target/ 不会更新。"
  say "   打包前请把 manifest 的 version 改成更高值（例如 $PKG_VER → 下一版）。"
  say ""
fi

# ---------------------------------------------------------------- 2. 必需文件
step "检查必需文件"
for f in manifest ICON.PNG ICON_256.PNG config/privilege config/resource \
         app/ui/config app/ui/images/icon_64.png app/ui/images/icon_256.png \
         cmd/main wizard/install; do
  [ -e "$f" ] || die "缺少必需文件：$f"
done
say "ok"

# 图标尺寸/大小不符合规范时，应用中心可能不显示图标（不是报错，是静默不显示）
if command -v node >/dev/null 2>&1; then
  node -e '
const fs=require("fs");
const want={"ICON.PNG":64,"ICON_256.PNG":256,"app/ui/images/icon_64.png":64,"app/ui/images/icon_256.png":256};
let bad=0;
for(const [f,exp] of Object.entries(want)){
  const b=fs.readFileSync(f);
  if(b.subarray(1,4).toString()!=="PNG"){console.log("✗ "+f+" 不是 PNG");bad=1;continue;}
  const w=b.readUInt32BE(16),h=b.readUInt32BE(20),kb=Math.round(b.length/1024);
  const ok=w===exp&&h===exp&&b.length<=1024*1024;
  console.log((ok?"ok  ":"✗   ")+f+"  "+w+"x"+h+"  "+kb+"KB");
  if(!ok)bad=1;
}
process.exit(bad);
' || die "图标不符合规范：需 64/256 正方形 PNG、≤1024KB"
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
if [ "$MODE" = "full" ]; then
  [ -x "$NODE_SRC/bin/node" ] || die "找不到 node：$NODE_SRC/bin/node（可用 NODE_SRC 指定）"
  NODE_VER="$("$NODE_SRC/bin/node" -v)"
  say "node: $NODE_VER ($NODE_SRC)"

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
  )
  say "运行时就绪"
else
  [ -f app/runtime/stub/server.mjs ] || die "骨架模式下缺少 app/runtime/stub/server.mjs"
  say "骨架模式：使用占位服务"
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
  for p in "/var/apps/$PKG_APP/shares/workspace" "/var/apps/$PKG_APP/share/workspace" \
           "$HERE/shares/workspace"; do
    [ -d "$p" ] && { SHARE="$p"; break; }
  done
  if [ -z "$SHARE" ]; then
    say "没找到共享目录（应用还没装？），包留在 $HERE/$FPK"
  else
    if cp -f "$FPK" "$SHARE/$FPK" 2>/dev/null; then
      chmod 644 "$SHARE/$FPK" 2>/dev/null || true
      say "已放到共享目录：$SHARE/$FPK"
      say "电脑上：飞牛 → 文件管理 → 共享目录「dsh / workspace」→ 下载 $(basename "$FPK")"
    else
      say "⚠ 复制到共享目录失败（权限或空间），包留在 $HERE/$FPK"
    fi
  fi
fi

say ""
say "安装 / 升级（全部在飞牛界面里完成，无需命令行）："
say "  1) 电脑上：文件管理 → 共享目录「dsh / workspace」→ 先把 $(basename "$FPK") 下载下来"
say "     （务必在卸载之前下载：卸载会临时把共享目录权限改成 000）"
say "  2) 应用中心 → dsh → 卸载，数据选「保留会话、凭据与设置」"
say "  3) 应用中心 → 手动安装 → 选择刚下载的 $(basename "$FPK") → 安装"
say "     向导里 API Key 留空即沿用旧值，入口方式默认「点图标直接进入」"
say ""
if [ -n "$INST_VER" ] && [ "$PKG_VER" = "$INST_VER" ]; then
  say "注意：版本与已安装的相同，应用中心会把它当成同一个包。打包前请把 manifest 的 version 提上去。"
fi
