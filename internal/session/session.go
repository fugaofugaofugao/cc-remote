package session

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

type Record struct {
	ID                 string     `json:"id"`
	Name               string     `json:"name"`
	CreatedAt          time.Time  `json:"created_at"`
	ExpiresAt          time.Time  `json:"expires_at"`
	ClosedAt           *time.Time `json:"closed_at,omitempty"`
	IdleTimeout        string     `json:"idle_timeout"`
	RelayHost          string     `json:"relay_host"`
	RelayUser          string     `json:"relay_user"`
	RelaySSHPort       int        `json:"relay_ssh_port"`
	RelaySSHHost       string     `json:"relay_ssh_host"`
	RemotePort         int        `json:"remote_port"`
	TargetUser         string     `json:"target_user"`
	BundlePath         string     `json:"bundle_path"`
	HandoffCMDPath     string     `json:"handoff_cmd_path"`
	HandoffPS1Path     string     `json:"handoff_ps1_path"`
	HandoffShPath      string     `json:"handoff_sh_path"`
	HandoffCommandPath string     `json:"handoff_command_path"`
	ConnectionMDPath   string     `json:"connection_md_path"`
	ConnectionJSONPath string     `json:"connection_json_path"`
	SSHConfigPath      string     `json:"ssh_config_path"`
	SSHHostAlias       string     `json:"ssh_host_alias"`
	TargetKeyPath      string     `json:"target_key_path"`
	TunnelKeyPath      string     `json:"tunnel_key_path"`
	TunnelPubKey       string     `json:"tunnel_public_key"`
	RelayAuthKey       string     `json:"relay_authorized_key_line"`
	RelayInstalled     bool       `json:"relay_installed"`
	RelayInstallCmd    string     `json:"relay_install_cmd"`
}

func NewID() (string, error) {
	var b [5]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

func BaseDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".cc-remote"), nil
}

func EnsureDirs() (string, error) {
	base, err := BaseDir()
	if err != nil {
		return "", err
	}
	for _, dir := range []string{"sessions", "bundles"} {
		if err := os.MkdirAll(filepath.Join(base, dir), 0o700); err != nil {
			return "", err
		}
	}
	return base, nil
}

func PortFromID(id string) (int, error) {
	if len(id) < 4 {
		return 0, errors.New("session id too short")
	}
	var n uint16
	if _, err := fmt.Sscanf(id[:4], "%x", &n); err != nil {
		return 0, err
	}
	return 39000 + int(n%1001), nil
}
