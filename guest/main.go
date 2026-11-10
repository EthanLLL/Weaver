// weaver-guest runs inside a tenant VM. It is the VM's only way in and out of
// Weaver, over vsock:
//
//   - The host connects to port 1024 to run processes and to read and write
//     files (exec.go, files.go).
//   - Programs in the VM call Weaver through `weaver <method> [json]`, a
//     connection to the host's port 1025 (call.go). The host knows the tenant
//     from which VM the connection came from; nothing in the VM holds a key.
//
// Every message on the wire is a frame: a 4-byte big-endian length, then that
// many bytes, the first being the frame's type. (Erlang reads these with
// `packet: 4`.) A connection does one thing, named by its first frame:
//
//	'x' run a process (exec.go)
//	'F' a file operation (files.go)
//	't' a TCP connection to a port on the VM's loopback (tunnel.go)
//	'c' a call to Weaver (call.go; VM to host)
//
// Frames that may follow, both ways:
//
//	'i' bytes in (stdin, a file's contents)        host → guest
//	'e' end of input                               host → guest
//	'k' one byte: a signal for the process group   host → guest
//	'z' 4 bytes: rows, cols of the terminal        host → guest
//	'o' bytes out (stdout, a file, a JSON reply)
//	'r' bytes from stderr                          guest → host
//	'q' 4-byte big-endian status, last (0 is success; 128+n if killed by signal n)
//	'f' why it failed, last
package main

import (
	"log"
	"os"
	"path/filepath"

	"github.com/mdlayher/vsock"
)

const (
	guestPort = 1024
	hostPort  = 1025
)

func main() {
	if filepath.Base(os.Args[0]) == "weaver" {
		os.Exit(call(os.Args[1:]))
	}

	l, err := vsock.Listen(guestPort, nil)
	if err != nil {
		log.Fatalf("listen on vsock port %d: %v", guestPort, err)
	}
	log.Printf("listening on vsock port %d", guestPort)
	for {
		c, err := l.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go serve(&conn{Conn: c})
	}
}

func serve(c *conn) {
	defer c.Close()
	typ, body, err := c.read()
	if err != nil {
		return
	}
	switch typ {
	case 'x':
		execute(c, body)
	case 'F':
		file(c, body)
	case 't':
		tunnel(c, body)
	default:
		c.fail("unknown request")
	}
}
