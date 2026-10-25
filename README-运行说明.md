# 闪衣 · AI 实时试衣 —— 运行 / 部署说明

这个页面**不是纯静态 HTML**：浏览器要拿摄像头、还要向 Decart 换发短期 token，
所以必须由一个「代码服务器」（哪怕很小）把页面发出去，并提供一个 `/api/decart-token` 接口。

## 目录结构

```
闪衣 · AI实时试衣3/
├─ src/app.html         整个前端（单文件，样式+逻辑都在里面）
├─ server.mjs           后端：静态托管 + /api/decart-token，可选自带 HTTPS
├─ package.json         只有 start/dev 两个脚本，无任何依赖
├─ .env.local           本机用的长期 API Key（不要提交、不要发人）
├─ 部署到云服务器.md      没有域名怎么上公网：IP 证书 / 隧道 / Docker
└─ deploy/
   ├─ deploy-ubuntu.sh  一键部署（装 Node+certbot、申请 IP 证书、systemd）
   ├─ Dockerfile
   ├─ docker-compose.yml
   └─ .env.example
```

## 一、本机跑起来（3 步）

```powershell
cd "D:\trea_game\闪衣 · AI实时试衣3"
npm start
# 打开 http://127.0.0.1:5180
```

首次会弹出摄像头授权，允许即可。AI 试衣需要摄像头画面，`127.0.0.1` 属于安全上下文，
浏览器允许 `http://127.0.0.1` 调摄像头；换成局域网 IP（如 `192.168.x.x`）就必须上 HTTPS。

接口自检：

```powershell
curl.exe http://127.0.0.1:5180/api/health
curl.exe -X POST http://127.0.0.1:5180/api/decart-token
```

## 二、为什么必须要有服务端（关键）

1. **静态托管**：`app.html` 里的模块从 `esm.sh` 加载 `@decartai/sdk`，
   而摄像头、`fetch('data:...')`、跨源请求都要求页面跑在 http(s) 而不是 `file://`。
   直接双击 `app.html` 打开 = 摄像头拿不到 + `/api/decart-token` 404。
2. **换发短期 token**：Decart 的长期 Key（`dct_v1_...`）一旦出现在前端就等于公开，
   任何人 F12 就能抄走、刷你的额度。正确做法是长期 Key 只留在服务端，
   前端每次点击试衣时向自己的服务器要一个有效期 5 分钟的短期 token。

`server.mjs` 里做的事情就这两件：

| 路由 | 说明 |
| --- | --- |
| `GET /`、`GET /src/*` | 只放行 `src/` 下的静态资源，隐藏文件和 `server.mjs` 一律 404 |
| `POST /api/decart-token` | 用 `x-api-key` 调 `https://api.decart.ai/v1/client/tokens`，把短期 token 返给前端 |
| `GET /api/health` | 健康检查 |

> 注意：原代码里写的 `https://api.platform.decart.ai/v1/client/tokens` 是错域名（连不上），
> 文档里是 `https://api.decart.ai/v1/client/tokens`。

换发 token 的核心代码（想换成别的语言时照这个写）：

```js
const res = await fetch('https://api.decart.ai/v1/client/tokens', {
  method: 'POST',
  headers: { 'x-api-key': process.env.DECART_API_KEY, 'Content-Type': 'application/json' },
  body: JSON.stringify({ expiresIn: 300 }),
});
const { apiKey } = await res.json();   // 返回给前端
```

## 三、部署到线上服务器（没有域名也行）

摄像头只在 `https://` 或 `127.0.0.1` 下可用，所以「`http://公网IP`」不算真正可用。
好在 Let's Encrypt 从 2026 年起签发**纯 IP 证书**，不需要域名、不需要备案绑定域名。

完整步骤、备案说明、排错表都在 **[部署到云服务器.md](部署到云服务器.md)**，四选一：

| 方式 | 命令 | 结果 |
| --- | --- | --- |
| 一键（Ubuntu/Debian） | `sudo bash deploy/deploy-ubuntu.sh` | `https://你的公网IP` |
| 手动 7 步（任意发行版） | 见文档路线 B | 同上 |
| Docker | `docker compose -f deploy/docker-compose.yml up -d --build` | 容器内 `:5180`，外层做 HTTPS |
| 隧道（临时演示） | `npx cloudflared tunnel --url http://127.0.0.1:5180` | `https://xxx.trycloudflare.com` |

应用**自带 HTTPS 能力**：`.env` 里给了 `TLS_CERT` / `TLS_KEY` 就直接监听 443（非 root 运行时用
systemd 的 `CAP_NET_BIND_SERVICE`），不需要 nginx；想用 nginx/宝塔反代也支持，让应用回到
`HOST=127.0.0.1 PORT=5180` 即可。

### 附：Cloudflare Workers（完全不想管服务器时）

`worker.js`：

```js
export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (url.pathname === '/api/decart-token' && req.method === 'POST') {
      const r = await fetch('https://api.decart.ai/v1/client/tokens', {
        method: 'POST',
        headers: { 'x-api-key': env.DECART_API_KEY, 'Content-Type': 'application/json' },
        body: JSON.stringify({ expiresIn: 300 }),
      });
      return new Response(await r.text(), { status: r.status, headers: { 'content-type': 'application/json' } });
    }
    return env.ASSETS.fetch(req);   // 静态资源由 Workers Static Assets 提供
  },
};
```

Key 放 Secret（`wrangler secret put DECART_API_KEY`），不要写进 `wrangler.toml`。
Vercel / Netlify 同理：`api/decart-token.js` + 静态目录，环境变量里配 Key。

## 四、安全提醒

- `dct_v1_Hyiw...` 这个 Key 之前在 `app.html` 里是明文，已经随 HTML 传播过，
  建议到 <https://platform.decart.ai> 后台**轮换/作废**这把 Key，再换新的到 `.env.local`。
- `.env.local` 已列入 `.gitignore`；部署时用环境变量注入，别提交。
- 根目录那个 `闪衣 · AI实时试衣3.zip` 是旧版本，里面还带着明文 Key，别再发人。

## 五、常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| 打开页面提示「AI试衣服务未就绪（SDK加载失败）」 | 访问不了 `esm.sh`（网络/公司防火墙）。换网络或把 SDK 用 npm 装到本地再改 importmap |
| 点开始试衣提示「AI试衣连接失败…已切换为本地模式」 | token 换发失败或额度用尽。看终端日志里的 `[token] 换发失败`，先 `curl -X POST /api/decart-token` 试一下 |
| 摄像头打不开 | 不是 https 也不是 127.0.0.1；或浏览器没给权限 |
| `npm start` 报 `EADDRINUSE` | 5180 被占用，`$env:PORT=5181; npm start` |
| 想改模型 | `src/app.html` 顶部 `window.DECART_CONFIG.model`，可选 `lucy-vton-3.6` / `lucy-vton-3.5` / `lucy-vton-latest` |