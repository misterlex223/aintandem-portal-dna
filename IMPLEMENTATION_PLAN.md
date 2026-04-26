# FRP Tunnel 自動化部署腳本方案

## Context

在中國境內使用 Cloudflare Tunnel 速度慢，需要自建隧道服務。本方案將 frp tunnel server 和客戶端的部署過程腳本化，實現一鍵部署和快速複製。

## 架構設計

```
scripts/
├── server/                    # 服務端腳本 (Docker Compose)
│   ├── install.sh            # 一鍵安裝腳本
│   ├── docker-compose.yml    # frps + nginx 容器編排
│   ├── configs/
│   │   ├── frps.toml         # frps 配置模板
│   │   └── nginx.conf        # nginx 反向代理配置
│   └── manage.sh             # 管理腳本 (啟動/停止/狀態)
│
├── client/                    # 客戶端腳本 (二進製)
│   ├── install.sh            # 一鍵安裝腳本
│   ├── configs/
│   │   └── frpc.toml         # frpc 配置模板
│   └── manage.sh             # 管理腳本
│
└── shared/
    ├── utils.sh              # 共用函數庫
    └── .env.template         # 環境變量模板
```

## 實施計劃

### 階段一：服務端腳本 (Docker Compose)

**文件結構**:
```
scripts/server/
├── install.sh              # 主安裝腳本
├── docker-compose.yml      # 容器編排
├── manage.sh               # 管理腳本
├── configs/
│   ├── frps.toml.template
│   └── nginx.conf.template
└── .env.template
```

**install.sh 功能**:
1. 檢查 Docker 和 Docker Compose 是否安裝
2. 詢問/讀取配置（域名、token、端口等）
3. 生成 frps.toml 和 nginx.conf
4. 配置防火牆/安全組提示
5. 啟動容器

**docker-compose.yml 服務**:
- `frps`: frp 服務端容器
- `nginx`: 反向代理容器（處理 SSL 和子域名路由）
- `certbot`: SSL 憑證獲取和自動續期

### 階段二：客戶端腳本 (二進製)

**文件結構**:
```
scripts/client/
├── install.sh              # 主安裝腳本
├── manage.sh               # 管理腳本
├── configs/
│   └── frpc.toml.template
└── .env.template
```

**install.sh 功能**:
1. 檢測系統架構 (amd64/arm64)
2. 下載對應架構的 frpc 二進製
3. 讀取配置文件生成 frpc.toml
4. 創建 systemd 服務
5. 啟動服務

### 階段三：配置管理

**沙盒配置文件格式** (`/etc/frp/sandbox.d/<name>.conf`):
```toml
sandbox_name = "my-sandbox"
server_addr = "<your-server-ip>"
server_port = 7000
auth_token = "secure-token"

[[proxies]]
name = "web"
type = "http"
local_ip = "127.0.0.1"
local_port = 3000
subdomain = "my-sandbox"
```

### 階段四：管理工具

**manage.sh 功能**:
- `./manage.sh status` - 查看所有沙盒連接狀態
- `./manage.sh add <name> <port>` - 添加新沙盒代理
- `./manage.sh remove <name>` - 移除沙盒代理
- `./manage.sh logs <name>` - 查看沙盒日誌

## 關鍵文件

### 新建文件

| 路徑 | 說明 |
|------|------|
| `scripts/server/install.sh` | 服務端一鍵安裝 |
| `scripts/server/docker-compose.yml` | Docker Compose 編排 |
| `scripts/server/configs/frps.toml.template` | frps 配置模板 |
| `scripts/server/configs/nginx.conf.template` | nginx 配置模板 |
| `scripts/client/install.sh` | 客戶端一鍵安裝 |
| `scripts/client/configs/frpc.toml.template` | frpc 配置模板 |
| `scripts/shared/utils.sh` | 共用函數 |
| `scripts/shared/.env.template` | 環境變量模板 |

## 驗證步驟

### 服務端驗證
```bash
# 1. 執行安裝
cd scripts/server
sudo ./install.sh

# 2. 檢查容器狀態
docker-compose ps

# 3. 檢查日誌
docker-compose logs -f frps

# 4. 測試本地連接
curl -H "Host: test.tunnel.domain.com" http://localhost:8080
```

### 客戶端驗證
```bash
# 1. 配置並安裝
cd scripts/client
sudo ./install.sh --server <your-server-ip> --subdomain test --port 3000

# 2. 檢查服務狀態
systemctl status frpc@test

# 3. 測試外網訪問
curl https://test.tunnel.yourdomain.com
```

## 執行順序

1. ✅ 創建目錄結構
2. ✅ 編寫共用函數庫 (utils.sh)
3. ✅ 編寫服務端腳本和配置
4. ✅ 編寫客戶端腳本和配置
5. ✅ 編寫管理工具
6. ⏳ 測試和驗證 (待執行)

---

## 實施狀態: 已完成 ✅

所有腳本和配置文件已創建，待在阿里雲服務器上進行實際部署測試。
