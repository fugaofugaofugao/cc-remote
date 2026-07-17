#requires -version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cc-remote-handshake-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Wait-Handshake([string]$Path, [string]$Status, [int]$TimeoutMilliseconds) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      try {
        $value = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($value.status -eq $Status) { return $value }
      } catch {
        # Atomic replacement can briefly contend with a reader; retry until the deadline.
      }
    }
    Start-Sleep -Milliseconds 50
  }
  $last = if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue } else { '<missing>' }
  throw "Timed out waiting for handshake status '$Status'. Last content: $last"
}

$childPath = Join-Path $testRoot 'fake-child.ps1'
@'
param([Parameter(Mandatory=$true)][ValidateSet('success','failure','exit')][string]$Mode)
[Console]::Error.WriteLine('fake child started')
[Console]::Error.Flush()
if ($Mode -eq 'success') {
  Start-Sleep -Milliseconds 300
  [Console]::Error.WriteLine('debug1: remote forward success for: listen 127.0.0.1:39634, connect 127.0.0.1:22')
  [Console]::Error.Flush()
  Start-Sleep -Seconds 5
  exit 0
}
if ($Mode -eq 'failure') {
  Start-Sleep -Milliseconds 300
  [Console]::Error.WriteLine('Error: remote port forwarding failed for listen port 39634')
  [Console]::Error.Flush()
  Start-Sleep -Milliseconds 300
  exit 1
}
Start-Sleep -Milliseconds 300
exit 7
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8

$wrapperPath = Join-Path $testRoot 'handshake-wrapper.ps1'
@'
param(
  [Parameter(Mandatory=$true)][string]$ChildPath,
  [Parameter(Mandatory=$true)][string]$Mode,
  [Parameter(Mandatory=$true)][string]$HandshakePath,
  [Parameter(Mandatory=$true)][string]$LogPath,
  [Parameter(Mandatory=$true)][string]$DiagnosticPath
)
$ErrorActionPreference = 'Stop'
function Write-Diagnostic([string]$Message) {
  Add-Content -Encoding UTF8 -LiteralPath $DiagnosticPath -Value ("{0:o} {1}" -f (Get-Date), $Message)
}
function Write-Handshake([string]$Status, [int]$ProcessId, [string]$Message) {
  $tempPath = $HandshakePath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
  $backupPath = $HandshakePath + '.' + [Guid]::NewGuid().ToString('N') + '.bak'
  Write-Diagnostic "writing handshake status=$Status temp=$tempPath backup=$backupPath"
  [ordered]@{
    status = $Status
    pid = $ProcessId
    message = $Message
    written_at = (Get-Date).ToString('o')
  } | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $tempPath
  if ([System.IO.File]::Exists($HandshakePath)) {
    try {
      [System.IO.File]::Replace($tempPath, $HandshakePath, $backupPath)
    } finally {
      Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
  } else {
    [System.IO.File]::Move($tempPath, $HandshakePath)
  }
}
$process = $null
try {
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = "$PSHOME\powershell.exe"
  $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ChildPath`" -Mode $Mode"
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardError = $true
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  Write-Diagnostic "starting child file=$($startInfo.FileName) arguments=$($startInfo.Arguments)"
  if (-not $process.Start()) { throw 'Failed to start fake child.' }
  Write-Diagnostic "child started pid=$($process.Id)"
  Write-Handshake -Status 'started' -ProcessId $process.Id -Message ''

  $failed = $false
  while ($true) {
    Write-Diagnostic 'waiting for stderr line'
    $line = $process.StandardError.ReadLine()
    if ($null -eq $line) {
      Write-Diagnostic 'stderr reached EOF'
      break
    }
    Write-Diagnostic "stderr line=$line"
    Add-Content -Encoding UTF8 -LiteralPath $LogPath -Value $line
    if ($line -match '(?i)remote forward success for:|forwarding_success: all expected forwarding replies received') {
      Write-Handshake -Status 'ready' -ProcessId $process.Id -Message $line
    } elseif ($line -match '(?i)remote port forwarding failed|Error: remote port forwarding|Could not request local forwarding|Permission denied|Host key verification failed|No more authentication methods to try') {
      Write-Handshake -Status 'failed' -ProcessId $process.Id -Message $line
      $failed = $true
    }
  }
  Write-Diagnostic 'waiting for child exit'
  $process.WaitForExit()
  $exitCode = $process.ExitCode
  Write-Diagnostic "child exited code=$exitCode"
  if (-not $failed) {
    Write-Handshake -Status 'exited' -ProcessId $process.Id -Message "fake child exited with code $exitCode"
  }
  exit $exitCode
} catch {
  $processId = if ($process -and $process.Id) { $process.Id } else { 0 }
  try { Write-Diagnostic "wrapper error=$($_.Exception.ToString())" } catch {}
  Write-Handshake -Status 'error' -ProcessId $processId -Message $_.Exception.Message
  exit 1
}
'@ | Set-Content -LiteralPath $wrapperPath -Encoding UTF8

function Start-Case([string]$Name, [string]$Mode) {
  $caseRoot = Join-Path $testRoot $Name
  New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
  $handshake = Join-Path $caseRoot 'tunnel-startup.json'
  $log = Join-Path $caseRoot 'tunnel.log'
  $diagnostic = Join-Path $caseRoot 'wrapper-diagnostic.log'
  $arguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapperPath,
    '-ChildPath', $childPath, '-Mode', $Mode,
    '-HandshakePath', $handshake, '-LogPath', $log,
    '-DiagnosticPath', $diagnostic
  )
  $wrapper = Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList $arguments -PassThru -WindowStyle Hidden
  return [pscustomobject]@{ Process = $wrapper; Handshake = $handshake; Log = $log; Diagnostic = $diagnostic; Root = $caseRoot }
}

function Format-CaseDiagnostic($Case) {
  $wrapperState = if ($Case.Process.HasExited) { "exited code=$($Case.Process.ExitCode)" } else { 'running' }
  $handshakeText = if (Test-Path -LiteralPath $Case.Handshake) { Get-Content -LiteralPath $Case.Handshake -Raw -ErrorAction SilentlyContinue } else { '<missing>' }
  $logText = if (Test-Path -LiteralPath $Case.Log) { Get-Content -LiteralPath $Case.Log -Raw -ErrorAction SilentlyContinue } else { '<missing>' }
  $diagnosticText = if (Test-Path -LiteralPath $Case.Diagnostic) { Get-Content -LiteralPath $Case.Diagnostic -Raw -ErrorAction SilentlyContinue } else { '<missing>' }
  return "Wrapper: $wrapperState`nHandshake:`n$handshakeText`nTunnel log:`n$logText`nWrapper diagnostic:`n$diagnosticText"
}

function Wait-CaseHandshake($Case, [string]$Status, [int]$TimeoutMilliseconds) {
  try {
    return Wait-Handshake -Path $Case.Handshake -Status $Status -TimeoutMilliseconds $TimeoutMilliseconds
  } catch {
    throw "$($_.Exception.Message)`n$(Format-CaseDiagnostic -Case $Case)"
  }
}

