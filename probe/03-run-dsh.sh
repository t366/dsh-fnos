#!/usr/bin/env bash
# dsh on fnOS —— 阶段三：常驻运行器（M0 收尾 + cmd/main 原型）
#
# 这不是包装脚本，而是 fpk 里 cmd/main 的逻辑原型：
#   - 启动前等待绑定地址就绪（真机实测：默认路由在 OVS 网桥，无线另有地址，开机时序不确定）
#   - setsid 建独立进程组，stop 时整组收尾（否则 pty 子进程变孤儿）
#   - status 只用 kill -0 + 端口探测，返回码对齐 fnOS 契约（0=运行 / 3=未运行）
#
# 用法：
#   bash 03-run-dsh.sh start      # 后台启动，打印带 token 的 URL
#   bash 03-run-dsh.sh url        # 只打印当前 URL（从日志里取）
#   bash 03-run-dsh.sh status     # 0=运行 3=未运行（fpk 契约）
#   bash 03-run-dsh.sh stop
#
# API Key（三选一，优先级从高到低）：
#   1) 已存在 $DSH_HOME/.credentials.yaml 里的值
#   2) 环境变量 DEEPSEEK_API_KEY
#   3) 文件 $WORKDIR/apikey（建议 chmod 600）
#
# 环境变量：WORKDIR（默认 ~/dsh-probe）、PORT（默认 3089）、BIND_IP、NODE_BIN

set -u
set -o pipefail

ACTION="${1:-status}"
WORKDIR="${WORKDIR:-$HOME/dsh-probe}"
PORT="${PORT:-3089}"
DSH_HOME="${DSH_HOME:-$WORKDIR/dsh-home}"
APP="$WORKDIR/app"
PIDFILE="$WORKDIR/dsh.pid"
LOGFILE="$WORKDIR/dsh-run.log"
URLFILE="$WORKDIR/dsh-url.txt"

have() { command -v "$1" >/dev/null 2>&1; }

# ---------- 运行时解析：bundled → system → 报错（不静默降级）----------
# 对应方案 §3.1 的第 1 条：解析顺序固定，缺了就明确失败
resolve_node() {
  if [ -n "${NODE_BIN:-}" ] && [ -x "${NODE_BIN:-}" ]; then echo "$NODE_BIN"; return; fi
  if [ -x "$WORKDIR/node/bin/node" ]; then echo "$WORKDIR/node/bin/node"; return; fi
  local best="" nv
  while IFS= read -r nb; do
    [ -z "$nb" ] && continue
    nv="$("$nb" -v 2>/dev/null)" || continue
    nv="${nv#v}"
    major="${nv%%.*}"; rest="${nv#*.}"; minor="${rest%%.*}"
    if [ "${major:-0}" -gt 24 ] || { [ "${major:-0}" -eq 24 ] && [ "${minor:-0}" -ge 9 ]; }; then
      best="$nb"; break
    fi
  done <<< "$(find /var/apps -maxdepth 6 -name node \( -type f -o -type l \) 2>/dev/null | sort -r | head -n 8)"
  if [ -n "$best" ]; then echo "$best"; return; fi
  return 1
}

resolve_bind_ip() {
  if [ -n "${BIND_IP:-}" ]; then echo "$BIND_IP"; return; fi
  if have ip; then
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}'
  fi
}

# 等待绑定地址真的出现在网卡上（开机时网络可能晚于应用就绪）
wait_for_addr() {
  local ip="$1" i
  for i in $(seq 1 "${ADDR_WAIT:-60}"); do
    if have ip; then
      ip -4 -o addr show 2>/dev/null | grep -q "inet $ip/"; return 0
    else
      return 0
    fi
    sleep 1
  done
  return 1
}

