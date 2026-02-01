<#
.SYNOPSIS
  Azure Automation Runbook: Orchestrated shutdown for multi-tier VMs
.DESCRIPTION
  - Orders shutdown by tag (ShutdownOrder) or JSON config.
  - Detaches from probe (AGW/LB) by renaming probe file inside guest.
  - Executes guest stop (services/app/db) via VM Run Command.
  - Stops (deallocates) VMs after guest stop completes.
  - Supports retries, timeouts, and idempotent behavior.
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$ResourceGroupName,

  [Parameter(Mandatory = $false)]
  [string]$SubscriptionId,

  [Parameter(Mandatory = $false)]
  [string]$ConfigJson,

  [Parameter(Mandatory = $false)]
  [switch]$UseTagOrder,

  [Parameter(Mandatory = $false)]
  [switch]$ParallelWithinOrder,

  [Parameter(Mandatory = $false)]
  [int]$DefaultTimeoutSec = 900,

  [Parameter(Mandatory = $false)]
  [int]$DefaultRetryCount = 2,

  [Parameter(Mandatory = $false)]
  [int]$ThrottleLimit = 5
)

$ErrorActionPreference = 'Stop'

function Write-Log {
  param(
    [string]$Message,
    [string]$Level = 'INFO'
  )
  $timestamp = (Get-Date).ToString('s')
  Write-Output "[$timestamp][$Level] $Message"
}

function Invoke-WithRetry {
  param(
    [scriptblock]$Script,
    [int]$RetryCount = 2,
    [int]$DelaySec = 10
  )
  $attempt = 0
  while ($true) {
    try {
      $attempt++
      return & $Script
    } catch {
      if ($attempt -gt $RetryCount) {
        throw
      }
      Write-Log "Retrying after error: $($_.Exception.Message)" 'WARN'
      Start-Sleep -Seconds $DelaySec
    }
  }
}

function Get-OsType {
  param(
    [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine]$Vm
  )
  return $Vm.StorageProfile.OsDisk.OsType.ToString()
}

function Wait-JobWithTimeout {
  param(
    [System.Management.Automation.Job]$Job,
    [int]$TimeoutSec
  )

  if (-not (Wait-Job -Job $Job -Timeout $TimeoutSec)) {
    Stop-Job -Job $Job -Force | Out-Null
    throw "Run Command timed out after ${TimeoutSec}s."
  }

  $jobOutput = Receive-Job -Job $Job -ErrorAction Stop
  Remove-Job -Job $Job | Out-Null
  return $jobOutput
}

function Invoke-RunCommand {
  param(
    [string]$VmName,
    [string]$VmResourceGroup,
    [string[]]$ScriptLines,
    [int]$TimeoutSec,
    [int]$RetryCount
  )

  Invoke-WithRetry -RetryCount $RetryCount -Script {
    $job = Invoke-AzVMRunCommand -ResourceGroupName $VmResourceGroup -Name $VmName -CommandId 'RunPowerShellScript' -ScriptString $ScriptLines -AsJob
    Wait-JobWithTimeout -Job $job -TimeoutSec $TimeoutSec | Out-Null
  }
}

function Get-ProbeDisableScript {
  param(
    [string]$ProbePath,
    [string]$RenameTo
  )

  if ([string]::IsNullOrWhiteSpace($ProbePath)) {
    return @()
  }

  $target = if ([string]::IsNullOrWhiteSpace($RenameTo)) { "$ProbePath.disabled" } else { $RenameTo }
  return @(
    '$ErrorActionPreference = "Stop"',
    "if (Test-Path -Path '$ProbePath') {",
    "  Rename-Item -Path '$ProbePath' -NewName '$target' -Force",
    "  Write-Output 'Probe file renamed to disable health checks.'",
    "} else {",
    "  Write-Output 'Probe file not found; skipping rename.'",
    "}"
  )
}

function Get-DefaultStopScript {
  param(
    [string]$Role,
    [string]$OsType,
    [string[]]$ServiceNames
  )

  if ($OsType -eq 'Linux') {
    $services = if ($ServiceNames) { $ServiceNames } else { @('apache2', 'nginx', 'httpd', 'tomcat', 'app') }
    $serviceList = $services -join ' '
    return @(
      'set -e',
      "for svc in $serviceList; do",
      '  systemctl list-unit-files | grep -q "${svc}.service" || continue',
      '  systemctl stop "$svc"',
      '  systemctl disable "$svc" || true',
      'done',
      "echo 'Services stopped for role: $Role'"
    )
  }

  $defaultServices = switch ($Role) {
    'WEB' { @('W3SVC', 'WAS') }
    'APP' { @('AppService', 'Schedule') }
    'DB'  { @('MSSQLSERVER', 'SQLSERVERAGENT') }
    default { @('W3SVC') }
  }

  $servicesToStop = if ($ServiceNames) { $ServiceNames } else { $defaultServices }

  $lines = @(
    '$ErrorActionPreference = "Stop"',
    "Write-Output 'Stopping services for role: $Role'"
  )

  foreach ($svc in $servicesToStop) {
    $lines += "if (Get-Service -Name '$svc' -ErrorAction SilentlyContinue) { Stop-Service -Name '$svc' -Force }"
  }

  return $lines
}

