#requires -version 5.1
param(
  [switch]$NoMonitor,
  [switch]$MonitorOnly
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ManifestPath = Join-Path $Root 'manifest.json'
$Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
$SessionId = $Manifest.session_id
$StateDir = Join-Path $env:ProgramData "cc-remote\sessions\$SessionId"
$BootstrapLog = Join-Path $StateDir 'bootstrap.log'

function Write-Stage {
  param([Parameter(Mandatory=$true)][string]$Message)
  Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Assert-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'cc-remote requires an elevated PowerShell session. Re-run as Administrator.'
  }
}

function Test-PayloadHashes {
  foreach ($payload in @($Manifest.payloads)) {
    $path = Join-Path $Root $payload.path
    if (-not (Test-Path $path)) { throw "Missing payload: $($payload.path)" }
    $hash = (Get-FileHash -Algorithm SHA256 $path).Hash.ToLowerInvariant()
    if ($hash -ne $payload.sha256) { throw "SHA256 mismatch: $($payload.path)" }
  }
  Write-Host 'payload verification ok'
}

function Get-UnqualifiedWindowsUserName {
  param([Parameter(Mandatory=$true)][string]$Identity)
  $name = $Identity.Trim()
  if ($name -match '\\([^\\]+)$') { return $Matches[1] }
  return $name
}

function Test-ServiceIdentityName {
  param([Parameter(Mandatory=$true)][string]$Identity)
  $name = (Get-UnqualifiedWindowsUserName -Identity $Identity).Trim()
  return (
    -not $name -or
    $name -match '(?i)^(SYSTEM|LOCAL SERVICE|NETWORK SERVICE|LOCAL SYSTEM|ANONYMOUS LOGON|DEFAULTACCOUNT|WDAGUTILITYACCOUNT)$' -or
    $name.EndsWith('$')
  )
}

function Resolve-TargetUser {
  if ($Manifest.target_user -and $Manifest.target_user -ne 'auto') {
    return [string]$Manifest.target_user
  }

  $candidates = New-Object System.Collections.Generic.List[string]
  $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
  if ($computerSystem -and $computerSystem.UserName) {
    [void]$candidates.Add([string]$computerSystem.UserName)
  }

  if ($candidates.Count -eq 0) {
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction SilentlyContinue)) {
      try {
        $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner -ErrorAction Stop
        if ($owner.ReturnValue -eq 0 -and $owner.User) {
          $identity = if ($owner.Domain) { "$($owner.Domain)\$($owner.User)" } else { [string]$owner.User }
          [void]$candidates.Add($identity)
        }
      } catch {
        continue
      }
    }
  }

  $resolved = @(
    $candidates |
      Where-Object { -not (Test-ServiceIdentityName -Identity $_) } |
      ForEach-Object { Get-UnqualifiedWindowsUserName -Identity $_ } |
      Sort-Object -Unique
  )
  if ($resolved.Count -ne 1) {
    throw "Could not resolve one unambiguous signed-in non-service Windows user; candidates: $($candidates -join ', ')"
  }

  $user = Get-LocalUser -Name $resolved[0] -ErrorAction SilentlyContinue
  if (-not $user -or -not $user.Enabled) {
    throw "Resolved interactive Windows user '$($resolved[0])' is missing or disabled."
  }
  return [string]$user.Name
}

function Find-BundledSSHClient {
  $payloadRoot = Join-Path $env:ProgramData 'cc-remote\payloads\OpenSSH-Win64'
  $client = Get-ChildItem -Path $payloadRoot -Filter ssh.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($client) { return $client.FullName }
  return $null
}

function Expand-BundledOpenSSH {
  $zip = Join-Path $Root 'payloads\windows\openssh-win64.zip'
  if (-not (Test-Path $zip)) {
    throw 'The required offline OpenSSH payload is not bundled. Ask the operator to regenerate this launcher.'
  }
  $dest = Join-Path $env:ProgramData 'cc-remote\payloads\OpenSSH-Win64'
  Remove-Item -Recurse -Force -Path $dest -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  Expand-Archive -Force -Path $zip -DestinationPath $dest
  return $dest
}

