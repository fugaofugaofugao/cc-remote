package manifest

import "time"

type Payload struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type Manifest struct {
	Version                  int       `json:"version"`
	SessionID                string    `json:"session_id"`
	Name                     string    `json:"name"`
	CreatedAt                time.Time `json:"created_at"`
	ExpiresAt                time.Time `json:"expires_at"`
	IdleTimeoutSeconds       int       `json:"idle_timeout_seconds"`
	RelayHost                string    `json:"relay_host"`
	RelayUser                string    `json:"relay_user"`
	RelaySSHPort             int       `json:"relay_ssh_port"`
	RemotePort               int       `json:"remote_port"`
	TargetUser               string    `json:"target_user"`
	TargetAuthorizedKey      string    `json:"target_authorized_key"`
	TunnelPrivateKeyPath     string    `json:"tunnel_private_key_path"`
	OperatorTargetKeyPath    string    `json:"operator_target_key_path,omitempty"`
	OperatorTunnelKeyPath    string    `json:"operator_tunnel_key_path,omitempty"`
	OperatorSSHConfigPath    string    `json:"operator_ssh_config_path,omitempty"`
	OperatorSSHHostAlias     string    `json:"operator_ssh_host_alias,omitempty"`
	OperatorSSHCommand       string    `json:"operator_ssh_command,omitempty"`
	TargetKeyFingerprint     string    `json:"target_key_fingerprint,omitempty"`
	TunnelKeyFingerprint     string    `json:"tunnel_key_fingerprint,omitempty"`
	TargetHostKeyFingerprint string    `json:"target_host_key_fingerprint,omitempty"`
	Payloads                 []Payload `json:"payloads"`
}
