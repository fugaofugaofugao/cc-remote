#requires -version 5.1
param(
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\cc-remote'),
  [switch]$AddToPath
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Exe = Join-Path $SourceDir 'cc-remote.exe'
if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { throw 'Missing cc-remote.exe. Run this from an extracted cc-remote Windows runtime archive.' }
if (-not (Test-Path -LiteralPath (Join-Path $SourceDir 'bootstrap\bootstrap.ps1') -PathType Leaf)) { throw 'Missing bootstrap\bootstrap.ps1. The archive is incomplete.' }
if (-not (Test-Path -LiteralPath (Join-Path $SourceDir 'bootstrap\bootstrap.sh') -PathType Leaf)) { throw 'Missing bootstrap\bootstrap.sh. The archive is incomplete.' }
if (-not (Test-Path -LiteralPath (Join-Path $SourceDir 'payloads\windows\openssh-win64.zip') -PathType Leaf)) { throw 'Missing bundled Windows OpenSSH payload. Use the full runtime archive.' }

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$localPrograms = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs'))
if ((Split-Path -Leaf $InstallDir) -ne 'cc-remote') { throw "InstallDir must end with cc-remote: $InstallDir" }
if (-not $InstallDir.StartsWith($localPrograms, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing unsafe InstallDir outside LOCALAPPDATA\Programs: $InstallDir" }
$Parent = Split-Path -Parent $InstallDir
New-Item -ItemType Directory -Force -Path $Parent | Out-Null
$Temp = Join-Path $Parent ('.cc-remote-install-' + [Guid]::NewGuid().ToString('N'))
$Backup = $null
try {
  New-Item -ItemType Directory -Force -Path $Temp | Out-Null
  Copy-Item -LiteralPath (Join-Path $SourceDir '*') -Destination $Temp -Recurse -Force
  if (Test-Path -LiteralPath $InstallDir) {
    $Backup = "$InstallDir.previous.$PID"
    Move-Item -LiteralPath $InstallDir -Destination $Backup
  }
  try {
    Move-Item -LiteralPath $Temp -Destination $InstallDir
    $Temp = $null
    if ($Backup -and (Test-Path -LiteralPath $Backup)) { Remove-Item -LiteralPath $Backup -Recurse -Force }
  } catch {
    if ($Backup -and (Test-Path -LiteralPath $Backup) -and -not (Test-Path -LiteralPath $InstallDir)) { Move-Item -LiteralPath $Backup -Destination $InstallDir }
    throw
  }

  $Shim = Join-Path $InstallDir 'cc-remote.cmd'
  $ExePath = Join-Path $InstallDir 'cc-remote.exe'
  Set-Content -LiteralPath $Shim -Encoding ASCII -Value "@echo off`r`n\"$ExePath\" %*`r`n"

  if ($AddToPath) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @($userPath -split ';' | Where-Object { $_ })
    if ($parts -notcontains $InstallDir) {
      $newPath = if ($userPath) { "$userPath;$InstallDir" } else { $InstallDir }
      [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
      Write-Host "Added to user PATH: $InstallDir"
      Write-Host 'Open a new terminal before running cc-remote by name.'
    }
  }

  Write-Host "cc-remote installed to: $InstallDir"
  Write-Host "Command shim: $Shim"
  Write-Host ''
  Write-Host 'Verify with:'
  Write-Host '  cc-remote version'
  Write-Host '  cc-remote doctor --json'
  Write-Host ''
  Write-Host 'Before cc-remote create, configure the relay you control:'
  Write-Host '  cc-remote relay set --host <relay-host> --port <relay-ssh-port> --user cc-tunnel'
  Write-Host 'If relay details are missing, ask the operator before creating a session.'
} finally {
  if ($Temp -and (Test-Path -LiteralPath $Temp)) { Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue }
}