try {
  $success = Start-Case -Name 'success' -Mode 'success'
  $started = Wait-CaseHandshake -Case $success -Status 'started' -TimeoutMilliseconds 3000
  $ready = Wait-CaseHandshake -Case $success -Status 'ready' -TimeoutMilliseconds 3000
  Assert-True ($ready.pid -eq $started.pid) 'ready PID differs from started PID'
  $child = Get-Process -Id ([int]$ready.pid) -ErrorAction SilentlyContinue
  Assert-True ($null -ne $child) 'child exited before ready was observable'
  $liveLog = Get-Content -LiteralPath $success.Log -Raw
  Assert-True ($liveLog -match 'remote forward success for:') 'success evidence was not logged in real time'
  Stop-Process -Id ([int]$ready.pid) -Force -ErrorAction SilentlyContinue
  $success.Process.WaitForExit(3000) | Out-Null
  Write-Host 'PASS success becomes ready while the exact child PID remains alive'

  $failure = Start-Case -Name 'failure' -Mode 'failure'
  $failed = Wait-CaseHandshake -Case $failure -Status 'failed' -TimeoutMilliseconds 3000
  $failure.Process.WaitForExit(3000) | Out-Null
  $failedAfterExit = Get-Content -LiteralPath $failure.Handshake -Raw | ConvertFrom-Json
  Assert-True ($failedAfterExit.status -eq 'failed') 'failed status was overwritten after child exit'
  Assert-True ($failedAfterExit.pid -eq $failed.pid) 'failed PID changed after child exit'
  Write-Host 'PASS failure remains failed after child exit'

  $exit = Start-Case -Name 'exit' -Mode 'exit'
  $exited = Wait-CaseHandshake -Case $exit -Status 'exited' -TimeoutMilliseconds 3000
  Assert-True ($exited.message -match 'code 7') 'exit status did not preserve the child exit code'
  $exit.Process.WaitForExit(3000) | Out-Null
  Write-Host 'PASS ordinary exit publishes exited after repeated atomic replacement'

  Write-Host 'ALL WINDOWS POWERSHELL 5.1 HANDSHAKE TESTS PASSED'
} finally {
  Get-ChildItem -LiteralPath $testRoot -Filter 'tunnel-startup.json' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    try {
      $state = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
      if ($state.pid) { Stop-Process -Id ([int]$state.pid) -Force -ErrorAction SilentlyContinue }
    } catch {}
  }
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
