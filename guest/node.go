package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/mdlayher/vsock"
)

// `weaver node list | exec | read | write`: the tenant's own machines, for
// the agents in this VM. Loom's `loom-node` CLI, asking Weaver over the call
// connection instead of HTTP (Weaver.Calls.Node relays to the device). What
// is meant for the model is plain text: output on stdout, problems on
// stderr, and an exit code that is the device's own, or one of these:
const (
	exitTimeout = 124 // the command ran past --timeout and was killed
	exitWeaver  = 255 // the device is offline, unknown, or dropped mid-request
)

const nodeUsage = `usage:
  weaver node list
  weaver node exec <device> [--cwd DIR] [--timeout SECONDS] -- <command>
  weaver node read <device> <path> > local-file
  weaver node write <device> <path> < local-file
`

func nodeCLI(args []string) int {
	if len(args) == 0 {
		fmt.Fprint(os.Stderr, nodeUsage)
		return 2
	}
	switch args[0] {
	case "list":
		return nodeList(args[1:])
	case "exec":
		return nodeExec(args[1:])
	case "read":
		return nodeRead(args[1:])
	case "write":
		return nodeWrite(args[1:])
	}
	fmt.Fprint(os.Stderr, nodeUsage)
	return 2
}

func nodeDie(format string, args ...any) int {
	fmt.Fprintf(os.Stderr, "weaver node: "+format+"\n", args...)
	return exitWeaver
}

// nodeCall sends the request and hands each frame Weaver answers with to
// handle, until 'q' (its status is the exit code) or 'f'.
func nodeCall(method string, args map[string]any, input io.Reader, handle func(typ byte, body []byte)) int {
	nc, err := vsock.Dial(vsock.Host, hostPort, nil)
	if err != nil {
		return nodeDie("cannot reach Weaver: %v", err)
	}
	c := &conn{Conn: nc}
	defer c.Close()
	body, _ := json.Marshal(map[string]any{"method": method, "args": args})
	if err := c.send('c', body); err != nil {
		return nodeDie("%v", err)
	}
	if input != nil {
		if err := c.copyOut('i', input); err != nil {
			return nodeDie("%v", err)
		}
		c.send('e', nil)
	}
	for {
		typ, body, err := c.read()
		if err != nil {
			return nodeDie("the connection to Weaver ended mid-request; run `weaver node list` to see whether the device is back online, then retry")
		}
		switch typ {
		case 'q':
			if len(body) == 4 {
				return int(body[0])<<24 | int(body[1])<<16 | int(body[2])<<8 | int(body[3])
			}
			return 0
		case 'f':
			return nodeDie("%s", body)
		default:
			handle(typ, body)
		}
	}
}

func nodeList(args []string) int {
	if len(args) != 0 {
		fmt.Fprint(os.Stderr, nodeUsage)
		return 2
	}
	var nodes []struct {
		Name       string  `json:"name"`
		Online     bool    `json:"online"`
		OS         *string `json:"os"`
		Arch       *string `json:"arch"`
		Hostname   *string `json:"hostname"`
		LastSeenAt *string `json:"last_seen_at"`
	}
	code := nodeCall("node.list", map[string]any{}, nil, func(typ byte, body []byte) {
		if typ == 'o' {
			json.Unmarshal(body, &nodes)
		}
	})
	if code != 0 {
		return code
	}
	if len(nodes) == 0 {
		fmt.Println("no devices registered; the user adds them under Devices in Weaver's sidebar")
		return 0
	}
	tw := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "NAME\tSTATUS\tSYSTEM\tHOSTNAME\tLAST SEEN")
	for _, n := range nodes {
		status := "offline"
		if n.Online {
			status = "online"
		}
		system := "-"
		if n.OS != nil && n.Arch != nil {
			system = *n.OS + "/" + *n.Arch
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\n", n.Name, status, system, deref(n.Hostname), ago(n.LastSeenAt, n.Online))
	}
	tw.Flush()
	return 0
}

func deref(s *string) string {
	if s == nil || *s == "" {
		return "-"
	}
	return *s
}

func ago(at *string, online bool) string {
	if online {
		return "now"
	}
	if at == nil {
		return "never"
	}
	t, err := time.Parse(time.RFC3339, *at)
	if err != nil {
		return *at
	}
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}

func nodeExec(args []string) int {
	fs := flag.NewFlagSet("exec", flag.ContinueOnError)
	cwd := fs.String("cwd", "", "directory to run in, on the device (default: home)")
	timeout := fs.Int("timeout", 120, "seconds before the command is killed (max 1800)")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: weaver node exec <device> [--cwd DIR] [--timeout SECONDS] -- <command>")
	}
	if len(args) < 1 || strings.HasPrefix(args[0], "-") {
		fs.Usage()
		return 2
	}
	node := args[0]
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	command := strings.Join(fs.Args(), " ")
	if strings.TrimSpace(command) == "" {
		fs.Usage()
		return 2
	}
	return nodeCall("node.exec", map[string]any{
		"node": node, "cmd": command, "cwd": devicePath(*cwd), "timeout": *timeout,
		"session": os.Getenv("LOOM_SESSION_ID"),
	}, nil, func(typ byte, body []byte) {
		switch typ {
		case 'o':
			os.Stdout.Write(body)
		case 'r':
			os.Stderr.Write(body)
		}
	})
}

func nodeRead(args []string) int {
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: weaver node read <device> <path> > local-file")
		return 2
	}
	out := bufio.NewWriterSize(os.Stdout, 1<<20)
	defer out.Flush()
	return nodeCall("node.read", map[string]any{"node": args[0], "path": devicePath(args[1])}, nil,
		func(typ byte, body []byte) {
			if typ == 'o' {
				out.Write(body)
			}
		})
}

func nodeWrite(args []string) int {
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: weaver node write <device> <path> < local-file")
		return 2
	}
	var written struct {
		Size int64  `json:"size"`
		Path string `json:"path"`
	}
	code := nodeCall("node.write", map[string]any{"node": args[0], "path": devicePath(args[1])}, os.Stdin,
		func(typ byte, body []byte) {
			if typ == 'o' {
				json.Unmarshal(body, &written)
			}
		})
	if code == 0 {
		fmt.Printf("wrote %d bytes to %s:%s\n", written.Size, args[0], written.Path)
	}
	return code
}

// devicePath undoes the one thing this VM's shell does to a path meant for
// the device: an unquoted ~ arrives here already expanded to *our* home.
// /home/tenant/x is never what was meant on a Mac, so it goes back to ~/x and
// the device expands it to its own.
func devicePath(p string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" || home == "/" {
		return p
	}
	switch {
	case p == home:
		return "~"
	case strings.HasPrefix(p, home+"/"):
		return "~/" + p[len(home)+1:]
	}
	return p
}