function Get-TargetVmList {
  param(
    [string]$ResourceGroup,
    [string]$ConfigJson,
    [switch]$UseTagOrder
  )

  if (-not [string]::IsNullOrWhiteSpace($ConfigJson)) {
    $config = $ConfigJson | ConvertFrom-Json
    return $config.vms | ForEach-Object {
      [PSCustomObject]@{
        Name           = $_.name
        ResourceGroup  = if ($_.resourceGroup) { $_.resourceGroup } else { $ResourceGroup }
        Order          = [int]$_.order
        Role           = $_.role
        ProbePath      = $_.probePath
        ProbeRenameTo  = $_.probeRenameTo
        ServiceNames   = $_.serviceNames
        ScriptOverride = $_.script
        TimeoutSec     = if ($_.timeoutSec) { [int]$_.timeoutSec } else { $DefaultTimeoutSec }
        RetryCount     = if ($_.retries) { [int]$_.retries } else { $DefaultRetryCount }
      }
    }
  }

  if (-not $UseTagOrder) {
    throw 'ConfigJson is empty and UseTagOrder is not specified. Provide one of them.'
  }

  $vms = Get-AzVM -ResourceGroupName $ResourceGroup -Status
  return $vms | Where-Object { $_.Tags.ContainsKey('ShutdownOrder') } | ForEach-Object {
    [PSCustomObject]@{
      Name           = $_.Name
      ResourceGroup  = $ResourceGroup
      Order          = [int]$_.Tags['ShutdownOrder']
      Role           = if ($_.Tags.ContainsKey('Role')) { $_.Tags['Role'] } else { 'APP' }
      ProbePath      = if ($_.Tags.ContainsKey('ProbePath')) { $_.Tags['ProbePath'] } else { $null }
      ProbeRenameTo  = if ($_.Tags.ContainsKey('ProbeRenameTo')) { $_.Tags['ProbeRenameTo'] } else { $null }
      ServiceNames   = $null
      ScriptOverride = $null
      TimeoutSec     = $DefaultTimeoutSec
      RetryCount     = $DefaultRetryCount
    }
  }
}

function Ensure-RunCommandReady {
  param(
    [string]$VmName,
    [string]$VmResourceGroup
  )

  $vm = Get-AzVM -ResourceGroupName $VmResourceGroup -Name $VmName -Status
  $agentStatus = $vm.VMAgent.Statuses | Select-Object -First 1

  if ($null -eq $agentStatus -or $agentStatus.DisplayStatus -notlike '*Ready*') {
    Write-Log "VM agent not ready for $VmName. Status: $($agentStatus.DisplayStatus)" 'WARN'
  }

  return $vm
}

function Stop-VmGracefully {
  param(
    [PSCustomObject]$Target
  )

  Write-Log "Processing VM: $($Target.Name) (Order $($Target.Order), Role $($Target.Role))"

  $vm = Ensure-RunCommandReady -VmName $Target.Name -VmResourceGroup $Target.ResourceGroup
  $osType = Get-OsType -Vm $vm

  $powerState = ($vm.Statuses | Where-Object { $_.Code -like 'PowerState/*' }).DisplayStatus
  if ($powerState -match 'deallocated|stopped') {
    Write-Log "VM $($Target.Name) already stopped ($powerState). Skipping guest stop and deallocate." 'INFO'
    return
  }

  if ($Target.Role -in @('WEB', 'APP') -and $Target.ProbePath) {
    Write-Log "Disabling probe path for $($Target.Name)" 'INFO'
    $probeScript = Get-ProbeDisableScript -ProbePath $Target.ProbePath -RenameTo $Target.ProbeRenameTo
    if ($probeScript.Count -gt 0) {
      Invoke-RunCommand -VmName $Target.Name -VmResourceGroup $Target.ResourceGroup -ScriptLines $probeScript -TimeoutSec $Target.TimeoutSec -RetryCount $Target.RetryCount
    }
  }

  Write-Log "Executing guest stop for $($Target.Name)" 'INFO'
  if ($Target.ScriptOverride) {
    $scriptLines = @($Target.ScriptOverride)
  } else {
    $scriptLines = Get-DefaultStopScript -Role $Target.Role -OsType $osType -ServiceNames $Target.ServiceNames
  }

  if ($osType -eq 'Linux') {
    $linuxScript = @(
      '#!/bin/bash',
      "echo 'Stopping role $($Target.Role)'"
    ) + $scriptLines

    Invoke-AzVMRunCommand -ResourceGroupName $Target.ResourceGroup -Name $Target.Name -CommandId 'RunShellScript' -ScriptString $linuxScript | Out-Null
  } else {
    Invoke-RunCommand -VmName $Target.Name -VmResourceGroup $Target.ResourceGroup -ScriptLines $scriptLines -TimeoutSec $Target.TimeoutSec -RetryCount $Target.RetryCount
  }

  Write-Log "Stopping VM (deallocate) $($Target.Name)" 'INFO'
  Invoke-WithRetry -RetryCount $Target.RetryCount -Script {
    Stop-AzVM -ResourceGroupName $Target.ResourceGroup -Name $Target.Name -Force -ErrorAction Stop | Out-Null
  }
}

Write-Log 'Connecting with managed identity'
Connect-AzAccount -Identity | Out-Null
if ($SubscriptionId) {
  Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
}

Write-Log 'Collecting target VM list'
$targets = Get-TargetVmList -ResourceGroup $ResourceGroupName -ConfigJson $ConfigJson -UseTagOrder:$UseTagOrder

if (-not $targets -or $targets.Count -eq 0) {
  Write-Log 'No target VMs found. Exiting.' 'WARN'
  return
}

$groups = $targets | Sort-Object Order | Group-Object Order

foreach ($group in $groups) {
  Write-Log "Processing order group: $($group.Name) with $($group.Count) VM(s)"

  if ($ParallelWithinOrder) {
    $group.Group | ForEach-Object -Parallel {
      Stop-VmGracefully -Target $_
    } -ThrottleLimit $ThrottleLimit
  } else {
    foreach ($target in $group.Group) {
      Stop-VmGracefully -Target $target
    }
  }

  Write-Log "Completed order group: $($group.Name)"
}

Write-Log 'Shutdown orchestration complete'