is_running() {
  [ -f "$PIDFILE" ] || return 1
  local pid; pid="$(cat "$PIDFILE" 2>/dev/null)"
  [ -n "${pid:-}" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # 防止 PID 复用误判
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "dsh" || return 1
  return 0
}

case "$ACTION" in
  start)
    if is_running; then
      echo "已在运行 (pid $(cat "$PIDFILE"))。URL："
      grep -oE 'https?://[^ "'"'"']*token=[A-Za-z0-9_-]+' "$LOGFILE" 2>/dev/null | head -n1
      exit 0
    fi

    NODE="$(resolve_node)" || { echo "错误：找不到可用的 Node（需 ≥24.9）。设置 NODE_BIN 或先跑 02 脚本。"; exit 1; }
    [ -e "$APP/node_modules/@deepseek-ai/dsh/lib/bin.js" ] || { echo "错误：$APP 下没有 dsh，先跑 02-smoke-dsh.sh"; exit 1; }

    IP="$(resolve_bind_ip)"
    [ -n "${IP:-}" ] || { echo "错误：无法确定绑定地址，请设置 BIND_IP"; exit 1; }

    # 凭据：环境变量 > 文件（已保存到 .credentials.yaml 的值优先级更高，会在 UI 里生效）
    if [ -z "${DEEPSEEK_API_KEY:-}" ] && [ -f "$WORKDIR/apikey" ]; then
      DEEPSEEK_API_KEY="$(cat "$WORKDIR/apikey")"
      export DEEPSEEK_API_KEY
    fi
    if [ -z "${DEEPSEEK_API_KEY:-}" ] && [ ! -f "$DSH_HOME/.credentials.yaml" ]; then
      echo "警告：未检测到 DEEPSEEK_API_KEY，模型列表会是空的，无法真正对话。"
      echo "      设置方法：printf '%s' 'sk-xxx' > $WORKDIR/apikey && chmod 600 $WORKDIR/apikey"
    fi

    echo "运行时：$NODE ($("$NODE" -v 2>/dev/null))"
    echo "绑定：$IP:$PORT"

    if ! wait_for_addr "$IP"; then
      echo "错误：等待 ${ADDR_WAIT:-60}s 后，地址 $IP 仍未出现在网卡上。"
      echo "      开机时若 WiFi/OVS 比应用晚就绪，就会是这种情况。候选地址："
      ip -4 -o addr show 2>/dev/null | awk '$2!="lo"{print "        "$2" "$4}'
      exit 1
    fi

    mkdir -p "$DSH_HOME"
    : > "$LOGFILE"

    # setsid：让 dsh 成为新进程组的组长，stop 时能整组收掉 pty 子进程
    if have setsid; then
      setsid "$NODE" "$APP/node_modules/@deepseek-ai/dsh/lib/bin.js" \
        --profile web --host "$IP" --port "$PORT" --no-open \
        >>"$LOGFILE" 2>&1 < /dev/null &
    else
      "$NODE" "$APP/node_modules/@deepseek-ai/dsh/lib/bin.js" \
        --profile web --host "$IP" --port "$PORT" --no-open \
        >>"$LOGFILE" 2>&1 < /dev/null &
    fi
    PID=$!
    echo "$PID" > "$PIDFILE"
    chmod 600 "$PIDFILE" 2>/dev/null

    URL=""
    for i in $(seq 1 60); do
      sleep 1
      kill -0 "$PID" 2>/dev/null || break
      URL="$(grep -oE 'https?://[^ "'"'"']*token=[A-Za-z0-9_-]+' "$LOGFILE" 2>/dev/null | head -n1)"
      [ -n "$URL" ] && break
    done

    if [ -z "$URL" ]; then
      echo "启动失败，日志末尾："
      tail -n 15 "$LOGFILE" 2>/dev/null
      rm -f "$PIDFILE"
      exit 1
    fi

    printf '%s\n' "$URL" > "$URLFILE"
    chmod 600 "$URLFILE" 2>/dev/null

    echo ""
    echo "已启动 (pid $PID)。在**另一台设备**的浏览器打开："
    echo ""
    echo "  $URL"
    echo ""
    echo "⚠️ 这个 URL 等于完整的 shell 权限，别外传。首次打开后换 30 天 cookie，之后 $URLFILE 可删。"
    ;;

  stop)
    if ! is_running; then echo "未在运行"; rm -f "$PIDFILE"; exit 0; fi
    PID="$(cat "$PIDFILE")"
    PGID="$(ps -o pgid= -p "$PID" 2>/dev/null | tr -d ' ')"
    if [ -n "${PGID:-}" ]; then kill -TERM "-$PGID" 2>/dev/null; else kill -TERM "$PID" 2>/dev/null; fi
    for i in $(seq 1 15); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
    if kill -0 "$PID" 2>/dev/null; then
      if [ -n "${PGID:-}" ]; then kill -KILL "-$PGID" 2>/dev/null; else kill -KILL "$PID" 2>/dev/null; fi
    fi
    rm -f "$PIDFILE"
    echo "已停止"
    ;;

  status)
    if is_running; then
      echo "running (pid $(cat "$PIDFILE"))"
      exit 0
    else
      echo "stopped"
      exit 3          # 对齐 fnOS cmd/main 契约：0=运行 / 3=未运行 / 1=失败
    fi
    ;;

  url)
    U="$(cat "$URLFILE" 2>/dev/null)"
    if [ -n "${U:-}" ]; then echo "$U"; else grep -oE 'https?://[^ "'"'"']*token=[A-Za-z0-9_-]+' "$LOGFILE" 2>/dev/null | head -n1; fi
    ;;

  *)
    echo "用法：bash $0 {start|stop|status|url}"
    exit 1
    ;;
esac
