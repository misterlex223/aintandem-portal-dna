# FRP Tunnel 自動化部署腳本

在中國境內快速部署自建隧道服務，替代 Cloudflare Tunnel。

## 架構

```
外部用戶 → HTTPS (443) → 阿里雲 (Nginx + frps) ← FRP 協議 ← 沙盒 (frpc)
                                    ↓
                              *.tunnel.yourdomain.com
```

## 快速開始

### 服務端部署 (阿里雲)

```bash
cd scripts/server
sudo ./install.sh
```

安裝腳本會引導你配置：
- 隧道域名（如 `tunnel.yourdomain.com`）
- 認證 Token
- SSL 憑證（Let's Encrypt）

### 客戶端部署 (沙盒)

```bash
cd scripts/client
sudo ./install.sh \
    --server <your-server-ip> \
    --token your-auth-token \
    --name myapp \
    --subdomain myapp \
    --local-port 3000
```

## 目錄結構

```
scripts/
├── server/              # 服務端腳本
│   ├── install.sh      # 一鍵安裝
│   ├── manage.sh       # 管理腳本
│   ├── docker-compose.yml
│   └── configs/        # 配置模板
├── client/              # 客戶端腳本
│   ├── install.sh      # 一鍵安裝
│   ├── manage.sh       # 管理腳本
│   └── configs/        # 配置模板
└── shared/              # 共用工具
    ├── utils.sh        # 共用函數
    └── .env.template   # 環境變量模板
```

## 服務端管理

```bash
cd scripts/server
./manage.sh status      # 查看狀態
./manage.sh logs        # 查看日誌
./manage.sh restart     # 重啟服務
./manage.sh config      # 查看配置
./manage.sh backup      # 備份配置
./manage.sh update      # 更新版本
```

## 客戶端管理

```bash
cd scripts/client
sudo ./manage.sh list                # 列出所有客戶端
sudo ./manage.sh status myapp        # 查看狀態
sudo ./manage.sh logs myapp          # 查看日誌
sudo ./manage.sh add                 # 交互式添加
sudo ./manage.sh remove myapp        # 移除客戶端
```

## DNS 配置

在域名 DNS 管理中添加：

| 類型 | 名稱 | 值 |
|------|------|-----|
| A | *.tunnel | 服務器 IP |

## 端口需求

### 服務端需要開放：
- `80` - HTTP (ACME 驗證)
- `443` - HTTPS
- `7000` - FRP 協議

### 客戶端：
- 無需開放任何端口（主動連出）

## 配置文件位置

### 服務端：
- 服務目錄: `scripts/server/`
- 配置文件: `scripts/server/.env`
- 日誌目錄: `scripts/server/logs/`

### 客戶端：
- 配置目錄: `/etc/frp/`
- 二進製: `/usr/local/bin/frpc`
- 服務名: `frpc@<name>`

## 故障排查

### 服務端

```bash
# 檢查容器狀態
docker compose ps

# 查看日誌
./manage.sh logs frps
./manage.sh logs nginx

# 重啟服務
./manage.sh restart
```

### 客戶端

```bash
# 檢查服務狀態
systemctl status frpc@myapp

# 查看日誌
journalctl -u frpc@myapp -f

# 測試連接
curl https://myapp.tunnel.yourdomain.com
```

## 常見問題

**Q: SSL 憑證獲取失敗？**
- 確保 DNS 已正確配置
- 確保端口 80 可訪問
- 檢查域名是否正確

**Q: 客戶端連接失敗？**
- 檢查服務器防火牆/安全組
- 確認 Token 是否正確
- 檢查服務端是否運行

**Q: 子域名無法訪問？**
- 確認 DNS 通配符記錄已配置
- 檢查 Nginx 配置中的域名
- 查看服務端日誌

## 安全建議

1. 使用強密碼作為 Auth Token
2. 定期更新 frp 版本
3. 監控訪問日誌
4. 限制訪問來源 IP（如需要）

## 授權

MIT License
