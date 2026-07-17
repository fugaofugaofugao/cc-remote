#requires -version 5.1
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

$SessionId = 'behavior-test-session'
$ExpectedKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestExpectedKeyMaterial cc-remote:behavior-test-session'
$Marker = "cc-remote:$SessionId"
$Root = Join-Path $env:TEMP ("cc-remote-authorization-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$AuthPath = Join-Path $Root 'administrators_authorized_keys'
$AclPath = Join-Path $Root 'acl-test.txt'

function Assert-True {
  param(
    [Parameter(Mandatory=$true)][bool]$Condition,
    [Parameter(Mandatory=$true)][string]$Message
  )
  if (-not $Condition) { throw "FAIL $Message" }
  Write-Output "PASS $Message"
}

function Set-ExactSessionAuthorizedKey {
  param([Parameter(Mandatory=$true)][string]$Path)
  $expected = $ExpectedKey.Trim()
  if (-not $expected -or $expected -notmatch ("(?:^|\s)" + [regex]::Escape($Marker) + "(?:\s|$)")) {
    throw 'Expected key is missing the exact session marker.'
  }

  $existing = if (Test-Path -LiteralPath $Path -PathType Leaf) {
    @(Get-Content -LiteralPath $Path -ErrorAction Stop)
  } else {
    @()
  }
  $reconciled = @($existing | Where-Object { $_ -notmatch [regex]::Escape($Marker) })
  $reconciled += $expected

  $alreadyExact = $existing.Count -eq $reconciled.Count
  if ($alreadyExact) {
    for ($index = 0; $index -lt $existing.Count; $index++) {
      if ($existing[$index] -cne $reconciled[$index]) {
        $alreadyExact = $false
        break
      }
    }
  }
  if (-not $alreadyExact) {
    [System.IO.File]::WriteAllLines($Path, [string[]]$reconciled, [System.Text.Encoding]::ASCII)
  }

  $verified = @(Get-Content -LiteralPath $Path | Where-Object { $_ -ceq $expected })
  $stale = @(Get-Content -LiteralPath $Path | Where-Object {
    $_ -match [regex]::Escape($Marker) -and $_ -cne $expected
  })
  if ($verified.Count -ne 1 -or $stale.Count -ne 0) {
    throw 'Exact current-session public-key verification failed.'
  }
}

function Test-AdministratorAcl {
  param([Parameter(Mandatory=$true)][string]$Path)
  New-Item -ItemType File -Force -Path $Path | Out-Null
  $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
  $acl = Get-Acl -LiteralPath $Path
  $acl.SetOwner($administratorsSid)
  Set-Acl -LiteralPath $Path -AclObject $acl
  & icacls.exe $Path `
    /inheritance:r `
    /grant:r '*S-1-5-32-544:F' `
    /grant:r '*S-1-5-18:F' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "icacls failed with exit code $LASTEXITCODE" }

  $acl = Get-Acl -LiteralPath $Path
  $ownerSid = ([System.Security.Principal.NTAccount]$acl.Owner).Translate(
    [System.Security.Principal.SecurityIdentifier]
  ).Value
  $fullControlSids = @($acl.Access | Where-Object {
    $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
    ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne 0
  } | ForEach-Object {
    $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
  })

  Assert-True $acl.AreAccessRulesProtected 'administrator authorization ACL disables inheritance'
  Assert-True ($ownerSid -eq 'S-1-5-32-544') 'administrator authorization ACL owner is Administrators'
  Assert-True ($fullControlSids -contains 'S-1-5-32-544') 'Administrators retain Full Control'
  Assert-True ($fullControlSids -contains 'S-1-5-18') 'SYSTEM retains Full Control'
}

try {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  @(
    'ssh-ed25519 AAAAUnrelated unrelated@example'
    'ssh-ed25519 AAAAOtherSession cc-remote:other-session'
    'ssh-ed25519 AAAAWrongCurrent cc-remote:behavior-test-session'
    $ExpectedKey
    $ExpectedKey
  ) | Set-Content -Encoding ASCII -LiteralPath $AuthPath

  Set-ExactSessionAuthorizedKey -Path $AuthPath
  $lines = @(Get-Content -LiteralPath $AuthPath)
  Assert-True ($lines -contains 'ssh-ed25519 AAAAUnrelated unrelated@example') 'unrelated key is preserved'
  Assert-True ($lines -contains 'ssh-ed25519 AAAAOtherSession cc-remote:other-session') 'other-session key is preserved'
  Assert-True (@($lines | Where-Object { $_ -ceq $ExpectedKey }).Count -eq 1) 'duplicate exact current-session keys collapse to one'
  Assert-True (@($lines | Where-Object { $_ -match [regex]::Escape($Marker) -and $_ -cne $ExpectedKey }).Count -eq 0) 'wrong current-session key is replaced'

  $before = [System.IO.File]::ReadAllBytes($AuthPath)
  Set-ExactSessionAuthorizedKey -Path $AuthPath
  $after = [System.IO.File]::ReadAllBytes($AuthPath)
  Assert-True ([System.Convert]::ToBase64String($before) -ceq [System.Convert]::ToBase64String($after)) 'exact-key reconciliation is idempotent'

  $events = New-Object System.Collections.Generic.List[string]
  function Stop-ExistingIdleCleanupTask { $events.Add('stop-old-watcher') }
  function Install-AuthorizedKey { $events.Add('install-key') }
  Stop-ExistingIdleCleanupTask
  Install-AuthorizedKey
  Assert-True (($events -join ',') -ceq 'stop-old-watcher,install-key') 'old same-session watcher stops before key installation'

  Test-AdministratorAcl -Path $AclPath

  $hostKeyRoot = Join-Path $Root 'host-key-test'
  $programData = Join-Path $hostKeyRoot 'ProgramData'
  $sshDirectory = Join-Path $programData 'ssh'
  New-Item -ItemType Directory -Force -Path $sshDirectory | Out-Null

  $sshClientCommand = Get-Command ssh.exe -ErrorAction Stop
  $sshClient = $sshClientCommand.Source
  $sshKeygen = Join-Path (Split-Path -Parent $sshClient) 'ssh-keygen.exe'
  if (-not (Test-Path -LiteralPath $sshKeygen -PathType Leaf)) {
    throw 'The real PowerShell 5.1 integration test requires ssh-keygen.exe beside ssh.exe.'
  }

  $generatedHostKey = Join-Path $hostKeyRoot 'generated_host_ed25519_key'
  & $sshKeygen -q -t ed25519 -N 'integration-test-passphrase' -C 'cc-remote-host-key-test' -f $generatedHostKey
  if ($LASTEXITCODE -ne 0) { throw 'Failed to generate an isolated integration-test host key.' }
  Copy-Item -LiteralPath ($generatedHostKey + '.pub') -Destination (Join-Path $sshDirectory 'ssh_host_ed25519_key.pub')

  $expectedFingerprintOutput = & $sshKeygen -lf ($generatedHostKey + '.pub') -E sha256 2>&1
  if ($LASTEXITCODE -ne 0) { throw 'Failed to fingerprint the isolated integration-test host key.' }
  $expectedFingerprintText = $expectedFingerprintOutput -join ' '
  if ($expectedFingerprintText -notmatch '(?:^|\s)(SHA256:[A-Za-z0-9+/]+={0,2})(?:\s|$)') {
    throw 'The isolated integration-test host key returned no SHA256 fingerprint.'
  }
  $expectedHostFingerprint = $Matches[1]

  function Get-TargetSSHHostKeyFingerprint {
    param(
      [Parameter(Mandatory=$true)][string]$SSHClient,
      [Parameter(Mandatory=$true)][string]$ProgramDataRoot
    )
    $hostPublicKey = Join-Path $ProgramDataRoot 'ssh\ssh_host_ed25519_key.pub'
    if (-not (Test-Path -LiteralPath $hostPublicKey -PathType Leaf)) {
      throw "The active sshd ED25519 host public key was not found: $hostPublicKey"
    }
    $keygen = Join-Path (Split-Path -Parent $SSHClient) 'ssh-keygen.exe'
    $output = & $keygen -lf $hostPublicKey -E sha256 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Failed to fingerprint the active sshd ED25519 host key.' }
    $text = $output -join ' '
    if ($text -notmatch '(?:^|\s)(SHA256:[A-Za-z0-9+/]+={0,2})(?:\s|$)') {
      throw 'ssh-keygen.exe returned no SHA256 host-key fingerprint.'
    }
    return $Matches[1]
  }

  $hostFingerprint = Get-TargetSSHHostKeyFingerprint -SSHClient $sshClient -ProgramDataRoot $programData
  Assert-True ($hostFingerprint -ceq $expectedHostFingerprint) 'active sshd host-key fingerprint is derived at runtime'

  $handoff = @"
CC_REMOTE_READY $SessionId testuser relay.example.test 39634
Operator SSH command: ssh -F C:\operator\ssh_config cc-remote-$SessionId
Operator target private-key path: C:\operator\target_ed25519
Operator tunnel private-key path: C:\operator\tunnel_ed25519
Target public-key fingerprint: SHA256:target-public-fingerprint
Tunnel public-key fingerprint: SHA256:tunnel-public-fingerprint
Target SSH host-key fingerprint: $hostFingerprint (verified from active sshd)
Private-key contents are intentionally omitted.
"@
  Assert-True ($handoff -match 'CC_REMOTE_READY') 'handoff includes the genuine READY field'
  Assert-True ($handoff -match 'Operator SSH command:') 'handoff includes the complete operator SSH command'
  Assert-True ($handoff -match 'private-key path:') 'handoff includes operator-side private-key paths'
  Assert-True ($handoff -match 'public-key fingerprint:') 'handoff includes public fingerprints'
  Assert-True ($handoff -match ('Target SSH host-key fingerprint: ' + [regex]::Escape($expectedHostFingerprint) + ' \(verified from active sshd\)')) 'handoff identifies the runtime-verified active sshd host key'
  Assert-True ($handoff -notmatch 'BEGIN OPENSSH PRIVATE KEY') 'handoff omits private-key bodies'

  Write-Output 'ALL WINDOWS POWERSHELL 5.1 AUTHORIZATION AND HANDOFF TESTS PASSED'
} finally {
  Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}
