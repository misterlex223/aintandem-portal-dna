# 開發主機模板

此模板用於部署開發主機實例，包含 FRP client 和開發環境容器。

## 服務

- **frpc**: FRP client，連接到 portal FRP server
- **dev-sandbox**: 開發環境容器（預設為 chromium-ai-sandbox）

## 環境變數

必須配置的環境變數見對應實例的 `.env.example`。

## 網路

兩個服務透過 `flexy-net` 橋接網路互相通訊。
