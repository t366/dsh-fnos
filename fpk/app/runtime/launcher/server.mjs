#!/usr/bin/env node
// ============================================================================
// dsh 入口跳转器（launcher）
//
// 为什么需要它：dsh 每次启动 mint 新 token，令牌只能换一次 cookie，且没有
// 「固定 token」的开关。于是把 service_port（图标打开的那个端口）交给这个
// 小服务，dsh 退到内部端口。跳转器负责把浏览器送到带令牌的地址。
//
// 安全模型（B 方案：设备白名单）：
//   - 没有任何 cookie 的访客只能看到「粘贴入口令牌」页面；
//   - 粘贴的令牌不比对、不解析，直接拿去请求 dsh，回 3xx 即视为有效
//     （这样 dsh 改令牌格式也不会影响本文件）；
//   - 通过后签一个 180 天的 HttpOnly cookie，之后点图标直接进；
//   - 失败按 IP 限速，防止在局域网上暴力猜令牌。
//
// 不做的事：不代理任何业务流量（只回 302）。代理就要改写 Host，
// 会破坏 dsh 的 Host/Origin 栅栏，那是另一个量级的问题。
//
// 参数：--host <bind ip> --port <listen port> --state <launcher.json>
// ============================================================================

import http from 'node:http';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const args = process.argv.slice(2);
const opt = (k, d) => {
  const i = args.indexOf(k);
  return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : d;
};

const HOST = opt('--host', '127.0.0.1');
const PORT = Number(opt('--port', '3080'));
const STATE_FILE = opt('--state', '');

const COOKIE = 'dsh_gate';
const COOKIE_MAX_AGE = 180 * 24 * 3600;
const FAIL_LIMIT = 5;
const FAIL_WINDOW_MS = 10 * 60 * 1000;

function log(msg) {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  const ts =
    `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
    `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  console.log(`${ts} [${process.pid}] launcher: ${msg}`);
}

// ---------------------------------------------------------------- 密钥
// 存 state 同目录（$PKGVAR = @appdata），重装会没，但那不影响安全性，
// 只意味着已配对的设备需要重新粘贴一次。
const SECRET_FILE = STATE_FILE ? path.join(path.dirname(STATE_FILE), 'launcher-secret') : '';
let SECRET = null;

function loadSecret() {
  if (SECRET) return SECRET;
  try {
    const s = fs.readFileSync(SECRET_FILE, 'utf8').trim();
    if (s.length >= 32) return (SECRET = Buffer.from(s, 'hex'));
  } catch {}
  SECRET = crypto.randomBytes(32);
  try {
    fs.writeFileSync(SECRET_FILE, SECRET.toString('hex'), { mode: 0o600 });
    fs.chmodSync(SECRET_FILE, 0o600);
  } catch (e) {
    log(`WARN: 无法写入密钥文件 ${SECRET_FILE}: ${e.message}（重启后已配对设备需重新粘贴）`);
  }
  return SECRET;
}

const sign = (payload) =>
  crypto.createHmac('sha256', loadSecret()).update(payload).digest('hex');