function Ensure-OpenSSHServer {
  $service = Get-Service sshd -ErrorAction SilentlyContinue
  if ($service) {
    $client = Find-BundledSSHClient
    if (-not $client) {
      $command = Get-Command ssh.exe -ErrorAction SilentlyContinue
      if ($command) { $client = $command.Source }
    }
    if (-not $client) {
      Write-Stage 'The existing sshd service has no available SSH client; extracting the embedded client without reinstalling sshd.'
      $dest = Expand-BundledOpenSSH
      $clientFile = Get-ChildItem -Path $dest -Filter ssh.exe -File -Recurse | Select-Object -First 1
      if ($clientFile) { $client = $clientFile.FullName }
    }
    if (-not $client) { throw 'sshd exists, but ssh.exe was not found in the verified offline OpenSSH payload.' }
    return [pscustomobject]@{ Mode = 'existing'; SSHClient = $client }
  }

  Write-Stage 'Installing OpenSSH Server from the embedded offline payload.'
  $dest = Expand-BundledOpenSSH
  $install = Get-ChildItem -Path $dest -Filter install-sshd.ps1 -File -Recurse | Select-Object -First 1
  $client = Get-ChildItem -Path $dest -Filter ssh.exe -File -Recurse | Select-Object -First 1
  if (-not $install) { throw 'install-sshd.ps1 was not found in the verified offline OpenSSH payload.' }
  if (-not $client) { throw 'ssh.exe was not found in the verified offline OpenSSH payload.' }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $install.FullName
  if ($LASTEXITCODE -ne 0) { throw "Offline install-sshd.ps1 exited with code $LASTEXITCODE." }
  if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { throw 'Offline OpenSSH installer completed but the sshd service was not registered.' }
  return [pscustomobject]@{ Mode = 'portable'; SSHClient = $client.FullName }
}

function Start-SSHD {
  param([Parameter(Mandatory=$true)][string]$InstallMode)
  $service = Get-Service sshd
  $serviceConfig = Get-CimInstance Win32_Service -Filter "Name = 'sshd'"
  if ($InstallMode -eq 'existing' -and $serviceConfig.StartMode -eq 'Disabled') {
    throw 'The pre-existing sshd service is Disabled. cc-remote will not change the startup type of an existing machine service.'
  }
  if ($service.Status -ne 'Running') { Start-Service sshd }
  $service = Get-Service sshd
  if ($service.Status -ne 'Running') { throw "sshd failed to start; current status: $($service.Status)" }
}

function Test-LocalSSHPort {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $pending = $client.BeginConnect('127.0.0.1', 22, $null, $null)
    if (-not $pending.AsyncWaitHandle.WaitOne(5000, $false)) { throw 'timed out after 5 seconds' }
    $client.EndConnect($pending)
  } catch {
    throw "Local SSH TCP verification failed for 127.0.0.1:22: $($_.Exception.Message)"
  } finally {
    $client.Close()
  }
}

function Get-TargetSSHHostKeyFingerprint {
  param([Parameter(Mandatory=$true)][string]$SSHClient)
  $hostPublicKey = Join-Path $env:ProgramData 'ssh\ssh_host_ed25519_key.pub'
  if (-not (Test-Path -LiteralPath $hostPublicKey -PathType Leaf)) {
    throw "The active sshd ED25519 host public key was not found: $hostPublicKey"
  }

  $sshKeygen = Join-Path (Split-Path -Parent $SSHClient) 'ssh-keygen.exe'
  if (-not (Test-Path -LiteralPath $sshKeygen -PathType Leaf)) {
    $command = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if ($command) { $sshKeygen = $command.Source }
  }
  if (-not (Test-Path -LiteralPath $sshKeygen -PathType Leaf)) {
    throw 'ssh-keygen.exe was not found beside the verified SSH client or on PATH.'
  }

  $output = & $sshKeygen -lf $hostPublicKey -E sha256 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to fingerprint the active sshd ED25519 host key: $($output -join ' ')"
  }
  $text = $output -join ' '
  if ($text -notmatch '(?:^|\s)(SHA256:[A-Za-z0-9+/]+={0,2})(?:\s|$)') {
    throw "ssh-keygen.exe returned no SHA256 host-key fingerprint: $text"
  }
  return $Matches[1]
}

function Test-LocalUserAdministrator {
  param([Parameter(Mandatory=$true)][Microsoft.PowerShell.Commands.LocalUser]$User)
  try {
    $members = Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop
    foreach ($member in $members) {
      if ($member.SID -and $member.SID.Value -eq $User.SID.Value) { return $true }
      if ($member.Name -match "\\$([regex]::Escape($User.Name))$") { return $true }
    }
  } catch {
    return $false
  }
  return $false
}

