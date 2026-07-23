package main

import (
	"archive/zip"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/fugaofugaofugao/cc-remote/internal/session"
)

func captureStdout(t *testing.T, action func() error) (string, error) {
	t.Helper()
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	original := os.Stdout
	os.Stdout = writer
	defer func() { os.Stdout = original }()
	actionErr := action()
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	os.Stdout = original
	output, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := reader.Close(); err != nil {
		t.Fatal(err)
	}
	return string(output), actionErr
}

func onlySessionRecord(t *testing.T) (session.Record, string) {
	t.Helper()
	base, err := session.BaseDir()
	if err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Join(base, "sessions"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected one session, got %d", len(entries))
	}
	path := filepath.Join(base, "sessions", entries[0].Name(), "record.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var rec session.Record
	if err := json.Unmarshal(data, &rec); err != nil {
		t.Fatal(err)
	}
	return rec, path
}

func assertNoSessionArtifacts(t *testing.T) {
	t.Helper()
	base, err := session.BaseDir()
	if err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Join(base, "sessions"))
	if err == nil && len(entries) != 0 {
		t.Fatalf("validation failure created %d session directories", len(entries))
	}
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
}

func TestWindowsCreateRequiresVerifiedOfflineOpenSSH(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	payloadRoot := t.TempDir()
	err := run([]string{"cc-remote", "create", "--name", "missing-payload", "--platform", "windows", "--relay-host", "relay.example.test", "--relay-port", "22", "--install-relay=false", "--payload-root", payloadRoot})
	if err == nil || !strings.Contains(err.Error(), windowsOpenSSHPayload) {
		t.Fatalf("expected missing Windows payload error, got %v", err)
	}
	entries, readErr := os.ReadDir(filepath.Join(os.Getenv("HOME"), ".cc-remote", "sessions"))
	if readErr == nil && len(entries) != 0 {
		t.Fatalf("missing payload validation created %d session directories", len(entries))
	}
}

func TestNonWindowsCreateDoesNotRequireWindowsPayload(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := run([]string{"cc-remote", "create", "--name", "mac-only", "--platform", "macos", "--relay-host", "relay.example.test", "--relay-port", "22", "--install-relay=false", "--payload-root", t.TempDir()}); err != nil {
		t.Fatal(err)
	}
}

func TestCreateJSONStdoutIsPureJSON(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	out, err := captureStdout(t, func() error {
		return run([]string{"cc-remote", "create", "--json", "--name", "json-only", "--platform", "macos", "--launcher-format", "command", "--relay-host", "relay.example.test", "--relay-port", "22", "--install-relay=false", "--payload-root", t.TempDir()})
	})
	if err != nil {
		t.Fatal(err)
	}
	var result createResult
	if err := json.Unmarshal([]byte(out), &result); err != nil {
		t.Fatalf("create --json stdout is not pure JSON: %v\n%s", err, out)
	}
	if !result.OK || result.SessionID == "" || result.LauncherFormat != "command" || result.HandoffMode != "embedded" {
		t.Fatalf("unexpected create result: %+v", result)
	}
	if strings.Contains(out, "Generating public/private") || strings.Contains(out, "randomart") {
		t.Fatalf("create --json stdout contains ssh-keygen noise:\n%s", out)
	}
}

