#!/usr/bin/env node
// ============================================================================
// dsh 入口跳转器（launcher）
//
// 为什么需要它：dsh 每次启动 mint 新 token，令牌只能换一次 cookie，且没有
// 「固定 token」的开关。于是把 service_port（图标打开的那个端口）交给这个
// 小服务，dsh 退到内部端口。跳转器负责把浏览器送到带令牌的地址。
//
// 两种入口模式（--auth）：
//
//   auto（默认）—— 点图标直接进。跳转器从 state 文件读本次启动的令牌
//     （cmd/main 启动 dsh 后从日志抓到并写入，600 权限、同用户可读），
//     拼成 http://<绑定IP>:<内部端口>/?token=… 后 302。
//     只对私有网段（10/8、172.16/12、192.168/16、100.64/10、fc00::/7、
//     ::1）的**直连**放行；来自公网地址、或带代理头（X-Forwarded-For 等）
//     的请求仍然要求配对，避免把 NAS 映射到公网 / 套一层反代后，整个 dsh
//     变成"无密码可执行终端"。
//
//   pair —— 老行为。没有 dsh_gate cookie 的访客只能看到「粘贴入口令牌」页，
//     粘贴的令牌不比对、不解析，直接拿去请求 dsh，回 3xx 即视为有效。
//     通过后签 180 天 HttpOnly cookie，失败按 IP 限速。
//
// 不做的事：不代理任何业务流量（只回 302）。代理就要改写 Host，
// 会破坏 dsh 的 Host/Origin 栅栏，那是另一个量级的问题。
//
// 参数：--host <bind ip> --port <listen port> --state <launcher.json>
//       [--auth auto|pair]
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
const AUTH = String(opt('--auth', 'auto') || 'auto').toLowerCase() === 'pair' ? 'pair' : 'auto';

const COOKIE = 'dsh_gate';
const COOKIE_MAX_AGE = 180 * 24 * 3600;
const FAIL_LIMIT = 5;
const FAIL_WINDOW_MS = 10 * 60 * 1000;
// state 写入后 60 秒内还读不到令牌，按「这一轮确实没抓到」处理，不再无限转圈
const TOKEN_GRACE_MS = 60 * 1000;

function log(msg) {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  const ts =
    `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
    `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  console.log(`${ts} [${process.pid}] launcher: ${msg}`);
}

// ---------------------------------------------------------------- 密钥
// pair 模式用。存 state 同目录（$PKGVAR = @appdata），重装会没，但那不影响
// 安全性，只意味着已配对的设备需要重新粘贴一次。
const SECRET_FILE = STATE_FILE ? path.join(path.dirname(STATE_FILE), 'launcher-secret') : '';
let SECRET = null;

function loadSecret() {
  if (SECRET) return SECRET;
  try {
    const s = fs.readFileSync(SECRET_FILE, 'utf8').trim();
    if (s.length >= 32) {
      // 自愈：只在「文件已存在」这条路径上才知道它可能是旧版本留下的。
      // 早期版本用 700 创建过这个文件，而写新文件时才 chmod，于是 700 会一直跟着
      // （probe/05 报 `WARN 配对密钥权限是 700`）。
      //
      // 2026-10-28 修：原判断是 `mode & 0o077`，只覆盖 group/other 位。
      // 700 的 group/other 恰好都是 0，条件恒为假 → 从不收紧。必须整段比对 0o777。
      try {
        if ((fs.statSync(SECRET_FILE).mode & 0o777) !== 0o600) fs.chmodSync(SECRET_FILE, 0o600);
      } catch {}
      return (SECRET = Buffer.from(s, 'hex'));
    }
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
    if (!st || typeof st.host !== 'string' || !st.port) return null;
    if (typeof st.url !== 'string' && typeof st.token !== 'string') return null;
    return st;
  } catch {
    return null;
  }
}

// 把「本次启动的令牌」拼成对外的入口地址。
// 不能直接用 state.url：那是 dsh 自己打印的，主机名可能是 127.0.0.1 或
// localhost，照抄会把浏览器送到用户自己的电脑上。
function targetUrl(st) {
  let tok = typeof st.token === 'string' ? st.token.trim() : '';
  if (!tok) {
    // 与 cmd/main 的抓取规则保持一致：不写死字符集（见那里的注释）。
    const m = /[?&]token=([^&\s]+)/.exec(String(st.url || ''));
    if (m) {
      try { tok = decodeURIComponent(m[1]); } catch { tok = m[1]; }
    }
  }
  if (!tok) return '';

  let pathPart = `/?token=${encodeURIComponent(tok)}`;
  try {
    const u = new URL(st.url);
    if (u.searchParams.get('token')) pathPart = u.pathname + u.search;
  } catch {}
  return `http://${st.host}:${st.port}${pathPart}`;
}