function Set-ExactSessionAuthorizedKey {
  param([Parameter(Mandatory=$true)][string]$Path)
  $expected = ([string]$Manifest.target_authorized_key).Trim()
  $marker = "cc-remote:$SessionId"
  if (-not $expected -or $expected -notmatch ("(?:^|\s)" + [regex]::Escape($marker) + "(?:\s|$)")) {
    throw 'Manifest target_authorized_key is missing the exact session marker.'
  }

  $existing = if (Test-Path -LiteralPath $Path -PathType Leaf) { @(Get-Content -LiteralPath $Path -ErrorAction Stop) } else { @() }
  $reconciled = @($existing | Where-Object { $_ -notmatch [regex]::Escape($marker) })
  $reconciled += $expected
  $alreadyExact = $existing.Count -eq $reconciled.Count
  if ($alreadyExact) {
    for ($index = 0; $index -lt $existing.Count; $index++) {
      if ($existing[$index] -cne $reconciled[$index]) { $alreadyExact = $false; break }
    }
  }
  if (-not $alreadyExact) {
    [System.IO.File]::WriteAllLines($Path, [string[]]$reconciled, [System.Text.Encoding]::ASCII)
  }

  $verified = @(Get-Content -LiteralPath $Path -ErrorAction Stop | Where-Object { $_ -ceq $expected })
  $stale = @(Get-Content -LiteralPath $Path -ErrorAction Stop | Where-Object { $_ -match [regex]::Escape($marker) -and $_ -cne $expected })
  if ($verified.Count -ne 1 -or $stale.Count -ne 0) {
    throw "Failed to verify exactly one current-session public key in $Path"
  }
}

function Install-AuthorizedKey {
  param([Parameter(Mandatory=$true)][string]$TargetUser)
  $user = Get-LocalUser -Name $TargetUser -ErrorAction Stop
  if (Test-LocalUserAdministrator -User $user) {
    $auth = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    New-Item -ItemType Directory -Force -Path (Split-Path $auth) | Out-Null
    if (-not (Test-Path -LiteralPath $auth -PathType Leaf)) { New-Item -ItemType File -Path $auth | Out-Null }
    Set-ExactSessionAuthorizedKey -Path $auth
    $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl = Get-Acl -LiteralPath $auth -ErrorAction Stop
    $acl.SetOwner($administratorsSid)
    Set-Acl -LiteralPath $auth -AclObject $acl -ErrorAction Stop
    & icacls.exe $auth /inheritance:r /grant:r '*S-1-5-32-544:F' /grant:r '*S-1-5-18:F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to set OpenSSH administrator key ACL on $auth" }
    $acl = Get-Acl -LiteralPath $auth -ErrorAction Stop
    $ownerSid = ([System.Security.Principal.NTAccount]$acl.Owner).Translate([System.Security.Principal.SecurityIdentifier]).Value
    $fullControlSids = @($acl.Access | Where-Object {
      $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
      ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0
    } | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value })
    if (-not $acl.AreAccessRulesProtected -or $ownerSid -ne 'S-1-5-32-544' -or $fullControlSids -notcontains 'S-1-5-32-544' -or $fullControlSids -notcontains 'S-1-5-18') {
      throw "OpenSSH administrator key ACL verification failed for $auth"
    }
    Set-ExactSessionAuthorizedKey -Path $auth
    return $auth
  }

  $profile = Join-Path 'C:\Users' $user.Name
  if (-not (Test-Path -LiteralPath $profile -PathType Container)) { throw "Profile directory not found: $profile" }
  $sshDir = Join-Path $profile '.ssh'
  $auth = Join-Path $sshDir 'authorized_keys'
  New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
  if (-not (Test-Path -LiteralPath $auth -PathType Leaf)) { New-Item -ItemType File -Path $auth | Out-Null }
  Set-ExactSessionAuthorizedKey -Path $auth
  return $auth
}

