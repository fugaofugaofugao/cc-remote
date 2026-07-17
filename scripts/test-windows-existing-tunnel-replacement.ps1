#requires -version 5.1

param(
  [string]$BootstrapPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap\bootstrap.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cc-remote-replacement-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
$script:TaskPresent = $false
$script:TaskStopped = $false
$script:TaskUnregistered = $false

function Get-ScheduledTask {
  param([string]$TaskName, $ErrorAction)
  if ($script:TaskPresent) { return [pscustomobject]@{ TaskName = $TaskName } }
  return $null
}
function Stop-ScheduledTask {
  param([string]$TaskName, $ErrorAction)
  $script:TaskStopped = $true
}
function Unregister-ScheduledTask {
  param([string]$TaskName, [switch]$Confirm, $ErrorAction)
  $script:TaskUnregistered = $true
  $script:TaskPresent = $false
}
function Write-Stage { param([string]$Message) }

function Reset-TaskMocks([bool]$Present) {
  $script:TaskPresent = $Present
  $script:TaskStopped = $false
  $script:TaskUnregistered = $false
}

function Wait-ProcessExit([int]$ProcessId) {
  for ($attempt = 0; $attempt -lt 50 -and (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue); $attempt++) {
    Start-Sleep -Milliseconds 50
  }
}

function Stop-TestProcess($Process) {
  if ($Process -and -not $Process.HasExited) {
    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
    Wait-ProcessExit -ProcessId $Process.Id
  }
}

try {
  if (-not (Test-Path -LiteralPath $BootstrapPath -PathType Leaf)) {
    throw "Bootstrap source not found: $BootstrapPath"
  }
  $bootstrap = Get-Content -LiteralPath $BootstrapPath -Raw
  $validatorStart = $bootstrap.IndexOf('function Test-ReverseTunnelProcess')
  $monitorDispatch = $bootstrap.IndexOf('if ($NoMonitor -and $MonitorOnly)')
  $replacementStart = $bootstrap.IndexOf('function Stop-ExistingReverseTunnel')
  $replacementEnd = $bootstrap.IndexOf('function ConvertTo-PowerShellLiteral')
  if ($validatorStart -lt 0 -or $monitorDispatch -le $validatorStart -or $replacementStart -le $monitorDispatch -or $replacementEnd -le $replacementStart) {
    throw 'Could not isolate the production tunnel validator and replacement helper.'
  }
  Invoke-Expression $bootstrap.Substring($validatorStart, $monitorDispatch - $validatorStart)
  Invoke-Expression $bootstrap.Substring($replacementStart, $replacementEnd - $replacementStart)

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

  $SessionId = 'replacement-test-session'
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
  $allProcesses = New-Object System.Collections.ArrayList

  function Start-FakeSSH([bool]$MatchingCommandLine) {
    $forward = if ($MatchingCommandLine) { '127.0.0.1:39634:127.0.0.1:22' } else { '127.0.0.1:49999:127.0.0.1:22' }
    $arguments = @('-p', '39022', '-R', $forward, '-i', $expectedKey, 'cc-tunnel@relay.example.test')
    $process = Start-Process -FilePath $fakeSSH -ArgumentList $arguments -PassThru -WindowStyle Hidden
    [void]$allProcesses.Add($process)
    Start-Sleep -Milliseconds 100
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
    }
    foreach ($key in $Overrides.Keys) { $value[$key] = $Overrides[$key] }
    $value | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $statePath
  }

  $unrelated = Start-FakeSSH -MatchingCommandLine $false
  $matching = Start-FakeSSH -MatchingCommandLine $true
  Write-State -Process $matching -Overrides @{}
  Reset-TaskMocks -Present $true
  Stop-ExistingReverseTunnel -SSHClient $fakeSSH
  Wait-ProcessExit -ProcessId $matching.Id
  Assert-True ($matching.HasExited) 'matching exact-session process was not stopped'
  Assert-True $script:TaskStopped 'matching exact-session task was not stopped'
  Assert-True $script:TaskUnregistered 'matching exact-session task was not unregistered'
  Assert-True (-not $unrelated.HasExited) 'unrelated process was stopped'
  Write-Host 'PASS matching state stops only the exact process and task'

  $exited = Start-FakeSSH -MatchingCommandLine $true
  Write-State -Process $exited -Overrides @{}
  Reset-TaskMocks -Present $false
  Stop-TestProcess -Process $exited
  Wait-ProcessExit -ProcessId $exited.Id
  Stop-ExistingReverseTunnel -SSHClient $fakeSSH
  Assert-True (-not $script:TaskStopped) 'absent recorded process stopped a task'
  Assert-True (-not $script:TaskUnregistered) 'absent recorded process unregistered a task'
  Assert-True (-not $unrelated.HasExited) 'absent recorded process stopped an unrelated process'
  Write-Host 'PASS already-exited exact-session PID is treated as stale state only when its task is absent'

  $mismatchCases = @(
    @{ Name = 'session id'; Values = @{ session_id = 'other-session' } },
    @{ Name = 'task name'; Values = @{ tunnel_task = 'cc-remote-tunnel-other' } },
    @{ Name = 'relay user'; Values = @{ relay_user = 'other-user' } },
    @{ Name = 'relay host'; Values = @{ relay_host = 'other.example.test' } },
    @{ Name = 'relay port'; Values = @{ relay_ssh_port = 39023 } },
    @{ Name = 'reverse port'; Values = @{ remote_port = 39635 } },
    @{ Name = 'SSH client path'; Values = @{ ssh_client = (Join-Path $testRoot 'other-ssh.exe') } },
    @{ Name = 'tunnel key path'; Values = @{ tunnel_key = (Join-Path $StateDir 'other-key') } },
    @{ Name = 'PID'; Values = @{ tunnel_pid = $unrelated.Id } }
  )
  foreach ($case in $mismatchCases) {
    $candidate = Start-FakeSSH -MatchingCommandLine $true
    Write-State -Process $candidate -Overrides $case.Values
    Reset-TaskMocks -Present $true
    $threw = $false
    try { Stop-ExistingReverseTunnel -SSHClient $fakeSSH } catch { $threw = $true }
    Assert-True $threw "$($case.Name) mismatch did not fail closed"
    Assert-True (-not $candidate.HasExited) "$($case.Name) mismatch stopped the candidate process"
    Assert-True (-not $script:TaskStopped) "$($case.Name) mismatch stopped the task"
    Assert-True (-not $script:TaskUnregistered) "$($case.Name) mismatch unregistered the task"
    Stop-TestProcess -Process $candidate
  }
  Write-Host 'PASS recorded identity mismatches fail closed without stopping anything'

  $wrongForward = Start-FakeSSH -MatchingCommandLine $false
  Write-State -Process $wrongForward -Overrides @{}
  Reset-TaskMocks -Present $true
  $threw = $false
  try { Stop-ExistingReverseTunnel -SSHClient $fakeSSH } catch { $threw = $true }
  Assert-True $threw 'live command-line mismatch did not fail closed'
  Assert-True (-not $wrongForward.HasExited) 'live command-line mismatch stopped the process'
  Assert-True (-not $script:TaskStopped) 'live command-line mismatch stopped the task'
  Stop-TestProcess -Process $wrongForward
  Write-Host 'PASS live executable and forwarding identity mismatch fails closed'

  Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
  Reset-TaskMocks -Present $true
  $threw = $false
  try { Stop-ExistingReverseTunnel -SSHClient $fakeSSH } catch { $threw = $true }
  Assert-True $threw 'missing state with exact task did not fail closed'
  Assert-True (-not $script:TaskStopped) 'missing state stopped the task'

  Set-Content -Encoding UTF8 -LiteralPath $statePath -Value '{malformed'
  Reset-TaskMocks -Present $true
  $threw = $false
  try { Stop-ExistingReverseTunnel -SSHClient $fakeSSH } catch { $threw = $true }
  Assert-True $threw 'malformed state did not fail closed'
  Assert-True (-not $script:TaskStopped) 'malformed state stopped the task'
  Assert-True (-not $unrelated.HasExited) 'fail-closed cases stopped the unrelated process'
  Write-Host 'PASS missing and malformed state preserve task and unrelated process'

  Write-Host 'ALL WINDOWS POWERSHELL 5.1 EXISTING-TUNNEL REPLACEMENT TESTS PASSED'
} finally {
  if (Get-Variable allProcesses -ErrorAction SilentlyContinue) {
    foreach ($process in $allProcesses) { Stop-TestProcess -Process $process }
  }
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
