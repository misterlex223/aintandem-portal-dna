# FRP Tunnel - 遠端主機初始化

一鍵初始化遠端主機環境並部署 FRP Tunnel 服務。

## 功能

- ✅ 自動檢測和安裝 Docker
- ✅ 配置國內 Docker 鏡像源
- ✅ 檢查防火牆/安全組配置
- ✅ **檢查點系統** - 支援斷點續傳
- ✅ **進度顯示** - 清晰的階段提示
- ✅ **錯誤恢復** - 失敗後可繼續

## 使用方式

### 從本地部署 (推薦)

```bash
cd scripts
./deploy-remote.sh 8.163.40.165
```

使用自定義 SSH 配置：

```bash
./deploy-remote.sh -u admin -p 2222 -i ~/.ssh/mykey your-server.com
```

### 在遠端主機直接執行

```bash
# 上傳腳本到遠端
scp scripts/remote-init/bootstrap.sh root@8.163.40.165:/root/

# SSH 登入執行
ssh root@8.163.40.165
bash /root/bootstrap.sh
```

## 部署階段

腳本會依序執行以下階段：

| 階段 | 說明 | 檢查點 |
|------|------|--------|
| 1. 系統檢查 | 檢查 OS、架構、網路 | ✅ |
| 2. Docker 檢查 | 檢查 Docker 是否已安裝 | ✅ |
| 3. Docker 安裝 | 自動安裝 Docker | ✅ |
| 4. 鏡像源配置 | 配置國內鏡像源 | ✅ |
| 5. Docker Compose | 檢查 Docker Compose | ✅ |
| 6. 防火牆檢查 | 檢查端口是否開放 | ✅ |
| 7. 工作目錄 | 創建 /root/frp-tunnel | ✅ |
| 8. 上傳腳本 | 複製安裝腳本 | ✅ |
| 9. 執行安裝 | 運行 server/install.sh | ✅ |

## 斷點續傳

如果部署中斷（網路問題、手動中斷等），重新運行腳本會自動從失敗的階段繼續：

```bash
# 首次運行，階段 4 失敗
./deploy-remote.sh 8.163.40.165
# → 失敗在 "配置 Docker 鏡像源"

# 修復問題後重新運行，自動跳過已完成階段
./deploy-remote.sh 8.163.40.165
# → 從階段 4 繼續
```

狀態保存在：`/var/lib/frp-tunnel/bootstrap.state`

## 必要條件

### 遠端主機

- **OS**: Ubuntu 20.04+, Debian 10+, CentOS 7+, Rocky Linux 8+, Alpine 3+
- **架構**: x86_64 (amd64) 或 ARM64
- **權限**: root 或 sudo
- **網路**: 可訪問外網

### 需開放的端口

| 端口 | 協議 | 用途 |
|------|------|------|
| 22 | TCP | SSH |
| 80 | TCP | HTTP |
| 443 | TCP | HTTPS |
| 7000 | TCP | FRP 協議 |
| 7500 | TCP | Dashboard (可選) |

⚠️ **阿里雲用戶**: 記得在**安全組**中開放以上端口。

### 本地機器

- SSH 客戶端
- 對遠端主機的 SSH 訪問權限

## 錯誤處理

### Docker 安裝失敗

```
[✗] Docker 安裝失敗
```

**解決方案**:
- 檢查 OS 版本是否支援
- 手動安裝 Docker: https://docs.docker.com/get-docker/

### 防火牆檢查失敗

```
[!] 以下端口需要在 firewalld 中開放:
  - 80/tcp
  - 443/tcp
```

**解決方案**:
```bash
# firewalld
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=7000/tcp
firewall-cmd --permanent --add-port=7500/tcp
firewall-cmd --reload

# 或 ufw
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 7000/tcp
ufw allow 7500/tcp
```

### DNS 未生效

如果部署完成但無法訪問子域名：

1. 確認 DNS 記錄已正確添加
2. 等待 DNS 傳播 (可能需要 5-30 分鐘)
3. 清除本地 DNS 緩存

## 完成後

部署成功後會顯示：

```
[✓] 遠端主機初始化完成！

工作目錄: /root/frp-tunnel
配置文件: /root/frp-tunnel/server/.env

管理命令:
  cd /root/frp-tunnel/server
  ./manage.sh status    # 查看狀態
  ./manage.sh logs      # 查看日誌
```

## 重置部署

如需完全重新部署：

```bash
ssh root@8.163.40.165
rm -rf /root/frp-tunnel /var/lib/frp-tunnel
exit

# 重新運行部署
./deploy-remote.sh 8.163.40.165
```