function Test-ReverseTunnelProcess {
  param(
    [Parameter(Mandatory=$true)][int]$ProcessId,
    [Parameter(Mandatory=$true)][string]$SSHClient,
    [Parameter(Mandatory=$true)][string]$TunnelKey
  )
  if ($ProcessId -le 0) { return $false }
  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
  if (-not $process -or $process.Name -ne 'ssh.exe' -or -not $process.CommandLine -or -not $process.ExecutablePath) { return $false }
  $expectedClient = [System.IO.Path]::GetFullPath($SSHClient)
  $actualClient = [System.IO.Path]::GetFullPath($process.ExecutablePath)
  if (-not $actualClient.Equals($expectedClient, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  $expectedForward = "127.0.0.1:$($Manifest.remote_port):127.0.0.1:22"
  $expectedPort = "-p $($Manifest.relay_ssh_port)"
  $expectedTarget = "$($Manifest.relay_user)@$($Manifest.relay_host)"
  return (
    $process.CommandLine -like "*$expectedForward*" -and
    $process.CommandLine -like "*$expectedPort*" -and
    $process.CommandLine -like "*$expectedTarget*" -and
    $process.CommandLine -like "*$TunnelKey*"
  )
}

function Get-ExactMonitorState {
  param([Parameter(Mandatory=$true)][string]$StatePath)
  try {
    $state = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "Exact-session monitor state is malformed or unreadable: $($_.Exception.Message)"
  }

  $expectedTask = "cc-remote-tunnel-$SessionId"
  $expectedKey = Join-Path $StateDir 'tunnel_ed25519'
  try {
    $stateClient = [System.IO.Path]::GetFullPath([string]$state.ssh_client)
    $stateKey = [System.IO.Path]::GetFullPath([string]$state.tunnel_key)
    $expectedKeyPath = [System.IO.Path]::GetFullPath($expectedKey)
  } catch {
    throw 'Exact-session monitor state contains invalid SSH client or tunnel key paths.'
  }
  $tunnelProcessId = 0
  $identityMatches = (
    [string]$state.session_id -ceq $SessionId -and
    [string]$state.tunnel_task -ceq $expectedTask -and
    [string]$state.relay_user -ceq [string]$Manifest.relay_user -and
    [string]$state.relay_host -ceq [string]$Manifest.relay_host -and
    [int]$state.relay_ssh_port -eq [int]$Manifest.relay_ssh_port -and
    [int]$state.remote_port -eq [int]$Manifest.remote_port -and
    $stateKey.Equals($expectedKeyPath, [System.StringComparison]::OrdinalIgnoreCase) -and
    [int]::TryParse([string]$state.tunnel_pid, [ref]$tunnelProcessId) -and
    $tunnelProcessId -gt 0
  )
  if (-not $identityMatches) {
    throw 'Exact-session monitor state does not match this launcher.'
  }
  return [pscustomobject]@{
    ProcessId = $tunnelProcessId
    SSHClient = $stateClient
    TunnelKey = $stateKey
    TunnelLog = [string]$state.tunnel_log
  }
}

function Start-StatusMonitor {
  param(
    [Parameter(Mandatory=$true)][string]$StatePath,
    [int]$PollSeconds = 10,
    [int]$ReplacementGraceSeconds = 45
  )
  Write-Stage 'Status monitor started. Keep this window open; Ctrl+C stops only the monitor.'
  $lastStatus = ''
  $invalidSince = $null
  $observedValidState = $false
  while ($true) {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
      if ($observedValidState) {
        Write-Stage 'Idle or manual cleanup completed; status monitor is stopping.'
        break
      }
      if (-not $invalidSince) {
        $invalidSince = Get-Date
        Write-Stage "STATUS exact-session state is temporarily unavailable; allowing up to $ReplacementGraceSeconds seconds for initial validation."
      }
      if (((Get-Date) - $invalidSince).TotalSeconds -ge $ReplacementGraceSeconds) {
        Write-Stage 'WARNING: exact-session state was not found within the bounded validation grace; status monitor is stopping.'
        break
      }
      Start-Sleep -Seconds $PollSeconds
      continue
    }

    $monitorState = $null
    $stateError = $null
    try {
      $monitorState = Get-ExactMonitorState -StatePath $StatePath
    } catch {
      $stateError = $_.Exception.Message
    }
    $tunnelAlive = $false
    if ($monitorState) {
      $tunnelAlive = Test-ReverseTunnelProcess -ProcessId $monitorState.ProcessId -SSHClient $monitorState.SSHClient -TunnelKey $monitorState.TunnelKey
    }
    if (-not $monitorState -or -not $tunnelAlive) {
      if (-not $invalidSince) { $invalidSince = Get-Date }
      $elapsed = ((Get-Date) - $invalidSince).TotalSeconds
      if ($elapsed -ge $ReplacementGraceSeconds) {
        $detail = if ($stateError) { $stateError } elseif ($monitorState) { "exact reverse tunnel PID $($monitorState.ProcessId) is not valid" } else { 'exact-session state is unavailable' }
        Write-Stage "WARNING: $detail after the bounded replacement grace; status monitor is stopping."
        break
      }
      Start-Sleep -Seconds $PollSeconds
      continue
    }

    $invalidSince = $null
    $observedValidState = $true
    $sshd = Get-Service sshd -ErrorAction SilentlyContinue
    $sshdStatus = if ($sshd) { $sshd.Status } else { 'Missing' }
    $activeConnections = @(Get-NetTCPConnection -LocalPort 22 -State Established -ErrorAction SilentlyContinue).Count
    $status = "sshd=$sshdStatus; tunnel=True; tunnel_pid=$($monitorState.ProcessId); active_ssh=$activeConnections; cleanup_complete=False"
    if ($status -ne $lastStatus) {
      Write-Stage "STATUS $status"
      $lastStatus = $status
    }
    Start-Sleep -Seconds $PollSeconds
  }
}

if ($NoMonitor -and $MonitorOnly) {
  throw '-NoMonitor and -MonitorOnly are mutually exclusive.'
}
if ($MonitorOnly) {
  Start-StatusMonitor -StatePath (Join-Path $StateDir 'state.json')
  return
}

function Stop-ExistingReverseTunnel {
  param([Parameter(Mandatory=$true)][string]$SSHClient)
  $taskName = "cc-remote-tunnel-$SessionId"
  $statePath = Join-Path $StateDir 'state.json'
  $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    if ($task) {
      throw "Refusing to replace $taskName because exact-session state is missing: $statePath"
    }
    return
  }

  try {
    $state = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "Refusing to replace the existing tunnel because exact-session state is malformed: $($_.Exception.Message)"
  }
  $expectedKey = Join-Path $StateDir 'tunnel_ed25519'
  $expectedTask = "cc-remote-tunnel-$SessionId"
  $expectedClient = [System.IO.Path]::GetFullPath($SSHClient)
  try {
    $stateClient = [System.IO.Path]::GetFullPath([string]$state.ssh_client)
    $stateKey = [System.IO.Path]::GetFullPath([string]$state.tunnel_key)
  } catch {
    throw 'Refusing to replace the existing tunnel because its recorded paths are invalid.'
  }
  $identityMatches = (
    [string]$state.session_id -ceq $SessionId -and
    [string]$state.tunnel_task -ceq $expectedTask -and
    [string]$state.relay_user -ceq [string]$Manifest.relay_user -and
    [string]$state.relay_host -ceq [string]$Manifest.relay_host -and
    [int]$state.relay_ssh_port -eq [int]$Manifest.relay_ssh_port -and
    [int]$state.remote_port -eq [int]$Manifest.remote_port -and
    $stateClient.Equals($expectedClient, [System.StringComparison]::OrdinalIgnoreCase) -and
    $stateKey.Equals([System.IO.Path]::GetFullPath($expectedKey), [System.StringComparison]::OrdinalIgnoreCase)
  )
  $oldPid = 0
  if (-not [int]::TryParse([string]$state.tunnel_pid, [ref]$oldPid) -or $oldPid -le 0 -or -not $identityMatches) {
    throw 'Refusing to replace the existing tunnel because its recorded exact-session identity does not match this launcher.'
  }
  $oldProcess = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
  if (-not $oldProcess) {
    if ($task) {
      throw "Refusing to replace $taskName because recorded PID $oldPid is absent while the exact-session task still exists."
    }
    Write-Stage "Recorded exact-session tunnel PID $oldPid has already exited; no process or task was changed."
    return
  }
  if (-not (Test-ReverseTunnelProcess -ProcessId $oldPid -SSHClient $SSHClient -TunnelKey $expectedKey)) {
    throw "Refusing to stop PID $oldPid because it is not the exact recorded current-session ssh.exe process."
  }

  if ($task) { Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop }
  if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) {
    Stop-Process -Id $oldPid -Force -ErrorAction Stop
  }
  for ($attempt = 0; $attempt -lt 50 -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue); $attempt++) {
    Start-Sleep -Milliseconds 100
  }
  if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) {
    throw "Exact current-session tunnel PID $oldPid did not exit."
  }
  if ($task) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop }
  Write-Stage "Stopped and removed the previous exact-session reverse tunnel: task=$taskName pid=$oldPid"
}

