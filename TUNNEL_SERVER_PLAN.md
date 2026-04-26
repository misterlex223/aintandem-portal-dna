# 自建隧道服務實施計劃

## 需求背景

- **問題**: 在中國境內使用 Cloudflare Tunnel 速度慢
- **目標**: 搭建自己的隧道主機管理多個沙盒
- **要求**: 每個沙盒有獨立子域名，沙盒無 public port（安全性）

## 選擇技術: frp (Fast Reverse Proxy)

**選擇理由**:
- 沙盒主動連出（不需暴露 public port）
- 原生支持子域名自動分配
- 支持多租戶 token 認證
- 性能好，中文文檔完善
- 可用 API 動態管理代理

## 架構設計

```
┌─────────────────────────────────────────────────────────────────┐
│                          外部用戶                                │
└────────────────────────────┬────────────────────────────────────┘
                             │ HTTPS :443
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  阿里雲主機 (<your-server-ip>)                                       │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Nginx (443) → Let's Encrypt SSL                          │  │
│  │     ↓                                                     │  │
│  │  *.tunnel.yourdomain.com → frps :7000                    │  │
│  │     ↓                                                     │  │
│  │  frps (Fast Reverse Proxy Server)                        │  │
│  │     - 根據子域名路由到對應客戶端                           │  │
│  │     - 支持認證 token                                       │  │
│  └───────────────────────────────────────────────────────────┘  │
└────────────────────────────┬────────────────────────────────────┘
                             │ frp protocol :7000
                             ▲
                    主動連接（沙盒連出）
                             │
┌────────────────────────────┴────────────────────────────────────┐
│  各雲端沙盒 (運行 frpc 客戶端)                                    │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐        │
│  │ 沙盒 A         │  │ 沙盒 B         │  │ 沙盒 C         │        │
│  │ sandbox-a.tunnel│  │ sandbox-b.tunnel│  │ sandbox-c.tunnel│        │
│  │ :本地端口      │  │ :本地端口      │  │ :本地端口      │        │
│  └───────────────┘  └───────────────┘  └───────────────┘        │
└─────────────────────────────────────────────────────────────────┘
```

## 實施步驟

### 階段一：阿里雲服務端配置

#### 1. 安全組設置

阿里雲控制台開放以下端口：
| 端口 | 協議 | 用途 |
|------|------|------|
| 80 | TCP | HTTP (ACME 驗證) |
| 443 | TCP | HTTPS |
| 7000 | TCP | frp 服務端口 |

#### 2. 安裝 frps

```bash
# 下載 frp (v0.60.0 或最新版)
wget https://github.com/fatedier/frp/releases/download/v0.60.0/frp_0.60.0_linux_amd64.tar.gz
tar -xzf frp_*.tar.gz
sudo cp frp_*/frps /usr/local/bin/

# 創建配置目錄
sudo mkdir -p /etc/frp
```

#### 3. frps 配置 (`/etc/frp/frps.toml`)

```toml
# frps 服務端配置
bindPort = 7000

# 虛擬主機 HTTP 端口 (Nginx 會轉發到這裡)
vhostHTTPPort = 8080

# 認證 token (請修改為強密碼)
auth.token = "CHANGE_ME_SECURE_TOKEN_HERE"

# 子域名域名 (不需要包含通配符)
subdomainHost = "tunnel.yourdomain.com"

# 儀表板 (可選，用於監控)
[webServer]
addr = "127.0.0.1"
port = 7500
user = "admin"
password = "CHANGE_ME_DASHBOARD_PASSWORD"

# 日誌配置
[log]
to = "/var/log/frp/frps.log"
level = "info"
maxDays = 7
```

#### 4. Nginx 反向代理 (`/etc/nginx/sites-available/tunnel`)

```nginx
# 隧道服務 HTTP (用於 ACME 驗證)
server {
    listen 80;
    server_name *.tunnel.yourdomain.com;

    # Let's Encrypt 驗證
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # 其他請求重定向到 HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}

# 隧道服務 HTTPS
server {
    listen 443 ssl http2;
    server_name *.tunnel.yourdomain.com;

    # SSL 憑證配置
    ssl_certificate /etc/letsencrypt/live/tunnel.yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/tunnel.yourdomain.com/privkey.pem;

    # SSL 安全配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # 日誌
    access_log /var/log/nginx/tunnel_access.log;
    error_log /var/log/nginx/tunnel_error.log;

    # 轉發到 frps
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        # 超時設置
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
```

