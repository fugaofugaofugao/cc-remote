package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/fugaofugaofugao/cc-remote/internal/bundle"
	"github.com/fugaofugaofugao/cc-remote/internal/manifest"
	"github.com/fugaofugaofugao/cc-remote/internal/session"
)

const (
	autoTargetUser        = "auto"
	windowsOpenSSHPayload = "payloads/windows/openssh-win64.zip"
	windowsOpenSSHSHA256  = "23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5"
)

func main() {
	if err := run(os.Args); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) < 2 {
		usage()
		return nil
	}
	switch args[1] {
	case "create":
		return create(args[2:])
	case "ready":
		return ready(args[2:])
	case "list":
		return list()
	case "show":
		return show(args[2:])
	case "ssh":
		return ssh(args[2:])
	case "close":
		return closeSession(args[2:])
	case "init-relay":
		return initRelay(args[2:])
	default:
		usage()
		return fmt.Errorf("unknown command %q", args[1])
	}
}

func usage() {
	fmt.Println(`cc-remote temporary SSH access tool

Commands:
  create      create a foolproof one-shot handoff script and session bundle
  ready       paste the CC_REMOTE_READY line back to save the detected target user
  list        list local sessions
  show        print the complete operator-side connection information
  ssh         connect to a session target through the relay
  close       print cleanup instructions and mark local session closed
  init-relay  print relay setup/check guidance`)
}

