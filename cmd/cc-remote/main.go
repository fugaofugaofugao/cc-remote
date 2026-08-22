package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/fugaofugaofugao/cc-remote/internal/bundle"
	"github.com/fugaofugaofugao/cc-remote/internal/manifest"
	"github.com/fugaofugaofugao/cc-remote/internal/session"
)

var (
	version       = "dev"
	commit        = "unknown"
	date          = "unknown"
	relayUserName = regexp.MustCompile(`^[a-z_][a-z0-9_-]{0,31}$`)
)

const (
	autoTargetUser        = "auto"
	windowsOpenSSHPayload = "payloads/windows/openssh-win64.zip"
	windowsOpenSSHSHA256  = "23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5"
)

var requiredBootstrapAssets = []string{
	"bootstrap/bootstrap.sh",
	"bootstrap/bootstrap.ps1",
	"bootstrap/cleanup.sh",
	"bootstrap/cleanup.ps1",
	"bootstrap/idle-watch.sh",
	"bootstrap/idle-watch.ps1",
}

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
	case "doctor":
		return doctor(args[2:])
	case "version":
		return printVersion()
	case "ready":
		return ready(args[2:])
	case "relay":
		return relay(args[2:])
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
  doctor      verify installed binary/assets and payload readiness
  version     print version/build information
  ready       paste the CC_REMOTE_READY line back to save the detected target user
  relay       save/show/check the default relay profile
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
	maxLifetime := fs.Duration("max-lifetime", 7*24*time.Hour, "hard safety lifetime for local record; 0 disables expiry")
	legacyTTL := fs.Duration("ttl", 0, "deprecated alias for --max-lifetime")
	idleTimeout := fs.Duration("idle-timeout", 2*time.Hour, "cleanup after this much time with no active SSH connection; 0 disables idle cleanup")
	payloadRoot := fs.String("payload-root", "payloads", "offline payload root")
	platform := fs.String("platform", "all", "launcher platform: windows, macos, linux, or all")
	launcherFormat := fs.String("launcher-format", "default", "launcher format: default, cmd, ps1, both, sh, command, or all")
	handoffMode := fs.String("handoff-mode", "embedded", "handoff mode: embedded or bundle")
	remotePort := fs.Int("remote-port", 0, "relay reverse port; auto if 0")
	jsonOutput := fs.Bool("json", false, "print machine-readable creation result")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *legacyTTL != 0 {
		*maxLifetime = *legacyTTL
	}
	if err := applyRelayDefaults(fs, relayHost, relayPort, relayUser, relaySSHHost); err != nil {
		return err
	}
	*relayHost = strings.TrimSpace(*relayHost)
	*relaySSHHost = strings.TrimSpace(*relaySSHHost)
	if *relayHost == "" {
		return errors.New("--relay-host is required and no saved relay profile exists. Ask the operator for the relay public host/IP, SSH port, and dedicated relay user, then run cc-remote relay set --host <relay-host> --port <relay-ssh-port> --user cc-tunnel once, or pass --relay-host explicitly")
	}
	if err := validateRelayUser(*relayUser); err != nil {
		return err
	}
	if *relayPort < 1 || *relayPort > 65535 {
		return fmt.Errorf("invalid --relay-port %d: use a port from 1 to 65535", *relayPort)
	}
	if *remotePort < 0 || *remotePort > 65535 {
		return fmt.Errorf("invalid --remote-port %d: use 0 for automatic selection or a port from 1 to 65535", *remotePort)
	}
	if *installRelay && *relaySSHHost == "" {
		return errors.New("--relay-ssh-host is required with --install-relay. Ask the operator for an explicitly authorized relay administrative SSH alias/destination, or omit --install-relay and install relay_authorized_key_line manually")
	}
	if *targetUser == "" {
		*targetUser = autoTargetUser
	}
	*platform = strings.ToLower(strings.TrimSpace(*platform))
	if *platform != "windows" && *platform != "macos" && *platform != "linux" && *platform != "all" {
		return fmt.Errorf("invalid --platform %q: use windows, macos, linux, or all", *platform)
	}
	*launcherFormat = strings.ToLower(strings.TrimSpace(*launcherFormat))
	if *launcherFormat == "" {
		*launcherFormat = "default"
	}
	if !validLauncherFormat(*launcherFormat) {
		return fmt.Errorf("invalid --launcher-format %q: use default, cmd, ps1, both, sh, command, or all", *launcherFormat)
	}
	*handoffMode = strings.ToLower(strings.TrimSpace(*handoffMode))
	if *handoffMode != "embedded" && *handoffMode != "bundle" {
		return fmt.Errorf("invalid --handoff-mode %q: use embedded or bundle", *handoffMode)
	}
	formats := selectedLauncherFormats(*platform, *launcherFormat)
	if err := validateLauncherFormatsForPlatform(*platform, formats); err != nil {
		return err
	}
	payloadPlatform := payloadPlatformForFormats(*platform, formats)
	payloads, err := collectPlatformPayloads(*payloadRoot, payloadPlatform)
	if err != nil {
		return err
	}
	subprocessStdout := io.Writer(os.Stdout)
	if *jsonOutput {
		subprocessStdout = os.Stderr
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
	// Local sshd port for the bundled standalone OpenSSH on the controlled machine.
	// Tied to the session id, in a high range distinct from <remote_port> and port 22,
	// so it never collides with a pre-existing system sshd.
	localPort, err := session.LocalSSHPortFromID(id)
	if err != nil {
		return err
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
	if err := sshKeygen(tunnelKey, "cc-remote tunnel "+id, subprocessStdout, os.Stderr); err != nil {
		return err
	}
	if err := sshKeygen(targetKey, "cc-remote target "+id, subprocessStdout, os.Stderr); err != nil {
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
	expiresAt := time.Time{}
	if *maxLifetime > 0 {
		expiresAt = created.Add(*maxLifetime)
	}
	m := manifest.Manifest{
		Version:               1,
		SessionID:             id,
		Name:                  *name,
		CreatedAt:             created,
		ExpiresAt:             expiresAt,
		IdleTimeoutSeconds:    int(idleTimeout.Seconds()),
		RelayHost:             *relayHost,
		RelayUser:             *relayUser,
		RelaySSHPort:          *relayPort,
		RemotePort:            port,
		LocalSSHPort:          localPort,
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
	bundleHash, err := bundle.HashFile(bundlePath)
	if err != nil {
		return fmt.Errorf("hash generated session bundle: %w", err)
	}

	relayAuth := fmt.Sprintf("permitopen=\"127.0.0.1:%d\",permitlisten=\"127.0.0.1:%d\",no-pty,no-X11-forwarding %s cc-remote:%s", port, port, strings.TrimSpace(string(tunnelPub)), id)
	relayInstalled := false
	relayInstallCmd := ""
	if *installRelay {
		relayInstallCmd = relayInstallCommand(*relayUser, relayAuth)
		if err := runRelayInstall(*relaySSHHost, relayInstallCmd, subprocessStdout, os.Stderr); err != nil {
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
	if formats["cmd"] || formats["ps1"] {
		cmdOut, ps1Out := "", ""
		if formats["cmd"] {
			cmdOut = handoffCMD
		}
		if formats["ps1"] {
			ps1Out = handoffPS1
		}
		if err := writeWindowsHandoffScripts(bundlePath, cmdOut, ps1Out, id, *handoffMode, bundleHash.SHA256); err != nil {
			return err
		}
		if formats["cmd"] {
			if err := copyFile(bundleCMD, handoffCMD, 0o600); err != nil {
				return err
			}
		} else {
			bundleCMD = ""
		}
		if formats["ps1"] {
			if err := copyFile(bundlePS1, handoffPS1, 0o600); err != nil {
				return err
			}
		} else {
			bundlePS1 = ""
		}
	} else {
		bundleCMD, bundlePS1 = "", ""
	}
	if formats["sh"] {
		if err := writeUnixHandoffScript(bundlePath, handoffSh, id, *handoffMode, bundleHash.SHA256); err != nil {
			return err
		}
		if err := copyFile(bundleSh, handoffSh, 0o700); err != nil {
			return err
		}
	} else {
		bundleSh = ""
	}
	if formats["command"] {
		if err := writeUnixHandoffScript(bundlePath, handoffCommand, id, *handoffMode, bundleHash.SHA256); err != nil {
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
		LocalSSHPort:       localPort,
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
		BundleSHA256:       bundleHash.SHA256,
		LauncherFormat:     *launcherFormat,
		HandoffMode:        *handoffMode,
	}
	if err := writeJSON(filepath.Join(sessDir, "record.json"), rec, 0o600); err != nil {
		return err
	}
	if err := writeConnectionArtifacts(rec); err != nil {
		return err
	}

	if *jsonOutput {
		return printJSON(createResultFromRecord(rec))
	}

	fmt.Println("Session created:", id)
	if bundleCMD != "" {
		fmt.Println("Windows double-click launcher:", bundleCMD)
	}
	if bundlePS1 != "" {
		fmt.Println("Windows PowerShell fallback:", bundlePS1)
	}
	if *handoffMode == "bundle" {
		fmt.Println("Offline bundle to send beside the launcher:", bundlePath)
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
		if *handoffMode == "bundle" {
			fmt.Println("Windows: send the .cmd file and the session .zip together; double-click the .cmd and approve the UAC prompt.")
		} else {
			fmt.Println("Windows: send the .cmd file; double-click it and approve the UAC prompt.")
		}
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

func printVersion() error {
	fmt.Printf("cc-remote %s\n", version)
	fmt.Printf("commit: %s\n", commit)
	fmt.Printf("date: %s\n", date)
	fmt.Printf("go: %s %s/%s\n", runtime.Version(), runtime.GOOS, runtime.GOARCH)
	return nil
}

type doctorCheck struct {
	Name   string `json:"name"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail,omitempty"`
	Path   string `json:"path,omitempty"`
	Error  string `json:"error,omitempty"`
}

type doctorResult struct {
	OK       bool          `json:"ok"`
	Version  string        `json:"version"`
	Commit   string        `json:"commit"`
	Date     string        `json:"date"`
	GOOS     string        `json:"goos"`
	GOARCH   string        `json:"goarch"`
	Mode     string        `json:"mode"`
	Checks   []doctorCheck `json:"checks"`
	Warnings []string      `json:"warnings,omitempty"`
}

func doctorAssetCheck(assetRoot, rel string) doctorCheck {
	path := filepath.Join(assetRoot, rel)
	if _, err := os.Stat(path); err != nil {
		return doctorCheck{Name: "asset:" + rel, OK: false, Path: path, Error: err.Error()}
	}
	return doctorCheck{Name: "asset:" + rel, OK: true, Path: path}
}

func doctorCommandCheck(name string) doctorCheck {
	path, err := exec.LookPath(name)
	if err != nil {
		return doctorCheck{Name: name, OK: false, Error: err.Error()}
	}
	return doctorCheck{Name: name, OK: true, Path: path}
}

func doctor(args []string) error {
	fs := flag.NewFlagSet("doctor", flag.ExitOnError)
	jsonOutput := fs.Bool("json", false, "print machine-readable result")
	platform := fs.String("platform", "all", "platform to verify: windows, macos, linux, or all")
	payloadRoot := fs.String("payload-root", "payloads", "offline payload root")
	if err := fs.Parse(args); err != nil {
		return err
	}
	*platform = strings.ToLower(strings.TrimSpace(*platform))
	if *platform != "windows" && *platform != "macos" && *platform != "linux" && *platform != "all" {
		return fmt.Errorf("invalid --platform %q: use windows, macos, linux, or all", *platform)
	}
	res := doctorResult{
		OK:      true,
		Version: version,
		Commit:  commit,
		Date:    date,
		GOOS:    runtime.GOOS,
		GOARCH:  runtime.GOARCH,
		Mode:    "portable",
	}
	add := func(c doctorCheck) {
		if !c.OK {
			res.OK = false
		}
		res.Checks = append(res.Checks, c)
	}

	assetRoot, err := findAssetRoot()
	if err != nil {
		add(doctorCheck{Name: "asset_root", OK: false, Error: err.Error()})
	} else {
		add(doctorCheck{Name: "asset_root", OK: true, Path: assetRoot})
		for _, rel := range requiredBootstrapAssets {
			add(doctorAssetCheck(assetRoot, rel))
		}
	}
	for _, name := range []string{"ssh-keygen", "ssh"} {
		add(doctorCommandCheck(name))
	}
	payloadCheckRoot := *payloadRoot
	if !filepath.IsAbs(payloadCheckRoot) && assetRoot != "" {
		payloadCheckRoot = filepath.Join(assetRoot, payloadCheckRoot)
	}
	if _, err := collectPlatformPayloads(payloadCheckRoot, *platform); err != nil {
		add(doctorCheck{Name: "payloads", OK: false, Path: payloadCheckRoot, Error: err.Error()})
	} else {
		add(doctorCheck{Name: "payloads", OK: true, Path: payloadCheckRoot, Detail: "payloads verified for " + *platform})
	}
	if base, err := session.BaseDir(); err != nil {
		add(doctorCheck{Name: "session_base", OK: false, Error: err.Error()})
	} else {
		add(doctorCheck{Name: "session_base", OK: true, Path: base, Detail: "created on first create"})
	}

	if *jsonOutput {
		if err := printJSON(res); err != nil {
			return err
		}
		if !res.OK {
			return errors.New("doctor checks failed")
		}
		return nil
	}
	if res.OK {
		fmt.Println("cc-remote doctor: ok")
	} else {
		fmt.Println("cc-remote doctor: failed")
	}
	for _, c := range res.Checks {
		status := "ok"
		if !c.OK {
			status = "failed"
		}
		line := fmt.Sprintf("- %s: %s", c.Name, status)
		if c.Path != "" {
			line += " (" + c.Path + ")"
		}
		if c.Detail != "" {
			line += " - " + c.Detail
		}
		if c.Error != "" {
			line += " - " + c.Error
		}
		fmt.Println(line)
	}
	if !res.OK {
		return errors.New("doctor checks failed")
	}
	return nil
}

type createResult struct {
	OK                     bool     `json:"ok"`
	SessionID              string   `json:"session_id"`
	Name                   string   `json:"name"`
	Status                 string   `json:"status"`
	BundlePath             string   `json:"bundle_path"`
	BundleSHA256           string   `json:"bundle_sha256,omitempty"`
	ShareWithRecipient     []string `json:"share_with_recipient"`
	OperatorOnly           []string `json:"operator_only"`
	RelayHost              string   `json:"relay_host"`
	RelaySSHPort           int      `json:"relay_ssh_port"`
	RelayUser              string   `json:"relay_user"`
	ReversePort            int      `json:"reverse_port"`
	RelayInstalled         bool     `json:"relay_installed"`
	RelayAuthorizedKeyLine string   `json:"relay_authorized_key_line,omitempty"`
	ConnectionMDPath       string   `json:"connection_md_path"`
	ConnectionJSONPath     string   `json:"connection_json_path"`
	SSHConfigPath          string   `json:"ssh_config_path"`
	LauncherFormat         string   `json:"launcher_format,omitempty"`
	HandoffMode            string   `json:"handoff_mode,omitempty"`
	NextStep               string   `json:"next_step"`
}

func createResultFromRecord(rec session.Record) createResult {
	share := []string{}
	for _, path := range []string{rec.HandoffCMDPath, rec.HandoffPS1Path, rec.HandoffShPath, rec.HandoffCommandPath} {
		if path != "" {
			share = append(share, path)
		}
	}
	if rec.HandoffMode == "bundle" && rec.BundlePath != "" {
		share = append(share, rec.BundlePath)
	}
	operator := []string{rec.ConnectionMDPath, rec.ConnectionJSONPath, rec.SSHConfigPath, rec.TargetKeyPath, rec.TunnelKeyPath}
	result := createResult{
		OK:                 true,
		SessionID:          rec.ID,
		Name:               rec.Name,
		Status:             recordStatus(rec),
		BundlePath:         rec.BundlePath,
		BundleSHA256:       rec.BundleSHA256,
		ShareWithRecipient: share,
		OperatorOnly:       operator,
		RelayHost:          rec.RelayHost,
		RelaySSHPort:       rec.RelaySSHPort,
		RelayUser:          rec.RelayUser,
		ReversePort:        rec.RemotePort,
		RelayInstalled:     rec.RelayInstalled,
		ConnectionMDPath:   rec.ConnectionMDPath,
		ConnectionJSONPath: rec.ConnectionJSONPath,
		SSHConfigPath:      rec.SSHConfigPath,
		LauncherFormat:     rec.LauncherFormat,
		HandoffMode:        rec.HandoffMode,
		NextStep:           "Send only the recipient launcher(s), wait for the genuine CC_REMOTE_READY line, then run cc-remote ready 'CC_REMOTE_READY ...'.",
	}
	if !rec.RelayInstalled {
		result.RelayAuthorizedKeyLine = rec.RelayAuthKey
	}
	return result
}

func printJSON(v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(b))
	return nil
}

func validLauncherFormat(format string) bool {
	switch format {
	case "default", "cmd", "ps1", "both", "sh", "command", "all":
		return true
	default:
		return false
	}
}

func selectedLauncherFormats(platform, format string) map[string]bool {
	formats := map[string]bool{}
	addDefaults := func() {
		switch platform {
		case "windows":
			formats["cmd"] = true
		case "linux":
			formats["sh"] = true
		case "macos":
			formats["command"] = true
		case "all":
			formats["cmd"], formats["sh"], formats["command"] = true, true, true
		}
	}
	if format == "default" {
		addDefaults()
		return formats
	}
	if format == "all" {
		formats["cmd"], formats["ps1"], formats["sh"], formats["command"] = true, true, true, true
		return formats
	}
	if format == "both" {
		formats["cmd"], formats["ps1"] = true, true
		return formats
	}
	formats[format] = true
	return formats
}

func validateLauncherFormatsForPlatform(platform string, formats map[string]bool) error {
	if platform == "all" {
		return nil
	}
	for format := range formats {
		switch platform {
		case "windows":
			if format != "cmd" && format != "ps1" {
				return fmt.Errorf("--platform windows cannot generate %s launcher; use cmd, ps1, both, or all", format)
			}
		case "macos":
			if format != "command" {
				return fmt.Errorf("--platform macos cannot generate %s launcher; use command", format)
			}
		case "linux":
			if format != "sh" {
				return fmt.Errorf("--platform linux cannot generate %s launcher; use sh", format)
			}
		}
	}
	return nil
}

func payloadPlatformForFormats(platform string, formats map[string]bool) string {
	if platform == "all" || formats["cmd"] || formats["ps1"] {
		return "all"
	}
	return platform
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
	// macOS/Linux launchers must bundle a self-contained OpenSSH payload built by
	// scripts/prepare-unix-openssh.sh so the controlled machine never depends on its
	// own system openssh. These payloads are cross-arch (arm64 + x86_64), so unlike
	// Windows we enforce presence, not a fixed per-version sha (the bootstrap verifies
	// the exact bundled bytes via the manifest). The "all" platform is assembled from a
	// full release tree, so its payloads are validated by the release/packaging scripts,
	// not here (a windows-only "all" bundle after --platform windows stays valid).
	if platform == "macos" || platform == "linux" {
		if err := requireUnixOpenSSHPayload(root, platform); err != nil {
			return nil, err
		}
	}
	return payloads, nil
}

// requireUnixOpenSSHPayload ensures at least one self-contained OpenSSH payload is
// present for the platform, else the session would depend on the system sshd.
// The payload root is the directory that directly holds the platform subdirs
// (linux/, macos/, windows/), matching bundle.CollectPayloads.
func requireUnixOpenSSHPayload(root, platform string) error {
	matches, _ := filepath.Glob(filepath.Join(root, platform, "openssh-*.tar.gz"))
	if len(matches) == 0 {
		return fmt.Errorf("%s launcher requires a bundled self-contained OpenSSH payload (payloads/%s/openssh-*.tar.gz); run scripts/prepare-unix-openssh.sh --os ... --arch ...", platform, platform)
	}
	return nil
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
	proxyCommand := fmt.Sprintf("ssh -i %s -o IdentitiesOnly=yes -p %d -W 127.0.0.1:%d %s",
		shellQuote(rec.TunnelKeyPath), rec.RelaySSHPort, rec.RemotePort, shellQuote(rec.RelayUser+"@"+rec.RelayHost))
	sshArgs := []string{
		"-i", rec.TargetKeyPath,
		"-o", "IdentitiesOnly=yes",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "HostKeyAlias=" + rec.SSHHostAlias,
		"-o", "UserKnownHostsFile=" + targetKnownHostsPath(rec),
		"-o", "ProxyCommand=" + proxyCommand,
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
		if err := validateRelayUser(rec.RelayUser); err != nil {
			return fmt.Errorf("cannot remove CLI-installed relay authorization: %w", err)
		}
		cmd := fmt.Sprintf("tmp=$(mktemp) && grep -vF %s ~%s/.ssh/authorized_keys > $tmp && cat $tmp > ~%s/.ssh/authorized_keys && rm -f $tmp", shellQuote("cc-remote:"+rec.ID), rec.RelayUser, rec.RelayUser)
		if err := runRelayInstall(rec.RelaySSHHost, cmd, os.Stdout, os.Stderr); err != nil {
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

type appConfig struct {
	DefaultRelay relayProfile `json:"default_relay,omitempty"`
}

type relayProfile struct {
	Host    string `json:"host,omitempty"`
	Port    int    `json:"port,omitempty"`
	User    string `json:"user,omitempty"`
	SSHHost string `json:"ssh_host,omitempty"`
}

type relayShowResult struct {
	OK         bool         `json:"ok"`
	Configured bool         `json:"configured"`
	ConfigPath string       `json:"config_path"`
	Relay      relayProfile `json:"default_relay,omitempty"`
}

func configPath() (string, error) {
	base, err := session.BaseDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "config.json"), nil
}

func readAppConfig() (appConfig, string, error) {
	path, err := configPath()
	if err != nil {
		return appConfig{}, "", err
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return appConfig{}, path, nil
	}
	if err != nil {
		return appConfig{}, path, err
	}
	var cfg appConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		return appConfig{}, path, fmt.Errorf("read %s: %w", path, err)
	}
	return cfg, path, nil
}

func writeAppConfig(cfg appConfig) (string, error) {
	base, err := session.EnsureDirs()
	if err != nil {
		return "", err
	}
	path := filepath.Join(base, "config.json")
	return path, writeJSONAtomic(path, cfg, 0o600)
}

func validateRelayProfile(p relayProfile, requireHost bool) error {
	p.Host = strings.TrimSpace(p.Host)
	p.User = strings.TrimSpace(p.User)
	p.SSHHost = strings.TrimSpace(p.SSHHost)
	if requireHost && p.Host == "" {
		return errors.New("relay host is required")
	}
	if p.Host != "" && strings.ContainsAny(p.Host, " \t\r\n") {
		return fmt.Errorf("invalid relay host %q: whitespace is not allowed", p.Host)
	}
	if p.Port < 1 || p.Port > 65535 {
		return fmt.Errorf("invalid relay port %d: use a port from 1 to 65535", p.Port)
	}
	if err := validateRelayUser(p.User); err != nil {
		return err
	}
	return nil
}

func flagWasSet(fs *flag.FlagSet, name string) bool {
	seen := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == name {
			seen = true
		}
	})
	return seen
}

func applyRelayDefaults(fs *flag.FlagSet, relayHost *string, relayPort *int, relayUser *string, relaySSHHost *string) error {
	relayHostSet := flagWasSet(fs, "relay-host")
	relayPortSet := flagWasSet(fs, "relay-port")
	relayUserSet := flagWasSet(fs, "relay-user")
	relaySSHHostSet := flagWasSet(fs, "relay-ssh-host")
	endpointFlagSet := relayHostSet || relayPortSet || relayUserSet
	needsEndpointDefault := !relayHostSet || !relayPortSet || !relayUserSet
	needsAdminHostDefault := !relaySSHHostSet && !endpointFlagSet
	if !needsEndpointDefault && !needsAdminHostDefault {
		return nil
	}

	cfg, _, err := readAppConfig()
	if err != nil {
		return err
	}
	profile := cfg.DefaultRelay
	if profile.Host == "" {
		return nil
	}
	if err := validateRelayProfile(profile, true); err != nil {
		return fmt.Errorf("saved relay profile is invalid; run cc-remote relay set again: %w", err)
	}
	if !relayHostSet {
		*relayHost = profile.Host
	}
	if !relayPortSet {
		*relayPort = profile.Port
	}
	if !relayUserSet {
		*relayUser = profile.User
	}
	if needsAdminHostDefault {
		*relaySSHHost = profile.SSHHost
	}
	return nil
}

func relay(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: cc-remote relay set|show|doctor|bootstrap|clear")
	}
	switch args[0] {
	case "set":
		return relaySet(args[1:])
	case "show":
		return relayShow(args[1:])
	case "doctor":
		return relayDoctor(args[1:])
	case "bootstrap":
		return relayBootstrap(args[1:])
	case "clear":
		return relayClear(args[1:])
	default:
		return fmt.Errorf("unknown relay command %q: use set, show, doctor, bootstrap, or clear", args[0])
	}
}

func relaySet(args []string) error {
	fs := flag.NewFlagSet("relay set", flag.ExitOnError)
	host := fs.String("host", "", "public relay hostname or address controlled machines dial")
	port := fs.Int("port", 22, "public relay SSH port")
	user := fs.String("user", "cc-tunnel", "dedicated relay tunnel user")
	sshHost := fs.String("ssh-host", "", "optional operator-side administrative SSH alias for --install-relay")
	jsonOutput := fs.Bool("json", false, "print machine-readable result")
	if err := fs.Parse(args); err != nil {
		return err
	}
	profile := relayProfile{Host: strings.TrimSpace(*host), Port: *port, User: strings.TrimSpace(*user), SSHHost: strings.TrimSpace(*sshHost)}
	if err := validateRelayProfile(profile, true); err != nil {
		return err
	}
	path, err := writeAppConfig(appConfig{DefaultRelay: profile})
	if err != nil {
		return err
	}
	res := relayShowResult{OK: true, Configured: true, ConfigPath: path, Relay: profile}
	if *jsonOutput {
		return printJSON(res)
	}
	fmt.Println("Saved default relay profile:", path)
	fmt.Printf("Relay endpoint: %s:%d\n", profile.Host, profile.Port)
	fmt.Println("Relay user:", profile.User)
	if profile.SSHHost != "" {
		fmt.Println("Administrative SSH destination:", profile.SSHHost)
		fmt.Println("Automatic per-session relay authorization is still opt-in: pass --install-relay=true.")
	} else {
		fmt.Println("Administrative SSH destination: not saved; create will print relay_authorized_key_line for manual installation.")
	}
	return nil
}

func relayShow(args []string) error {
	fs := flag.NewFlagSet("relay show", flag.ExitOnError)
	jsonOutput := fs.Bool("json", false, "print machine-readable result")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, path, err := readAppConfig()
	if err != nil {
		return err
	}
	configured := cfg.DefaultRelay.Host != ""
	res := relayShowResult{OK: true, Configured: configured, ConfigPath: path}
	if configured {
		res.Relay = cfg.DefaultRelay
	}
	if *jsonOutput {
		return printJSON(res)
	}
	if !configured {
		fmt.Println("No default relay profile is configured.")
		fmt.Println("Run: cc-remote relay set --host <relay-host> --port <relay-ssh-port> --user cc-tunnel")
		return nil
	}
	fmt.Println("Default relay profile:", path)
	fmt.Printf("- Endpoint: %s:%d\n", cfg.DefaultRelay.Host, cfg.DefaultRelay.Port)
	fmt.Println("- User:", cfg.DefaultRelay.User)
	if cfg.DefaultRelay.SSHHost != "" {
		fmt.Println("- Administrative SSH destination:", cfg.DefaultRelay.SSHHost)
	} else {
		fmt.Println("- Administrative SSH destination: not configured")
	}
	return nil
}

func relayDoctor(args []string) error {
	fs := flag.NewFlagSet("relay doctor", flag.ExitOnError)
	jsonOutput := fs.Bool("json", false, "print machine-readable result")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, path, err := readAppConfig()
	if err != nil {
		return err
	}
	res := relayShowResult{OK: true, Configured: cfg.DefaultRelay.Host != "", ConfigPath: path, Relay: cfg.DefaultRelay}
	if !res.Configured {
		res.OK = false
	} else if err := validateRelayProfile(cfg.DefaultRelay, true); err != nil {
		res.OK = false
	}
	if *jsonOutput {
		if err := printJSON(res); err != nil {
			return err
		}
		if !res.OK {
			return errors.New("relay profile is not configured or invalid")
		}
		return nil
	}
	if !res.Configured {
		fmt.Println("cc-remote relay doctor: no default relay profile configured")
		fmt.Println("Run: cc-remote relay set --host <relay-host> --port <relay-ssh-port> --user cc-tunnel")
		return errors.New("relay profile is not configured")
	}
	if err := validateRelayProfile(cfg.DefaultRelay, true); err != nil {
		fmt.Println("cc-remote relay doctor: failed")
		return err
	}
	fmt.Println("cc-remote relay doctor: ok")
	fmt.Printf("- Endpoint: %s:%d\n", cfg.DefaultRelay.Host, cfg.DefaultRelay.Port)
	fmt.Println("- User:", cfg.DefaultRelay.User)
	fmt.Println("This validates the saved operator profile only. Verify sshd/GatewayPorts on the relay host separately with docs/relay.md.")
	return nil
}

type relayBootstrapResult struct {
	OK          bool         `json:"ok"`
	Configured  bool         `json:"configured"`
	ConfigPath  string       `json:"config_path"`
	Relay       relayProfile `json:"default_relay"`
	AdminTarget string       `json:"admin_target"`
	Mutated     bool         `json:"mutated"`
	Saved       bool         `json:"saved"`
}

func relayBootstrap(args []string) error {
	fs := flag.NewFlagSet("relay bootstrap", flag.ExitOnError)
	adminTarget := fs.String("admin-target", "", "administrative SSH destination for the relay, for example root@relay.example.test or an SSH alias")
	publicHost := fs.String("host", "", "public relay hostname or address controlled machines dial")
	publicPort := fs.Int("port", 22, "public relay SSH port")
	relayUser := fs.String("user", "cc-tunnel", "dedicated relay tunnel user")
	identityFile := fs.String("identity-file", "", "optional administrative SSH private-key path; private-key contents are never stored")
	sshPort := fs.Int("ssh-port", 0, "optional administrative SSH port; defaults to --port when --admin-target is a host")
	yes := fs.Bool("yes", false, "confirm this command may mutate the authorized relay host")
	noSave := fs.Bool("no-save", false, "configure the relay but do not save it as the default profile")
	jsonOutput := fs.Bool("json", false, "print machine-readable result")
	if err := fs.Parse(args); err != nil {
		return err
	}
	*adminTarget = strings.TrimSpace(*adminTarget)
	profile := relayProfile{Host: strings.TrimSpace(*publicHost), Port: *publicPort, User: strings.TrimSpace(*relayUser)}
	if *identityFile == "" && *sshPort == 0 {
		profile.SSHHost = *adminTarget
	}
	if err := validateRelayProfile(profile, true); err != nil {
		return err
	}
	if *adminTarget == "" {
		return errors.New("--admin-target is required; provide an administrative SSH destination for the relay you control")
	}
	if strings.HasPrefix(*adminTarget, "-") || strings.ContainsAny(*adminTarget, " \t\r\n") {
		return errors.New("invalid --admin-target: use an SSH host alias or user@host without whitespace or leading dashes")
	}
	if *identityFile != "" && strings.ContainsAny(*identityFile, "\r\n") {
		return errors.New("invalid --identity-file: newlines are not allowed")
	}
	if (*identityFile != "" || *sshPort != 0) && !*noSave {
		return errors.New("--identity-file or --ssh-port requires --no-save; create an SSH alias for non-default admin access and use that alias as --admin-target before saving")
	}
	if *sshPort < 0 || *sshPort > 65535 {
		return fmt.Errorf("invalid --ssh-port %d: use a port from 1 to 65535", *sshPort)
	}
	if !*yes {
		return errors.New("refusing to mutate a relay without --yes; confirm this exact relay host is authorized")
	}

	sshArgs := []string{"-o", "ConnectTimeout=15"}
	if *identityFile != "" {
		sshArgs = append(sshArgs, "-o", "BatchMode=yes", "-i", *identityFile)
	}
	if *sshPort == 0 && *identityFile == "" {
		sshArgs = append(sshArgs, "-tt")
	}
	port := *sshPort
	if port == 0 && strings.Contains(*adminTarget, "@") {
		port = *publicPort
	}
	if port != 0 {
		sshArgs = append(sshArgs, "-p", strconv.Itoa(port))
	}
	sshArgs = append(sshArgs, "--", *adminTarget, relayBootstrapScript(profile.User))
	cmd := exec.Command("ssh", sshArgs...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("bootstrap relay over SSH: %w", err)
	}
	path := ""
	if !*noSave {
		var err error
		path, err = writeAppConfig(appConfig{DefaultRelay: profile})
		if err != nil {
			return err
		}
	}
	res := relayBootstrapResult{OK: true, Configured: !*noSave, ConfigPath: path, Relay: profile, AdminTarget: *adminTarget, Mutated: true, Saved: !*noSave}
	if *jsonOutput {
		return printJSON(res)
	}
	fmt.Println("Relay bootstrap completed:", *adminTarget)
	if *noSave {
		fmt.Println("Default relay profile was not saved because --no-save was set.")
	} else {
		fmt.Println("Saved default relay profile:", path)
		fmt.Printf("Relay endpoint: %s:%d\n", profile.Host, profile.Port)
		fmt.Println("Relay user:", profile.User)
	}
	return nil
}

func relayBootstrapScript(user string) string {
	return fmt.Sprintf(`set -eu
if ! command -v sudo >/dev/null 2>&1; then echo 'sudo is required on the relay' >&2; exit 1; fi
if ! id %[1]s >/dev/null 2>&1; then sudo useradd --system --create-home --shell /usr/sbin/nologin %[1]s; fi
home=$(getent passwd %[1]s | cut -d: -f6)
shell=$(getent passwd %[1]s | cut -d: -f7)
if [ -z "$home" ]; then echo 'cannot resolve relay user home' >&2; exit 1; fi
case "$shell" in */nologin|*/false) ;; *) echo 'relay user %[1]s exists but has an interactive shell; review the account before bootstrap' >&2; exit 1 ;; esac
sudo install -d -m 700 -o %[1]s -g %[1]s "$home/.ssh"
sudo touch "$home/.ssh/authorized_keys"
sudo chown %[1]s:%[1]s "$home/.ssh/authorized_keys"
sudo chmod 600 "$home/.ssh/authorized_keys"
if sudo grep -q '^# cc-remote relay bootstrap begin %[1]s$' /etc/ssh/sshd_config; then
  :
elif sudo grep -Eq '^Match[[:space:]]+' /etc/ssh/sshd_config; then
  echo 'existing sshd Match block found; review sshd_config manually before bootstrap' >&2
  exit 1
else
  sudo tee -a /etc/ssh/sshd_config >/dev/null <<'EOF'

# cc-remote relay bootstrap begin %[1]s
Match User %[1]s
  PasswordAuthentication no
  PermitTTY no
  X11Forwarding no
  AllowTcpForwarding yes
  GatewayPorts no
# cc-remote relay bootstrap end %[1]s
EOF
fi
sudo sshd -t
if command -v systemctl >/dev/null 2>&1; then
  sudo systemctl reload sshd 2>/dev/null || sudo systemctl reload ssh 2>/dev/null || sudo service ssh reload 2>/dev/null || sudo service sshd reload 2>/dev/null
else
  sudo service ssh reload 2>/dev/null || sudo service sshd reload 2>/dev/null
fi
printf 'CC_REMOTE_RELAY_READY %[1]s\n'
`, user)
}

func relayClear(args []string) error {
	fs := flag.NewFlagSet("relay clear", flag.ExitOnError)
	jsonOutput := fs.Bool("json", false, "print machine-readable result")
	if err := fs.Parse(args); err != nil {
		return err
	}
	path, err := configPath()
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if *jsonOutput {
		return printJSON(relayShowResult{OK: true, Configured: false, ConfigPath: path})
	}
	fmt.Println("Cleared default relay profile:", path)
	return nil
}

func initRelay(args []string) error {
	fs := flag.NewFlagSet("init-relay", flag.ExitOnError)
	printSnippet := fs.Bool("print-snippet", true, "print relay setup snippet")
	user := fs.String("user", "cc-tunnel", "relay tunnel user")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if err := validateRelayUser(*user); err != nil {
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

func validateRelayUser(user string) error {
	if !relayUserName.MatchString(user) {
		return fmt.Errorf("invalid relay user %q: use a Linux account name matching %s", user, relayUserName.String())
	}
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

func runRelayInstall(alias, script string, stdout, stderr io.Writer) error {
	cmd := exec.Command("ssh", alias, script)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
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
	fmt.Fprintf(&md, "- Session ID: `%s`\n- Status: **%s**\n- Created: `%s`\n", rec.ID, info.Status, rec.CreatedAt.Format(time.RFC3339))
	if rec.ExpiresAt.IsZero() {
		fmt.Fprintln(&md, "- Expires: `never` (manual close required)")
	} else {
		fmt.Fprintf(&md, "- Expires: `%s`\n", rec.ExpiresAt.Format(time.RFC3339))
	}
	if rec.ClosedAt != nil {
		fmt.Fprintf(&md, "- Closed: `%s`\n", rec.ClosedAt.Format(time.RFC3339))
	}
	if rec.IdleTimeout == "0s" {
		fmt.Fprintln(&md, "- Idle cleanup: `disabled` (manual close required)")
		fmt.Fprintln(&md)
	} else {
		fmt.Fprintf(&md, "- Idle cleanup: `%s` after the last active SSH connection\n\n", rec.IdleTimeout)
	}
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
	if !rec.ExpiresAt.IsZero() && time.Now().UTC().After(rec.ExpiresAt) {
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

func writeWindowsHandoffScripts(bundlePath, cmdPath, ps1Path, id, mode, bundleSHA256 string) error {
	if mode == "bundle" {
		return writeBundleHandoffScripts(bundlePath, cmdPath, ps1Path, "", "", id, bundleSHA256)
	}
	return writeHandoffScripts(bundlePath, cmdPath, ps1Path, "", "", id)
}

func writeUnixHandoffScript(bundlePath, path, id, mode, bundleSHA256 string) error {
	if mode == "bundle" {
		return writeBundleHandoffScripts(bundlePath, "", "", path, "", id, bundleSHA256)
	}
	return writeHandoffScripts(bundlePath, "", "", path, "", id)
}

func writeBundleHandoffScripts(bundlePath, cmdPath, ps1Path, shPath, commandPath, id, bundleSHA256 string) error {
	bundleName := filepath.Base(bundlePath)
	cmdTemplate := `@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >/dev/null
title cc-remote __ID__ temporary support
set "CC_REMOTE_SELF=%~f0"
set "ROOT=%TEMP%\cc-remote-__ID__"
set "ZIP=%~dp0__BUNDLE__"
set "EXPECTED_SHA=__SHA__"
set "LOG=%ProgramData%\cc-remote\sessions\__ID__\bootstrap.log"
set "RC=1"

net session >/dev/null 2>&1
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
if not exist "%ZIP%" (
  echo ERROR: Expected bundle not found beside launcher: %ZIP%
  goto :failed
)
echo [%date% %time%] Verifying offline bundle: %ZIP%
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$h=(Get-FileHash -Algorithm SHA256 -LiteralPath $env:ZIP).Hash.ToLowerInvariant(); if($h -ne $env:EXPECTED_SHA){throw ('Bundle SHA256 mismatch: ' + $h)}" >>"%LOG%" 2>&1
if errorlevel 1 goto :failed

echo [%date% %time%] Extracting bundle to "%ROOT%"...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "New-Item -ItemType Directory -Force -Path $env:ROOT | Out-Null; Expand-Archive -Force -Path $env:ZIP -DestinationPath $env:ROOT; $m=Get-Content (Join-Path $env:ROOT 'manifest.json') -Raw | ConvertFrom-Json; if($m.session_id -ne '__ID__'){throw 'Extracted manifest session_id mismatch'}" >>"%LOG%" 2>&1
if errorlevel 1 goto :failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { & $env:ROOT\bootstrap.ps1 -NoMonitor *>&1 | Tee-Object -FilePath $env:LOG -Append; if (-not $?) { exit 1 } } catch { $_ | Out-String | Tee-Object -FilePath $env:LOG -Append; exit 1 }"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" goto :bootstrap_failed

echo cc-remote setup finished successfully.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\bootstrap.ps1" -MonitorOnly
set "RC=%ERRORLEVEL%"
goto :hold

:bootstrap_failed
echo ERROR: cc-remote bootstrap failed with exit code %RC%.
echo Review or send this log to the operator: %LOG%
goto :hold

:failed
echo ERROR: cc-remote launcher could not complete setup.
echo If a log was created, it is at: %LOG%

:hold
echo.
pause
exit /b %RC%
`
	cmd := strings.NewReplacer("__ID__", id, "__BUNDLE__", bundleName, "__SHA__", bundleSHA256).Replace(cmdTemplate)
	ps := fmt.Sprintf(`# cc-remote Windows bootstrap. Run in PowerShell as Administrator with %[2]s beside this file.
$ErrorActionPreference = 'Stop'
$SelfDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Join-Path $env:TEMP 'cc-remote-%[1]s'
$Zip = Join-Path $SelfDir '%[2]s'
$ExpectedSHA = '%[3]s'
$Log = Join-Path $env:ProgramData 'cc-remote\sessions\%[1]s\bootstrap.log'
New-Item -ItemType Directory -Force -Path $Root, (Split-Path -Parent $Log) | Out-Null
if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { throw "Expected bundle not found beside launcher: $Zip" }
$Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Zip).Hash.ToLowerInvariant()
if ($Hash -ne $ExpectedSHA) { throw "Bundle SHA256 mismatch: $Hash" }
Expand-Archive -Force -Path $Zip -DestinationPath $Root
$Manifest = Get-Content (Join-Path $Root 'manifest.json') -Raw | ConvertFrom-Json
if ($Manifest.session_id -ne '%[1]s') { throw 'Extracted manifest session_id mismatch.' }
& (Join-Path $Root 'bootstrap.ps1') -NoMonitor *>&1 | Tee-Object -FilePath $Log -Append
if (-not $?) { throw 'cc-remote setup failed; monitor was not started.' }
& (Join-Path $Root 'bootstrap.ps1') -MonitorOnly
`, id, bundleName, bundleSHA256)
	shTemplate := `#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi
set -Eeuo pipefail

session_id="__ID__"
self_dir="$(cd "$(dirname "$0")" && pwd)"
root="${TMPDIR:-/tmp}/cc-remote-$session_id"
zip="$self_dir/__BUNDLE__"
expected_sha="__SHA__"
log_dir="/var/tmp/cc-remote/$session_id"
log="$log_dir/bootstrap.log"
stage="launcher initialization"
rc=1

stamp() { date '+%Y-%m-%d %H:%M:%S'; }
log_line() { printf '[%s] %s\n' "$(stamp)" "$*"; }
hold_on_failure() { if [ -t 0 ]; then printf '\nPress Return to close this window...'; IFS= read -r _ || true; fi; }
on_error() { local code="$1" line="$2"; trap - ERR; log_line "ERROR: launcher failed during '$stage' (line $line, exit $code)." >&2; log_line "Persistent log: $log" >&2; hold_on_failure; exit "$code"; }
trap 'on_error $? $LINENO' ERR

if [ "$(uname -s)" != "Darwin" ] && [ "$(uname -s)" != "Linux" ]; then log_line "ERROR: unsupported operating system: $(uname -s)" >&2; hold_on_failure; exit 1; fi
if [ "$(id -u)" -ne 0 ]; then log_line "Requesting administrator privileges. Enter this Mac's login password once."; exec sudo /bin/bash "$0" --elevated; fi
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

stage="verifying bundle"
[ -f "$zip" ] || { log_line "ERROR: expected bundle not found beside launcher: $zip" >&2; false; }
actual_sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
[ "$actual_sha" = "$expected_sha" ] || { log_line "ERROR: bundle SHA256 mismatch: $actual_sha" >&2; false; }
stage="extracting bundle"
command -v unzip >/dev/null 2>&1 || { log_line "ERROR: unzip is required." >&2; false; }
unzip -o "$zip" -d "$root" >/dev/null
manifest_session="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("session_id", ""))' "$root/manifest.json")"
[ "$manifest_session" = "$session_id" ] || { log_line "ERROR: extracted manifest session_id mismatch." >&2; false; }
chmod 700 "$root/bootstrap.sh" "$root/cleanup.sh" "$root/idle-watch.sh"
stage="running bootstrap"
CC_REMOTE_LOG="$log" /bin/bash "$root/bootstrap.sh"
rc=$?
if [ "$rc" -eq 0 ]; then log_line "cc-remote bootstrap finished."; else log_line "ERROR: bootstrap exited with code $rc. Log: $log" >&2; hold_on_failure; fi
exit "$rc"
`
	sh := strings.NewReplacer("__ID__", id, "__BUNDLE__", bundleName, "__SHA__", bundleSHA256).Replace(shTemplate)
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

func sshKeygen(path, comment string, stdout, stderr io.Writer) error {
	if _, err := exec.LookPath("ssh-keygen"); err != nil {
		return errors.New("ssh-keygen not found")
	}
	cmd := exec.Command("ssh-keygen", "-t", "ed25519", "-N", "", "-C", comment, "-f", path)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
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
