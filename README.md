# 闪衣 · AI 实时试衣

> Real-time AI virtual try-on in the browser — one garment photo in, a live try-on video out. No 3D modelling, no app install.
>
> 用一张衣服图，让消费者在浏览器里实时“穿”上它。

衣物图上传 → 实时换装（WebRTC 视频流）→ 10 秒定格前后对比。前端是一个单文件页面，后端是一个零依赖的 Node 服务，一台入门服务器即可跑起来。

## 它能做什么

- **商家端**：上传一张平铺图或模特图，选品类与材质，生成可试穿商品
- **消费者端**：打开链接 → 授权摄像头 → 实时试穿 → 10 秒自动定格
- **前后对比**：自动截取试穿前后两帧，生成对比图，可保存可分享
- **材质语义**：8 类面料（牛仔/丝绸/棉/针织/皮革/亚麻/羊毛/涤纶）分别注入物理描述，换装更像真布料
- **失败降级**：模型不可用时退回本地录制模式，页面不白屏

## 快速开始

前置：Node.js 20+，以及一个 [Decart](https://platform.decart.ai) API Key。

```bash
git clone https://github.com/jing1522/shangyi.git
cd shangyi

# 写入密钥（该文件已被 .gitignore 忽略）
echo "DECART_API_KEY=dct_v1_你的密钥" > .env.local

npm start
# 打开 http://127.0.0.1:5180
```

首次打开会请求摄像头权限，允许即可。**必须通过 `http://127.0.0.1` 或 `https://` 访问**，`file://` 双击打开拿不到摄像头。

## 目录结构

```
.
├─ src/app.html            前端单文件（界面 + 逻辑，无构建步骤）
├─ server.mjs              服务端：静态托管 + 短期凭证换发，零第三方依赖
├─ package.json
├─ deploy/
│  ├─ deploy-ubuntu.sh     一键部署（Node + certbot + systemd）
│  ├─ Dockerfile
│  ├─ docker-compose.yml
│  └─ .env.example
├─ README-运行说明.md       本机运行、原理、常见问题
└─ 部署到云服务器.md         没有域名怎么上公网（纯 IP 证书 / 隧道 / Docker）
```

## 技术要点

| 环节 | 做法 |
| --- | --- |
| 实时视频 | WebRTC 双向流，摄像头画面实时上行、换装画面实时回传 |
| 试衣模型 | Decart 实时虚拟试衣（`lucy-vton-latest`），通过提示词控制品类与材质 |
| 前端 | 原生 JS + ES Module，SDK 直接从 CDN 加载，无需打包 |
| 后端 | `node:http` 单文件服务，路由只有三个 |
| 部署 | 自带 TLS 能力，可直接用 Let's Encrypt 的纯 IP 证书，**没有域名也能 HTTPS** |

## 安全模型

这是本项目最需要注意的一点。

- 长期 API Key **只存在于服务端**（`.env.local` 或部署环境变量），浏览器里永远不出现
- 前端每次点击“开始试衣”都向 `/api/decart-token` 换取一次 **300 秒有效的短期凭证**
- 静态资源走白名单：只放行 `src/` 下的前端资源，隐藏文件与服务端脚本一律 404
- 仓库自带的 `pre-commit` 钩子会在提交前拦截疑似密钥

```bash
# 自检：确认仓库里没有密钥
git grep -I -n "dct_v1_"
```

⚠️ **Fork 或使用本项目时，请申请你自己的 Key。** 不要把任何人的密钥提交进仓库——包括测试用的。

## 部署

没有域名也能上线（Let's Encrypt 已支持纯 IP 证书）：

```bash
scp -r . root@<服务器IP>:/root/shanyi/
ssh root@<服务器IP>
cd /root/shanyi && sudo bash deploy/deploy-ubuntu.sh
```

细节见 [部署到云服务器.md](部署到云服务器.md)，换装流程与排错见 [README-运行说明.md](README-运行说明.md)。

## 已知边界

- 模型对体型差异、遮挡、复杂图案仍敏感，目前以单品类（上衣/外套/连衣裙/裤装）试点为主
- 只做“换装”，不做尺码合身度判断
- 商品与积分暂存浏览器 localStorage，正式版需迁移到服务端
- 计费相关功能为演示态，未接真实支付

## License

暂未选择开源协议，默认保留所有权利。如需使用、商用或二次分发，请联系作者。