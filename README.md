# Gemini Web2API VPS

脱敏公开版 Gemini Web2API 部署包：在普通 VPS/服务器本地运行 OpenAI-compatible 接口，不依赖 Cloudflare Worker。

## 一键部署

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yh594774855/gemini-web2api-vps/main/deploy-vps.sh)
```

脚本会交互询问：

- 调用 API Key：可回车自动生成
- 监听端口：默认 `7861`
- 是否绑定域名：默认否
- 若绑定域名：自动安装 nginx + certbot，申请 Let's Encrypt 免费证书，并启用自动续期

## 接口

```text
GET  /v1/models
POST /v1/chat/completions
POST /v1/responses
GET  /v1beta/models
POST /v1beta/models/{model}:generateContent
```

## 测试

```bash
curl http://127.0.0.1:7861/v1/chat/completions \
  -H "Authorization: Bearer sk-你的key" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemini-3.5-flash","messages":[{"role":"user","content":"你好"}]}'
```

## 服务管理

```bash
systemctl status gemini-web2api
journalctl -u gemini-web2api -f
systemctl restart gemini-web2api
```

## 安全说明

- 本仓库不包含任何真实 API key、Cloudflare token、Cookie。
- 真实配置保存在服务器 `/etc/gemini-web2api.env`，权限为 `600`。
- 如果不绑定域名但开放公网端口，请自行配置防火墙并保护 API key。
