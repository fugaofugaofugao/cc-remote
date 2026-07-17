#requires -version 5.1
param(
  [Parameter(Mandatory=$true)]
  [string]$StatePath,
  [int]$IdleSeconds = 7200,
  [int]$CheckSeconds = 60
)
$ErrorActionPreference = 'Continue'
if (-not (Test-Path $StatePath)) { throw "State file not found: $StatePath" }
$State = Get-Content $StatePath -Raw | ConvertFrom-Json
$lastActive = Get-Date

function Test-SshActive {
  try {
    $connections = Get-NetTCPConnection -LocalPort 22 -State Established -ErrorAction SilentlyContinue
    return [bool]$connections
  } catch {
    return $false
  }
}

while ($true) {
  if (Test-SshActive) { $lastActive = Get-Date }
  if (((Get-Date) - $lastActive).TotalSeconds -ge $IdleSeconds) {
    powershell -ExecutionPolicy Bypass -File "$PSScriptRoot\cleanup.ps1" -StatePath $StatePath
    exit 0
  }
  Start-Sleep -Seconds $CheckSeconds
}