function ConvertTo-PowerShellLiteral {
  param([Parameter(Mandatory=$true)][string]$Value)
  return "'" + ($Value -replace "'", "''") + "'"
}

function Join-ArgumentList {
  param([Parameter(Mandatory=$true)][string[]]$Arguments)
  $quoted = foreach ($arg in $Arguments) {
    if ($arg -match '[\s"]') { '"' + ($arg -replace '"', '\"') + '"' } else { $arg }
  }
  return ($quoted -join ' ')
}

function Start-ReverseTunnel {
  param([Parameter(Mandatory=$true)][string]$SSHClient)
  Stop-ExistingReverseTunnel -SSHClient $SSHClient
  $bundleKey = Join-Path $Root $Manifest.tunnel_private_key_path
  $key = Join-Path $StateDir 'tunnel_ed25519'
  $knownHosts = Join-Path $StateDir 'known_hosts'
  $log = Join-Path $StateDir 'tunnel.log'
  $handshake = Join-Path $StateDir 'tunnel-startup.json'
  $wrapper = Join-Path $StateDir 'start-tunnel.ps1'
  Copy-Item -Force -Path $bundleKey -Destination $key
  icacls $key /inheritance:r | Out-Null
  icacls $key /remove:g '*S-1-5-32-545' "$env:USERDOMAIN\$env:USERNAME" | Out-Null
  icacls $key /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
  if (-not (Test-Path -LiteralPath $SSHClient -PathType Leaf)) { throw "Resolved ssh.exe does not exist: $SSHClient" }
  Remove-Item -Force -Path $log, $handshake -ErrorAction SilentlyContinue
  $args = @(
    '-vv',
    '-N',
    '-i', $key,
    '-p', [string]$Manifest.relay_ssh_port,
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=15',
    '-o', 'ConnectionAttempts=2',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ServerAliveInterval=30',
    '-o', 'ServerAliveCountMax=3',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', "UserKnownHostsFile=$knownHosts",
    '-o', 'ControlPath=none',
    '-R', "127.0.0.1:$($Manifest.remote_port):127.0.0.1:22",
    "$($Manifest.relay_user)@$($Manifest.relay_host)"
  )
  $argumentLine = Join-ArgumentList -Arguments $args
  $wrapperText = @'
#requires -version 5.1
$ErrorActionPreference = 'Stop'
$sshClient = __SSH_CLIENT__
$argumentLine = __ARGUMENT_LINE__
$handshakePath = __HANDSHAKE_PATH__
$logPath = __LOG_PATH__
function Write-Handshake([string]$Status, [int]$ProcessId, [string]$Message) {
  $tempPath = $handshakePath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
  $backupPath = $handshakePath + '.' + [Guid]::NewGuid().ToString('N') + '.bak'
  try {
    [ordered]@{
      status = $Status
      pid = $ProcessId
      message = $Message
      written_at = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath $tempPath
    if ([System.IO.File]::Exists($handshakePath)) {
      [System.IO.File]::Replace($tempPath, $handshakePath, $backupPath)
    } else {
      [System.IO.File]::Move($tempPath, $handshakePath)
    }
  } finally {
    Remove-Item -LiteralPath $tempPath, $backupPath -Force -ErrorAction SilentlyContinue
  }
}
try {
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $sshClient
  $startInfo.Arguments = $argumentLine
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardError = $true
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  if (-not $process.Start()) { throw 'Failed to start ssh.exe.' }
  Write-Handshake -Status 'started' -ProcessId $process.Id -Message ''

  $failed = $false
  while ($null -ne ($line = $process.StandardError.ReadLine())) {
    Add-Content -Encoding UTF8 -Path $logPath -Value $line
    if ($line -match '(?i)remote forward success for:|forwarding_success: all expected forwarding replies received') {
      Write-Handshake -Status 'ready' -ProcessId $process.Id -Message $line
    } elseif ($line -match '(?i)remote port forwarding failed|Error: remote port forwarding|Could not request local forwarding|Permission denied|Host key verification failed|No more authentication methods to try') {
      Write-Handshake -Status 'failed' -ProcessId $process.Id -Message $line
      $failed = $true
    }
  }
  $process.WaitForExit()
  $exitCode = $process.ExitCode
  if (-not $failed) {
    Write-Handshake -Status 'exited' -ProcessId $process.Id -Message "ssh.exe exited with code $exitCode"
  }
  exit $exitCode
} catch {
  $processId = if ($process -and $process.Id) { $process.Id } else { 0 }
  Write-Handshake -Status 'error' -ProcessId $processId -Message $_.Exception.Message
  exit 1
}
'@
  $wrapperText = $wrapperText.Replace('__SSH_CLIENT__', (ConvertTo-PowerShellLiteral $SSHClient))
  $wrapperText = $wrapperText.Replace('__ARGUMENT_LINE__', (ConvertTo-PowerShellLiteral $argumentLine))
  $wrapperText = $wrapperText.Replace('__HANDSHAKE_PATH__', (ConvertTo-PowerShellLiteral $handshake))
  $wrapperText = $wrapperText.Replace('__LOG_PATH__', (ConvertTo-PowerShellLiteral $log))
  [System.IO.File]::WriteAllText($wrapper, $wrapperText, (New-Object System.Text.UTF8Encoding($false)))

  $taskName = "cc-remote-tunnel-$SessionId"
  if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    throw "Exact-session tunnel task still exists after replacement cleanup: $taskName"
  }
  $taskArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`""
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArguments
  # A past one-time trigger satisfies Task Scheduler registration but can never launch later.
  # The task is started exactly once below, explicitly, after registration completes.
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddDays(-1)
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName $taskName

  $tunnelPid = 0
  $lastHandshakeDetail = 'handshake file was not observed'
  try {
    $handshakeWaitSeconds = 75
    for ($i = 0; $i -lt $handshakeWaitSeconds; $i++) {
      Start-Sleep -Seconds 1
      $startup = $null
      if (Test-Path $handshake) {
        try {
          $startup = Get-Content $handshake -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
          # The wrapper replaces this file atomically. A transient sharing or parse
          # error is not readiness evidence; retry within the bounded window.
          $startup = $null
        }
      }
      if ($startup) {
        $lastHandshakeDetail = "last handshake status=$($startup.status), pid=$($startup.pid), message=$($startup.message)"
        $candidatePid = [int]$startup.pid
        if ($startup.status -eq 'started') {
          if (Test-ReverseTunnelProcess -ProcessId $candidatePid -SSHClient $SSHClient -TunnelKey $key) {
            if ($tunnelPid -eq 0) { $tunnelPid = $candidatePid }
            if ($tunnelPid -ne $candidatePid) { throw 'Tunnel task changed ssh.exe PID before readiness verification.' }
          }
        } elseif ($startup.status -eq 'ready') {
          if ($tunnelPid -ne 0 -and $tunnelPid -ne $candidatePid) {
            throw 'Tunnel ready handshake does not match the exact startup PID.'
          }
          if (-not (Test-ReverseTunnelProcess -ProcessId $candidatePid -SSHClient $SSHClient -TunnelKey $key)) {
            throw 'Tunnel ready handshake did not identify the exact current-session ssh.exe process.'
          }
          $tunnelPid = $candidatePid
          break
        } elseif ($startup.status -eq 'failed' -or $startup.status -eq 'exited' -or $startup.status -eq 'error') {
          throw "Tunnel task startup failed: $($startup.message)"
        }
      }
      $task = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
      if ($task -and $task.LastTaskResult -ne 0 -and $task.LastTaskResult -ne 267009) {
        throw "Tunnel task exited with result $($task.LastTaskResult) before producing a valid ready handshake."
      }
    }
    if ($tunnelPid -eq 0 -or -not $startup -or $startup.status -ne 'ready') {
      throw "Tunnel task did not produce a verified ready handshake within $handshakeWaitSeconds seconds."
    }
    Start-Sleep -Seconds 3
    if (-not (Test-ReverseTunnelProcess -ProcessId $tunnelPid -SSHClient $SSHClient -TunnelKey $key)) {
      throw 'The exact current-session ssh.exe process did not remain stable after forward confirmation.'
    }
    return [pscustomobject]@{ ProcessId = $tunnelPid; KeyPath = $key; HandshakePath = $handshake; WrapperPath = $wrapper; TaskName = $taskName }
  } catch {
    if ($tunnelPid -gt 0 -and (Test-ReverseTunnelProcess -ProcessId $tunnelPid -SSHClient $SSHClient -TunnelKey $key)) {
      Stop-Process -Id $tunnelPid -Force -ErrorAction SilentlyContinue
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    $logDetail = if (Test-Path $log) { (Get-Content $log -Tail 20 -ErrorAction SilentlyContinue) -join [Environment]::NewLine } else { 'tunnel log was not created' }
    throw "$($_.Exception.Message) $lastHandshakeDetail Tunnel log tail: $logDetail"
  }
}

function Stop-ExistingIdleCleanupTask {
  $taskName = "cc-remote-idle-watch-$SessionId"
  $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($task) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    Write-Stage "Stopped and removed the previous exact-session idle cleanup task: $taskName"
  }
}

function Register-IdleCleanupTask($statePath) {
  $idleSeconds = [int]$Manifest.idle_timeout_seconds
  $taskName = "cc-remote-idle-watch-$SessionId"
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -File `"$Root\idle-watch.ps1`" -StatePath `"$statePath`" -IdleSeconds $idleSeconds"
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddDays(-1)
  $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
  Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
  $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
  if (-not $task -or $task.Principal.UserId -notin @('S-1-5-18', 'SYSTEM')) {
    throw "Exact-session idle cleanup task registration could not be verified: $taskName"
  }
}