func TestCreateRejectsIncompatibleLauncherFormat(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	err := run([]string{"cc-remote", "create", "--name", "bad-format", "--platform", "linux", "--launcher-format", "cmd", "--relay-host", "relay.example.test", "--relay-port", "22", "--install-relay=false", "--payload-root", t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "--platform linux cannot generate cmd launcher") {
		t.Fatalf("expected incompatible format error, got %v", err)
	}
	assertNoSessionArtifacts(t)
}

func TestMacOSCreateBuildsParseableCommandWithoutWindowsPayload(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := run([]string{"cc-remote", "create", "--name", "mac-command", "--platform", "macos", "--relay-host", "relay.example.test", "--relay-port", "22", "--install-relay=false", "--payload-root", t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	base, err := session.BaseDir()
	if err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Join(base, "sessions"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected one session, got %d", len(entries))
	}
	recordBytes, err := os.ReadFile(filepath.Join(base, "sessions", entries[0].Name(), "record.json"))
	if err != nil {
		t.Fatal(err)
	}
	var rec session.Record
	if err := json.Unmarshal(recordBytes, &rec); err != nil {
		t.Fatal(err)
	}
	if rec.HandoffCommandPath == "" {
		t.Fatal("macOS record is missing .command path")
	}
	if rec.HandoffCMDPath != "" || rec.HandoffPS1Path != "" || rec.HandoffShPath != "" {
		t.Fatal("macOS record unexpectedly contains other launcher paths")
	}
	commandBytes, err := os.ReadFile(rec.HandoffCommandPath)
	if err != nil {
		t.Fatal(err)
	}
	commandText := string(commandBytes)
	for _, marker := range []string{"#!/bin/sh", `if [ -z "${BASH_VERSION:-}" ]; then`, `exec /bin/bash "$0" "$@"`, "exec sudo", "/bin/bash", "bootstrap.log", "mkfifo", "tee -a", "trap 'on_error", "Press Return", "CC_REMOTE_LOG", "cat > \"$zip.b64\" <<'EOF'", `base64 -D -i "$zip.b64" -o "$zip"`} {
		if !strings.Contains(commandText, marker) {
			t.Fatalf("macOS launcher missing %q", marker)
		}
	}
	if info, err := os.Stat(rec.HandoffCommandPath); err != nil || info.Mode()&0o100 == 0 {
		t.Fatal("macOS .command launcher is not executable")
	}
	if strings.Contains(commandText, "BEGIN OPENSSH PRIVATE KEY") {
		t.Fatal("macOS launcher unexpectedly exposes a private key marker outside its embedded bundle encoding")
	}
	if strings.Contains(commandText, "> >(") || strings.Contains(commandText, "base64 --help") {
		t.Fatal("macOS launcher contains a known shell compatibility regression")
	}
	if out, err := exec.Command("/bin/sh", "-n", rec.HandoffCommandPath).CombinedOutput(); err != nil {
		t.Fatalf("macOS launcher cannot be parsed when invoked with sh: %v\n%s", err, out)
	}
}

func TestWindowsBootstrapIsOfflineFirst(t *testing.T) {
	assetRoot, err := findAssetRoot()
	if err != nil {
		t.Fatal(err)
	}
	textBytes, err := os.ReadFile(filepath.Join(assetRoot, "bootstrap", "bootstrap.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(textBytes)
	if strings.Contains(text, "Add-WindowsCapability") || strings.Contains(text, "Get-WindowsCapability") {
		t.Fatal("Windows bootstrap still depends on Windows capability installation")
	}
	for _, want := range []string{"openssh-win64.zip", "Test-LocalSSHPort", "BatchMode=yes", "ConnectTimeout=15", "Start-ReverseTunnel -SSHClient", "Verified local SSH TCP connectivity", "cc-remote will not change the startup type of an existing machine service"} {
		if !strings.Contains(text, want) {
			t.Fatalf("Windows bootstrap missing %q", want)
		}
	}
	if strings.Contains(text, "New-NetFirewallRule") {
		t.Fatal("Windows bootstrap opens an unnecessary inbound firewall rule")
	}
	if strings.Contains(text, "Set-Service -Name sshd") {
		t.Fatal("Windows bootstrap changes the startup type of the shared sshd service")
	}
	flowStart := strings.Index(text, "Write-Stage 'sshd is running without opening an inbound firewall rule.'")
	if flowStart == -1 {
		t.Fatal("Windows bootstrap main flow marker is missing")
	}
	flow := text[flowStart:]
	localCheck := strings.Index(flow, "Test-LocalSSHPort")
	tunnelCheck := strings.Index(flow, "Start-ReverseTunnel -SSHClient")
	ready := strings.Index(flow, "CC_REMOTE_READY")
	if localCheck == -1 || tunnelCheck == -1 || ready == -1 || localCheck > tunnelCheck || tunnelCheck > ready {
		t.Fatal("Windows bootstrap emits READY before local SSH and reverse tunnel verification")
	}
}

func TestWindowsTunnelUsesExactStartupHandshake(t *testing.T) {
	assetRoot, err := findAssetRoot()
	if err != nil {
		t.Fatal(err)
	}
	textBytes, err := os.ReadFile(filepath.Join(assetRoot, "bootstrap", "bootstrap.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(textBytes)
	if strings.Contains(text, "AddMinutes(1)") {
		t.Fatal("Windows tunnel or cleanup task still has a runnable one-minute delayed trigger")
	}
	starterStart := strings.Index(text, "function Start-ReverseTunnel")
	starterEnd := strings.Index(text, "function Stop-ExistingIdleCleanupTask")
	if starterStart == -1 || starterEnd <= starterStart {
		t.Fatal("cannot isolate Windows reverse-tunnel starter")
	}
	if count := strings.Count(text[starterStart:starterEnd], "Start-ScheduledTask -TaskName $taskName"); count != 1 {
		t.Fatalf("expected exactly one explicit tunnel task start, got %d", count)
	}
	for _, required := range []string{
		"tunnel-startup.json",
		"start-tunnel.ps1",
		"System.Diagnostics.ProcessStartInfo",
		"$startInfo.UseShellExecute = $false",
		"$startInfo.CreateNoWindow = $true",
		"$startInfo.RedirectStandardError = $true",
		"$process.StandardError.ReadLine()",
		"$backupPath = $handshakePath + '.' + [Guid]::NewGuid().ToString('N') + '.bak'",
		"[System.IO.File]::Replace($tempPath, $handshakePath, $backupPath)",
		"[System.IO.File]::Move($tempPath, $handshakePath)",
		"Remove-Item -LiteralPath $tempPath, $backupPath -Force -ErrorAction SilentlyContinue",
		"Add-Content -Encoding UTF8 -Path $logPath -Value $line",
		"Write-Handshake -Status 'ready' -ProcessId $process.Id -Message $line",
		"Write-Handshake -Status 'started'",
		"Write-Handshake -Status 'failed' -ProcessId $process.Id -Message $line",
		"if (-not $failed) {",
		"$lastHandshakeDetail = \"last handshake status=$($startup.status), pid=$($startup.pid), message=$($startup.message)\"",
		"Tunnel log tail:",
		"$startup.status -eq 'ready'",
		"Tunnel ready handshake does not match the exact startup PID.",
		"Test-ReverseTunnelProcess -ProcessId $candidatePid",
		"$process.ExecutablePath",
		"$expectedPort",
		"$expectedTarget",
		"$process.CommandLine -like \"*$TunnelKey*\"",
		"remote forward success for:",
		"forwarding_success: all expected forwarding replies received",
		"The exact current-session ssh.exe process did not remain stable after forward confirmation.",
		"Stop-Process -Id $tunnelPid -Force",
		"Unregister-ScheduledTask -TaskName $taskName",
		"AddDays(-1)",
		"MultipleInstances IgnoreNew",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("Windows tunnel startup is missing %q", required)
		}
	}
	for _, forbidden := range []string{
		"'-E', $log",
		"[System.IO.File]::Replace($tempPath, $handshakePath, $null)",
		"Register-ObjectEvent",
		"ErrorDataReceived",
		"BeginErrorReadLine",
		"Unregister-Event",
		"Remove-Job",
		"$Event.",
		"$forwardWaitSeconds",
		"Read the complete log once more after the polling window",
		"if (-not $forwardConfirmed -and (Test-Path $log))",
	} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("Windows tunnel startup retains buffered-log readiness path %q", forbidden)
		}
	}
	flowStart := strings.Index(text, "Write-Stage 'sshd is running without opening an inbound firewall rule.'")
	if flowStart == -1 {
		t.Fatal("Windows bootstrap main flow marker is missing")
	}
	flow := text[flowStart:]
	forwardEvidence := strings.Index(flow, "relay forward verified")
	ready := strings.Index(flow, "CC_REMOTE_READY")
	if forwardEvidence == -1 || ready == -1 || forwardEvidence > ready {
		t.Fatal("Windows bootstrap emits READY before explicit relay-forward verification")
	}
}

func TestWindowsExistingTunnelReplacementIsExactAndFailClosed(t *testing.T) {
	assetRoot, err := findAssetRoot()
	if err != nil {
		t.Fatal(err)
	}
	textBytes, err := os.ReadFile(filepath.Join(assetRoot, "bootstrap", "bootstrap.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(textBytes)
	for _, required := range []string{
		"function Stop-ExistingReverseTunnel",
		"$statePath = Join-Path $StateDir 'state.json'",
		"Refusing to replace $taskName because exact-session state is missing",
		"exact-session state is malformed",
		"its recorded paths are invalid",
		"[string]$state.session_id -ceq $SessionId",
		"[string]$state.tunnel_task -ceq $expectedTask",
		"[string]$state.relay_user -ceq [string]$Manifest.relay_user",
		"[string]$state.relay_host -ceq [string]$Manifest.relay_host",
		"[int]$state.relay_ssh_port -eq [int]$Manifest.relay_ssh_port",
		"[int]$state.remote_port -eq [int]$Manifest.remote_port",
		"$stateClient.Equals($expectedClient",
		"$stateKey.Equals([System.IO.Path]::GetFullPath($expectedKey)",
		"[int]::TryParse([string]$state.tunnel_pid, [ref]$oldPid)",
		"$oldProcess = Get-Process -Id $oldPid -ErrorAction SilentlyContinue",
		"recorded PID $oldPid is absent while the exact-session task still exists",
		"Recorded exact-session tunnel PID $oldPid has already exited; no process or task was changed.",
		"Test-ReverseTunnelProcess -ProcessId $oldPid -SSHClient $SSHClient -TunnelKey $expectedKey",
		"Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop",
		"Stop-Process -Id $oldPid -Force -ErrorAction Stop",
		"Exact current-session tunnel PID $oldPid did not exit.",
		"Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop",
		"Stop-ExistingReverseTunnel -SSHClient $SSHClient",
		"Exact-session tunnel task still exists after replacement cleanup",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("Windows existing-tunnel replacement is missing %q", required)
		}
	}

	start := strings.Index(text, "function Stop-ExistingReverseTunnel")
	end := strings.Index(text, "function ConvertTo-PowerShellLiteral")
	if start == -1 || end == -1 || start >= end {
		t.Fatal("cannot isolate Windows existing-tunnel replacement helper")
	}
	helper := text[start:end]
	validate := strings.Index(helper, "Test-ReverseTunnelProcess -ProcessId $oldPid")
	stopTask := strings.Index(helper, "Stop-ScheduledTask -TaskName $taskName")
	stopProcess := strings.Index(helper, "Stop-Process -Id $oldPid")
	unregister := strings.Index(helper, "Unregister-ScheduledTask -TaskName $taskName")
	if validate == -1 || stopTask == -1 || stopProcess == -1 || unregister == -1 || validate > stopTask || validate > stopProcess || stopProcess > unregister {
		t.Fatal("Windows replacement does not validate exact process identity before stopping and unregistering it")
	}
	startTunnel := strings.Index(text, "function Start-ReverseTunnel")
	if startTunnel == -1 {
		t.Fatal("Windows reverse-tunnel starter is missing")
	}
	starter := text[startTunnel:]
	cleanup := strings.Index(starter, "Stop-ExistingReverseTunnel -SSHClient $SSHClient")
	copyKey := strings.Index(starter, "Copy-Item -Force -Path $bundleKey -Destination $key")
	postcondition := strings.Index(starter, "Exact-session tunnel task still exists after replacement cleanup")
	register := strings.Index(starter, "Register-ScheduledTask -TaskName $taskName")
	if cleanup == -1 || copyKey == -1 || postcondition == -1 || register == -1 || cleanup > copyKey || postcondition > register {
		t.Fatal("Windows starter does not complete exact-session cleanup before replacing key material and registering the new task")
	}
	if strings.Contains(starter[:register], "Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue") {
		t.Fatal("Windows starter silently unregisters a leftover tunnel task outside the validated replacement helper")
	}
	for _, forbidden := range []string{"Get-Process ssh", "Get-Process -Name ssh", "Stop-Process -Name ssh", "taskkill /IM ssh.exe", "taskkill.exe /IM ssh.exe"} {
		if strings.Contains(helper, forbidden) {
			t.Fatalf("Windows replacement broadly targets SSH processes via %q", forbidden)
		}
	}
}

func TestWindowsIdleCleanupTaskUsesVerifiedSystemPrincipal(t *testing.T) {
	assetRoot, err := findAssetRoot()
	if err != nil {
		t.Fatal(err)
	}
	textBytes, err := os.ReadFile(filepath.Join(assetRoot, "bootstrap", "bootstrap.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(textBytes)
	start := strings.Index(text, "function Register-IdleCleanupTask")
	if start == -1 {
		t.Fatal("cannot find Windows idle cleanup registration helper")
	}
	end := strings.Index(text[start:], "\ntry {")
	if end == -1 {
		t.Fatal("cannot isolate Windows idle cleanup registration helper")
	}
	helper := text[start : start+end]
	for _, required := range []string{
		`$taskName = "cc-remote-idle-watch-$SessionId"`,
		"New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest",
		"New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries",
		"Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop",
		"Start-ScheduledTask -TaskName $taskName -ErrorAction Stop",
		"Get-ScheduledTask -TaskName $taskName -ErrorAction Stop",
		"$task.Principal.UserId -notin @('S-1-5-18', 'SYSTEM')",
		"Exact-session idle cleanup task registration could not be verified",
	} {
		if !strings.Contains(helper, required) {
			t.Fatalf("Windows idle cleanup registration is missing %q", required)
		}
	}
	register := strings.Index(helper, "Register-ScheduledTask")
	startTask := strings.Index(helper, "Start-ScheduledTask")
	verify := strings.LastIndex(helper, "Get-ScheduledTask")
	if register == -1 || startTask == -1 || verify == -1 || register > startTask || startTask > verify {
		t.Fatal("Windows idle cleanup task is not registered, started, and verified in order")
	}
	flowStart := strings.Index(text, "Register-IdleCleanupTask $statePath")
	ready := strings.Index(text, "CC_REMOTE_READY")
	if flowStart == -1 || ready == -1 || flowStart > ready {
		t.Fatal("Windows bootstrap can emit READY before mandatory idle cleanup registration")
	}
}

func TestWindowsTargetUserResolutionRejectsServiceIdentity(t *testing.T) {
	assetRoot, err := findAssetRoot()
	if err != nil {
		t.Fatal(err)
	}
	textBytes, err := os.ReadFile(filepath.Join(assetRoot, "bootstrap", "bootstrap.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(textBytes)
	for _, required := range []string{
		"function Test-ServiceIdentityName",
		`'(?i)^(SYSTEM|LOCAL SERVICE|NETWORK SERVICE|LOCAL SYSTEM|ANONYMOUS LOGON|DEFAULTACCOUNT|WDAGUTILITYACCOUNT)$'`,
		"$name.EndsWith('$')",
		"Get-CimInstance Win32_ComputerSystem",
		`Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'"`,
		"Invoke-CimMethod -InputObject $process -MethodName GetOwner",
		"Sort-Object -Unique",
		"$resolved.Count -ne 1",
		"Get-LocalUser -Name $resolved[0]",
		"-not $user.Enabled",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("Windows interactive-user resolver is missing %q", required)
		}
	}
	resolverStart := strings.Index(text, "function Resolve-TargetUser")
	resolverEnd := strings.Index(text, "function Find-BundledSSHClient")
	if resolverStart == -1 || resolverEnd <= resolverStart {
		t.Fatal("Windows target-user resolver could not be isolated")
	}
	resolver := text[resolverStart:resolverEnd]
	if strings.Contains(resolver, "WindowsIdentity]::GetCurrent().Name") {
		t.Fatal("Windows auto target-user resolution still trusts the elevated process identity")
	}
}

func TestWindowsAuthorizationAndOperatorHandoffAreExact(t *testing.T) {
	assetRoot, err := findAssetRoot()
	if err != nil {
		t.Fatal(err)
	}
	textBytes, err := os.ReadFile(filepath.Join(assetRoot, "bootstrap", "bootstrap.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(textBytes)
	for _, required := range []string{
		`$BootstrapLog = Join-Path $StateDir 'bootstrap.log'`,
		`$expected = ([string]$Manifest.target_authorized_key).Trim()`,
		`$marker = "cc-remote:$SessionId"`,
		`$_ -notmatch [regex]::Escape($marker)`,
		`$reconciled += $expected`,
		`$_ -ceq $expected`,
		`$verified.Count -ne 1 -or $stale.Count -ne 0`,
		`'ssh\administrators_authorized_keys'`,
		`New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')`,
		`$acl.SetOwner($administratorsSid)`,
		`Set-Acl -LiteralPath $auth -AclObject $acl`,
		`/inheritance:r /grant:r '*S-1-5-32-544:F' /grant:r '*S-1-5-18:F'`,
		`$ownerSid -ne 'S-1-5-32-544'`,
		`$acl.AreAccessRulesProtected`,
		`$fullControlSids -notcontains 'S-1-5-32-544'`,
		`$fullControlSids -notcontains 'S-1-5-18'`,
		`function Stop-ExistingIdleCleanupTask`,
		`Stop-ScheduledTask -TaskName $taskName`,
		`Unregister-ScheduledTask -TaskName $taskName`,
		`Write-Stage "Verified the session public key in: $authKeys"`,
		`====== COPY THIS COMPLETE BLOCK BACK TO OPERATOR ======`,
		`Operator SSH command: $($Manifest.operator_ssh_command)`,
		`Operator target private-key path: $($Manifest.operator_target_key_path)`,
		`Operator tunnel private-key path: $($Manifest.operator_tunnel_key_path)`,
		`Target public-key fingerprint: $($Manifest.target_key_fingerprint)`,
		`Tunnel public-key fingerprint: $($Manifest.tunnel_key_fingerprint)`,
		`function Get-TargetSSHHostKeyFingerprint`,
		`'ssh\ssh_host_ed25519_key.pub'`,
		`& $sshKeygen -lf $hostPublicKey -E sha256`,
		`$targetHostKeyFingerprint = Get-TargetSSHHostKeyFingerprint -SSHClient $openSSH.SSHClient`,
		`Target SSH host-key fingerprint: $targetHostKeyFingerprint (verified from active sshd)`,
		`Windows bootstrap log: $BootstrapLog`,
		`Windows tunnel log: $tunnelLog`,
		`Private-key contents are intentionally omitted.`,
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("Windows authorization or handoff is missing %q", required)
		}
	}
	flowStart := strings.Index(text, "Write-Stage 'sshd is running without opening an inbound firewall rule.'")
	if flowStart == -1 {
		t.Fatal("Windows bootstrap main flow marker is missing")
	}
	flow := text[flowStart:]
	stopOldWatcher := strings.Index(flow, "Stop-ExistingIdleCleanupTask")
	installKey := strings.Index(flow, "Install-AuthorizedKey -TargetUser")
	localSSH := strings.Index(flow, "Test-LocalSSHPort")
	ready := strings.Index(flow, "CC_REMOTE_READY")
	if stopOldWatcher == -1 || installKey == -1 || localSSH == -1 || ready == -1 || stopOldWatcher > installKey || installKey > localSSH || localSSH > ready {
		t.Fatal("Windows bootstrap does not stop the old watcher, verify the key, and verify local SSH before READY")
	}
	if strings.Contains(text, "BEGIN OPENSSH PRIVATE KEY") {
		t.Fatal("Windows visible bootstrap contains private-key body material")
	}
	if strings.Contains(text, `Target SSH host-key fingerprint: $($Manifest.target_host_key_fingerprint)`) {
		t.Fatal("Windows handoff trusts stale manifest target host-key metadata")
	}
}

func TestWindowsCleanupNeverChangesSSHDService(t *testing.T) {
	assetRoot, err := findAssetRoot()
	if err != nil {
		t.Fatal(err)
	}
	textBytes, err := os.ReadFile(filepath.Join(assetRoot, "bootstrap", "cleanup.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(textBytes)
	for _, forbidden := range []string{"Stop-Service sshd", "Stop-Service -Name sshd", "Set-Service -Name sshd", "Remove-Service sshd", "sc.exe stop sshd", "sc.exe delete sshd", "Uninstall-sshd.ps1"} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("Windows cleanup may alter the shared sshd service via %q", forbidden)
		}
	}
	for _, required := range []string{`cc-remote:$($State.session_id)`, "Get-CimInstance Win32_Process", `$State.relay_user`, `$State.relay_ssh_port`, `$State.tunnel_key`, `$State.ssh_client`, `$process.ExecutablePath`, `cc-remote-idle-watch-$($State.session_id)`, `cc-remote-tunnel-$($State.session_id)`} {
		if !strings.Contains(text, required) {
			t.Fatalf("Windows cleanup is missing exact session cleanup marker %q", required)
		}
	}
}

func TestUnixCleanupNeverChangesSharedSSHService(t *testing.T) {
	assetRoot, err := findAssetRoot()
	if err != nil {
		t.Fatal(err)
	}
	textBytes, err := os.ReadFile(filepath.Join(assetRoot, "bootstrap", "cleanup.sh"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(textBytes)
	for _, forbidden := range []string{
		"launchctl unload",
		"launchctl disable",
		"launchctl bootout",
		"systemsetup -setremotelogin off",
		"systemctl stop ssh",
		"systemctl stop sshd",
		"systemctl disable ssh",
		"systemctl disable sshd",
	} {
		if strings.Contains(text, forbidden) {
			t.Fatalf("Unix cleanup may alter a shared SSH service via %q", forbidden)
		}
	}
	for _, required := range []string{
		`grep -v "cc-remote:${SESSION_ID}"`,
		`ps -p "$TUNNEL_PID" -o comm=`,
		`ps -p "$TUNNEL_PID" -o command=`,
		`[ "$(basename "$command_name")" = "ssh" ]`,
		`expected_forward="127.0.0.1:${REMOTE_PORT:-}:127.0.0.1:22"`,
		`expected_port="-p ${RELAY_SSH_PORT:-}"`,
		`expected_target="${RELAY_USER:-}@${RELAY_HOST:-}"`,
		`grep -F -- "$TUNNEL_KEY"`,
		"stopped verified session tunnel process",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("Unix cleanup is missing exact session validation marker %q", required)
		}
	}
}

func TestUnixStateRecordsTunnelIdentity(t *testing.T) {
	assetRoot, err := findAssetRoot()
	if err != nil {
		t.Fatal(err)
	}
	textBytes, err := os.ReadFile(filepath.Join(assetRoot, "bootstrap", "bootstrap.sh"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(textBytes)
	for _, required := range []string{
		"RELAY_USER='$RELAY_USER'",
		"RELAY_HOST='$RELAY_HOST'",
		"RELAY_SSH_PORT='$RELAY_SSH_PORT'",
		"REMOTE_PORT='$REMOTE_PORT'",
		"TUNNEL_KEY='$ROOT_DIR/keys/tunnel_ed25519'",
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("Unix state is missing tunnel identity field %q", required)
		}
	}
}

func TestCreateBuildsUsableSessionBundle(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	payloadRoot := t.TempDir()
	payloadPath := filepath.Join(payloadRoot, "windows", "openssh-win64.zip")
	if err := os.MkdirAll(filepath.Dir(payloadPath), 0o755); err != nil {
		t.Fatal(err)
	}
	assetRoot, err := findAssetRoot()
	if err != nil {
		t.Fatal(err)
	}
	payloadBytes, err := os.ReadFile(filepath.Join(assetRoot, "payloads", "windows", "openssh-win64.zip"))
	if errors.Is(err, os.ErrNotExist) {
		t.Skip("source-only tree does not include the optional pinned Windows OpenSSH payload")
	}
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(payloadPath, payloadBytes, 0o644); err != nil {
		t.Fatal(err)
	}

	if err := run([]string{"cc-remote", "create", "--name", "unit", "--platform", "windows", "--relay-host", "relay.example.test", "--relay-port", "22", "--relay-user", "cc-tunnel", "--install-relay=false", "--target-user", "tester", "--max-lifetime", "30m", "--idle-timeout", "15m", "--payload-root", payloadRoot}); err != nil {
		t.Fatal(err)
	}

	base, err := session.BaseDir()
	if err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Join(base, "sessions"))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected one session, got %d", len(entries))
	}

	recordPath := filepath.Join(base, "sessions", entries[0].Name(), "record.json")
	recordBytes, err := os.ReadFile(recordPath)
	if err != nil {
		t.Fatal(err)
	}
	var rec session.Record
	if err := json.Unmarshal(recordBytes, &rec); err != nil {
		t.Fatal(err)
	}
	if rec.TunnelKeyPath == "" {
		t.Fatal("record is missing tunnel key path")
	}
	if rec.HandoffCMDPath == "" {
		t.Fatal("Windows record is missing default .cmd handoff script path")
	}
	if rec.HandoffPS1Path != "" || rec.HandoffShPath != "" || rec.HandoffCommandPath != "" {
		t.Fatal("Windows default record unexpectedly contains non-default launcher paths")
	}
	if rec.ConnectionMDPath == "" || rec.ConnectionJSONPath == "" || rec.SSHConfigPath == "" || rec.SSHHostAlias == "" {
		t.Fatal("record is missing connection artifact paths")
	}
	if rec.IdleTimeout != "15m0s" {
		t.Fatalf("expected idle timeout 15m0s, got %s", rec.IdleTimeout)
	}
	if !strings.Contains(rec.RelayAuthKey, "cc-remote:"+rec.ID) {
		t.Fatalf("relay authorized key missing session marker: %s", rec.RelayAuthKey)
	}
	manifestBytes, err := os.ReadFile(filepath.Join(base, "sessions", entries[0].Name(), "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var sessionManifest struct {
		OperatorTargetKeyPath string `json:"operator_target_key_path"`
		OperatorTunnelKeyPath string `json:"operator_tunnel_key_path"`
		OperatorSSHConfigPath string `json:"operator_ssh_config_path"`
		OperatorSSHHostAlias  string `json:"operator_ssh_host_alias"`
		OperatorSSHCommand    string `json:"operator_ssh_command"`
		TargetKeyFingerprint  string `json:"target_key_fingerprint"`
		TunnelKeyFingerprint  string `json:"tunnel_key_fingerprint"`
		TargetAuthorizedKey   string `json:"target_authorized_key"`
		TunnelPrivateKeyPath  string `json:"tunnel_private_key_path"`
		Payloads              []struct {
			Path   string `json:"path"`
			SHA256 string `json:"sha256"`
			Size   int64  `json:"size"`
		} `json:"payloads"`
	}
	if err := json.Unmarshal(manifestBytes, &sessionManifest); err != nil {
		t.Fatal(err)
	}
	if len(sessionManifest.Payloads) != 1 || sessionManifest.Payloads[0].Path != windowsOpenSSHPayload || sessionManifest.Payloads[0].SHA256 != windowsOpenSSHSHA256 || sessionManifest.Payloads[0].Size != int64(len(payloadBytes)) {
		t.Fatalf("unexpected Windows payload manifest: %+v", sessionManifest.Payloads)
	}
	for name, value := range map[string]string{
		"operator_target_key_path": sessionManifest.OperatorTargetKeyPath,
		"operator_tunnel_key_path": sessionManifest.OperatorTunnelKeyPath,
		"operator_ssh_config_path": sessionManifest.OperatorSSHConfigPath,
		"operator_ssh_host_alias":  sessionManifest.OperatorSSHHostAlias,
		"operator_ssh_command":     sessionManifest.OperatorSSHCommand,
		"target_key_fingerprint":   sessionManifest.TargetKeyFingerprint,
		"tunnel_key_fingerprint":   sessionManifest.TunnelKeyFingerprint,
		"target_authorized_key":    sessionManifest.TargetAuthorizedKey,
		"tunnel_private_key_path":  sessionManifest.TunnelPrivateKeyPath,
	} {
		if value == "" {
			t.Fatalf("session manifest is missing %s", name)
		}
	}
	if sessionManifest.OperatorTargetKeyPath != rec.TargetKeyPath ||
		sessionManifest.OperatorTunnelKeyPath != rec.TunnelKeyPath ||
		sessionManifest.OperatorSSHConfigPath != rec.SSHConfigPath ||
		sessionManifest.OperatorSSHHostAlias != rec.SSHHostAlias {
		t.Fatal("session manifest operator paths or alias do not match the record")
	}
	if !strings.Contains(sessionManifest.OperatorSSHCommand, "ssh -F") || !strings.Contains(sessionManifest.OperatorSSHCommand, rec.SSHHostAlias) {
		t.Fatalf("unexpected operator SSH command: %s", sessionManifest.OperatorSSHCommand)
	}
	if !strings.HasPrefix(sessionManifest.TargetKeyFingerprint, "SHA256:") || !strings.HasPrefix(sessionManifest.TunnelKeyFingerprint, "SHA256:") {
		t.Fatal("session manifest is missing public-key fingerprints")
	}
	if strings.Contains(string(manifestBytes), "BEGIN OPENSSH PRIVATE KEY") {
		t.Fatal("session manifest contains private-key body material")
	}

	cmdBytes, err := os.ReadFile(rec.HandoffCMDPath)
	if err != nil {
		t.Fatal(err)
	}
	cmdText := string(cmdBytes)
	for _, marker := range []string{"chcp 65001", "Start-Process", "-Verb RunAs", "bootstrap.log", "Tee-Object", "pause", "#__CC_REMOTE_PAYLOAD_BEGIN__", "#__CC_REMOTE_PAYLOAD_END__"} {
		if !strings.Contains(cmdText, marker) {
			t.Fatalf("Windows launcher missing %q", marker)
		}
	}
	if strings.Contains(cmdText, "^& $env:ROOT") || strings.Contains(cmdText, "$_ ^| Out-String") {
		t.Fatal("Windows launcher passes CMD caret escapes through to PowerShell")
	}
	setupPipeline := "try { & $env:ROOT\\bootstrap.ps1 -NoMonitor *>&1 | Tee-Object"
	monitorInvocation := `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\bootstrap.ps1" -MonitorOnly`
	setupPos := strings.Index(cmdText, setupPipeline)
	monitorPos := strings.Index(cmdText, monitorInvocation)
	if setupPos == -1 {
		t.Fatal("Windows launcher is missing the finite -NoMonitor all-stream setup pipeline")
	}
	if monitorPos == -1 || monitorPos < setupPos {
		t.Fatal("Windows launcher must start -MonitorOnly only after finite setup succeeds")
	}
	monitorLineEnd := strings.Index(cmdText[monitorPos:], "\n")
	if monitorLineEnd == -1 {
		monitorLineEnd = len(cmdText) - monitorPos
	}
	monitorLine := cmdText[monitorPos : monitorPos+monitorLineEnd]
	if strings.Contains(monitorLine, "Tee-Object") || strings.Contains(monitorLine, "bootstrap.log") || strings.Contains(monitorLine, "%LOG%") {
		t.Fatal("Windows -MonitorOnly invocation must remain outside every bootstrap log pipeline")
	}
	failurePos := strings.Index(cmdText, `if not "%RC%"=="0" goto :bootstrap_failed`)
	if failurePos == -1 || failurePos > monitorPos {
		t.Fatal("Windows launcher must branch on setup failure before starting -MonitorOnly")
	}
	logDirPos := strings.Index(cmdText, `if not exist "%ProgramData%\cc-remote\sessions\`)
	decodePos := strings.Index(cmdText, "Decoding the embedded offline bundle")
	if logDirPos == -1 || decodePos == -1 || logDirPos > decodePos {
		t.Fatal("Windows launcher must create its persistent log directory before decoding")
	}
	if !strings.Contains(cmdText, `WriteAllBytes($env:ZIP`) || !strings.Contains(cmdText, `>>"%LOG%" 2>&1`) {
		t.Fatal("Windows launcher does not persist pre-bootstrap extraction failures")
	}

	for _, path := range []string{rec.ConnectionMDPath, rec.ConnectionJSONPath, rec.SSHConfigPath} {
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(b), "BEGIN OPENSSH PRIVATE KEY") {
			t.Fatalf("connection artifact contains private key body: %s", path)
		}
	}
	mdBytes, err := os.ReadFile(rec.ConnectionMDPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"relay.example.test:22", "tester", rec.TargetKeyPath, rec.TunnelKeyPath, "ssh -F", rec.SSHHostAlias} {
		if !strings.Contains(string(mdBytes), want) {
			t.Fatalf("connection.md missing %q", want)
		}
	}
	configBytes, err := os.ReadFile(rec.SSHConfigPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Host " + rec.SSHHostAlias, "User tester", "ProxyCommand", "127.0.0.1:", "HostKeyAlias \"" + rec.SSHHostAlias + "\"", "UserKnownHostsFile "} {
		if !strings.Contains(string(configBytes), want) {
			t.Fatalf("ssh_config missing %q", want)
		}
	}

	readyLine := "CC_REMOTE_READY " + rec.ID + " detected-user relay.example.test 39999"
	if err := run([]string{"cc-remote", "ready", readyLine}); err != nil {
		t.Fatal(err)
	}
	updatedConfig, err := os.ReadFile(rec.SSHConfigPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"User detected-user", "relay.example.test", "127.0.0.1:39999"} {
		if !strings.Contains(string(updatedConfig), want) {
			t.Fatalf("updated ssh_config missing %q", want)
		}
	}
	updatedJSON, err := os.ReadFile(rec.ConnectionJSONPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`"status": "ready"`, `"target_user": "detected-user"`, `"relay_host": "relay.example.test"`, `"reverse_port": 39999`} {
		if !strings.Contains(string(updatedJSON), want) {
			t.Fatalf("updated connection.json missing %q", want)
		}
	}

	zr, err := zip.OpenReader(rec.BundlePath)
	if err != nil {
		t.Fatal(err)
	}
	defer zr.Close()
	want := map[string]bool{
		"manifest.json":                      false,
		"keys/tunnel_ed25519":                false,
		"bootstrap.sh":                       false,
		"bootstrap.ps1":                      false,
		"cleanup.sh":                         false,
		"cleanup.ps1":                        false,
		"idle-watch.sh":                      false,
		"idle-watch.ps1":                     false,
		"payloads/windows/openssh-win64.zip": false,
	}
	for _, f := range zr.File {
		if _, ok := want[f.Name]; ok {
			want[f.Name] = true
		}
	}
	for name, found := range want {
		if !found {
			t.Fatalf("bundle missing %s", name)
		}
	}

	t.Setenv("HOME", t.TempDir())
	if err := run([]string{"cc-remote", "create", "--name", "unit-both", "--platform", "windows", "--launcher-format", "both", "--relay-host", "relay.example.test", "--relay-port", "22", "--relay-user", "cc-tunnel", "--install-relay=false", "--target-user", "tester", "--payload-root", payloadRoot}); err != nil {
		t.Fatal(err)
	}
	rec, _ = onlySessionRecord(t)
	if rec.HandoffCMDPath == "" || rec.HandoffPS1Path == "" {
		t.Fatal("Windows --launcher-format both should create both .cmd and .ps1 launchers")
	}
}

func TestCreateValidationLeavesNoSessionArtifacts(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want string
	}{
		{name: "missing relay host", args: []string{"--platform", "macos"}, want: "--relay-host is required"},
		{name: "relay port zero", args: []string{"--platform", "macos", "--relay-host", "relay.example.test", "--relay-port", "0"}, want: "invalid --relay-port"},
		{name: "relay port too large", args: []string{"--platform", "macos", "--relay-host", "relay.example.test", "--relay-port", "65536"}, want: "invalid --relay-port"},
		{name: "reverse port negative", args: []string{"--platform", "macos", "--relay-host", "relay.example.test", "--remote-port", "-1"}, want: "invalid --remote-port"},
		{name: "reverse port too large", args: []string{"--platform", "macos", "--relay-host", "relay.example.test", "--remote-port", "65536"}, want: "invalid --remote-port"},
		{name: "install missing administrative host", args: []string{"--platform", "macos", "--relay-host", "relay.example.test", "--install-relay=true"}, want: "--relay-ssh-host is required"},
		{name: "invalid relay user", args: []string{"--platform", "macos", "--relay-host", "relay.example.test", "--relay-user", "bad user;touch /tmp/nope"}, want: "invalid relay user"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			args := append([]string{"cc-remote", "create", "--payload-root", t.TempDir()}, test.args...)
			err := run(args)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("expected error containing %q, got %v", test.want, err)
			}
			assertNoSessionArtifacts(t)
		})
	}
}

func TestDefaultCreatePrintsRestrictedAuthorizationWithoutRelayMutation(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	output, err := captureStdout(t, func() error {
		return run([]string{"cc-remote", "create", "--name", "manual-relay", "--platform", "macos", "--relay-host", "relay.example.test", "--payload-root", t.TempDir()})
	})
	if err != nil {
		t.Fatal(err)
	}
	rec, _ := onlySessionRecord(t)
	if rec.RelayInstalled || rec.RelaySSHHost != "" || rec.RelayInstallCmd != "" {
		t.Fatalf("default create recorded relay mutation: %+v", rec)
	}
	for _, want := range []string{
		rec.RelayAuthKey,
		`permitopen="127.0.0.1:`,
		`permitlisten="127.0.0.1:`,
		"no-pty",
		"no-X11-forwarding",
		"cc-remote:" + rec.ID,
		"Relay authorization installation: skipped",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("create output missing %q", want)
		}
	}
	if strings.Contains(output, "BEGIN OPENSSH PRIVATE KEY") {
		t.Fatal("create output contains private-key body material")
	}
}

func TestExplicitRelayInstallUsesConfiguredAdministrativeDestination(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	fakeBin := t.TempDir()
	invocationPath := filepath.Join(t.TempDir(), "ssh-invocation.txt")
	fakeSSH := filepath.Join(fakeBin, "ssh")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CC_REMOTE_TEST_SSH_INVOCATION\"\n"
	if err := os.WriteFile(fakeSSH, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CC_REMOTE_TEST_SSH_INVOCATION", invocationPath)
	t.Setenv("PATH", fakeBin+string(os.PathListSeparator)+os.Getenv("PATH"))
	if err := run([]string{"cc-remote", "create", "--name", "installed-relay", "--platform", "macos", "--relay-host", "relay.example.test", "--relay-ssh-host", "relay-admin", "--install-relay=true", "--payload-root", t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	invocation, err := os.ReadFile(invocationPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(invocation)
	if !strings.HasPrefix(text, "relay-admin\n") || !strings.Contains(text, "cc-remote:") || !strings.Contains(text, "127.0.0.1:") {
		t.Fatalf("unexpected fake ssh invocation:\n%s", text)
	}
	rec, _ := onlySessionRecord(t)
	if !rec.RelayInstalled || rec.RelaySSHHost != "relay-admin" || rec.RelayInstallCmd == "" {
		t.Fatalf("explicit install was not recorded accurately: %+v", rec)
	}
}

func TestReadyValidationPreservesArtifactsByteForByte(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := run([]string{"cc-remote", "create", "--name", "ready-validation", "--platform", "macos", "--relay-host", "relay.example.test", "--payload-root", t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	rec, recordPath := onlySessionRecord(t)
	paths := []string{recordPath, rec.SSHConfigPath, rec.ConnectionMDPath, rec.ConnectionJSONPath}
	before := make(map[string][]byte, len(paths))
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		before[path] = data
	}
	invalid := []struct {
		name string
		line string
		want string
	}{
		{name: "relay host", line: "CC_REMOTE_READY " + rec.ID + " target-user other-relay.example.test 41001", want: "does not match configured relay host"},
		{name: "reverse port", line: "CC_REMOTE_READY " + rec.ID + " target-user relay.example.test 65536", want: "invalid READY reverse port"},
	}
	for _, test := range invalid {
		t.Run(test.name, func(t *testing.T) {
			err := run([]string{"cc-remote", "ready", test.line})
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("expected error containing %q, got %v", test.want, err)
			}
			for _, path := range paths {
				after, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				if string(after) != string(before[path]) {
					t.Fatalf("READY validation changed %s", path)
				}
			}
		})
	}
}

func TestUsageAndRelayGuidanceAreProviderNeutral(t *testing.T) {
	output, err := captureStdout(t, func() error {
		usage()
		return initRelay([]string{})
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"public Linux/OpenSSH relay you control", "GatewayPorts no", "cc-tunnel"} {
		if !strings.Contains(output, want) {
			t.Fatalf("provider-neutral guidance missing %q", want)
		}
	}
	for _, forbidden := range []string{"ali" + "yun", "Ali" + "yun", "ali" + "cloud"} {
		if strings.Contains(output, forbidden) {
			t.Fatalf("provider-specific guidance leaked %q", forbidden)
		}
	}
}

func TestDefaultCloseMakesNoRemoteRelayChange(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := run([]string{"cc-remote", "create", "--name", "manual-close", "--platform", "macos", "--relay-host", "relay.example.test", "--payload-root", t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	rec, _ := onlySessionRecord(t)
	fakeBin := t.TempDir()
	invocationPath := filepath.Join(t.TempDir(), "unexpected-ssh.txt")
	fakeSSH := filepath.Join(fakeBin, "ssh")
	script := "#!/bin/sh\nprintf invoked > \"$CC_REMOTE_TEST_SSH_INVOCATION\"\nexit 97\n"
	if err := os.WriteFile(fakeSSH, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CC_REMOTE_TEST_SSH_INVOCATION", invocationPath)
	t.Setenv("PATH", fakeBin+string(os.PathListSeparator)+os.Getenv("PATH"))
	output, err := captureStdout(t, func() error {
		return run([]string{"cc-remote", "close", rec.ID})
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(invocationPath); !os.IsNotExist(err) {
		t.Fatalf("default close invoked ssh; stat error=%v", err)
	}
	if !strings.Contains(output, "no remote relay change was made") || strings.Contains(output, "marker removed") {
		t.Fatalf("default close reported inaccurate relay mutation:\n%s", output)
	}
}

func TestMalformedInstalledRelayRecordFailsClosed(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := run([]string{"cc-remote", "create", "--name", "malformed-close", "--platform", "macos", "--relay-host", "relay.example.test", "--payload-root", t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	rec, recordPath := onlySessionRecord(t)
	rec.RelayInstalled = true
	rec.RelaySSHHost = ""
	data, err := json.MarshalIndent(rec, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	data = append(data, '\n')
	if err := os.WriteFile(recordPath, data, 0o600); err != nil {
		t.Fatal(err)
	}
	before, err := os.ReadFile(recordPath)
	if err != nil {
		t.Fatal(err)
	}
	err = run([]string{"cc-remote", "close", rec.ID})
	if err == nil || !strings.Contains(err.Error(), "no administrative relay SSH host") {
		t.Fatalf("expected fail-closed malformed record error, got %v", err)
	}
	after, err := os.ReadFile(recordPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(before) {
		t.Fatal("failed close changed malformed installed record")
	}
}
