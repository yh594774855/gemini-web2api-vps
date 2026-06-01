#!/usr/bin/env bash
set -Eeuo pipefail

# Gemini Web2API VPS 一键部署脚本
# - 在普通 Ubuntu/Debian 服务器本地部署，不依赖 Cloudflare Worker
# - 交互式设置调用 key、端口、是否绑定域名
# - 默认端口 7861，默认不绑定域名
# - 如绑定域名：自动安装 nginx + certbot，申请 Let's Encrypt 免费证书，并启用自动续期
#
# 快速使用：
#   bash <(curl -fsSL https://raw.githubusercontent.com/yh594774855/gemini-web2api-vps/main/deploy-vps.sh)
#
# 或：
#   git clone https://github.com/yh594774855/gemini-web2api-vps.git
#   cd gemini-web2api-vps
#   bash deploy-vps.sh

REPO_URL_DEFAULT="https://github.com/yh594774855/gemini-web2api-vps.git"
APP_DIR_DEFAULT="/opt/gemini-web2api-server"
SERVICE_NAME_DEFAULT="gemini-web2api"
PORT_DEFAULT="7861"
DEFAULT_MODEL_DEFAULT="gemini-3.5-flash"
GEMINI_BL_FALLBACK="boq_assistant-bard-web-server_20260529.02_p0"

say() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }
as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

pm_install() {
  if need_cmd apt-get; then
    as_root apt-get update
    as_root apt-get install -y "$@"
  elif need_cmd dnf; then
    as_root dnf install -y "$@"
  elif need_cmd yum; then
    as_root yum install -y "$@"
  else
    err "未找到支持的包管理器：apt-get / dnf / yum"
    exit 1
  fi
}

pm_install_node20() {
  if need_cmd apt-get; then
    as_root apt-get update
    as_root apt-get install -y curl ca-certificates gnupg
    curl -fsSL https://deb.nodesource.com/setup_20.x | as_root bash -
    as_root apt-get install -y nodejs
  elif need_cmd dnf || need_cmd yum; then
    # NodeSource supports EL/RHEL/CentOS-like systems.
    curl -fsSL https://rpm.nodesource.com/setup_20.x | as_root bash -
    if need_cmd dnf; then as_root dnf install -y nodejs; else as_root yum install -y nodejs; fi
  else
    err "未找到支持的包管理器，无法安装 Node.js 20"
    exit 1
  fi
}

random_key() {
  if need_cmd openssl; then
    printf 'sk-gemini-web2api-%s\n' "$(openssl rand -hex 24)"
  else
    printf 'sk-gemini-web2api-%s%s\n' "$(date +%s)" "$RANDOM"
  fi
}

ask() {
  local var="$1" prompt="$2" default="$3" value="${!var-}"
  if [ -n "$value" ]; then return 0; fi
  printf "%s [%s]: " "$prompt" "$default" >&2
  IFS= read -r value
  value="${value:-$default}"
  export "$var=$value"
}

ask_secret_or_generate() {
  local var="$1" prompt="$2" generated="$3" value="${!var-}"
  if [ -n "$value" ]; then return 0; fi
  printf "%s [回车自动生成]: " "$prompt" >&2
  stty -echo 2>/dev/null || true
  IFS= read -r value
  stty echo 2>/dev/null || true
  printf '\n' >&2
  value="${value:-$generated}"
  export "$var=$value"
}

ask_yes_no() {
  local var="$1" prompt="$2" default="$3" value="${!var-}"
  if [ -n "$value" ]; then return 0; fi
  printf "%s [%s]: " "$prompt" "$default" >&2
  IFS= read -r value
  value="${value:-$default}"
  case "$value" in
    y|Y|yes|YES|Yes|是) value="yes" ;;
    *) value="no" ;;
  esac
  export "$var=$value"
}

node_major() {
  if ! need_cmd node; then echo 0; return; fi
  node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || echo 0
}

install_node20() {
  say "安装/升级 Node.js 20 LTS（本服务需要 Node >= 18）"
  pm_install_node20
}

install_base_deps() {
  say "检查基础依赖"
  pm_install curl git ca-certificates python3 openssl
  local major
  major="$(node_major)"
  if [ "$major" -lt 18 ]; then
    warn "当前 Node.js 版本过低或未安装：$(node -v 2>/dev/null || echo none)"
    install_node20
  fi
  say "Node.js 版本：$(node -v)"
}

clone_or_update_project() {
  local repo_url="$1" app_dir="$2"
  if [ -d "$app_dir/.git" ]; then
    say "更新已有项目：$app_dir"
    git -C "$app_dir" fetch --all --prune
    git -C "$app_dir" reset --hard origin/main
  elif [ -f "./worker.js" ] && [ -f "./deploy-vps.sh" ]; then
    say "检测到当前目录已有项目文件，复制到：$app_dir"
    rm -rf "$app_dir"
    mkdir -p "$app_dir"
    cp -a . "$app_dir/"
  else
    say "克隆公开仓库：$repo_url"
    rm -rf "$app_dir"
    mkdir -p "$(dirname "$app_dir")"
    git clone "$repo_url" "$app_dir"
  fi
}

