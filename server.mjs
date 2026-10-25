import { createServer as createHttpServer } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { readFileSync } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
// 配了 TLS_CERT/TLS_KEY 就走 HTTPS（端口通常给 443），否则走 HTTP
const TLS_CERT = process.env.TLS_CERT || '';
const TLS_KEY = process.env.TLS_KEY || '';
const USE_TLS = Boolean(TLS_CERT && TLS_KEY);
const PORT = Number(process.env.PORT || (USE_TLS ? 443 : 5180));
const HOST = process.env.HOST || (USE_TLS ? '0.0.0.0' : '127.0.0.1');
const DECART_TOKEN_URL = 'https://api.decart.ai/v1/client/tokens';
const TOKEN_TTL = Number(process.env.TOKEN_TTL || 300);

// ---------- API Key：优先环境变量，其次 .env.local ----------
async function loadApiKey() {
  if (process.env.DECART_API_KEY) return process.env.DECART_API_KEY.trim();
  try {
    const raw = await readFile(path.join(ROOT, '.env.local'), 'utf8');
    for (const line of raw.split(/\r?\n/)) {
      const m = line.match(/^\s*DECART_API_KEY\s*=\s*(.+?)\s*$/);
      if (m) return m[1].replace(/^["']|["']$/g, '');
    }
  } catch { /* 没有 .env.local */ }
  return '';
}
const API_KEY = await loadApiKey();
if (!API_KEY) {
  console.error('[启动失败] 没有找到 DECART_API_KEY。请设置环境变量，或在同目录创建 .env.local：');
  console.error('  DECART_API_KEY=dct_v1_xxxxxxxx');
  process.exit(1);
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
};

function sendJson(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

// ---------- 换发短期 client token ----------
async function mintToken() {
  const res = await fetch(DECART_TOKEN_URL, {
    method: 'POST',
    headers: { 'x-api-key': API_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ expiresIn: TOKEN_TTL }),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`Decart ${res.status}: ${text.slice(0, 300)}`);
  return JSON.parse(text);
}

// ---------- 静态文件 ----------
async function serveStatic(req, res, pathname) {
  let rel = decodeURIComponent(pathname);
  if (rel === '/' || rel === '/index.html' || rel === '/app.html') rel = '/src/app.html';
  const normalized = path.normalize(rel).replace(/^([/\\])+/, '');
  // 只对外开放 src/ 里的静态资源；隐藏文件和服务端代码一律不对外
  const segments = normalized.split(/[/\\]+/);
  const ALLOWED_EXT = new Set(['.html', '.css', '.js', '.mjs', '.png', '.jpg', '.jpeg', '.webp', '.svg', '.ico', '.gif', '.woff2', '.mp4', '.webm']);
  const blocked =
    segments.some((s) => !s || s.startsWith('.')) ||
    segments[0] !== 'src' ||
    !ALLOWED_EXT.has(path.extname(normalized).toLowerCase());
  if (blocked) return sendJson(res, 404, { error: 'not found' });
  const target = path.join(ROOT, normalized);
  if (!target.startsWith(ROOT + path.sep)) return sendJson(res, 403, { error: 'forbidden' });
  try {
    const info = await stat(target);
    if (!info.isFile()) return sendJson(res, 404, { error: 'not found' });
    const data = await readFile(target);
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(target).toLowerCase()] || 'application/octet-stream',
      'Content-Length': data.length,
      'Cache-Control': 'no-cache',
    });
    res.end(data);
  } catch {
    sendJson(res, 404, { error: 'not found', path: rel });
  }
}

const handler = async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const { pathname } = url;

  if (pathname === '/api/health') {
    return sendJson(res, 200, { ok: true, keyConfigured: true, tokenTtl: TOKEN_TTL, tls: USE_TLS });
  }

  if (pathname === '/api/decart-token') {
    if (req.method !== 'POST') return sendJson(res, 405, { error: 'method not allowed' });
    try {
      const data = await mintToken();
      console.log(`[token] 已换发，有效期 ${TOKEN_TTL}s`);
      return sendJson(res, 200, { apiKey: data.apiKey, expiresIn: TOKEN_TTL });
    } catch (err) {
      console.error('[token] 换发失败:', err.message);
      return sendJson(res, 502, { error: 'token mint failed', detail: err.message });
    }
  }

  if (req.method !== 'GET' && req.method !== 'HEAD') return sendJson(res, 405, { error: 'method not allowed' });
  return serveStatic(req, res, pathname);
};

let server;
if (USE_TLS) {
  try {
    server = createHttpsServer(
      { cert: readFileSync(TLS_CERT), key: readFileSync(TLS_KEY) },
      (req, res) => {
        // 摄像头要求安全上下文，顺手补上 HSTS（纯 IP 场景不加 preload）
        res.setHeader('Strict-Transport-Security', 'max-age=31536000');
        handler(req, res);
      },
    );
  } catch (err) {
    console.error(`[启动失败] 证书读取失败（TLS_CERT=${TLS_CERT} / TLS_KEY=${TLS_KEY}）: ${err.message}`);
    process.exit(1);
  }
} else {
  server = createHttpServer(handler);
}

server.listen(PORT, HOST, () => {
  const scheme = USE_TLS ? 'https' : 'http';
  console.log(`闪衣服务已启动: ${scheme}://${HOST}:${PORT}`);
  console.log(`  GET  /                  试衣页面`);
  console.log(`  POST /api/decart-token  换发 Decart 短期 token`);
  console.log(`  GET  /api/health        健康检查`);
});

// systemd / docker stop 时优雅退出，避免端口占用
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    console.log(`[${sig}] 正在关闭...`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 3000).unref();
  });
}