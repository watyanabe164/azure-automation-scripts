# azure-automation-scripts
AzureAutomationでの自動化スクリプト集

## Runbook: Shutdown-Orchestrator
マルチレイヤー（WEB→APP→DB）の停止を順序制御し、
"(1) LB/AGW から切り離す → (2) ゲスト内でサービス停止 → (3) VM停止/割り当て解除" の順序で実行するRunbookです。

### 主な特徴
- タグ（`ShutdownOrder`）またはJSON設定で停止順序を管理
- 同一 order のVMは並列停止可能（PowerShell 7ランタイム想定）
- VM Run CommandでゲストOS内のサービス停止を実行
- 失敗時リトライ/タイムアウト/冪等性を考慮

### 使い方（タグ運用）
VMにタグを付与して順序を管理します。

```
ShutdownOrder = 10
Role          = WEB
ProbePath     = C:\inetpub\wwwroot\health.html
ProbeRenameTo = health.off
```

Runbookパラメータ例：
```
ResourceGroupName = "rg-app"
UseTagOrder       = true
ParallelWithinOrder = true
```

### 使い方（JSON運用）
Automation Variable などにJSONを保存し、`ConfigJson`に渡します。

```
{
  "vms": [
    {
      "name": "web-01",
      "order": 10,
      "role": "WEB",
      "probePath": "C:\\inetpub\\wwwroot\\health.html",
      "probeRenameTo": "health.off",
      "serviceNames": ["W3SVC", "WAS"],
      "timeoutSec": 900,
      "retries": 2
    },
    {
      "name": "app-01",
      "order": 20,
      "role": "APP",
      "serviceNames": ["AppService", "Schedule"]
    },
    {
      "name": "db-01",
      "order": 30,
      "role": "DB",
      "serviceNames": ["MSSQLSERVER", "SQLSERVERAGENT"]
    }
  ]
}
```

### 注意事項
- `ProbePath` を指定すると Run Command でプローブ用ファイルをリネームし、
  AGW/LBの正常性プローブを意図的に落とします。
- Linux VMの場合は `systemctl stop/disable` を使用します。
- 役割ごとの停止サービスは環境に合わせて `serviceNames` で調整してください。
