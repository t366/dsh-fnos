#!/usr/bin/env node
// ============================================================================
// 多网卡入口的 TCP 中继（relay）
//
// 为什么需要它：dsh 的 web 载体只接受「本机某个具体接口的地址」作为 --host，
// 0.0.0.0 在 load 阶段就被拒绝（packages/host/webserver 的 Config.host 契约）。
// 于是当 NAS 有多个 IPv4（无线 + OVS 网桥是常见组合）时，只有被选中的那一个
// 能直接连上，从另一个地址访问就是 ECONNREFUSED。
//
// 为什么是 TCP 层而不是 HTTP 反代：dsh 的 cookie 绑定「hostname + port」，
// Host/Origin 栅栏在认证之前生效。任何改写 Host 的代理都会让 cookie audience
// 与请求 authority 对不上，表现为「302 过去了但立刻 401」。TCP 层原样转发
// 字节，Host 不变、Upgrade 不变、cookie 自洽 —— 再配合 dsh 的
// --trusted-host <该IP>:<端口>，栅栏也就过了。
//
// 参数：
//   --listen <ip:port>   要接住的地址，可重复，也可逗号分隔
//   --target <ip:port>   dsh 真正监听的地址（必须是绑定地址）
//
// 行为约定：
//   · 每个 --listen 一个独立 server，某个地址绑不上只影响它自己
//   · 任何 socket 错误都只销毁这一条连接，进程不退出（入口不能因为一条坏连接消失）
//   · SIGTERM/SIGINT 关闭所有 server，等在途连接自然结束（最多 2 秒）
// ============================================================================

import net from 'node:net';

const args = process.argv.slice(2);

function optAll(name) {
  const out = [];
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] !== name) continue;
    const v = args[i + 1];
    if (v === undefined) continue;
    for (const part of String(v).split(',')) {
      const t = part.trim();
      if (t) out.push(t);
    }
  }
  return out;
}

function opt(name, fallback) {
  const all = optAll(name);
  return all.length > 0 ? all[all.length - 1] : fallback;
}

/** 解析 `ip:port` / `[v6]:port`。只接受显式端口——猜端口在入口链路上太危险。 */
function parseAddr(s) {
  const m = /^\[([^\]]+)\]:(\d+)$/.exec(s) || /^([^:]+):(\d+)$/.exec(s);
  if (!m) return null;
  const port = Number(m[2]);
  if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
  return { host: m[1], port };
}

function log(msg) {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  const ts =
    `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
    `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  console.log(`${ts} [${process.pid}] relay: ${msg}`);
}

const target = parseAddr(opt('--target', ''));
if (!target) {
  log('缺少或无法解析 --target（需要 ip:port），退出');
  process.exit(2);
}

const listens = optAll('--listen').map(parseAddr).filter(Boolean);
if (listens.length === 0) {
  log('没有可用的 --listen（需要 ip:port），退出');
  process.exit(2);
}

const servers = [];
let openConnections = 0;

function serve(addr) {
  const server = net.createServer((socket) => {
    socket.setNoDelay(true);

    const upstream = net.connect({ host: target.host, port: target.port });
    upstream.setNoDelay(true);
    openConnections += 1;

    let closed = false;
    const done = () => {
      if (closed) return;
      closed = true;
      openConnections -= 1;
      socket.destroy();
      upstream.destroy();
    };

    // 连接没建成就失败（dsh 还没起来 / 已经退出）：关掉这一条，不动进程
    upstream.on('error', (e) => {
      log(`upstream ${target.host}:${target.port} error: ${e.code || e.message}`);
      done();
    });
    socket.on('error', (e) => {
      log(`client ${socket.remoteAddress || '?'} error: ${e.code || e.message}`);
      done();
    });

    upstream.on('connect', () => {
      socket.pipe(upstream);
      upstream.pipe(socket);
    });

    socket.on('end', () => upstream.end());
    upstream.on('end', () => socket.end());
    socket.on('close', done);
    upstream.on('close', done);
  });

  server.on('error', (e) => {
    log(`listen ${addr.host}:${addr.port} failed: ${e.code || e.message}（该地址不可用，其余地址不受影响）`);
  });
  server.listen(addr.port, addr.host, () => {
    log(`listening on ${addr.host}:${addr.port} -> ${target.host}:${target.port}`);
  });
  servers.push(server);
}

for (const a of listens) serve(a);

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    log(`${sig} received, closing ${servers.length} listener(s), ${openConnections} connection(s) open`);
    for (const s of servers) s.close();
    // 在途连接最多再活 2 秒：入口宁可断一条上传，也不要留着进程让下次 start 撞端口
    setTimeout(() => process.exit(0), 2000).unref();
  });
}
