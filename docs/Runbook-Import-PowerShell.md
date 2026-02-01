# Azure Automation Runbook import (PowerShell)

このドキュメントは PowerShell を使って runbook を import / publish する手順を説明します。

## 前提条件
- Az PowerShell モジュールがインストール済み
- 対象サブスクリプションへのアクセス権

## 手順

### 1) サインインしてサブスクリプションを選択
```powershell
Connect-AzAccount
Set-AzContext -Subscription "<SUBSCRIPTION_ID_OR_NAME>"
```

### 2) Runbook を import
```powershell
$importParams = @{
  AutomationAccountName = "<AUTOMATION_ACCOUNT>"
  ResourceGroupName     = "<RESOURCE_GROUP>"
  Name                  = "Shutdown-Orchestrator"
  Type                  = "PowerShell"
  Path                  = "C:\Users\user\Documents\work\azure-automation-scripts\runbooks\Shutdown-Orchestrator.ps1"
  # Force               = $true  # 同名 runbook がある場合に上書きする
}
Import-AzAutomationRunbook @importParams
```

### 3) Runbook を publish
```powershell
$publishParams = @{
  AutomationAccountName = "<AUTOMATION_ACCOUNT>"
  ResourceGroupName     = "<RESOURCE_GROUP>"
  Name                  = "Shutdown-Orchestrator"
}
Publish-AzAutomationRunbook @publishParams
```

## 補足
- Import すると **draft** が作成されるため、実行可能にするには publish が必要です。
- PowerShell 7 を使う場合は、publish 前に Automation Account で runtime version を設定してください。