func create(args []string) error {
	fs := flag.NewFlagSet("create", flag.ExitOnError)
	name := fs.String("name", "", "session name")
	relayHost := fs.String("relay-host", "", "public hostname or address of your SSH relay")
	relayUser := fs.String("relay-user", "cc-tunnel", "dedicated relay tunnel user")
	relayPort := fs.Int("relay-port", 22, "public SSH port of your relay")
	relaySSHHost := fs.String("relay-ssh-host", "", "administrative SSH host or alias used only with --install-relay")
	installRelay := fs.Bool("install-relay", false, "explicitly install relay authorization through --relay-ssh-host")
	targetUser := fs.String("target-user", autoTargetUser, "target machine login user; use auto to detect on controlled machine")
	maxLifetime := fs.Duration("max-lifetime", 7*24*time.Hour, "hard safety lifetime for local record")
	legacyTTL := fs.Duration("ttl", 0, "deprecated alias for --max-lifetime")
	idleTimeout := fs.Duration("idle-timeout", 2*time.Hour, "cleanup after this much time with no active SSH connection")
	payloadRoot := fs.String("payload-root", "payloads", "offline payload root")
	platform := fs.String("platform", "all", "launcher platform: windows, macos, linux, or all")
	remotePort := fs.Int("remote-port", 0, "relay reverse port; auto if 0")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *legacyTTL != 0 {
		*maxLifetime = *legacyTTL
	}
	*relayHost = strings.TrimSpace(*relayHost)
	*relaySSHHost = strings.TrimSpace(*relaySSHHost)
	if *relayHost == "" {
		return errors.New("--relay-host is required; configure the public endpoint of a relay you control")
	}
	if *relayPort < 1 || *relayPort > 65535 {
		return fmt.Errorf("invalid --relay-port %d: use a port from 1 to 65535", *relayPort)
	}
	if *remotePort < 0 || *remotePort > 65535 {
		return fmt.Errorf("invalid --remote-port %d: use 0 for automatic selection or a port from 1 to 65535", *remotePort)
	}
	if *installRelay && *relaySSHHost == "" {
		return errors.New("--relay-ssh-host is required with --install-relay; it must name your administrative SSH destination")
	}
	if *targetUser == "" {
		*targetUser = autoTargetUser
	}
	*platform = strings.ToLower(strings.TrimSpace(*platform))
	if *platform != "windows" && *platform != "macos" && *platform != "linux" && *platform != "all" {
		return fmt.Errorf("invalid --platform %q: use windows, macos, linux, or all", *platform)
	}
	payloads, err := collectPlatformPayloads(*payloadRoot, *platform)
	if err != nil {
		return err
	}

	id, err := session.NewID()
	if err != nil {
		return err
	}
	if *name == "" {
		*name = id
	}
	port := *remotePort
	if port == 0 {
		port, err = session.PortFromID(id)
		if err != nil {
			return err
		}
	}
	base, err := session.EnsureDirs()
	if err != nil {
		return err
	}
	sessDir := filepath.Join(base, "sessions", id)
	if err := os.MkdirAll(sessDir, 0o700); err != nil {
		return err
	}

	tunnelKey := filepath.Join(sessDir, "tunnel_ed25519")
	targetKey := filepath.Join(sessDir, "target_ed25519")
	if err := sshKeygen(tunnelKey, "cc-remote tunnel "+id); err != nil {
		return err
	}
	if err := sshKeygen(targetKey, "cc-remote target "+id); err != nil {
		return err
	}
	tunnelPub, err := os.ReadFile(tunnelKey + ".pub")
	if err != nil {
		return err
	}
	targetPub, err := os.ReadFile(targetKey + ".pub")
	if err != nil {
		return err
	}
	targetFingerprint, err := publicKeyFingerprint(targetKey + ".pub")
	if err != nil {
		return err
	}
	tunnelFingerprint, err := publicKeyFingerprint(tunnelKey + ".pub")
	if err != nil {
		return err
	}
	connectionMD := filepath.Join(sessDir, "connection.md")
	connectionJSON := filepath.Join(sessDir, "connection.json")
	sshConfig := filepath.Join(sessDir, "ssh_config")
	hostAlias := "cc-remote-" + id
	operatorSSHCommand := fmt.Sprintf("ssh -F %s %s", shellQuote(sshConfig), shellQuote(hostAlias))

	created := time.Now().UTC()
	m := manifest.Manifest{
		Version:               1,
		SessionID:             id,
		Name:                  *name,
		CreatedAt:             created,
		ExpiresAt:             created.Add(*maxLifetime),
		IdleTimeoutSeconds:    int(idleTimeout.Seconds()),
		RelayHost:             *relayHost,
		RelayUser:             *relayUser,
		RelaySSHPort:          *relayPort,
		RemotePort:            port,
		TargetUser:            *targetUser,
		TargetAuthorizedKey:   strings.TrimSpace(string(targetPub)) + " cc-remote:" + id,
		TunnelPrivateKeyPath:  "keys/tunnel_ed25519",
		OperatorTargetKeyPath: targetKey,
		OperatorTunnelKeyPath: tunnelKey,
		OperatorSSHConfigPath: sshConfig,
		OperatorSSHHostAlias:  hostAlias,
		OperatorSSHCommand:    operatorSSHCommand,
		TargetKeyFingerprint:  targetFingerprint,
		TunnelKeyFingerprint:  tunnelFingerprint,
	}
	m.Payloads = payloads

	manifestPath := filepath.Join(sessDir, "manifest.json")
	if err := writeJSON(manifestPath, m, 0o600); err != nil {
		return err
	}

	assetRoot, err := findAssetRoot()
	if err != nil {
		return err
	}
	files := map[string]string{
		"manifest.json":       manifestPath,
		"keys/tunnel_ed25519": tunnelKey,
		"bootstrap.sh":        filepath.Join(assetRoot, "bootstrap", "bootstrap.sh"),
		"bootstrap.ps1":       filepath.Join(assetRoot, "bootstrap", "bootstrap.ps1"),
		"cleanup.sh":          filepath.Join(assetRoot, "bootstrap", "cleanup.sh"),
		"cleanup.ps1":         filepath.Join(assetRoot, "bootstrap", "cleanup.ps1"),
		"idle-watch.sh":       filepath.Join(assetRoot, "bootstrap", "idle-watch.sh"),
		"idle-watch.ps1":      filepath.Join(assetRoot, "bootstrap", "idle-watch.ps1"),
	}
	for _, payload := range payloads {
		src := filepath.Join(*payloadRoot, strings.TrimPrefix(payload.Path, "payloads/"))
		files[payload.Path] = src
	}
	bundlePath := filepath.Join(base, "bundles", "cc-remote-session-"+id+".zip")
	if err := bundle.CreateZip(bundlePath, files); err != nil {
		return err
	}

	relayAuth := fmt.Sprintf("permitopen=\"127.0.0.1:%d\",permitlisten=\"127.0.0.1:%d\",no-pty,no-X11-forwarding %s cc-remote:%s", port, port, strings.TrimSpace(string(tunnelPub)), id)
	relayInstalled := false
	relayInstallCmd := ""
	if *installRelay {
		relayInstallCmd = relayInstallCommand(*relayUser, relayAuth)
		if err := runRelayInstall(*relaySSHHost, relayInstallCmd); err != nil {
			return err
		}
		relayInstalled = true
	}

	handoffCMD := filepath.Join(sessDir, "cc-remote-"+id+".cmd")
	handoffPS1 := filepath.Join(sessDir, "cc-remote-"+id+".ps1")
	handoffSh := filepath.Join(sessDir, "cc-remote-"+id+".sh")
	handoffCommand := filepath.Join(sessDir, "cc-remote-"+id+".command")
	bundleCMD := filepath.Join(base, "bundles", "cc-remote-"+id+".cmd")
	bundlePS1 := filepath.Join(base, "bundles", "cc-remote-"+id+".ps1")
	bundleSh := filepath.Join(base, "bundles", "cc-remote-"+id+".sh")
	bundleCommand := filepath.Join(base, "bundles", "cc-remote-"+id+".command")
	if *platform == "windows" || *platform == "all" {
		if err := writeWindowsHandoffScripts(bundlePath, handoffCMD, handoffPS1, id); err != nil {
			return err
		}
		if err := copyFile(bundleCMD, handoffCMD, 0o600); err != nil {
			return err
		}
		if err := copyFile(bundlePS1, handoffPS1, 0o600); err != nil {
			return err
		}
	} else {
		bundleCMD, bundlePS1 = "", ""
	}
	if *platform == "linux" || *platform == "all" {
		if err := writeUnixHandoffScript(bundlePath, handoffSh, id); err != nil {
			return err
		}
		if err := copyFile(bundleSh, handoffSh, 0o700); err != nil {
			return err
		}
	} else {
		bundleSh = ""
	}
	if *platform == "macos" || *platform == "all" {
		if err := writeUnixHandoffScript(bundlePath, handoffCommand, id); err != nil {
			return err
		}
		if err := copyFile(bundleCommand, handoffCommand, 0o700); err != nil {
			return err
		}
	} else {
		bundleCommand = ""
	}

	rec := session.Record{
		ID:                 id,
		Name:               *name,
		CreatedAt:          created,
		ExpiresAt:          m.ExpiresAt,
		IdleTimeout:        idleTimeout.String(),
		RelayHost:          *relayHost,
		RelayUser:          *relayUser,
		RelaySSHPort:       *relayPort,
		RelaySSHHost:       *relaySSHHost,
		RemotePort:         port,
		TargetUser:         *targetUser,
		BundlePath:         bundlePath,
		HandoffCMDPath:     bundleCMD,
		HandoffPS1Path:     bundlePS1,
		HandoffShPath:      bundleSh,
		HandoffCommandPath: bundleCommand,
		ConnectionMDPath:   connectionMD,
		ConnectionJSONPath: connectionJSON,
		SSHConfigPath:      sshConfig,
		SSHHostAlias:       hostAlias,
		TargetKeyPath:      targetKey,
		TunnelKeyPath:      tunnelKey,
		TunnelPubKey:       strings.TrimSpace(string(tunnelPub)),
		RelayAuthKey:       relayAuth,
		RelayInstalled:     relayInstalled,
		RelayInstallCmd:    relayInstallCmd,
	}
	if err := writeJSON(filepath.Join(sessDir, "record.json"), rec, 0o600); err != nil {
		return err
	}
	if err := writeConnectionArtifacts(rec); err != nil {
		return err
	}

	fmt.Println("Session created:", id)
	if bundleCMD != "" {
		fmt.Println("Windows double-click launcher:", bundleCMD)
		fmt.Println("Windows PowerShell fallback:", bundlePS1)
	}
	if bundleCommand != "" {
		fmt.Println("macOS double-click launcher:", bundleCommand)
	}
	if bundleSh != "" {
		fmt.Println("Unix shell fallback:", bundleSh)
	}
	fmt.Println("Relay endpoint:", *relayHost+":"+strconv.Itoa(*relayPort))
	if relayInstalled {
		fmt.Println("Relay authorization installation: installed through", *relaySSHHost)
	} else {
		fmt.Println("Relay authorization installation: skipped; install this restricted authorized_keys line on your relay:")
		fmt.Println(relayAuth)
	}
	fmt.Println("Idle cleanup:", idleTimeout.String(), "after the last SSH connection becomes inactive")
	fmt.Println("Operator connection guide:", connectionMD)
	fmt.Println("Machine-readable connection data:", connectionJSON)
	fmt.Println("Session SSH config:", sshConfig)
	fmt.Println()
	if bundleCMD != "" {
		fmt.Println("Windows: send the .cmd file; double-click it and approve the UAC prompt.")
	}
	if bundleCommand != "" {
		fmt.Println("macOS: send the .command file; double-click it and enter the Mac login password once.")
	}
	fmt.Println("The status window stays open and displays the persistent log and connection summary.")
	fmt.Println()
	fmt.Println("Process only the genuine CC_REMOTE_READY line shown after tunnel verification. Then run:")
	fmt.Printf("  cc-remote ready 'CC_REMOTE_READY ...' && cc-remote ssh %s\n", *name)
	return nil
}