try {
  Write-Stage 'Checking Administrator privileges.'
  Assert-Admin
  Write-Stage 'Verifying embedded payload hashes.'
  Test-PayloadHashes
  $TargetUser = Resolve-TargetUser
  Write-Stage "Resolved controlled-machine SSH user: $TargetUser"
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  $prevService = Get-Service sshd -ErrorAction SilentlyContinue
  $prevStatus = if ($prevService) { $prevService.Status.ToString() } else { 'Missing' }
  $prevStartMode = if ($prevService) { (Get-CimInstance Win32_Service -Filter "Name = 'sshd'").StartMode } else { 'Missing' }
  Write-Stage "Ensuring OpenSSH Server is installed from local resources; previous sshd status: $prevStatus"
  $openSSH = Ensure-OpenSSHServer
  Write-Stage "OpenSSH Server install mode: $($openSSH.Mode); tunnel client: $($openSSH.SSHClient)"
  Start-SSHD -InstallMode $openSSH.Mode
  Write-Stage 'sshd is running without opening an inbound firewall rule.'
  Stop-ExistingIdleCleanupTask
  $authKeys = Install-AuthorizedKey -TargetUser $TargetUser
  Write-Stage "Verified the session public key in: $authKeys"
  Test-LocalSSHPort
  Write-Stage 'Verified local SSH TCP connectivity on 127.0.0.1:22.'
  $targetHostKeyFingerprint = Get-TargetSSHHostKeyFingerprint -SSHClient $openSSH.SSHClient
  Write-Stage "Verified active sshd ED25519 host-key fingerprint: $targetHostKeyFingerprint"
  Write-Stage "Starting loopback-only reverse tunnel to $($Manifest.relay_host):$($Manifest.relay_ssh_port)."
  $tunnel = Start-ReverseTunnel -SSHClient $openSSH.SSHClient
  $tunnelPid = [int]$tunnel.ProcessId
  $tunnelLog = Join-Path $StateDir 'tunnel.log'
  Write-Stage "Reverse tunnel process is running with PID $tunnelPid; relay forward verified; log: $tunnelLog"
  $state = [ordered]@{
    session_id = $SessionId
    target_user = $TargetUser
    relay_user = $Manifest.relay_user
    relay_host = $Manifest.relay_host
    relay_ssh_port = [int]$Manifest.relay_ssh_port
    remote_port = [int]$Manifest.remote_port
    auth_keys = $authKeys
    tunnel_pid = $tunnelPid
    tunnel_key = $tunnel.KeyPath
    tunnel_task = $tunnel.TaskName
    tunnel_wrapper = $tunnel.WrapperPath
    tunnel_handshake = $tunnel.HandshakePath
    tunnel_log = $tunnelLog
    previous_sshd_status = $prevStatus
    previous_sshd_start_mode = $prevStartMode
    install_mode = $openSSH.Mode
    ssh_client = $openSSH.SSHClient
  }
  $statePath = Join-Path $StateDir 'state.json'
  $summaryPath = Join-Path $StateDir 'status.txt'
  $state | ConvertTo-Json | Set-Content -Encoding UTF8 $statePath
  @(
    "Session: $SessionId"
    "Target user: $TargetUser"
    "Relay: $($Manifest.relay_host):$($Manifest.relay_ssh_port)"
    "Reverse port: $($Manifest.remote_port) (relay loopback only)"
    "Tunnel PID: $tunnelPid"
    "Tunnel log: $tunnelLog"
    "State: $statePath"
    'The target private key remains only on the operator machine.'
  ) | Set-Content -Encoding UTF8 $summaryPath
  Register-IdleCleanupTask $statePath
  Write-Stage "Registered idle cleanup after $($Manifest.idle_timeout_seconds) seconds without an active SSH connection."

  Write-Host ''
  Write-Host '====== COPY THIS COMPLETE BLOCK BACK TO OPERATOR ======'
  Write-Host "CC_REMOTE_READY $SessionId $TargetUser $($Manifest.relay_host) $($Manifest.remote_port)"
  Write-Host "Session ID: $SessionId"
  Write-Host "Controlled-machine user: $TargetUser"
  Write-Host "Relay SSH endpoint: $($Manifest.relay_host):$($Manifest.relay_ssh_port)"
  Write-Host "Relay reverse listener: 127.0.0.1:$($Manifest.remote_port) (loopback-only)"
  Write-Host "Operator SSH alias: $($Manifest.operator_ssh_host_alias)"
  Write-Host "Operator SSH command: $($Manifest.operator_ssh_command)"
  Write-Host "Operator target private-key path: $($Manifest.operator_target_key_path)"
  Write-Host "Operator tunnel private-key path: $($Manifest.operator_tunnel_key_path)"
  Write-Host "Operator SSH config path: $($Manifest.operator_ssh_config_path)"
  Write-Host "Target public-key fingerprint: $($Manifest.target_key_fingerprint)"
  Write-Host "Tunnel public-key fingerprint: $($Manifest.tunnel_key_fingerprint)"
  Write-Host "Target SSH host-key fingerprint: $targetHostKeyFingerprint (verified from active sshd)"
  Write-Host "Windows bootstrap log: $BootstrapLog"
  Write-Host "Windows tunnel log: $tunnelLog"
  Write-Host 'Private-key contents are intentionally omitted. Both private keys remain only on the operator machine.'
  Write-Host '====== END COPY BLOCK ======'
  Write-Host ''
  Write-Host 'cc-remote session is ready.'
  Write-Host "State summary: $summaryPath"
  Write-Host "Manual cleanup: powershell -ExecutionPolicy Bypass -File $Root\cleanup.ps1 -StatePath $statePath"

  if (-not $NoMonitor) {
    Start-StatusMonitor -StatePath $statePath
  }
} catch {
  Write-Host ''
  Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] ERROR: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "Bootstrap source: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkRed
  throw
}