function safeEq(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

// ---------------------------------------------------------------- 状态
function readState() {
  try {
    const st = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    if (!st || typeof st.url !== 'string' || typeof st.host !== 'string' || !st.port) return null;
    return st;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------- cookie
function parseCookies(req) {
  const raw = req.headers.cookie || '';
  const out = {};
  for (const part of raw.split(';')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    out[part.slice(0, i).trim()] = part.slice(i + 1).trim();
  }
  return out;
}

function gateOk(req) {
  const raw = parseCookies(req)[COOKIE];
  if (!raw) return false;
  const bits = raw.split('.');
  if (bits.length !== 3) return false;
  const [id, exp, sig] = bits;
  if (!/^[0-9a-f]{16,64}$/.test(id) || !/^[0-9]+$/.test(exp)) return false;
  if (Number(exp) * 1000 < Date.now()) return false;
  return safeEq(sig, sign(`${id}.${exp}`));
}

function newGateCookie() {
  const id = crypto.randomBytes(12).toString('hex');
  const exp = Math.floor(Date.now() / 1000) + COOKIE_MAX_AGE;
  const sig = sign(`${id}.${exp}`);
  return `${COOKIE}=${id}.${exp}.${sig}; Path=/; Max-Age=${COOKIE_MAX_AGE}; HttpOnly; SameSite=Lax`;
}

// ---------------------------------------------------------------- 限速
const fails = new Map(); // ip -> { n, until }

function tooMany(ip) {
  const f = fails.get(ip);
  if (!f) return false;
  if (Date.now() > f.until) {
    fails.delete(ip);
    return false;
  }
  return f.n >= FAIL_LIMIT;
}

function noteFail(ip) {
  const f = fails.get(ip) || { n: 0, until: Date.now() + FAIL_WINDOW_MS };
  f.n += 1;
  f.until = Date.now() + FAIL_WINDOW_MS;
  fails.set(ip, f);
}

// ---------------------------------------------------------------- 校验令牌
function probeToken(st, token) {
  return new Promise((resolve) => {
    const req = http.request(
      {
        host: st.host,
        port: st.port,
        path: '/?token=' + encodeURIComponent(token),
        method: 'GET',
        headers: { Host: `${st.host}:${st.port}` },
        timeout: 5000,
      },
      (res) => {
        res.resume();
        resolve(res.statusCode || 0);
      }
    );
    req.on('timeout', () => { req.destroy(); resolve(0); });
    req.on('error', () => resolve(0));
    req.end();
  });
}

function extractToken(text) {
  const s = String(text || '').trim();
  // 支持三种粘法：完整 URL、`token=xxx`、光秃秃的 token 本身。
  // 裸 token 的下限放到 8：真实令牌通常 32+ 位，但下限写 16 会把短令牌
  // （以及我们一起联调用的测试令牌）误判成「没识别到」→ 400。
  const m = /token=([A-Za-z0-9_-]{8,})/.exec(s);
  if (m) return m[1];
  if (/^[A-Za-z0-9_-]{8,256}$/.test(s)) return s;
  return '';
}

// ---------------------------------------------------------------- 页面
const css = `
  :root{color-scheme:light dark}
  *{box-sizing:border-box}
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
    background:#0f1115;color:#e6e8ee;font:15px/1.6 -apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}
  .card{width:min(520px,92vw);background:#171a21;border:1px solid #262b36;border-radius:14px;padding:28px 28px 24px}
  h1{font-size:19px;margin:0 0 6px;font-weight:600}
  p{margin:10px 0;color:#a9b0be}
  code{background:#0f1115;border:1px solid #262b36;border-radius:6px;padding:1px 6px;font-size:13px;color:#c8d0e0}
  input{width:100%;margin:14px 0 10px;padding:11px 12px;border-radius:9px;border:1px solid #2c3240;
    background:#0f1115;color:#e6e8ee;font-size:14px;font-family:ui-monospace,Consolas,monospace}
  button{width:100%;padding:11px;border:0;border-radius:9px;background:#3b6ef5;color:#fff;font-size:15px;cursor:pointer}
  button:hover{background:#4a7bfb}
  .err{color:#ff8a8a;margin-top:12px;font-size:14px}
  .hint{margin-top:18px;padding-top:14px;border-top:1px solid #262b36;font-size:13px;color:#8d94a3}
  .hint b{color:#a9b0be;font-weight:600}
`;

const page = (title, body) =>
  `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title><style>${css}</style></head>
<body><div class="card">${body}</div></body></html>`;

const waitPage = () => page(
  'DeepSeek Harness — 正在启动',
  `<h1>正在启动…</h1>
   <p>dsh 还没就绪，这个页面会自动重试。</p>
   <p>若长时间停在这里，请到应用中心查看 dsh 的日志。</p>
   <script>setTimeout(()=>location.reload(),2000)</script>`
);

const pairPage = (err) => page(
  'DeepSeek Harness — 配对这台设备',
  `<h1>配对这台设备</h1>
   <p>这是第一次从该设备打开。粘贴一次入口令牌，之后点图标即可直接进入。</p>
   <form method="post" action="/pair">
     <input name="token" placeholder="粘贴完整地址或 token" autocomplete="off" spellcheck="false" autofocus>
     <button type="submit">配对并进入</button>
   </form>
   ${err ? `<div class="err">${err}</div>` : ''}
   <div class="hint">
     <b>入口令牌在哪：</b><br>
     NAS 上执行 <code>cat /var/apps/dsh/var/dsh-url.txt</code>，
     或用应用中心的「日志」查看带 <code>token=</code> 的那行。<br>
     令牌与 cookie 有效期不同：令牌每次启动都会变，配对一次后可长期使用。
   </div>`
);

// ---------------------------------------------------------------- 请求处理
function readBody(req, limit = 8192) {
  return new Promise((resolve) => {
    let n = 0;
    const chunks = [];
    req.on('data', (c) => {
      n += c.length;
      if (n > limit) { req.destroy(); resolve(null); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', () => resolve(null));
  });
}

const server = http.createServer(async (req, res) => {
  const ip = req.socket.remoteAddress || '?';
  const url = new URL(req.url || '/', `http://${req.headers.host || HOST}`);

  if (url.pathname === '/healthz') {
    const st = readState();
    res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
    res.end(JSON.stringify({ ok: true, ready: !!st }));
    return;
  }
  if (url.pathname === '/favicon.ico') {
    res.writeHead(204).end();
    return;
  }

  if (req.method === 'POST' && url.pathname === '/pair') {
    if (tooMany(ip)) {
      log(`pair: rate limited ip=${ip}`);
      res.writeHead(429, { 'content-type': 'text/html; charset=utf-8' });
      res.end(pairPage('尝试次数过多，请 10 分钟后再试。'));
      return;
    }
    const st = readState();
    if (!st) {
      res.writeHead(503, { 'content-type': 'text/html; charset=utf-8', 'retry-after': '2' });
      res.end(waitPage());
      return;
    }
    const body = await readBody(req);
    const token = extractToken(new URLSearchParams(body || '').get('token') || '');
    if (!token) {
      res.writeHead(400, { 'content-type': 'text/html; charset=utf-8' });
      res.end(pairPage('没有识别到令牌。请粘贴完整地址（含 <code>token=</code>）。'));
      return;
    }
    const code = await probeToken(st, token);
    if (code >= 300 && code < 400) {
      log(`pair: ok ip=${ip} (dsh ${code})`);
      res.writeHead(302, { location: st.url, 'set-cookie': newGateCookie(), 'cache-control': 'no-store' });
      res.end();
      return;
    }
    noteFail(ip);
    log(`pair: reject ip=${ip} (dsh ${code || 'unreachable'})`);
    res.writeHead(401, { 'content-type': 'text/html; charset=utf-8' });
    res.end(pairPage('令牌无效或已过期（重启后旧令牌就会失效）。请重新取一次。'));
    return;
  }

  // 其余一律走「已配对 → 跳转」
  const st = readState();
  if (!st) {
    res.writeHead(503, { 'content-type': 'text/html; charset=utf-8', 'retry-after': '2' });
    res.end(waitPage());
    return;
  }
  if (gateOk(req)) {
    res.writeHead(302, { location: st.url, 'cache-control': 'no-store' });
    res.end();
    return;
  }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
  res.end(pairPage(''));
});

loadSecret();

server.on('error', (e) => {
  log(`listen failed: ${e.message}`);
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  log(`listening on http://${HOST}:${PORT} (state=${STATE_FILE || 'none'})`);
});

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    log(`${sig} received, closing`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 2000).unref();
  });
}