#### 5. 獲取 SSL 憑證

```bash
# 安裝 certbot
sudo apt update
sudo apt install certbot python3-certbot-nginx -y

# 創建 webroot
sudo mkdir -p /var/www/certbot

# 獲取憑證 (替換為你的域名)
sudo certbot certonly --webroot \
  -w /var/www/certbot \
  -d "*.tunnel.yourdomain.com" \
  --email your@email.com \
  --agree-tos \
  --no-eff-email

# 測試自動續期
sudo certbot renew --dry-run
```

#### 6. 創建 systemd 服務 (`/etc/systemd/system/frps.service`)

```ini
[Unit]
Description=frp server service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

啟動服務：
```bash
sudo systemctl daemon-reload
sudo systemctl enable frps
sudo systemctl start frps
sudo systemctl status frps
```

### 階段二：沙盒客戶端配置

#### frpc 配置模板

```toml
# frpc 客戶端配置
serverAddr = "<your-server-ip>"
serverPort = 7000
auth.token = "CHANGE_ME_SECURE_TOKEN_HERE"

# HTTP 代理配置
[[proxies]]
name = "web-service"
type = "http"
localIP = "127.0.0.1"
localPort = 3000
subdomain = "sandbox-name"  # → sandbox-name.tunnel.yourdomain.com

# 可選：TCP 代理 (如 SSH)
[[proxies]]
name = "ssh-service"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6001  # 需在 frps 配置中允許
```

#### Docker 運行 frpc

```yaml
version: '3.8'
services:
  frpc:
    image: snowdreamtech/frpc:0.60.0
    container_name: frpc
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./frpc.toml:/etc/frp/frpc.toml:ro
```

### 階段三：驗收測試

```bash
# 1. 檢查 frps 服務狀態
sudo systemctl status frps

# 2. 檢查 Nginx 配置
sudo nginx -t
sudo systemctl reload nginx

# 3. 測試沙盒連接
# 在沙盒上啟動 frpc 後，訪問:
curl https://sandbox-name.tunnel.yourdomain.com

# 4. 檢查 frps 日誌
sudo tail -f /var/log/frp/frps.log

# 5. 檢查 Nginx 日誌
sudo tail -f /var/log/nginx/tunnel_access.log
```

## DNS 配置

在域名 DNS 管理中添加：

| 類型 | 名稱 | 值 |
|------|------|-----|
| A | *.tunnel | <your-server-ip> |

## 安全考量

| 項目 | 措施 |
|------|------|
| 認證 | 每個 frpc 連接需要 token |
| 隔離 | 每個沙盒只能訪問自己的本地端口 |
| 速率限制 | Nginx 層可配置 limit_req |
| 防火牆 | 只開放必要端口 |
| 日誌 | frps 和 Nginx 訪問日誌記錄 |

## 常用管理命令

```bash
# 查看連接的客戶端
sudo journalctl -u frps -f

# 重啟 frps
sudo systemctl restart frps

# 更新 frp 版本
sudo systemctl stop frps
sudo cp frp_*/frps /usr/local/bin/
sudo systemctl start frps

# 查看 Nginx 訪問日誌
sudo tail -f /var/log/nginx/tunnel_access.log
```

## 擴展功能 (可選)

1. **frp 儀表板**: 通過 nginx 反向代理訪問 `127.0.0.1:7500`
2. **Prometheus 監控**: frps 支持 Prometheus metrics
3. **API 管理**: 使用 frp API 動態添加/刪除代理

## 故障排查

```bash
# 檢查端口監聽
sudo netstat -tlnp | grep -E ':(80|443|7000|8080)'

# 檢查 frps 連接
sudo ss -tunlp | grep frps

# 測試本地 frps
curl -H "Host: test.tunnel.yourdomain.com" http://127.0.0.1:8080

# 檢查防火牆
sudo ufw status
```

## 伺服器信息

- **主機**: root@<your-server-ip>
- **私鑰**: <path/to/your/private-key.pem>
- **系統**: Ubuntu 22.04 (Linux 5.15.0-174-generic)
