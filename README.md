# Gemini Web2API VPS

脱敏公开版 Gemini Web2API 部署包：在普通 VPS/服务器本地运行 OpenAI-compatible 接口，不依赖 Cloudflare Worker。

它会把 Gemini Web 的匿名网页接口包装成 OpenAI 风格接口，适合自己部署后给中转站、OpenAI SDK、Chatbox、Cherry Studio、OpenWebUI 等工具调用。

> 安全说明：本仓库不包含任何真实 API key、Cloudflare token、Cookie 或账号凭据。

---

## 功能

- 一键部署到 Ubuntu/Debian VPS
- 自动安装基础依赖：`curl`、`git`、`python3`、`openssl`，并确保 Node.js >= 18（低版本会自动升级到 Node.js 20 LTS）
- 交互式设置调用 API Key
  - 可以自己输入
  - 也可以回车自动生成 `sk-gemini-web2api-...`
- 交互式设置监听端口
  - 默认：`7861`
- 交互式选择是否绑定域名
  - 默认：不绑定
  - 如果绑定域名：自动安装 nginx + certbot，申请 Let's Encrypt 免费证书
- 自动配置 systemd 服务
- 自动启用证书续期 timer
- 自动测试 `/v1/models` 和 `/v1/chat/completions`

---

## 准备条件

### 服务器

推荐：

- Ubuntu 22.04 / 24.04
- Debian 11 / 12
- Node.js 会由脚本自动检查；低于 18 会安装 Node.js 20 LTS
- root 用户，或有 sudo 权限的用户

### 网络

服务器需要能访问：

- `github.com`
- `raw.githubusercontent.com`
- `gemini.google.com`
- `letsencrypt.org` / Let's Encrypt 相关服务（仅绑定域名申请证书时需要）

### 如果要绑定域名

请先把域名解析到服务器公网 IP，例如：

```text
A    gemini.example.com    你的服务器公网IP
```

并确保服务器安全组/防火墙开放：

```text
80/tcp
443/tcp
```

不绑定域名时，如果要公网直接访问端口，则需要开放你选择的端口，例如默认：

```text
7861/tcp
```

---

## 一键部署

在新服务器上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yh594774855/gemini-web2api-vps/main/deploy-vps.sh)
```

脚本会进入交互式安装流程。

---

## 交互项说明

### 1. 公开仓库地址

默认：

```text
https://github.com/yh594774855/gemini-web2api-vps.git
```

通常直接回车。

### 2. 安装目录

默认：

```text
/opt/gemini-web2api-server
```

通常直接回车。

### 3. 服务名

默认：

```text
gemini-web2api
```

systemd 会创建：

```text
gemini-web2api.service
```

### 4. 监听端口

默认：

```text
7861
```

如果服务器上 7861 已被占用，可以换成其他端口。

### 5. 默认模型

默认：

```text
gemini-3.5-flash
```

通常直接回车。

### 6. API Key

脚本会提示：

```text
设置调用 API Key [回车自动生成]:
```

你可以输入自己的 key，例如：

```text
sk-my-private-key
```

也可以直接回车，让脚本自动生成。

之后调用接口时需要：

```http
Authorization: Bearer 你的key
```

### 7. 是否绑定域名并申请免费证书

默认：

```text
no
```

如果选择 `yes`，脚本会继续询问：

- 域名，例如：`gemini.example.com`
- 证书通知邮箱，可留空

然后自动：

- 安装 nginx
- 安装 certbot
- 写入 nginx 反代配置
- 申请 Let's Encrypt 证书
- 配置 HTTPS
- 启用 certbot 自动续期
- 执行一次 `certbot renew --dry-run`

---

## 部署后的接口地址

### 不绑定域名

如果选择直接监听公网：

```text
http://服务器IP:7861/v1
```

如果选择不监听公网：

```text
http://127.0.0.1:7861/v1
```

### 绑定域名

```text
https://你的域名/v1
```

例如：

```text
https://gemini.example.com/v1
```

---

## 支持的模型

当前内置模型包括：

```text
gemini-3.5-flash
gemini-3.5-flash-thinking
gemini-3.1-pro
gemini-3.1-pro-enhanced
gemini-auto
gemini-3.5-flash-thinking-lite
gemini-flash-lite
```

说明：

- 匿名方式主要适合 Flash 系列。
- 真正 Pro 路由可能需要 Gemini 登录态/Cookie；本公开部署脚本默认不要求登录，也不保存 Cookie。

---

## 调用示例

### 查看模型

```bash
curl http://服务器IP:7861/v1/models \
  -H "Authorization: Bearer sk-你的key"
```

绑定域名后：

```bash
curl https://gemini.example.com/v1/models \
  -H "Authorization: Bearer sk-你的key"
```

### Chat Completions

```bash
curl http://服务器IP:7861/v1/chat/completions \
  -H "Authorization: Bearer sk-你的key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemini-3.5-flash",
    "messages": [
      {"role": "user", "content": "你好，只回复 OK"}
    ]
  }'
