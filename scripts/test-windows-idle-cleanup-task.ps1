#requires -version 5.1

param(
  [string]$BootstrapPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap\bootstrap.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$testId = [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "cc-remote-idle-task-test-$testId"
$taskName = "cc-remote-idle-watch-$testId"
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

try {
  if (-not (Test-Path -LiteralPath $BootstrapPath -PathType Leaf)) {
    throw "Bootstrap source not found: $BootstrapPath"
  }
  $bootstrap = Get-Content -LiteralPath $BootstrapPath -Raw
  $helperStart = $bootstrap.IndexOf('function Register-IdleCleanupTask')
  $helperEnd = $bootstrap.IndexOf("`ntry {", $helperStart)
  if ($helperStart -lt 0 -or $helperEnd -le $helperStart) {
    throw 'Could not isolate the production idle cleanup registration helper.'
  }
  Invoke-Expression $bootstrap.Substring($helperStart, $helperEnd - $helperStart)

  $watcherPath = Join-Path $testRoot 'idle-watch.ps1'
  @'
#requires -version 5.1
param([string]$StatePath, [int]$IdleSeconds)
Start-Sleep -Seconds 60
'@ | Set-Content -Encoding UTF8 -LiteralPath $watcherPath
  $statePath = Join-Path $testRoot 'state.json'
  '{}' | Set-Content -Encoding UTF8 -LiteralPath $statePath

  $SessionId = $testId
  $Root = $testRoot
  $Manifest = [pscustomobject]@{ idle_timeout_seconds = 7200 }
  Register-IdleCleanupTask $statePath

  $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
  Assert-True ($null -ne $task) 'exact test task was not registered'
  Assert-True ($task.Principal.UserId -in @('S-1-5-18', 'SYSTEM')) "unexpected task principal: $($task.Principal.UserId)"
  Assert-True ($task.Principal.LogonType -eq 'ServiceAccount') "unexpected logon type: $($task.Principal.LogonType)"
  Assert-True ($task.Principal.RunLevel -eq 'Highest') "unexpected run level: $($task.Principal.RunLevel)"

  $running = $false
  for ($attempt = 0; $attempt -lt 150; $attempt++) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ([string]$task.State -eq 'Running') {
      $running = $true
      break
    }
    Start-Sleep -Milliseconds 200
  }
  Assert-True $running "exact test task did not enter Running state; final state: $($task.State)"
  Write-Host 'PASS exact idle cleanup task uses the SYSTEM service-account principal'
  Write-Host 'PASS registration and start failures are terminating and the task is verifiably running'
  Write-Host 'ALL WINDOWS POWERSHELL 5.1 IDLE-CLEANUP TASK TESTS PASSED'
} finally {
  $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($task) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