func collectPlatformPayloads(root, platform string) ([]manifest.Payload, error) {
	all, err := bundle.CollectPayloads(root)
	if err != nil {
		return nil, err
	}
	prefix := "payloads/" + platform + "/"
	payloads := make([]manifest.Payload, 0, len(all))
	var windowsPayload *manifest.Payload
	for i := range all {
		payload := all[i]
		if payload.Path == windowsOpenSSHPayload {
			windowsPayload = &payload
		}
		if platform == "all" || strings.HasPrefix(payload.Path, prefix) {
			payloads = append(payloads, payload)
		}
	}
	if platform == "windows" || platform == "all" {
		if windowsPayload == nil {
			return nil, fmt.Errorf("Windows launcher requires verified offline payload %s under --payload-root %s; run scripts/prepare-windows-openssh.sh", windowsOpenSSHPayload, root)
		}
		if windowsPayload.SHA256 != windowsOpenSSHSHA256 {
			return nil, fmt.Errorf("Windows OpenSSH payload SHA256 mismatch: expected %s, got %s", windowsOpenSSHSHA256, windowsPayload.SHA256)
		}
	}
	return payloads, nil
}

func ready(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: cc-remote ready 'CC_REMOTE_READY <session> <target-user> <relay-host> <remote-port>'")
	}
	fields := strings.Fields(strings.Join(args, " "))
	if len(fields) != 5 || fields[0] != "CC_REMOTE_READY" {
		return errors.New("expected: CC_REMOTE_READY <session> <target-user> <relay-host> <remote-port>")
	}
	rec, path, err := findRecordWithPath(fields[1])
	if err != nil {
		return err
	}
	if fields[3] != rec.RelayHost {
		return fmt.Errorf("READY relay host %q does not match configured relay host %q", fields[3], rec.RelayHost)
	}
	port, err := strconv.Atoi(fields[4])
	if err != nil || port < 1 || port > 65535 {
		return fmt.Errorf("invalid READY reverse port %q: use a port from 1 to 65535", fields[4])
	}
	rec.TargetUser = fields[2]
	rec.RemotePort = port
	if err := writeJSON(path, rec, 0o600); err != nil {
		return err
	}
	if err := writeConnectionArtifacts(rec); err != nil {
		return err
	}
	fmt.Println("Ready line saved for session:", rec.ID)
	return printConnectionSummary(rec)
}

func show(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: cc-remote show <session-id-or-name>")
	}
	rec, err := findRecord(args[0])
	if err != nil {
		return err
	}
	if err := writeConnectionArtifacts(rec); err != nil {
		return err
	}
	b, err := os.ReadFile(rec.ConnectionMDPath)
	if err != nil {
		return err
	}
	fmt.Print(string(b))
	return nil
}

