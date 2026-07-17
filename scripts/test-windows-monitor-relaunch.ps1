#requires -version 5.1
param(
  [string]$BootstrapPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap\bootstrap.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cc-remote-monitor-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
$script:Stages = New-Object System.Collections.Generic.List[string]
$script:SleepCount = 0
$script:SleepAction = $null
$script:Clock = [datetime]'2026-01-01T00:00:00Z'
$script:ServiceReads = 0
$script:ConnectionReads = 0

function Write-Stage { param([string]$Message) [void]$script:Stages.Add($Message) }
function Get-Service { param([string]$Name, $ErrorAction) $script:ServiceReads++; return [pscustomobject]@{ Status = 'Running' } }
function Get-NetTCPConnection { param([int]$LocalPort, [string]$State, $ErrorAction) $script:ConnectionReads++; return @() }
function Get-Date {
  param([string]$Format)
  $script:Clock = $script:Clock.AddSeconds(1)
  if ($Format) { return $script:Clock.ToString($Format) }
  return $script:Clock
}
function Start-Sleep {
  param([int]$Seconds, [int]$Milliseconds)
  $script:SleepCount++
  if ($script:SleepAction) { & $script:SleepAction $script:SleepCount }
}

function Stop-TestProcess($Process) {
  if ($Process -and -not $Process.HasExited) {
    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    [void]$Process.WaitForExit(5000)
  }
}

try {
  if (-not (Test-Path -LiteralPath $BootstrapPath -PathType Leaf)) { throw "Bootstrap source not found: $BootstrapPath" }
  $bootstrap = Get-Content -LiteralPath $BootstrapPath -Raw
  $monitorStart = $bootstrap.IndexOf('function Test-ReverseTunnelProcess')
  $monitorDispatch = $bootstrap.IndexOf('if ($NoMonitor -and $MonitorOnly)')
  if ($monitorStart -lt 0 -or $monitorDispatch -le $monitorStart) { throw 'Could not isolate the production monitor functions.' }
  Invoke-Expression $bootstrap.Substring($monitorStart, $monitorDispatch - $monitorStart)

  $fakeSource = @'
using System;
using System.Threading;
public static class Program {
  public static int Main(string[] args) {
    Thread.Sleep(60000);
    return 0;
  }
}
'@
  $fakeSSH = Join-Path $testRoot 'ssh.exe'
  Add-Type -TypeDefinition $fakeSource -Language CSharp -OutputAssembly $fakeSSH -OutputType ConsoleApplication

  $SessionId = 'monitor-test-session'
  $StateDir = Join-Path $testRoot 'state'
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  $Manifest = [pscustomobject]@{
    relay_user = 'cc-tunnel'
    relay_host = 'relay.example.test'
    relay_ssh_port = 39022
    remote_port = 39634
  }
  $expectedTask = "cc-remote-tunnel-$SessionId"
  $expectedKey = Join-Path $StateDir 'tunnel_ed25519'
  New-Item -ItemType File -Force -Path $expectedKey | Out-Null
  $statePath = Join-Path $StateDir 'state.json'
  $bootstrapLog = Join-Path $StateDir 'bootstrap.log'
  Set-Content -LiteralPath $bootstrapLog -Encoding UTF8 -Value 'sentinel-bootstrap-log'
  $logHashBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $bootstrapLog).Hash
  $allProcesses = New-Object System.Collections.ArrayList

  function Start-FakeSSH([bool]$MatchingCommandLine) {
    $forward = if ($MatchingCommandLine) { '127.0.0.1:39634:127.0.0.1:22' } else { '127.0.0.1:49999:127.0.0.1:22' }
    $arguments = @('-p', '39022', '-R', $forward, '-i', $expectedKey, 'cc-tunnel@relay.example.test')
    $process = Start-Process -FilePath $fakeSSH -ArgumentList $arguments -PassThru -WindowStyle Hidden
    [void]$allProcesses.Add($process)
    [Threading.Thread]::Sleep(150)
    return $process
  }

  function Write-State($Process, [hashtable]$Overrides) {
    $value = [ordered]@{
      session_id = $SessionId
      tunnel_task = $expectedTask
      relay_user = $Manifest.relay_user
      relay_host = $Manifest.relay_host
      relay_ssh_port = $Manifest.relay_ssh_port
      remote_port = $Manifest.remote_port
      ssh_client = $fakeSSH
      tunnel_key = $expectedKey
      tunnel_pid = $Process.Id
      tunnel_log = (Join-Path $StateDir 'tunnel.log')
    }
    foreach ($key in $Overrides.Keys) { $value[$key] = $Overrides[$key] }
    $value | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $statePath
  }

  $unrelated = Start-FakeSSH -MatchingCommandLine $false
  $oldTunnel = Start-FakeSSH -MatchingCommandLine $true
  $newTunnel = Start-FakeSSH -MatchingCommandLine $true
  Write-State -Process $oldTunnel -Overrides @{}
  $initialState = Get-ExactMonitorState -StatePath $statePath
  $initialProcessValid = Test-ReverseTunnelProcess -ProcessId $initialState.ProcessId -SSHClient $initialState.SSHClient -TunnelKey $initialState.TunnelKey
  if (-not $initialProcessValid) {
    $processDetails = Get-CimInstance Win32_Process -Filter "ProcessId = $($oldTunnel.Id)" -ErrorAction SilentlyContinue | Select-Object Name, ExecutablePath, CommandLine | Format-List | Out-String
    throw "ASSERTION FAILED: initial exact tunnel process was rejected. Process: $processDetails"
  }
  $script:Stages.Clear()
  $script:SleepCount = 0
  $script:SleepAction = {
    param($Count)
    if ($Count -eq 1) { Stop-TestProcess -Process $oldTunnel }
    if ($Count -eq 2) { Write-State -Process $newTunnel -Overrides @{} }
    if ($Count -eq 3) { Remove-Item -LiteralPath $statePath -Force }
  }
  Start-StatusMonitor -StatePath $statePath -PollSeconds 1 -ReplacementGraceSeconds 6
  $statusText = $script:Stages -join "`n"
  if ($statusText -notmatch "tunnel_pid=$($oldTunnel.Id)") {
    $processDetails = Get-CimInstance Win32_Process -Filter "ProcessId = $($oldTunnel.Id)" -ErrorAction SilentlyContinue | Select-Object Name, ExecutablePath, CommandLine | Format-List | Out-String
    throw "ASSERTION FAILED: monitor did not recognize the original exact tunnel PID. Stages: $statusText Process: $processDetails"
  }
  Assert-True ($statusText -match "tunnel_pid=$($newTunnel.Id)") 'monitor did not follow the replacement exact tunnel PID'
  Assert-True ($statusText -match 'Idle or manual cleanup completed') 'state deletion after a valid observation was not treated as clean monitor completion'
  Assert-True (-not $newTunnel.HasExited) 'monitor stopped the replacement tunnel process'
  Assert-True (-not $unrelated.HasExited) 'monitor stopped an unrelated SSH process'
  Assert-True ($script:ServiceReads -gt 0) 'monitor did not read sshd status'
  Assert-True ($script:ConnectionReads -gt 0) 'monitor did not read active SSH connection status'
  Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $bootstrapLog).Hash -eq $logHashBefore) 'monitor modified bootstrap.log'
  Write-Host 'PASS monitor follows exact-session PID replacement and exits cleanly after state deletion'

  $mismatchCases = @(
    @{ Name = 'session id'; Values = @{ session_id = 'other-session' } },
    @{ Name = 'task name'; Values = @{ tunnel_task = 'cc-remote-tunnel-other' } },
    @{ Name = 'relay user'; Values = @{ relay_user = 'other-user' } },
    @{ Name = 'relay host'; Values = @{ relay_host = 'other.example.test' } },
    @{ Name = 'relay port'; Values = @{ relay_ssh_port = 39023 } },
    @{ Name = 'reverse port'; Values = @{ remote_port = 39635 } },
    @{ Name = 'tunnel key path'; Values = @{ tunnel_key = (Join-Path $StateDir 'other-key') } },
    @{ Name = 'PID'; Values = @{ tunnel_pid = 0 } }
  )
  foreach ($case in $mismatchCases) {
    Write-State -Process $newTunnel -Overrides $case.Values
    $threw = $false
    try { [void](Get-ExactMonitorState -StatePath $statePath) } catch { $threw = $true }
    Assert-True $threw "$($case.Name) mismatch was accepted by monitor-state validation"
  }
  Set-Content -LiteralPath $statePath -Encoding UTF8 -Value '{malformed'
  $threw = $false
  try { [void](Get-ExactMonitorState -StatePath $statePath) } catch { $threw = $true }
  Assert-True $threw 'malformed monitor state was accepted'
  Write-Host 'PASS malformed and mismatched monitor state is rejected'

  Write-State -Process $unrelated -Overrides @{}
  $script:Stages.Clear()
  $script:SleepCount = 0
  $script:SleepAction = $null
  Start-StatusMonitor -StatePath $statePath -PollSeconds 1 -ReplacementGraceSeconds 2
  Assert-True (($script:Stages -join "`n") -match 'bounded replacement grace') 'wrong reverse-forward process did not exhaust bounded grace'
  Assert-True (-not $unrelated.HasExited) 'invalid exact-session candidate was stopped by monitor'
  Assert-True (-not $newTunnel.HasExited) 'valid but unrecorded tunnel was stopped by monitor'
  Write-Host 'PASS invalid process identity is rejected after bounded grace without stopping processes'

  Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
  $script:Stages.Clear()
  $script:SleepCount = 0
  Start-StatusMonitor -StatePath $statePath -PollSeconds 1 -ReplacementGraceSeconds 2
  Assert-True (($script:Stages -join "`n") -match 'not found within the bounded validation grace') 'initially missing state did not stop after bounded validation grace'
  Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath $bootstrapLog).Hash -eq $logHashBefore) 'bounded failure paths modified bootstrap.log'
  Write-Host 'PASS initially missing state stops after bounded grace without log ownership'

  Write-Host 'ALL WINDOWS POWERSHELL 5.1 MONITOR/RELAUNCH TESTS PASSED'
} finally {
  if (Get-Variable allProcesses -ErrorAction SilentlyContinue) {
    foreach ($process in $allProcesses) { Stop-TestProcess -Process $process }
  }
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
