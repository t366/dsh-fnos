#!/bin/bash
# ============================================================================
# 06-upgrade-truth.sh — 卸载到底会不会吃掉用户数据？（M2 升级方案的地基实验）
#
#   bash 06-upgrade-truth.sh            # 全自动：埋标记 → stop → 卸载 → 检查 → 重装 → 对比
#   bash 06-upgrade-truth.sh prepare    # 只埋标记，然后去 Web UI 手工卸载
#   bash 06-upgrade-truth.sh check      # Web UI 卸载完之后跑：检查 + 重装 + 对比
#
# 为什么要做：
#   命令行上唯一的“升级”路径是「卸载 + 重装」——install-fpk 对已装应用直接不动作。
#   如果卸载会连带删除 @appdata / @appconf，那 uninstall_callback 里的 keep 就是空转，
#   dsh-home 与 settings.conf 必须搬到 data-share 才能跨升级存活。
#
# 上一版的教训（2026-10-27 17:36）：
#   `appcenter-cli uninstall` 在应用运行中会直接拒绝，只回一句
#   「Failed to uninstall dsh, please uninstall it from Web UI.」。
#   当时脚本没验证卸载是否发生，就把“目录还在”当成“数据存活”，报出 PASS 11 的假阳性。
#   所以现在有一道硬门禁：卸完必须看见 $ROOT 消失，否则整场实验判无效。
# ============================================================================
set -u

APP="${APP:-dsh}"
FPK="${FPK:-$HOME/dsh-fnos/fpk/dsh.fpk}"
ROOT="/var/apps/$APP"
STATE="${STATE:-$HOME/dsh-fnos/probe/.06-state}"
PHASE="${1:-all}"

