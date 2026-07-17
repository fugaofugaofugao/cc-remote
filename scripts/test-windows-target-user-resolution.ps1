#requires -version 5.1

param(
  [string]$BootstrapPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'bootstrap\bootstrap.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-Equal([string]$Expected, [string]$Actual, [string]$Message) {
  if ($Expected -cne $Actual) {
    throw "ASSERTION FAILED: $Message; expected='$Expected' actual='$Actual'"
  }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
  $threw = $false
  try { & $Action } catch { $threw = $true }
  if (-not $threw) { throw "ASSERTION FAILED: $Message" }
}

if (-not (Test-Path -LiteralPath $BootstrapPath -PathType Leaf)) {
  throw "Bootstrap source not found: $BootstrapPath"
}
$bootstrap = Get-Content -LiteralPath $BootstrapPath -Raw
$start = $bootstrap.IndexOf('function Get-UnqualifiedWindowsUserName')
$end = $bootstrap.IndexOf('function Find-BundledSSHClient')
if ($start -lt 0 -or $end -le $start) {
  throw 'Could not isolate the production target-user resolver.'
}
Invoke-Expression $bootstrap.Substring($start, $end - $start)

$script:Manifest = [pscustomobject]@{ target_user = 'auto' }
$script:ComputerUser = 'TESTHOST\testuser'
$script:ExplorerOwners = @()
$script:LocalUsers = @{
  testuser = [pscustomobject]@{ Name = 'testuser'; Enabled = $true }
  alice = [pscustomobject]@{ Name = 'alice'; Enabled = $true }
  disabled = [pscustomobject]@{ Name = 'disabled'; Enabled = $false }
}

function Get-CimInstance {
  param([string]$ClassName, [string]$Filter, $ErrorAction)
  if ($ClassName -eq 'Win32_ComputerSystem') {
    return [pscustomobject]@{ UserName = $script:ComputerUser }
  }
  if ($ClassName -eq 'Win32_Process') {
    return @($script:ExplorerOwners | ForEach-Object { [pscustomobject]@{ MockOwner = $_ } })
  }
  return $null
}
function Invoke-CimMethod {
  param($InputObject, [string]$MethodName, $ErrorAction)
  $parts = ([string]$InputObject.MockOwner).Split('\', 2)
  return [pscustomobject]@{
    ReturnValue = 0
    Domain = if ($parts.Count -eq 2) { $parts[0] } else { '' }
    User = if ($parts.Count -eq 2) { $parts[1] } else { $parts[0] }
  }
}
function Get-LocalUser {
  param([string]$Name, $ErrorAction)
  return $script:LocalUsers[$Name]
}

Assert-Equal 'testuser' (Resolve-TargetUser) 'SYSTEM-launched bootstrap did not prefer the signed-in desktop user'
Write-Host 'PASS Win32_ComputerSystem resolves the signed-in local user'

$script:ComputerUser = $null
$script:ExplorerOwners = @('TESTHOST\testuser', 'TESTHOST\testuser')
Assert-Equal 'testuser' (Resolve-TargetUser) 'explorer ownership fallback did not deduplicate one interactive user'
Write-Host 'PASS explorer ownership fallback resolves one unambiguous user'

$script:ExplorerOwners = @('NT AUTHORITY\SYSTEM')
Assert-Throws { Resolve-TargetUser } 'SYSTEM service identity was accepted'
$script:ExplorerOwners = @('NT AUTHORITY\LOCAL SERVICE')
Assert-Throws { Resolve-TargetUser } 'LOCAL SERVICE identity was accepted'
$script:ExplorerOwners = @('NT AUTHORITY\NETWORK SERVICE')
Assert-Throws { Resolve-TargetUser } 'NETWORK SERVICE identity was accepted'
Write-Host 'PASS service identities are rejected'

$script:ExplorerOwners = @('TESTHOST\testuser', 'TESTHOST\alice')
Assert-Throws { Resolve-TargetUser } 'ambiguous interactive users were guessed'
$script:ExplorerOwners = @('TESTHOST\disabled')
Assert-Throws { Resolve-TargetUser } 'disabled local user was accepted'
Write-Host 'PASS ambiguity and disabled accounts fail closed'

$script:Manifest.target_user = 'explicit-user'
Assert-Equal 'explicit-user' (Resolve-TargetUser) 'explicit manifest target user was not preserved'
Write-Host 'PASS explicit manifest target user is preserved'

Write-Host 'ALL WINDOWS POWERSHELL 5.1 TARGET-USER RESOLUTION TESTS PASSED'