// ---------------------------------------------------------------- 来源判定
// auto 模式只对「家里/公司内网」放行。判断不了的一律当成不可信 —— 宁可让
// 用户看到配对页，也不要因为一条 ::ffff: 之类的前缀没处理就把入口敞开。
function isPrivate(ip) {
  let s = String(ip || '').trim().toLowerCase().replace(/^::ffff:/, '');
  if (!s) return false;
  if (s === '::1' || s === 'localhost') return true;
  if (s.startsWith('127.')) return true;
  if (s.startsWith('10.')) return true;
  if (s.startsWith('192.168.')) return true;
  if (/^172\.(1[6-9]|2\d|3[01])\./.test(s)) return true;
  if (/^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(s)) return true; // CGNAT / Tailscale
  if (s.startsWith('169.254.')) return true;
  if (s.startsWith('fe80:')) return true;
  if (/^f[cd][0-9a-f]{2}:/.test(s)) return true; // IPv6 ULA fc00::/7
  return false;
}

// ---------------------------------------------------------------- 代理判定
// 只要出现「客户端地址由代理提供」的头，就不再相信 socket.remoteAddress。
//
// 原因：本机反代（nginx / frp / 飞牛统一网关）会把 remoteAddress 变成
// 127.0.0.1，而 127/8 属于 isPrivate() —— 公网访客会被误判成内网并自动
// 放行，等于把带终端与文件工具的 dsh 敞开。这里宁可多要求一次配对，
// 也不接受「无法确认来源」的自动进入。
//
// 将来接入飞牛统一网关时，正确做法不是删掉这段，而是改成「校验网关签名/
// 身份头 + 只信任来自 app.sock 的连接」，见 docs/ISSUES.md T7。
const PROXY_HEADERS = [
  'x-forwarded-for',
  'x-forwarded-host',
  'x-forwarded-proto',
  'x-real-ip',
  'forwarded',
  'cf-connecting-ip',
  'true-client-ip',
];