func list() error {
	base, err := session.BaseDir()
	if err != nil {
		return err
	}
	root := filepath.Join(base, "sessions")
	entries, err := os.ReadDir(root)
	if errors.Is(err, fs.ErrNotExist) {
		fmt.Println("no sessions")
		return nil
	}
	if err != nil {
		return err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		rec, err := readRecord(filepath.Join(root, e.Name(), "record.json"))
		if err != nil {
			continue
		}
		status := recordStatus(rec)
		fmt.Printf("%s\t%s\t%s\t%s:%d\tuser=%s\tidle=%s\talias=%s\tguide=%s\n", rec.ID, rec.Name, status, rec.RelayHost, rec.RemotePort, rec.TargetUser, rec.IdleTimeout, rec.SSHHostAlias, rec.ConnectionMDPath)
	}
	return nil
}

func ssh(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: cc-remote ssh <session-id-or-name>")
	}
	rec, err := findRecord(args[0])
	if err != nil {
		return err
	}
	if rec.TargetUser == "" || rec.TargetUser == autoTargetUser {
		return errors.New("target user is not known yet; paste the controlled machine's CC_REMOTE_READY line with: cc-remote ready 'CC_REMOTE_READY ...'")
	}
	sshArgs := []string{
		"-i", rec.TargetKeyPath,
		"-o", "IdentitiesOnly=yes",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "HostKeyAlias=" + rec.SSHHostAlias,
		"-o", "UserKnownHostsFile=" + targetKnownHostsPath(rec),
		"-o", fmt.Sprintf("ProxyCommand=ssh -i %s -o IdentitiesOnly=yes -p %d -W 127.0.0.1:%d %s@%s", rec.TunnelKeyPath, rec.RelaySSHPort, rec.RemotePort, rec.RelayUser, rec.RelayHost),
		fmt.Sprintf("%s@127.0.0.1", rec.TargetUser),
	}
	cmd := exec.Command("ssh", sshArgs...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func closeSession(args []string) error {
	if len(args) != 1 {
		return errors.New("usage: cc-remote close <session-id-or-name>")
	}
	rec, path, err := findRecordWithPath(args[0])
	if err != nil {
		return err
	}
	relayAuthorizationRemoved := false
	if rec.RelayInstalled && rec.RelayAuthKey != "" {
		if strings.TrimSpace(rec.RelaySSHHost) == "" {
			return errors.New("cannot remove CLI-installed relay authorization: record has no administrative relay SSH host")
		}
		cmd := fmt.Sprintf("tmp=$(mktemp) && grep -vF %s ~%s/.ssh/authorized_keys > $tmp && cat $tmp > ~%s/.ssh/authorized_keys && rm -f $tmp", shellQuote("cc-remote:"+rec.ID), rec.RelayUser, rec.RelayUser)
		if err := runRelayInstall(rec.RelaySSHHost, cmd); err != nil {
			return err
		}
		relayAuthorizationRemoved = true
	}
	rec.RelayInstalled = false
	closedAt := time.Now().UTC()
	rec.ClosedAt = &closedAt
	if err := writeJSON(path, rec, 0o600); err != nil {
		return err
	}
	if err := writeConnectionArtifacts(rec); err != nil {
		return err
	}
	fmt.Println("Session closed:", rec.ID)
	if relayAuthorizationRemoved {
		fmt.Println("Relay authorized_keys marker removed:", "cc-remote:"+rec.ID)
	} else {
		fmt.Println("Relay authorization was not installed by this CLI; no remote relay change was made.")
	}
	fmt.Println("Ask the controlled machine to run cleanup.sh or cleanup.ps1 from its extracted bundle if idle cleanup has not run yet.")
	return nil
}

func initRelay(args []string) error {
	fs := flag.NewFlagSet("init-relay", flag.ExitOnError)
	printSnippet := fs.Bool("print-snippet", true, "print relay setup snippet")
	user := fs.String("user", "cc-tunnel", "relay tunnel user")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if !*printSnippet {
		return nil
	}
	fmt.Printf(`# Review before running on a public Linux/OpenSSH relay you control.
sudo useradd --system --create-home --shell /usr/sbin/nologin %[1]s || true
sudo install -d -m 700 -o %[1]s -g %[1]s ~%[1]s/.ssh
sudo touch ~%[1]s/.ssh/authorized_keys
sudo chown %[1]s:%[1]s ~%[1]s/.ssh/authorized_keys
sudo chmod 600 ~%[1]s/.ssh/authorized_keys

# Add to /etc/ssh/sshd_config:
Match User %[1]s
  PasswordAuthentication no
  PermitTTY no
  X11Forwarding no
  AllowTcpForwarding yes
  GatewayPorts no

# Then validate and reload:
sudo sshd -t && sudo systemctl reload sshd
`, *user)
	return nil
}

func relayInstallCommand(user, relayAuth string) string {
	quotedKey := shellQuote(relayAuth)
	return fmt.Sprintf(`set -e
if ! id %[1]s >/dev/null 2>&1; then sudo useradd --system --create-home --shell /usr/sbin/nologin %[1]s; fi
home=$(getent passwd %[1]s | cut -d: -f6)
sudo install -d -m 700 -o %[1]s -g %[1]s "$home/.ssh"
sudo touch "$home/.ssh/authorized_keys"
sudo chown %[1]s:%[1]s "$home/.ssh/authorized_keys"
sudo chmod 600 "$home/.ssh/authorized_keys"
if ! sudo grep -q 'cc-remote:'"$(printf %%s %[2]s | sed 's/.*cc-remote://')" "$home/.ssh/authorized_keys" 2>/dev/null; then printf '%%s\n' %[2]s | sudo tee -a "$home/.ssh/authorized_keys" >/dev/null; fi
if ! sudo grep -q 'Match User %[1]s' /etc/ssh/sshd_config; then sudo tee -a /etc/ssh/sshd_config >/dev/null <<'EOF'

Match User %[1]s
  PasswordAuthentication no
  PermitTTY no
  X11Forwarding no
  AllowTcpForwarding yes
  GatewayPorts no
EOF
fi
sudo sshd -t
sudo systemctl reload sshd 2>/dev/null || sudo service ssh reload 2>/dev/null || true
`, user, quotedKey)
}

func runRelayInstall(alias, script string) error {
	cmd := exec.Command("ssh", alias, script)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

type connectionInfo struct {
	SessionID            string     `json:"session_id"`
	Name                 string     `json:"name"`
	Status               string     `json:"status"`
	CreatedAt            time.Time  `json:"created_at"`
	ExpiresAt            time.Time  `json:"expires_at"`
	ClosedAt             *time.Time `json:"closed_at,omitempty"`
	IdleTimeout          string     `json:"idle_timeout"`
	RelayHost            string     `json:"relay_host"`
	RelaySSHPort         int        `json:"relay_ssh_port"`
	RelayUser            string     `json:"relay_user"`
	ReversePort          int        `json:"reverse_port"`
	ReverseListenAddress string     `json:"reverse_listen_address"`
	TargetUser           string     `json:"target_user"`
	TargetKeyPath        string     `json:"target_key_path"`
	TargetKeyFingerprint string     `json:"target_key_fingerprint,omitempty"`
	TunnelKeyPath        string     `json:"tunnel_key_path"`
	TunnelKeyFingerprint string     `json:"tunnel_key_fingerprint,omitempty"`
	SSHHostAlias         string     `json:"ssh_host_alias"`
	SSHConfigPath        string     `json:"ssh_config_path"`
	SSHCommand           string     `json:"ssh_command,omitempty"`
	SSHConfigCommand     string     `json:"ssh_config_command,omitempty"`
	ConnectionMDPath     string     `json:"connection_md_path"`
	ConnectionJSONPath   string     `json:"connection_json_path"`
}

func targetKnownHostsPath(rec session.Record) string {
	return filepath.Join(filepath.Dir(rec.SSHConfigPath), "target_known_hosts")
}

func writeConnectionArtifacts(rec session.Record) error {
	info := connectionInfo{
		SessionID:            rec.ID,
		Name:                 rec.Name,
		Status:               recordStatus(rec),
		CreatedAt:            rec.CreatedAt,
		ExpiresAt:            rec.ExpiresAt,
		ClosedAt:             rec.ClosedAt,
		IdleTimeout:          rec.IdleTimeout,
		RelayHost:            rec.RelayHost,
		RelaySSHPort:         rec.RelaySSHPort,
		RelayUser:            rec.RelayUser,
		ReversePort:          rec.RemotePort,
		ReverseListenAddress: fmt.Sprintf("127.0.0.1:%d", rec.RemotePort),
		TargetUser:           rec.TargetUser,
		TargetKeyPath:        rec.TargetKeyPath,
		TunnelKeyPath:        rec.TunnelKeyPath,
		SSHHostAlias:         rec.SSHHostAlias,
		SSHConfigPath:        rec.SSHConfigPath,
		ConnectionMDPath:     rec.ConnectionMDPath,
		ConnectionJSONPath:   rec.ConnectionJSONPath,
	}
	info.TargetKeyFingerprint, _ = publicKeyFingerprint(rec.TargetKeyPath + ".pub")
	info.TunnelKeyFingerprint, _ = publicKeyFingerprint(rec.TunnelKeyPath + ".pub")
	targetKnownHosts := targetKnownHostsPath(rec)
	if rec.TargetUser != "" && rec.TargetUser != autoTargetUser {
		proxy := fmt.Sprintf("ssh -i %s -o IdentitiesOnly=yes -p %d -W 127.0.0.1:%d %s", shellQuote(rec.TunnelKeyPath), rec.RelaySSHPort, rec.RemotePort, shellQuote(rec.RelayUser+"@"+rec.RelayHost))
		info.SSHCommand = fmt.Sprintf("ssh -i %s -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o %s -o %s -o %s %s", shellQuote(rec.TargetKeyPath), shellQuote("HostKeyAlias="+rec.SSHHostAlias), shellQuote("UserKnownHostsFile="+targetKnownHosts), shellQuote("ProxyCommand="+proxy), shellQuote(rec.TargetUser+"@127.0.0.1"))
		info.SSHConfigCommand = fmt.Sprintf("ssh -F %s %s", shellQuote(rec.SSHConfigPath), shellQuote(rec.SSHHostAlias))
	}

	config := fmt.Sprintf("Host %s\n  HostName 127.0.0.1\n  Port 22\n  User %s\n  IdentityFile %s\n  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n  HostKeyAlias %s\n  UserKnownHostsFile %s\n  ProxyCommand ssh -i %s -o IdentitiesOnly=yes -p %d -W 127.0.0.1:%d %s\n", rec.SSHHostAlias, rec.TargetUser, sshConfigQuote(rec.TargetKeyPath), sshConfigQuote(rec.SSHHostAlias), sshConfigQuote(targetKnownHosts), sshConfigQuote(rec.TunnelKeyPath), rec.RelaySSHPort, rec.RemotePort, sshConfigQuote(rec.RelayUser+"@"+rec.RelayHost))
	if rec.TargetUser == "" || rec.TargetUser == autoTargetUser {
		config = "# Target user is not known yet. Run cc-remote ready with the controlled machine's READY line.\n" + config
	}
	if err := writeFileAtomic(rec.SSHConfigPath, []byte(config), 0o600); err != nil {
		return err
	}
	if err := writeJSONAtomic(rec.ConnectionJSONPath, info, 0o600); err != nil {
		return err
	}

	var md strings.Builder
	fmt.Fprintf(&md, "# cc-remote connection: %s\n\n", rec.Name)
	fmt.Fprintf(&md, "- Session ID: `%s`\n- Status: **%s**\n- Created: `%s`\n- Expires: `%s`\n", rec.ID, info.Status, rec.CreatedAt.Format(time.RFC3339), rec.ExpiresAt.Format(time.RFC3339))
	if rec.ClosedAt != nil {
		fmt.Fprintf(&md, "- Closed: `%s`\n", rec.ClosedAt.Format(time.RFC3339))
	}
	fmt.Fprintf(&md, "- Idle cleanup: `%s` after the last active SSH connection\n\n", rec.IdleTimeout)
	fmt.Fprintf(&md, "## Endpoint\n\n- Relay SSH: `%s:%d`\n- Restricted relay user: `%s`\n- Reverse listener: `127.0.0.1:%d` on relay loopback only\n- Controlled-machine user: `%s`\n\n", rec.RelayHost, rec.RelaySSHPort, rec.RelayUser, rec.RemotePort, rec.TargetUser)
	fmt.Fprintf(&md, "## Operator keys\n\n- Target private-key path: `%s`\n- Target public-key fingerprint: `%s`\n- Tunnel private-key path: `%s`\n- Tunnel public-key fingerprint: `%s`\n\nPrivate-key contents are intentionally omitted. Keep both key files on the operator machine.\n\n", rec.TargetKeyPath, info.TargetKeyFingerprint, rec.TunnelKeyPath, info.TunnelKeyFingerprint)
	fmt.Fprintf(&md, "## Connect\n\n")
	if info.SSHCommand == "" {
		fmt.Fprintf(&md, "The controlled-machine user is not known yet. Process its READY line first:\n\n```sh\ncc-remote ready 'CC_REMOTE_READY %s <target-user> %s %d'\n```\n", rec.ID, rec.RelayHost, rec.RemotePort)
	} else {
		fmt.Fprintf(&md, "Using the session SSH config (recommended):\n\n```sh\n%s\n```\n\nFull command:\n\n```sh\n%s\n```\n", info.SSHConfigCommand, info.SSHCommand)
	}
	fmt.Fprintf(&md, "\n## Files and cleanup\n\n- SSH config: `%s`\n- Machine-readable data: `%s`\n- Show again: `cc-remote show %s`\n- Remove relay authorization: `cc-remote close %s`\n- Controlled-machine cleanup: run `cleanup.ps1` or `cleanup.sh` from the extracted bundle if idle cleanup has not already run.\n", rec.SSHConfigPath, rec.ConnectionJSONPath, rec.ID, rec.ID)
	return writeFileAtomic(rec.ConnectionMDPath, []byte(md.String()), 0o600)
}

func printConnectionSummary(rec session.Record) error {
	fmt.Println("Connection guide:", rec.ConnectionMDPath)
	fmt.Println("Machine-readable data:", rec.ConnectionJSONPath)
	if rec.TargetUser == "" || rec.TargetUser == autoTargetUser {
		fmt.Println("Target user is still unknown; process the CC_REMOTE_READY line before connecting.")
		return nil
	}
	fmt.Println("Connect with:")
	fmt.Printf("  ssh -F %s %s\n", shellQuote(rec.SSHConfigPath), shellQuote(rec.SSHHostAlias))
	fmt.Println("Or show the full command with:")
	fmt.Printf("  cc-remote show %s\n", rec.ID)
	return nil
}

func recordStatus(rec session.Record) string {
	if rec.ClosedAt != nil {
		return "closed"
	}
	if time.Now().UTC().After(rec.ExpiresAt) {
		return "expired"
	}
	if rec.TargetUser == "" || rec.TargetUser == autoTargetUser {
		return "awaiting-ready"
	}
	return "ready"
}

func publicKeyFingerprint(path string) (string, error) {
	out, err := exec.Command("ssh-keygen", "-lf", path).Output()
	if err != nil {
		return "", err
	}
	fields := strings.Fields(string(out))
	if len(fields) < 2 {
		return "", fmt.Errorf("unexpected ssh-keygen fingerprint output for %s", path)
	}
	return fields[1], nil
}

func sshConfigQuote(s string) string {
	return `"` + strings.ReplaceAll(s, `"`, `\"`) + `"`
}

func writeJSONAtomic(path string, v any, perm os.FileMode) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(path, append(b, '\n'), perm)
}

func writeFileAtomic(path string, data []byte, perm os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".cc-remote-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if err := tmp.Chmod(perm); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, path)
}

func writeWindowsHandoffScripts(bundlePath, cmdPath, ps1Path, id string) error {
	return writeHandoffScripts(bundlePath, cmdPath, ps1Path, "", "", id)
}

func writeUnixHandoffScript(bundlePath, path, id string) error {
	return writeHandoffScripts(bundlePath, "", "", path, "", id)
}

func writeHandoffScripts(bundlePath, cmdPath, ps1Path, shPath, commandPath, id string) error {
	b, err := os.ReadFile(bundlePath)
	if err != nil {
		return err
	}
	encoded := base64.StdEncoding.EncodeToString(b)
	wrapped := wrapBase64(encoded)
	cmdTemplate := `@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul
title cc-remote __ID__ temporary support
set "CC_REMOTE_SELF=%~f0"
set "ROOT=%TEMP%\cc-remote-__ID__"
set "ZIP=%TEMP%\cc-remote-__ID__.zip"
set "LOG=%ProgramData%\cc-remote\sessions\__ID__\bootstrap.log"
set "RC=1"

echo [%date% %time%] cc-remote __ID__ launcher started.
net session >nul 2>&1
if errorlevel 1 (
  if /I "%~1"=="--elevated" (
    echo ERROR: Administrator privileges are still unavailable after UAC.
    goto :failed
  )
  echo Requesting Administrator privileges through UAC...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/c',('""' + $env:CC_REMOTE_SELF + '" --elevated"')) -Verb RunAs -ErrorAction Stop } catch { Write-Host ('UAC launch failed: ' + $_.Exception.Message); exit 1 }"
  if errorlevel 1 goto :failed
  exit /b 0
)

if not exist "%ProgramData%\cc-remote\sessions\__ID__" mkdir "%ProgramData%\cc-remote\sessions\__ID__"
echo [%date% %time%] Decoding the embedded offline bundle...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:CC_REMOTE_SELF); $m=[regex]::Match($s,'(?s)#__CC_REMOTE_PAYLOAD_BEGIN__\r?\n(.*?)\r?\n#__CC_REMOTE_PAYLOAD_END__'); if(-not $m.Success){throw 'Embedded payload marker not found'}; [IO.File]::WriteAllBytes($env:ZIP,[Convert]::FromBase64String(($m.Groups[1].Value -replace '\s','')))" >>"%LOG%" 2>&1
if errorlevel 1 goto :failed

echo [%date% %time%] Extracting bundle to "%ROOT%"...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "New-Item -ItemType Directory -Force -Path $env:ROOT | Out-Null; Expand-Archive -Force -Path $env:ZIP -DestinationPath $env:ROOT" >>"%LOG%" 2>&1
if errorlevel 1 goto :failed

echo [%date% %time%] Starting the Windows bootstrap. Output is also saved to:
echo   %LOG%
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { & $env:ROOT\bootstrap.ps1 -NoMonitor *>&1 | Tee-Object -FilePath $env:LOG -Append; if (-not $?) { exit 1 } } catch { $_ | Out-String | Tee-Object -FilePath $env:LOG -Append; exit 1 }"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto :bootstrap_failed

echo.
echo cc-remote setup finished successfully.
echo Starting the read-only status monitor outside the bootstrap log pipeline.
echo Log: %LOG%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\bootstrap.ps1" -MonitorOnly
set "RC=%ERRORLEVEL%"
goto :hold

:bootstrap_failed
echo.
echo ERROR: cc-remote bootstrap failed with exit code %RC%.
echo Review or send this log to the operator: %LOG%
goto :hold

:failed
echo.
echo ERROR: cc-remote launcher could not complete setup.
echo If a log was created, it is at: %LOG%

:hold
echo.
pause
exit /b %RC%

#__CC_REMOTE_PAYLOAD_BEGIN__
__PAYLOAD__
#__CC_REMOTE_PAYLOAD_END__
`
	cmd := strings.NewReplacer("__ID__", id, "__PAYLOAD__", wrapped).Replace(cmdTemplate)
	ps := fmt.Sprintf(`# cc-remote one-shot Windows bootstrap. Run in PowerShell as Administrator.
$ErrorActionPreference = 'Stop'
$Root = Join-Path $env:TEMP 'cc-remote-%[1]s'
$Zip = Join-Path $env:TEMP 'cc-remote-%[1]s.zip'
$Log = Join-Path $env:ProgramData 'cc-remote\sessions\%[1]s\bootstrap.log'
New-Item -ItemType Directory -Force -Path $Root, (Split-Path -Parent $Log) | Out-Null
$B64 = @'
%[2]s
'@
[IO.File]::WriteAllBytes($Zip, [Convert]::FromBase64String(($B64 -replace '\s','')))
Expand-Archive -Force -Path $Zip -DestinationPath $Root
& (Join-Path $Root 'bootstrap.ps1') -NoMonitor *>&1 | Tee-Object -FilePath $Log -Append
if (-not $?) { throw 'cc-remote setup failed; monitor was not started.' }
& (Join-Path $Root 'bootstrap.ps1') -MonitorOnly
`, id, wrapped)
	shTemplate := `#!/bin/sh
# Some transfer tools remove the executable bit. If the recipient runs this file
# with "sh", switch to Bash before any Bash-only syntax is parsed.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi
set -Eeuo pipefail

session_id="__ID__"
self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
root="${TMPDIR:-/tmp}/cc-remote-$session_id"
zip="${TMPDIR:-/tmp}/cc-remote-$session_id.zip"
log_dir="/var/tmp/cc-remote/$session_id"
log="$log_dir/bootstrap.log"
stage="launcher initialization"
rc=1

stamp() { date '+%Y-%m-%d %H:%M:%S'; }
log_line() { printf '[%s] %s\n' "$(stamp)" "$*"; }
hold_on_failure() {
  if [ -t 0 ]; then
    printf '\nPress Return to close this window...'
    IFS= read -r _ || true
  fi
}
on_error() {
  local code="$1" line="$2"
  trap - ERR
  log_line "ERROR: launcher failed during '$stage' (line $line, exit $code)." >&2
  log_line "Persistent log: $log" >&2
  hold_on_failure
  exit "$code"
}
trap 'on_error $? $LINENO' ERR

if [ "$(uname -s)" != "Darwin" ] && [ "$(uname -s)" != "Linux" ]; then
  log_line "ERROR: unsupported operating system: $(uname -s)" >&2
  hold_on_failure
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  log_line "Requesting administrator privileges. Enter this Mac's login password once."
  exec sudo /bin/bash "$self" --elevated
fi

mkdir -p "$log_dir" "$root"
chmod 700 "$log_dir"
touch "$log"
chmod 600 "$log"
log_pipe="$root/launcher-output.pipe"
rm -f "$log_pipe"
mkfifo "$log_pipe"
tee -a "$log" < "$log_pipe" &
tee_pid=$!
trap 'rm -f "$log_pipe"; kill "$tee_pid" >/dev/null 2>&1 || true' EXIT
exec > "$log_pipe" 2>&1

log_line "cc-remote $session_id one-click launcher started."
log_line "Persistent log: $log"
stage="writing embedded bundle"
mkdir -p "$root"
cat > "$zip.b64" <<'EOF'
__PAYLOAD__
EOF

stage="decoding embedded bundle"
log_line "Decoding the embedded offline bundle..."
if [ "$(uname -s)" = "Darwin" ]; then
  base64 -D -i "$zip.b64" -o "$zip"
else
  base64 -d < "$zip.b64" > "$zip"
fi

stage="extracting embedded bundle"
log_line "Extracting the verified bootstrap bundle..."
command -v unzip >/dev/null 2>&1 || { log_line "ERROR: unzip is required." >&2; false; }
unzip -o "$zip" -d "$root" >/dev/null
chmod 700 "$root/bootstrap.sh" "$root/cleanup.sh" "$root/idle-watch.sh"

stage="running bootstrap"
log_line "Starting automatic SSH setup and restricted reverse tunnel..."
CC_REMOTE_LOG="$log" /bin/bash "$root/bootstrap.sh"
rc=$?
if [ "$rc" -eq 0 ]; then
  log_line "cc-remote bootstrap finished."
else
  log_line "ERROR: bootstrap exited with code $rc. Log: $log" >&2
  hold_on_failure
fi
exit "$rc"
`
	sh := strings.NewReplacer("__ID__", id, "__PAYLOAD__", wrapped).Replace(shTemplate)
	if cmdPath != "" {
		if err := os.WriteFile(cmdPath, []byte(cmd), 0o600); err != nil {
			return err
		}
	}
	if ps1Path != "" {
		if err := os.WriteFile(ps1Path, []byte(ps), 0o600); err != nil {
			return err
		}
	}
	if shPath != "" {
		if err := os.WriteFile(shPath, []byte(sh), 0o700); err != nil {
			return err
		}
	}
	if commandPath != "" {
		return os.WriteFile(commandPath, []byte(sh), 0o700)
	}
	return nil
}

func wrapBase64(s string) string {
	var b strings.Builder
	for len(s) > 76 {
		b.WriteString(s[:76])
		b.WriteByte('\n')
		s = s[76:]
	}
	b.WriteString(s)
	return b.String()
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}

func copyFile(dst, src string, perm os.FileMode) error {
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, b, perm)
}