PASS=0; WARN=0; FAIL=0
ok()   { printf 'PASS  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; PASS=$((PASS + 1)); }
warn() { printf 'WARN  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; WARN=$((WARN + 1)); }
bad()  { printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '      %s\n' "$2"; FAIL=$((FAIL + 1)); }
sec()  { printf '\n== %s\n' "$*"; }

alive() { [ -f "$1/.probe-keep" ]; }

volroot() { # 从软链反推卷根，避免写死 /vol1
  local vardir
  vardir="$(readlink -f "$ROOT/var" 2>/dev/null)"
  [ -n "$vardir" ] || vardir="$(readlink -f "$ROOT" 2>/dev/null)"
  dirname "$(dirname "$vardir")"
}

# ---------------------------------------------------------------- prepare
do_prepare() {
  sec "1. 卸载前：埋标记 + 存快照"
  local vol; vol="$(volroot)"
  [ -n "$vol" ] && [ -d "$vol" ] || { bad "无法反推卷根"; return 1; }
  printf '卷根：%s\n' "$vol"

  mkdir -p "$ROOT/var/dsh-home" "$ROOT/shares/workspace" 2>/dev/null
  local d
  for d in "$ROOT/var/dsh-home" "$ROOT/shares/workspace" "$ROOT/etc"; do
    if [ -d "$d" ]; then
      printf 'probe %s %s\n' "$(date '+%F %T')" "$APP" >"$d/.probe-keep" 2>/dev/null \
        && ok "已埋标记" "$d/.probe-keep" \
        || warn "标记写不进" "$d"
    else
      warn "目录不存在" "$d"
    fi
  done

  local bind="" keylen=0
  if [ -f "$ROOT/etc/settings.conf" ]; then
    bind="$(grep -E '^DSH_BIND=' "$ROOT/etc/settings.conf" 2>/dev/null | cut -d= -f2- | tr -d '\r')"
    keylen="$(grep -E '^DSH_API_KEY=' "$ROOT/etc/settings.conf" 2>/dev/null | cut -d= -f2- | tr -d '\r' | wc -c)"
  fi
  {
    printf 'VOL=%q\n' "$vol"
    printf 'BEFORE_BIND=%q\n' "$bind"
    printf 'BEFORE_KEYLEN=%q\n' "$keylen"
  } >"$STATE" 2>/dev/null
  printf '快照：DSH_BIND=%s  API_KEY 长度=%s（已存 %s）\n' "${bind:-<无>}" "$keylen" "$STATE"
}

# ---------------------------------------------------------------- uninstall
do_uninstall() {
  sec "2. 卸载"
  printf -- '--- 先 stop（运行中的话 CLI 会拒绝卸载）---\n'
  appcenter-cli stop "$APP" 2>&1 | sed 's/^/      /'
  sleep 1
  appcenter-cli uninstall "$APP" 2>&1 | sed 's/^/      /'

  sec "2.5 门禁：卸载真的发生了吗"
  if [ -d "$ROOT" ]; then
    bad "卸载未发生（本次实验无效）" "$ROOT 仍然存在，下面任何“存活”结论都不成立"
    printf '\n  下一步二选一：\n'
    printf '    a) 应用中心 → 应用详情 → 卸载（Web UI），然后回来跑：\n'
    printf '         bash %s check\n' "${BASH_SOURCE[0]:-$0}"
    printf '    b) 若 UI 也不给卸，说明该应用被锁定，先查 appcenter-cli list 的 STATUS\n'
    return 1
  fi
  ok "已卸载" "$ROOT 已消失"
}

# ---------------------------------------------------------------- inspect
do_inspect() {
  sec "3. 卸载后：谁活下来"
  local vol=""
  [ -f "$STATE" ] && . "$STATE"
  vol="${VOL:-$(volroot)}"
  printf '卷根：%s\n' "$vol"

  local d p
  for d in appdata appconf apphome appshare appmeta appcenter apptemp; do
    p="$vol/@$d/$APP"
    if [ -e "$p" ]; then
      printf '  存在  %-34s %s\n' "$p" "$(stat -c '%U:%G %a' "$p" 2>/dev/null)"
    else
      printf '  已删  %s\n' "$p"
    fi
  done

  local pair dir label
  for pair in \
    "$vol/@appdata/$APP/dsh-home|dsh-home（@appdata）" \
    "$vol/@appshare/$APP/workspace|workspace（@appshare）" \
    "$vol/@appconf/$APP|etc（@appconf）"; do
    dir="${pair%%|*}"; label="${pair#*|}"
    if alive "$dir"; then
      ok "标记存活：$label" "$dir/.probe-keep"
    else
      warn "标记已丢：$label" "$dir 不存在或已被清空"
    fi
  done

  if [ -e "$vol/@appshare/$APP" ]; then
    printf -- '--- @appshare/%s 卸载后的样子 ---\n' "$APP"
    ls -laR "$vol/@appshare/$APP" 2>&1 | head -20 | sed 's/^/      /'
  fi
}

# ---------------------------------------------------------------- reinstall + after
do_reinstall_and_check() {
  sec "4. 重装"
  [ -f "$FPK" ] || { bad "找不到安装包" "$FPK（用 FPK= 指定）"; return 1; }
  appcenter-cli install-fpk "$FPK" 2>&1 | sed 's/^/      /'
  [ -d "$ROOT" ] || { bad "重装失败" "$ROOT 不存在，需手工 install-fpk $FPK"; return 1; }
  ok "已重装" "version=$(sed -n 's/^version *= *//p' "$ROOT/manifest" 2>/dev/null | head -1)"

  sec "5. 重装后：旧数据回来了吗"
  local bind="" keylen=0 vol=""
  [ -f "$STATE" ] && . "$STATE"
  vol="${VOL:-$(volroot)}"
  if [ -f "$ROOT/etc/settings.conf" ]; then
    bind="$(grep -E '^DSH_BIND=' "$ROOT/etc/settings.conf" | cut -d= -f2- | tr -d '\r')"
    keylen="$(grep -E '^DSH_API_KEY=' "$ROOT/etc/settings.conf" | cut -d= -f2- | tr -d '\r' | wc -c)"
    printf '  DSH_BIND   %s → %s\n  API_KEY 长度 %s → %s\n' \
      "${BEFORE_BIND:-<无>}" "${bind:-<无>}" "${BEFORE_KEYLEN:-0}" "$keylen"
    if [ "$bind" = "${BEFORE_BIND:-}" ] && [ "$keylen" = "${BEFORE_KEYLEN:-0}" ]; then
      ok "settings.conf 恢复了旧值"
    else
      warn "settings.conf 被重置" "卸载删掉了 @appconf，用户只能重填"
    fi
  else
    bad "settings.conf 不存在" "install_callback 没跑成功"
  fi

  # 0.2.0 起 dsh-home 迁到共享目录，所以 var/dsh-home 的标记消失属于预期
  if alive "$ROOT/var/dsh-home"; then
    warn "dsh-home 仍在 var/（旧布局）" "0.2.0 起应落在共享目录 .dsh-home"
  fi
  if alive "$ROOT/shares/workspace"; then
    ok "shares/workspace 旧标记还在" "data-share 能跨卸载存活 → PLAN §2.8 的设计成立"
  else
    bad "shares/workspace 里的标记也没了" "data-share 同样被清，数据无处可放，得换到 @app* 之外的目录"
  fi
  if [ -d "$ROOT/shares/workspace/.dsh-home" ]; then
    ok "新布局已生效" "dsh-home 落在共享目录"
  else
    warn "未见到 .dsh-home" "装的可能还是旧版包，或共享目录不可写（看 var/info.log 的 WARN）"
  fi
}

# ---------------------------------------------------------------- summary
do_summary() {
  sec "6. 结论"
  printf '  PASS %s / WARN %s / FAIL %s\n' "$PASS" "$WARN" "$FAIL"
  printf '\n判读：\n'
  printf '  · @appdata 显示「已删」→ uninstall_callback 的 keep 是空转，\n'
  printf '    要“升级不丢数据”就得把 dsh-home 与 settings.conf 搬到存活的目录。\n'
  printf '  · @appshare 的标记活着 → data-share 是唯一可跨卸载的持久位置；\n'
  printf '    注意卸载会把该目录 chmod 000，重装后必须由 install_callback 修权限。\n'
  printf '  · 两处都被清 → fpk 形态下无法“卸载式升级不丢数据”，只能赌 UI 原生升级。\n'
}

# ---------------------------------------------------------------- main
printf 'dsh on fnOS — 卸载/重装的数据存活实验（phase=%s）\n' "$PHASE"
printf '时间：%s\n' "$(date '+%F %T')"

[ "$(id -u)" = "0" ] || { printf '需要 root\n'; exit 1; }

case "$PHASE" in
  prepare)
    [ -d "$ROOT" ] || { printf '未安装 %s\n' "$ROOT"; exit 1; }
    do_prepare || exit 1
    printf '\n现在去应用中心 → 应用详情 → 卸载，然后回来跑：\n  bash %s check\n' "${BASH_SOURCE[0]:-$0}"
    ;;
  check)
    [ -d "$ROOT" ] && { bad "应用还在，先卸载再跑 check" "$ROOT"; do_summary; exit 1; }
    do_inspect
    do_reinstall_and_check
    do_summary
    [ "$FAIL" -eq 0 ] || exit 1
    ;;
  all)
    [ -d "$ROOT" ] || { printf '未安装 %s，先用 install-fpk 装上\n' "$ROOT"; exit 1; }
    do_prepare || exit 1
    do_uninstall || { do_summary; exit 2; }
    do_inspect
    do_reinstall_and_check
    do_summary
    [ "$FAIL" -eq 0 ] || exit 1
    ;;
  *)
    printf '用法：bash %s [all|prepare|check]\n' "${BASH_SOURCE[0]:-$0}"
    exit 1
    ;;
esac
