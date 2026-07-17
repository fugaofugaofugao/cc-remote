#requires -version 5.1
param(
  [Parameter(Mandatory=$true)]
  [string]$StatePath
)
$ErrorActionPreference = 'Continue'
if (-not (Test-Path $StatePath)) { throw "State file not found: $StatePath" }
$State = Get-Content $StatePath -Raw | ConvertFrom-Json

if ($State.auth_keys -and (Test-Path $State.auth_keys)) {
  $marker = [regex]::Escape("cc-remote:$($State.session_id)")
  $lines = @(Get-Content $State.auth_keys | Where-Object { $_ -notmatch $marker })
  [System.IO.File]::WriteAllLines($State.auth_keys, $lines, [System.Text.Encoding]::ASCII)
  if ($State.auth_keys -like '*\administrators_authorized_keys') {
    icacls $State.auth_keys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
  }
  Write-Host "removed temporary authorized_keys marker cc-remote:$($State.session_id)"
}

if ($State.tunnel_pid) {
  $pidValue = [int]$State.tunnel_pid
  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $pidValue" -ErrorAction SilentlyContinue
  $identityComplete = (
    $State.remote_port -and $State.relay_user -and $State.relay_host -and
    $State.relay_ssh_port -and $State.tunnel_key -and $State.ssh_client
  )
  $expectedForward = "127.0.0.1:$($State.remote_port):127.0.0.1:22"
  $expectedPort = "-p $($State.relay_ssh_port)"
  $expectedTarget = "$($State.relay_user)@$($State.relay_host)"
  $pathMatches = $false
  if ($identityComplete -and $process -and $process.ExecutablePath) {
    try {
      $actualPath = [System.IO.Path]::GetFullPath($process.ExecutablePath)
      $expectedPath = [System.IO.Path]::GetFullPath([string]$State.ssh_client)
      $pathMatches = $actualPath.Equals($expectedPath, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
      $pathMatches = $false
    }
  }
  if (
    $identityComplete -and $process -and $process.Name -eq 'ssh.exe' -and $process.CommandLine -and $pathMatches -and
    $process.CommandLine -like "*$expectedForward*" -and
    $process.CommandLine -like "*$expectedPort*" -and
    $process.CommandLine -like "*$expectedTarget*" -and
    $process.CommandLine -like "*$($State.tunnel_key)*"
  ) {
    Stop-Process -Id $pidValue -Force -ErrorAction SilentlyContinue
    Write-Host "stopped verified session tunnel process $pidValue"
  } elseif ($process) {
    Write-Warning "PID $pidValue does not have complete exact-session identity; it was not stopped"
  } else {
    Write-Host "tunnel process $pidValue was already stopped"
  }
}

# sshd is a shared machine service, not a session-owned resource. Cleanup must
# leave its running state, startup type, installation, and configuration intact.

Unregister-ScheduledTask -TaskName "cc-remote-idle-watch-$($State.session_id)" -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "cc-remote-tunnel-$($State.session_id)" -Confirm:$false -ErrorAction SilentlyContinue
$completePath = Join-Path (Split-Path -Parent $StatePath) 'cleanup-complete.txt'
"$(Get-Date -Format o) cc-remote cleanup complete for $($State.session_id)" | Set-Content -Encoding UTF8 $completePath
Remove-Item -Force -Path $StatePath -ErrorAction SilentlyContinue
Write-Host "cc-remote cleanup complete for $($State.session_id)"