func findAssetRoot() (string, error) {
	candidates := []string{"."}
	if exe, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Dir(exe))
	}
	if wd, err := os.Getwd(); err == nil {
		for dir := wd; ; dir = filepath.Dir(dir) {
			candidates = append(candidates, dir)
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
		}
	}
	for _, candidate := range candidates {
		if _, err := os.Stat(filepath.Join(candidate, "bootstrap", "bootstrap.sh")); err == nil {
			return candidate, nil
		}
	}
	return "", errors.New("could not locate bootstrap assets; run from the cc-remote project directory or place bootstrap/ next to the binary")
}

func sshKeygen(path, comment string) error {
	if _, err := exec.LookPath("ssh-keygen"); err != nil {
		return errors.New("ssh-keygen not found")
	}
	cmd := exec.Command("ssh-keygen", "-t", "ed25519", "-N", "", "-C", comment, "-f", path)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func writeJSON(path string, v any, perm os.FileMode) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	b = append(b, '\n')
	return os.WriteFile(path, b, perm)
}

func readRecord(path string) (session.Record, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return session.Record{}, err
	}
	var rec session.Record
	return rec, json.Unmarshal(b, &rec)
}

func findRecord(idOrName string) (session.Record, error) {
	rec, _, err := findRecordWithPath(idOrName)
	return rec, err
}

func findRecordWithPath(idOrName string) (session.Record, string, error) {
	base, err := session.BaseDir()
	if err != nil {
		return session.Record{}, "", err
	}
	root := filepath.Join(base, "sessions")
	entries, err := os.ReadDir(root)
	if err != nil {
		return session.Record{}, "", err
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		path := filepath.Join(root, e.Name(), "record.json")
		rec, err := readRecord(path)
		if err != nil {
			continue
		}
		if rec.ID == idOrName || rec.Name == idOrName {
			return rec, path, nil
		}
	}
	return session.Record{}, "", fmt.Errorf("session %q not found", idOrName)
}

func init() {
	rand.Seed(time.Now().UnixNano())
}
