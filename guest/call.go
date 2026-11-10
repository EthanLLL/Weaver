package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"

	"github.com/mdlayher/vsock"
)

// `weaver <method> [json | -]`: call Weaver from inside the VM and print its
// JSON reply; `-` reads the JSON from stdin. Exits 0 on success, 1 if Weaver
// says no, 2 if it can't be reached. The request is a 'c' frame:
// {"method": "...", "args": {...}}. `weaver node …` is node.go.
func call(args []string) int {
	if len(args) > 0 && args[0] == "node" {
		return nodeCLI(args[1:])
	}
	if len(args) == 0 || len(args) > 2 {
		fmt.Fprintln(os.Stderr, "usage: weaver <method> [json-args | -]")
		return 2
	}
	req := map[string]any{"method": args[0], "args": map[string]any{}}
	if len(args) == 2 {
		raw := []byte(args[1])
		if args[1] == "-" {
			var err error
			if raw, err = io.ReadAll(os.Stdin); err != nil {
				fmt.Fprintln(os.Stderr, "weaver: cannot read stdin:", err)
				return 2
			}
		}
		var a any
		if err := json.Unmarshal(raw, &a); err != nil {
			fmt.Fprintln(os.Stderr, "weaver: args are not JSON:", err)
			return 2
		}
		req["args"] = a
	}
	body, _ := json.Marshal(req)

	nc, err := vsock.Dial(vsock.Host, hostPort, nil)
	if err != nil {
		fmt.Fprintln(os.Stderr, "weaver: cannot reach the host:", err)
		return 2
	}
	c := &conn{Conn: nc}
	defer c.Close()
	if err := c.send('c', body); err != nil {
		fmt.Fprintln(os.Stderr, "weaver:", err)
		return 2
	}
	for {
		typ, body, err := c.read()
		if err != nil {
			fmt.Fprintln(os.Stderr, "weaver: connection lost")
			return 2
		}
		switch typ {
		case 'o':
			os.Stdout.Write(body)
			fmt.Println()
		case 'q':
			return 0
		case 'f':
			fmt.Fprintln(os.Stderr, "weaver:", string(body))
			return 1
		}
	}
}