fetch_latest_gemini_bl() {
  python3 - <<'PY' 2>/dev/null || true
import re, urllib.request
req=urllib.request.Request('https://gemini.google.com/app', headers={'User-Agent':'Mozilla/5.0','Accept':'text/html,application/xhtml+xml'})
data=urllib.request.urlopen(req, timeout=30).read().decode('utf-8','ignore')
vals=sorted(set(re.findall(r'boq_assistant-bard-web-server_[A-Za-z0-9._-]+', data)))
if vals:
    print(vals[-1])
PY
}

write_node_adapter() {
  local dir="$1"
  python3 - "$dir/worker.js" "$dir/worker.local.mjs" <<'PY'
import pathlib, sys, re
src=pathlib.Path(sys.argv[1]).read_text()
# Cloudflare Workers 专属模块在 Node 本地不可用，移除静态 import，并让代码自动走 fetch 回退。
src=re.sub(r"^import\s+\{\s*connect\s*\}\s+from\s+['\"]cloudflare:sockets['\"];\s*\n", "", src, flags=re.M)
src="const connect = undefined;\n" + src
pathlib.Path(sys.argv[2]).write_text(src)
PY

  cat > "$dir/server.mjs" <<'EOF_NODE'
import http from 'node:http';
import worker from './worker.local.mjs';

const PORT = Number(process.env.PORT || 7861);
const HOST = process.env.HOST || '127.0.0.1';

function toWebRequest(req, body) {
  const proto = req.headers['x-forwarded-proto'] || 'http';
  const host = req.headers.host || `127.0.0.1:${PORT}`;
  const url = `${proto}://${host}${req.url}`;
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) {
    if (Array.isArray(v)) headers.set(k, v.join(', '));
    else if (v !== undefined) headers.set(k, String(v));
  }
  return new Request(url, {
    method: req.method,
    headers,
    body: ['GET','HEAD'].includes(req.method || 'GET') ? undefined : body,
  });
}

async function sendWebResponse(res, webResp) {
  res.statusCode = webResp.status;
  webResp.headers.forEach((v, k) => res.setHeader(k, v));
  const ab = await webResp.arrayBuffer();
  res.end(Buffer.from(ab));
}

const server = http.createServer(async (req, res) => {
  try {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = chunks.length ? Buffer.concat(chunks) : undefined;
    const webReq = toWebRequest(req, body);
    const webResp = await worker.fetch(webReq, process.env, {});
    await sendWebResponse(res, webResp);
  } catch (e) {
    console.error('[gemini-web2api] request failed:', e);
    res.statusCode = 500;
    res.setHeader('content-type', 'application/json; charset=utf-8');
    res.end(JSON.stringify({ error: { message: String(e?.message || e) } }));
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[gemini-web2api] listening on http://${HOST}:${PORT}`);
});
EOF_NODE
}

write_service() {
  local dir="$1" service="$2" port="$3" api_key="$4" bl="$5" bind_public="$6"
  local host="127.0.0.1"
  if [ "$bind_public" = "yes" ]; then host="0.0.0.0"; fi

  as_root tee "/etc/${service}.env" >/dev/null <<EOF_ENV
HOST=${host}
PORT=${port}
API_KEYS=${api_key}
DEFAULT_MODEL=${DEFAULT_MODEL}
LOG_REQUESTS=true
UPSTREAM_SOCKET=false
GEMINI_BL=${bl}
GEMINI_ORIGIN=https://gemini.google.com
EOF_ENV
  as_root chmod 600 "/etc/${service}.env"

  as_root tee "/etc/systemd/system/${service}.service" >/dev/null <<EOF_UNIT
[Unit]
Description=Gemini Web2API local OpenAI-compatible server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${dir}
EnvironmentFile=/etc/${service}.env
ExecStart=$(command -v node) ${dir}/server.mjs
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF_UNIT

  as_root systemctl daemon-reload
  as_root systemctl enable --now "${service}.service"
}

install_nginx_certbot() {
  say "安装 nginx + certbot"
  if need_cmd apt-get; then
    pm_install nginx certbot python3-certbot-nginx
  elif need_cmd dnf; then
    as_root dnf install -y epel-release || true
    as_root dnf install -y nginx certbot python3-certbot-nginx
  elif need_cmd yum; then
    as_root yum install -y epel-release || true
    as_root yum install -y nginx certbot python3-certbot-nginx
  else
    err "未找到支持的包管理器，无法安装 nginx/certbot"
    exit 1
  fi
  as_root systemctl enable --now nginx
}