function viaProxy(req) {
  return PROXY_HEADERS.some((h) => req.headers[h] !== undefined);
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
  // 字符集同样不写死：上游可能用 "." / "~" / "+" / "%" / "=" 组成 opaque 串。
  const m = /token=([^&\s]{8,})/.exec(s);
  if (m) return m[1];
  if (/^[A-Za-z0-9._~+%=-]{8,512}$/.test(s)) return s;
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

const pairPage = (err, note) => page(
  'DeepSeek Harness — 配对这台设备',
  `<h1>配对这台设备</h1>
   <p>${note || '粘贴一次入口令牌，之后点图标即可直接进入。'}</p>
   <form method="post" action="/pair">
     <input name="token" placeholder="粘贴完整地址或 token" autocomplete="off" spellcheck="false" autofocus>
     <button type="submit">配对并进入</button>
   </form>
   ${err ? `<div class="err">${err}</div>` : ''}
   <div class="hint">
     <b>入口令牌在哪：</b><br>
     NAS 上执行 <code>cat /var/apps/dsh/var/dsh-url.txt</code>，
     或用应用中心的「日志」查看带 <code>token=</code> 的那行。<br>
     令牌每次启动都会变，配对一次后 180 天内不必再填。
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

const redirect = (res, location, extra) => {
  res.writeHead(302, { location, 'cache-control': 'no-store', ...(extra || {}) });
  res.end();
};

const handler = async (req, res) => {
  const ip = req.socket.remoteAddress || '?';
  const url = new URL(req.url || '/', `http://${req.headers.host || HOST}`);

  if (url.pathname === '/healthz') {
    const st = readState();
    const target = st ? targetUrl(st) : '';
    res.writeHead(200, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
    res.end(JSON.stringify({ ok: true, ready: !!st, auto: AUTH === 'auto' && !!target, mode: AUTH }));
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
      redirect(res, `http://${st.host}:${st.port}/?token=${encodeURIComponent(token)}`, {
        'set-cookie': newGateCookie(),
      });
      return;
    }
    noteFail(ip);
    log(`pair: reject ip=${ip} (dsh ${code || 'unreachable'})`);
    res.writeHead(401, { 'content-type': 'text/html; charset=utf-8' });
    res.end(pairPage('令牌无效或已过期（重启后旧令牌就会失效）。请重新取一次。'));
    return;
  }

  const st = readState();
  if (!st) {
    res.writeHead(503, { 'content-type': 'text/html; charset=utf-8', 'retry-after': '2' });
    res.end(waitPage());
    return;
  }

  const target = targetUrl(st);

  // ---- auto：点图标直接进 ----
  if (AUTH === 'auto') {
    if (viaProxy(req)) {
      // 有代理头 = 来源由别人转述，不能拿 remoteAddress 当客户端地址。
      // 这类请求一律落到配对页：能拿到令牌的人仍然进得去，但不会因为
      // 「反代在本机」就把入口对公网敞开。
      log(`auto: proxy headers present ip=${ip} -> pair`);
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      res.end(pairPage('', '请求经过代理，无法确认来源地址，需要先配对一次。'));
      return;
    }
    if (!isPrivate(ip)) {
      // 公网来源一律要求配对，哪怕我们用 auto 模式
      log(`auto: non-private ip=${ip} -> pair`);
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      res.end(pairPage('', '当前访问来自非内网地址，需要先配对一次。'));
      return;
    }
    if (target) {
      log(`auto: redirect ip=${ip}`);
      redirect(res, target);
      return;
    }
    // 没抓到令牌，但浏览器里已经有 dsh 自己的 cookie（30 天）——直接送去裸地址，
    // 比让用户对着「正在启动」转圈强。首次访问没有 cookie 时才走后面的提示页。
    if ((req.headers.cookie || '').trim()) {
      log(`auto: no token but cookie present, redirect bare ip=${ip}`);
      redirect(res, `http://${st.host}:${st.port}/`);
      return;
    }
    const since = Number(st.since) || 0;
    const fresh = since && Date.now() - since * 1000 < TOKEN_GRACE_MS;
    if (fresh) {
      res.writeHead(503, { 'content-type': 'text/html; charset=utf-8', 'retry-after': '2' });
      res.end(waitPage());
      return;
    }
    // 这一轮确实没抓到令牌（dsh 改了输出格式 / 启动失败），别让用户对着
    // 永远刷新的白屏，直接告诉他可以手工粘贴一次。
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    res.end(pairPage(
      '自动获取入口令牌失败。这通常是 dsh 没有正常启动，或改用了新的日志格式。',
      '可以粘贴一次令牌进入，或先到应用中心看日志。'
    ));
    return;
  }

  // ---- pair：老行为 ----
  if (gateOk(req) && target) {
    log(`pair: pass ip=${ip}`);
    redirect(res, target);
    return;
  }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
  res.end(pairPage(''));
};

const server = http.createServer(handler);

loadSecret();

server.on('error', (e) => {
  log(`listen failed: ${e.message}`);
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  log(`listening on http://${HOST}:${PORT} (auth=${AUTH} state=${STATE_FILE || 'none'})`);
});

// 回环也要有监听：应用中心的「运行中」判定与本机自检连的都是 127.0.0.1。
// 只绑局域网地址时，平台那边是 ECONNREFUSED，卡片上就只剩「打开 / 卸载」，
// 没有停止——2026-10-27 真机就是这么暴露的（manifest 里 ctl_stop 明明是 true）。
// 失败只记日志：局域网访问不受影响，别为了一个本地检查把入口整个起不来。
const LOOPBACKS = new Set(['127.0.0.1', '::1', 'localhost', '0.0.0.0', '::']);
let loServer = null;
if (!LOOPBACKS.has(HOST)) {
  loServer = http.createServer(handler);
  loServer.on('error', (e) => {
    log(`loopback listen failed: ${e.message}（平台仍可能把应用当成未运行）`);
  });
  loServer.listen(PORT, '127.0.0.1', () => {
    log(`listening on http://127.0.0.1:${PORT} (loopback, 供平台与本机自检)`);
  });
}

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    log(`${sig} received, closing`);
    if (loServer) loServer.close();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 2000).unref();
  });
}
