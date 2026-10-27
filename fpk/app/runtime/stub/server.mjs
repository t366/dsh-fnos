/**
 * M1 骨架用的占位服务（stub）。
 *
 * 它存在的唯一目的：在没有捆绑 dsh 的情况下，让「安装 → 启停 → 端口监听 →
 * 桌面图标打开」这条链路能被完整验证。M1b 塞入真正的 runtime 后，
 * cmd/main 会自动优先使用 dsh，这个文件即可删除。
 *
 * 只依赖 Node 标准库，系统自带的 node v22 就能跑。
 */

import http from 'node:http';
import os from 'node:os';

const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};

const host = arg('host', '127.0.0.1');
const port = Number(arg('port', 3080));
const startedAt = new Date();

const page = () => `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DeepSeek Harness · M1</title>
<style>
  :root { color-scheme: dark }
  * { box-sizing: border-box }
  body {
    margin: 0; min-height: 100vh; display: grid; place-items: center;
    background: radial-gradient(1200px 600px at 20% 0%, #16263f 0%, #0b0f16 60%);
    color: #e6edf7;
    font: 15px/1.7 -apple-system, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
  }
  .card {
    width: min(560px, calc(100vw - 32px)); padding: 32px 34px;
    background: #11161f; border: 1px solid #23303f; border-radius: 14px;
    box-shadow: 0 20px 60px rgba(0,0,0,.45);
  }
  .badge {
    display: inline-block; padding: 3px 10px; border-radius: 999px;
    background: #1b2b45; color: #8ab4f8; font-size: 12px; letter-spacing: .04em;
  }
  h1 { margin: 16px 0 6px; font-size: 21px; font-weight: 600 }
  p { margin: 8px 0; color: #9fb0c6 }
  dl { display: grid; grid-template-columns: 108px 1fr; gap: 8px 12px; margin: 22px 0 0;
       padding-top: 20px; border-top: 1px solid #1d2836; font-size: 13px }
  dt { color: #6f8299 }
  dd { margin: 0; font-family: ui-monospace, SFMono-Regular, Consolas, monospace; color: #cfdcec; word-break: break-all }
  .note { margin-top: 22px; padding: 12px 14px; border-radius: 9px;
          background: #17202c; border-left: 3px solid #3b6ea5; color: #9fb0c6; font-size: 13px }
</style>
</head>
<body>
  <div class="card">
    <span class="badge">M1 · 骨架</span>
    <h1>应用链路已打通</h1>
    <p>当前跑的是占位服务，用来验证安装、启停、端口与桌面入口。真正的 dsh 还没捆绑进来。</p>
    <dl>
      <dt>监听地址</dt><dd>${host}:${port}</dd>
      <dt>进程 PID</dt><dd>${process.pid}</dd>
      <dt>已运行</dt><dd>${Math.floor(process.uptime())} 秒</dd>
      <dt>启动于</dt><dd>${startedAt.toLocaleString('zh-CN')}</dd>
      <dt>Node</dt><dd>${process.version}</dd>
      <dt>主机</dt><dd>${os.hostname()}</dd>
    </dl>
    <div class="note">下一步（M1b）：把 dsh 运行时打进 app/runtime，<code>cmd/main</code> 会自动切过去，此页面随之失效。</div>
  </div>
</body>
</html>`;

const server = http.createServer((req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ ok: true, mode: 'stub', pid: process.pid, uptime: process.uptime() }));
    return;
  }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(page());
});

server.on('error', (err) => {
  console.error(`stub: listen failed on ${host}:${port} — ${err.code || ''} ${err.message}`);
  process.exit(1);
});

server.listen(port, host, () => {
  console.log(`stub: listening on http://${host}:${port} (pid=${process.pid}, node=${process.version})`);
});

const shutdown = (sig) => {
  console.log(`stub: ${sig} received, closing`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
