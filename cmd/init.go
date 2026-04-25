package cmd

import (
	"fmt"
	"os"

	"tsm/internal/client"

	"github.com/charmbracelet/huh"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func newInitCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "init",
		Short: "Create vault, generate master key, store in Keychain",
		Long: `Initialize a new tsm vault. Generates a master key protected by Touch ID
and stores it in the macOS Keychain. Optionally set a recovery passphrase
for vault portability.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			recover, _ := cmd.Flags().GetBool("recover")
			return withClient(func(c client.Caller) error {
				if recover {
					return runInitRecover(c)
				}
				return runInit(c)
			})
		},
	}
	cmd.Flags().Bool("recover", false, "recover vault on new device using recovery passphrase")
	return cmd
}

func runInit(c client.Caller) error {
	var passphrase string

	if term.IsTerminal(int(os.Stdin.Fd())) {
		var useRecovery bool

		form := huh.NewForm(
			huh.NewGroup(
				huh.NewConfirm().
					Title("Set a recovery passphrase?").
					Description("Allows recovering the vault on a new device without Touch ID.").
					Value(&useRecovery),
			),
		)
		if err := form.Run(); err != nil {
			return err
		}

		if useRecovery {
			var confirm string
			form := huh.NewForm(
				huh.NewGroup(
					huh.NewInput().
						Title("Recovery passphrase").
						EchoMode(huh.EchoModePassword).
						Value(&passphrase),
					huh.NewInput().
						Title("Confirm passphrase").
						EchoMode(huh.EchoModePassword).
						Value(&confirm),
				),
			)
			if err := form.Run(); err != nil {
				return err
			}
			if passphrase != confirm {
				return fmt.Errorf("passphrases do not match")
			}
		}
	}

	params := map[string]any{}
	if passphrase != "" {
		params["recovery_passphrase"] = passphrase
	}

	if err := c.Call("vault.init", params, nil); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Println("Vault created. Master key stored in Keychain with Touch ID protection.")
	if passphrase != "" {
		fmt.Println("Recovery passphrase set. Store it somewhere safe — it cannot be retrieved later.")
	}
	return nil
}

func runInitRecover(c client.Caller) error {
	var passphrase string

	if term.IsTerminal(int(os.Stdin.Fd())) {
		form := huh.NewForm(
			huh.NewGroup(
				huh.NewInput().
					Title("Recovery passphrase").
					Description("Enter the passphrase you set during 'tsm init'.").
					EchoMode(huh.EchoModePassword).
					Value(&passphrase),
			),
		)
		if err := form.Run(); err != nil {
			return err
		}
	} else {
		return fmt.Errorf("--recover requires an interactive terminal for passphrase input")
	}

	if passphrase == "" {
		return fmt.Errorf("passphrase cannot be empty")
	}

	if err := c.Call("vault.unlock", map[string]any{"passphrase": passphrase}, nil); err != nil {
		return handleError(err)
	}

	if jsonOutput() {
		return printJSON(map[string]bool{"ok": true})
	}
	fmt.Println("Vault recovered. Master key stored in Keychain with Touch ID protection.")
	return nil
}
