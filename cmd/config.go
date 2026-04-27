package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"tsm/internal/client"
	"tsm/internal/paths"

	"github.com/spf13/cobra"
)

// tsmConfig is the local CLI-side config file. It holds settings that are
// purely client-side (e.g., when to phone home for version checks). The TTL
// lives in the daemon vault and is read/written via vault.config RPC methods.
type tsmConfig struct {
	UpdateCheck              bool `json:"update_check"`
	UpdateCheckIntervalHours int  `json:"update_check_interval_hours"`
}

var defaultConfig = tsmConfig{
	UpdateCheck:              true,
	UpdateCheckIntervalHours: 24,
}

func newConfigCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "config",
		Short: "View or set configuration",
		RunE: func(cmd *cobra.Command, args []string) error {
			return runConfigView()
		},
	}

	setCmd := &cobra.Command{
		Use:   "set <key> <value>",
		Short: "Set a config value",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runConfigSet(args[0], args[1])
		},
	}

	getCmd := &cobra.Command{
		Use:   "get <key>",
		Short: "Get a config value",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runConfigGet(args[0])
		},
	}

	cmd.AddCommand(setCmd, getCmd)
	return cmd
}

func loadConfig() tsmConfig {
	cfg := defaultConfig
	data, err := os.ReadFile(paths.ConfigFile())
	if err != nil {
		return cfg
	}
	json.Unmarshal(data, &cfg)
	return cfg
}

func saveConfig(cfg tsmConfig) error {
	path := paths.ConfigFile()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(data, '\n'), 0o600)
}

// parseTTLDuration parses a Go duration string and returns whole seconds.
// Sub-second durations and zero/negative values are rejected.
func parseTTLDuration(s string) (int, error) {
	d, err := time.ParseDuration(s)
	if err != nil {
		return 0, fmt.Errorf("ttl must be a Go duration like '30m' or '1h': %w", err)
	}
	if d < time.Second {
		return 0, fmt.Errorf("ttl must be at least 1 second")
	}
	if d.Truncate(time.Second) != d {
		return 0, fmt.Errorf("ttl must be a whole number of seconds; got %s", d)
	}
	return int(d.Seconds()), nil
}

// formatTTLSeconds renders a seconds count as a Go duration string.
func formatTTLSeconds(seconds int) string {
	return (time.Duration(seconds) * time.Second).String()
}

func runConfigView() error {
	cfg := loadConfig()
	out := map[string]any{
		"client": cfg,
	}
	// Best-effort: include vault config if the daemon is running and unlocked.
	_ = withClient(func(c client.Caller) error {
		var resp struct {
			TTLSeconds int `json:"ttl_seconds"`
		}
		if err := c.Call("vault.config.get", nil, &resp); err == nil {
			out["vault"] = map[string]any{
				"ttl": formatTTLSeconds(resp.TTLSeconds),
			}
		}
		return nil
	})
	return printJSON(out)
}

func runConfigGet(key string) error {
	switch key {
	case "ttl":
		return withUnlockedClient(func(c client.Caller) error {
			var resp struct {
				TTLSeconds int `json:"ttl_seconds"`
			}
			if err := c.Call("vault.config.get", nil, &resp); err != nil {
				return handleError(err)
			}
			fmt.Println(formatTTLSeconds(resp.TTLSeconds))
			return nil
		})
	case "update_check":
		fmt.Println(loadConfig().UpdateCheck)
		return nil
	case "update_check_interval_hours":
		fmt.Println(loadConfig().UpdateCheckIntervalHours)
		return nil
	default:
		return fmt.Errorf("unknown config key: %s", key)
	}
}

func runConfigSet(key, value string) error {
	switch key {
	case "ttl":
		seconds, err := parseTTLDuration(value)
		if err != nil {
			return err
		}
		return withUnlockedClient(func(c client.Caller) error {
			var resp struct {
				TTLSeconds int `json:"ttl_seconds"`
			}
			if err := c.Call("vault.config.set", map[string]any{
				"ttl_seconds": seconds,
			}, &resp); err != nil {
				return handleError(err)
			}
			if !jsonOutput() {
				fmt.Printf("ttl = %s\n", formatTTLSeconds(resp.TTLSeconds))
			}
			return nil
		})
	case "update_check":
		v, err := strconv.ParseBool(value)
		if err != nil {
			return fmt.Errorf("update_check must be true or false")
		}
		cfg := loadConfig()
		cfg.UpdateCheck = v
		if err := saveConfig(cfg); err != nil {
			return err
		}
		if !jsonOutput() {
			fmt.Printf("%s = %s\n", key, value)
		}
		return nil
	case "update_check_interval_hours":
		v, err := strconv.Atoi(value)
		if err != nil || v < 1 {
			return fmt.Errorf("update_check_interval_hours must be a positive integer")
		}
		cfg := loadConfig()
		cfg.UpdateCheckIntervalHours = v
		if err := saveConfig(cfg); err != nil {
			return err
		}
		if !jsonOutput() {
			fmt.Printf("%s = %s\n", key, value)
		}
		return nil
	default:
		return fmt.Errorf("unknown config key: %s", key)
	}
}
