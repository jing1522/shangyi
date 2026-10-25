# 备用法：不想用 systemd / 发行版不是 Ubuntu 时，用容器跑应用
# TLS 由容器外（nginx / 云厂商负载均衡）或挂载证书进来处理
FROM node:22-alpine

WORKDIR /app
COPY package.json server.mjs ./
COPY src ./src

# 非 root 运行
USER node
ENV HOST=0.0.0.0
ENV PORT=5180
EXPOSE 5180

CMD ["node", "server.mjs"]