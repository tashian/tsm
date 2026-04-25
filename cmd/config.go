package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"tsm/internal/paths"

	"github.com/spf13/cobra"
)

type tsmConfig struct {
	TTLHours                 int  `json:"ttl_hours"`
	UpdateCheck              bool `json:"update_check"`
	UpdateCheckIntervalHours int  `json:"update_check_interval_hours"`
}

var defaultConfig = tsmConfig{
	TTLHours:                 12,
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

func runConfigView() error {
	cfg := loadConfig()
	return printJSON(cfg)
}

func runConfigGet(key string) error {
	cfg := loadConfig()
	switch key {
	case "ttl_hours":
		fmt.Println(cfg.TTLHours)
	case "update_check":
		fmt.Println(cfg.UpdateCheck)
	case "update_check_interval_hours":
		fmt.Println(cfg.UpdateCheckIntervalHours)
	default:
		return fmt.Errorf("unknown config key: %s", key)
	}
	return nil
}

func runConfigSet(key, value string) error {
	cfg := loadConfig()
	switch key {
	case "ttl_hours":
		v, err := strconv.Atoi(value)
		if err != nil || v < 1 {
			return fmt.Errorf("ttl_hours must be a positive integer")
		}
		cfg.TTLHours = v
	case "update_check":
		v, err := strconv.ParseBool(value)
		if err != nil {
			return fmt.Errorf("update_check must be true or false")
		}
		cfg.UpdateCheck = v
	case "update_check_interval_hours":
		v, err := strconv.Atoi(value)
		if err != nil || v < 1 {
			return fmt.Errorf("update_check_interval_hours must be a positive integer")
		}
		cfg.UpdateCheckIntervalHours = v
	default:
		return fmt.Errorf("unknown config key: %s", key)
	}

	if err := saveConfig(cfg); err != nil {
		return err
	}
	if !jsonOutput() {
		fmt.Printf("%s = %s\n", key, value)
	}
	return nil
}
