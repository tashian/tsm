package cmd

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"

	"tsm/internal/paths"

	"github.com/spf13/cobra"
)

func newLogCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "log",
		Short: "View the access log",
		Long:  "Shows recent access log entries. Defaults to the last 20 entries.",
		RunE: func(cmd *cobra.Command, args []string) error {
			n, _ := cmd.Flags().GetInt("tail")
			all, _ := cmd.Flags().GetBool("all")
			if all {
				n = 0
			}
			return runLog(n)
		},
	}
	cmd.Flags().Int("tail", 20, "number of recent entries to show")
	cmd.Flags().Bool("all", false, "show all entries")
	return cmd
}

func runLog(tail int) error {
	f, err := os.Open(paths.AccessLog())
	if err != nil {
		if os.IsNotExist(err) {
			fmt.Println("No access log found.")
			return nil
		}
		return err
	}
	defer f.Close()

	var lines []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		return err
	}

	if tail > 0 && len(lines) > tail {
		lines = lines[len(lines)-tail:]
	}

	if jsonOutput() {
		var entries []json.RawMessage
		for _, line := range lines {
			entries = append(entries, json.RawMessage(line))
		}
		return printJSON(entries)
	}

	for _, line := range lines {
		var entry struct {
			TS       string  `json:"ts"`
			Method   string  `json:"method"`
			Secret   *string `json:"secret"`
			ClientID *string `json:"client_id"`
			Result   string  `json:"result"`
		}
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			fmt.Println(line)
			continue
		}
		secret := ""
		if entry.Secret != nil {
			secret = " " + *entry.Secret
		}
		clientID := ""
		if entry.ClientID != nil {
			clientID = " (" + *entry.ClientID + ")"
		}
		fmt.Printf("%s  %-14s%s  %s%s\n", entry.TS, entry.Method, secret, entry.Result, clientID)
	}
	return nil
}
