# DNA & RNA 設計概念

## 概念

這個項目使用生物學隱喻來管理 FRP Tunnel 部署：

- **DNA** (aintandem-portal-dna) - 包含所有部署腳本和配置模板
- **RNA** (unclemon-studio-portal-rna) - 從 DNA 生成並部署的具體實例

## DNA (Deoxyribonucleic Acid)

**定位：** 基因代碼，包含部署所需的所有信息

**目錄：** `~/workspace/aintandem-portal-dna`

**內容：**
```
scripts/
├── deploy-remote.sh       # 一鍵遠端部署
├── remote-init/           # 遠端主機初始化
│   └── bootstrap.sh      # 引導腳本，檢查點恢復
├── server/                # 服務端腳本
│   ├── install.sh        # 一鍵安裝
│   ├── manage.sh         # 管理腳本
│   ├── docker-compose.yml
│   └── configs/          # 配置模板
├── client/                # 客戶端腳本
└── shared/                # 共用工具
```

**特點：**
- 可重複使用
- 參數化配置
- 版本控制
- 無狀態

## RNA (Ribonucleic Acid)

**定位：** 從 DNA 轉錄並生成的實際部署實例

**目錄：** `~/workspace/unclemon-studio-portal-rna`

**內容：**
```
.proxy.env        # Proxy 配置（敏感，不進 git）
regenerate.sh     # RNA 再生腳本（細胞更新）
README.md         # 實例具體配置
status.sh         # 狀態檢查腳本
```

**特點：**
- 特定於某個實例
- 包含實際配置（域名、IP、Token）
- 包含敏感信息（proxy 配置）
- 可被「銷毀並再生」

## 設計原則

### 1. 單向數據流
```
DNA ──轉錄──→ RNA ──翻譯──→ 蛋白質 (運行中的服務)
```
- DNA → RNA：可重複
- RNA → 服務：可重啟
- 服務 → DNA：**不可逆**（運行中修改不應直接改 DNA）

### 2. 實例隔離
- 每個 RNA 代表一個獨立的 FRP 服務器實例
- 多個 RNA 可以從同一個 DNA 生成
- RNA 之間完全獨立

### 3. 細胞更新（Cell Renewal）
```bash
# RNA 提供的再生腳本
cd ~/workspace/unclemon-studio-portal-rna
./regenerate.sh
```

流程：
1. 停止舊實例
2. 從 DNA 重新部署
3. 恢復配置（從 RNA 的 README.md 和 .proxy.env）

### 4. 基因突變（升級）
- 更新 DNA 中的腳本
- 使用 `regenerate.sh` 應用到現有 RNA
- 不破壞已部署的實例

## 使用模式

### 部署新實例
```bash
cd ~/workspace/aintandem-portal-dna/scripts
./deploy-remote.sh -d tunnel.example.com your-server.com
```

### 維護現有實例
```bash
cd ~/workspace/unclemon-studio-portal-rna
./regenerate.sh    # 細胞更新
./status.sh        # 檢查狀態
```

### 更新 DNA
```bash
# 修改 DNA 腳本後
cd ~/workspace/unclemon-studio-portal-rna
./regenerate.sh    # 應用更新
```

## 命名約定

| 概念 | 生物學術語 | 技術對應 |
|------|------------|----------|
| DNA | 基因 | 部署腳本庫 |
| RNA | RNA | 具體實例配置 |
| 蛋白質 | 蛋白質 | 運行中的服務 |
| 細胞更新 | Cell renewal | 重新部署 |
| 基因突變 | Mutation | 腳本升級 |
| 轉錄 | Transcription | 生成實例 |
| 翻譯 | Translation | 啟動服務 |

## 擴展指南

當添加新實例時：

1. **創建新 RNA 目錄**
   ```bash
   mkdir -p ~/workspace/<instance-name>-rna
   ```

2. **添加 README.md**
   ```markdown
   # RNA: <instance-name>
   
   Generated from DNA: ~/workspace/aintandem-portal-dna
   
   ## Instance Details
   - Domain: ...
   - Host: ...
   - SSH Key: ...
   ```

3. **添加 regenerate.sh**
   ```bash
   #!/bin/bash
   DNA_DIR="~/workspace/aintandem-portal-dna"
   # ... 部署邏輯
   ```

4. **添加 .proxy.env**（如需要）
   ```bash
   FRP_PROXY_VLESS="vless://..."
   ```

這個架構確保：
- DNA 作�為單一事實來源
- RNA 作為實例特定配置
- 清晰的數據流向
- 易於維護和擴展