```

绑定域名后：

```bash
curl https://gemini.example.com/v1/chat/completions \
  -H "Authorization: Bearer sk-你的key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemini-3.5-flash",
    "messages": [
      {"role": "user", "content": "你好"}
    ]
  }'
```

---

## OpenAI SDK 示例

### JavaScript / Node.js

```js
import OpenAI from "openai";

const client = new OpenAI({
  apiKey: "sk-你的key",
  baseURL: "http://服务器IP:7861/v1", // 或 https://gemini.example.com/v1
});

const resp = await client.chat.completions.create({
  model: "gemini-3.5-flash",
  messages: [{ role: "user", content: "你好" }],
});

console.log(resp.choices[0].message.content);
```

### Python

```python
from openai import OpenAI

client = OpenAI(
    api_key="sk-你的key",
    base_url="http://服务器IP:7861/v1",  # 或 https://gemini.example.com/v1
)

resp = client.chat.completions.create(
    model="gemini-3.5-flash",
    messages=[{"role": "user", "content": "你好"}],
)

print(resp.choices[0].message.content)
```

---

## 服务管理

查看状态：

```bash
systemctl status gemini-web2api
```

查看日志：

```bash
journalctl -u gemini-web2api -f
```

重启服务：

```bash
systemctl restart gemini-web2api
```

停止服务：

```bash
systemctl stop gemini-web2api
```

---

## 配置文件

真实运行配置保存在：

```text
/etc/gemini-web2api.env
```

权限：

```text
600
```

常见字段：

```bash
HOST=127.0.0.1
PORT=7861
API_KEYS=sk-你的key
DEFAULT_MODEL=gemini-3.5-flash
LOG_REQUESTS=true
UPSTREAM_SOCKET=false
GEMINI_BL=boq_assistant-bard-web-server_xxx
GEMINI_ORIGIN=https://gemini.google.com
```

修改后重启：

```bash
systemctl restart gemini-web2api
```

---

## 证书续期

如果选择绑定域名，脚本会使用 certbot 配置 Let's Encrypt 证书。

查看 timer：

```bash
systemctl status certbot.timer
```

手动测试续期：

```bash
certbot renew --dry-run
```

正常情况下 certbot 会自动续期，不需要手工处理。

---

## 更新项目

重新执行一键部署脚本即可：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yh594774855/gemini-web2api-vps/main/deploy-vps.sh)
```

脚本检测到已有安装目录后，会拉取最新代码并重启服务。

---

## 卸载

如果服务名使用默认 `gemini-web2api`：

```bash
systemctl disable --now gemini-web2api
rm -f /etc/systemd/system/gemini-web2api.service
rm -f /etc/gemini-web2api.env
rm -rf /opt/gemini-web2api-server
systemctl daemon-reload
```

如果绑定过域名，还可以删除 nginx 配置：

```bash
rm -f /etc/nginx/sites-enabled/你的域名.conf
rm -f /etc/nginx/sites-available/你的域名.conf
nginx -t && systemctl reload nginx
```

证书文件通常位于：

```text
/etc/letsencrypt/live/你的域名/
```

如需删除证书：

```bash
certbot delete --cert-name 你的域名
```

---

## 常见问题

### 1. 返回 401 invalid api key

说明调用时没有带正确 key。

检查请求头：

```http
Authorization: Bearer sk-你的key
```

检查服务器配置：

```bash
cat /etc/gemini-web2api.env
```

### 2. Upstream Gemini returned an empty response

常见原因：

- `GEMINI_BL` 过期
- 服务器 IP 到 Google Gemini 上游异常
- Google 临时限制或页面协议变动

处理：

1. 重新执行部署脚本，让脚本抓最新 `GEMINI_BL`
2. 或手动修改 `/etc/gemini-web2api.env` 的 `GEMINI_BL`
3. 重启服务

```bash
systemctl restart gemini-web2api
```

### 3. 绑定域名申请证书失败

检查：

- 域名 A 记录是否已经解析到当前服务器公网 IP
- 服务器 80 端口是否开放
- 云厂商安全组是否放行 80/443
- 是否已有其他服务占用 80/443

查看 nginx：

```bash
nginx -t
systemctl status nginx
```

### 4. 端口无法访问

检查服务是否运行：

```bash
systemctl status gemini-web2api
```

检查监听：

```bash
ss -ltnp | grep 7861
```

检查防火墙/安全组是否开放对应端口。

---

## 安全建议

- 不要把 `/etc/gemini-web2api.env` 上传到公开仓库。
- 不要公开分享 API Key。
- 公网开放时建议绑定域名 + HTTPS。
- 如果只给本机中转站使用，建议不开放公网，只监听 `127.0.0.1`。
- 如果 API Key 泄露，修改 `/etc/gemini-web2api.env` 的 `API_KEYS` 后重启服务。