setup_domain_tls() {
  local domain="$1" email="$2" service="$3" port="$4"
  install_nginx_certbot

  say "写入 nginx 反代配置：$domain -> 127.0.0.1:$port"
  as_root tee "/etc/nginx/sites-available/${domain}.conf" >/dev/null <<EOF_NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF_NGINX
  as_root ln -sf "/etc/nginx/sites-available/${domain}.conf" "/etc/nginx/sites-enabled/${domain}.conf"
  as_root nginx -t
  as_root systemctl reload nginx

  say "申请 Let's Encrypt 免费证书"
  if [ -n "$email" ]; then
    as_root certbot --nginx -d "$domain" --non-interactive --agree-tos -m "$email" --redirect
  else
    as_root certbot --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email --redirect
  fi

  say "启用/检查证书自动续期"
  as_root systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  as_root certbot renew --dry-run || warn "certbot renew dry-run 未通过，请检查域名 DNS 是否已解析到本机公网 IP。"
}

test_service() {
  local port="$1" key="$2" url_base="$3"
  say "测试模型列表"
  curl -sS -m 30 "${url_base}/v1/models" -H "Authorization: Bearer ${key}" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print("models", len(d.get("data",[]))); print("\n".join(m.get("id","") for m in d.get("data",[])[:20]))'

  say "测试聊天接口"
  curl -sS -m 120 -w '\nHTTP:%{http_code}\n' \
    -H "Authorization: Bearer ${key}" \
    -H 'Content-Type: application/json' \
    -d '{"model":"gemini-3.5-flash","messages":[{"role":"user","content":"只回复 OK"}],"stream":false,"max_tokens":20}' \
    "${url_base}/v1/chat/completions"
}

main() {
  install_base_deps

  ask REPO_URL "公开仓库地址" "$REPO_URL_DEFAULT"
  ask APP_DIR "安装目录" "$APP_DIR_DEFAULT"
  ask SERVICE_NAME "服务名" "$SERVICE_NAME_DEFAULT"
  ask PORT "监听端口" "$PORT_DEFAULT"
  ask DEFAULT_MODEL "默认模型" "$DEFAULT_MODEL_DEFAULT"
  ask_secret_or_generate API_KEY "设置调用 API Key" "$(random_key)"
  ask_yes_no BIND_DOMAIN "是否绑定域名并申请免费证书？" "no"

  DOMAIN=""
  EMAIL=""
  PUBLIC_BIND="yes"
  if [ "$BIND_DOMAIN" = "yes" ]; then
    ask DOMAIN "请输入域名，例如 gemini.example.com（需已解析到本机 IP）" ""
    ask EMAIL "证书通知邮箱（可留空）" ""
    PUBLIC_BIND="no"
  else
    ask_yes_no PUBLIC_BIND "不绑定域名时，是否直接监听公网 0.0.0.0？" "yes"
  fi

  clone_or_update_project "$REPO_URL" "$APP_DIR"
  [ -f "$APP_DIR/worker.js" ] || { err "worker.js 不存在：$APP_DIR/worker.js"; exit 1; }

  latest_bl="$(fetch_latest_gemini_bl || true)"
  GEMINI_BL="${GEMINI_BL:-${latest_bl:-$GEMINI_BL_FALLBACK}}"
  say "使用 GEMINI_BL=$GEMINI_BL"

  write_node_adapter "$APP_DIR"
  write_service "$APP_DIR" "$SERVICE_NAME" "$PORT" "$API_KEY" "$GEMINI_BL" "$PUBLIC_BIND"

  URL_BASE="http://127.0.0.1:${PORT}"
  if [ "$BIND_DOMAIN" = "yes" ]; then
    setup_domain_tls "$DOMAIN" "$EMAIL" "$SERVICE_NAME" "$PORT"
    URL_BASE="https://${DOMAIN}"
  elif [ "$PUBLIC_BIND" = "yes" ]; then
    URL_BASE="http://服务器IP:${PORT}"
  fi

  test_service "$PORT" "$API_KEY" "http://127.0.0.1:${PORT}"

  echo
  say "部署完成"
  echo "服务名：${SERVICE_NAME}"
  echo "本机接口：http://127.0.0.1:${PORT}/v1"
  if [ "$BIND_DOMAIN" = "yes" ]; then
    echo "公网接口：https://${DOMAIN}/v1"
  elif [ "$PUBLIC_BIND" = "yes" ]; then
    echo "公网接口：http://服务器IP:${PORT}/v1"
  else
    echo "公网接口：未开放；仅本机可访问。"
  fi
  echo "API Key：${API_KEY}"
  echo
  echo "测试命令："
  cat <<EOF_TEST
curl ${URL_BASE}/v1/chat/completions \\
  -H "Authorization: Bearer ${API_KEY}" \\
  -H "Content-Type: application/json" \\
  -d '{"model":"gemini-3.5-flash","messages":[{"role":"user","content":"你好"}]}'
EOF_TEST
  echo
  echo "查看日志：journalctl -u ${SERVICE_NAME} -f"
}

main "$@"
