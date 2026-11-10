// weaver-node puts the user's own machines within reach of their tenant's
// agents in Weaver: Loom's loom-node, renamed so that both can live on one
// machine.
//
// On a device (a Mac, a WSL box): `weaver-node daemon` keeps a websocket open
// to the tenant's host (https://<tenant>.luozhen.cloud) and runs what it is
// sent: commands, file reads and writes. `weaver-node install` sets that up
// as a login service; the install script Weaver hands out runs it.
//
// The agents' side is not here: in the tenant's VM it is `weaver node …`
// (guest/node.go), which asks Weaver, which relays to the device.
package main

import (
	"fmt"
	"os"
)

// Set at build time; see the Makefile.
var version = "dev"

const usage = `weaver-node — let your Weaver agents run commands and move files on this machine

  weaver-node daemon                          stay connected to Weaver (what the service runs)
  weaver-node install --url URL --token TOKEN [--shell SHELL]
  weaver-node uninstall
  weaver-node version
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}

	args := os.Args[2:]
	var code int

	switch os.Args[1] {
	case "daemon":
		code = runDaemon(args)
	case "install":
		code = runInstall(args)
	case "uninstall":
		code = runUninstall(args)
	case "version", "--version", "-v":
		fmt.Println("weaver-node", version)
	case "help", "--help", "-h":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "weaver-node: unknown command %q\n\n%s", os.Args[1], usage)
		code = 2
	}

	os.Exit(code)
}
