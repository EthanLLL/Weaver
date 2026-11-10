// weaver-guest runs inside a tenant VM and starts processes for the host.
//
// It listens on vsock port 1024. Each connection is one process: the host
// sends what to run, then the process's stdin; the guest sends back its
// stdout, stderr and exit status. Closing the connection kills the process,
// as closing a port does.
//
// Every message on the wire is a frame: a 4-byte big-endian length, then that
// many bytes, the first being the frame's type. (Erlang reads these with
// `packet: 4`.)
//
// Host to guest:
//
//	'x' JSON {"argv": [...], "cwd": "...", "env": ["K=V", ...]}, first and once
//	'i' bytes for stdin
//	'e' end of stdin
//	'k' one byte: a signal for the process group
//
// Guest to host:
//
//	'o' bytes from stdout
//	'r' bytes from stderr
//	'q' 4-byte big-endian exit status (128+n if killed by signal n), last
//	'f' why the process could not start, last
package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"sync"
	"syscall"

	"github.com/mdlayher/vsock"
)

const port = 1024

type request struct {
	Argv []string `json:"argv"`
	Cwd  string   `json:"cwd"`
	Env  []string `json:"env"`
}

func main() {
	l, err := vsock.Listen(port, nil)
	if err != nil {
		log.Fatalf("listen on vsock port %d: %v", port, err)
	}
	log.Printf("listening on vsock port %d", port)
	for {
		c, err := l.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go serve(c)
	}
}

// conn writes frames from several goroutines, one at a time.
type conn struct {
	net.Conn
	mu sync.Mutex
}

func (c *conn) send(typ byte, payload []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	head := make([]byte, 5)
	binary.BigEndian.PutUint32(head, uint32(len(payload)+1))
	head[4] = typ
	if _, err := c.Write(head); err != nil {
		return err
	}
	_, err := c.Write(payload)
	return err
}

func read(r io.Reader) (byte, []byte, error) {
	var n uint32
	if err := binary.Read(r, binary.BigEndian, &n); err != nil {
		return 0, nil, err
	}
	if n == 0 || n > 16<<20 {
		return 0, nil, errors.New("bad frame length")
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return 0, nil, err
	}
	return buf[0], buf[1:], nil
}

func serve(nc net.Conn) {
	c := &conn{Conn: nc}
	defer c.Close()

	typ, body, err := read(c)
	var req request
	if err == nil && (typ != 'x' || json.Unmarshal(body, &req) != nil || len(req.Argv) == 0) {
		err = errors.New("expected an exec request first")
	}
	if err != nil {
		c.send('f', []byte(err.Error()))
		return
	}

	cmd := exec.Command(req.Argv[0], req.Argv[1:]...)
	cmd.Dir = req.Cwd
	cmd.Env = append(os.Environ(), req.Env...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		c.send('f', []byte(err.Error()))
		return
	}
	kill := func(sig syscall.Signal) { syscall.Kill(-cmd.Process.Pid, sig) }

	// The host's side: stdin and signals. When it goes away, so does the process.
	go func() {
		defer stdin.Close()
		for {
			typ, body, err := read(c)
			if err != nil {
				kill(syscall.SIGKILL)
				return
			}
			switch {
			case typ == 'i':
				stdin.Write(body)
			case typ == 'e':
				stdin.Close()
			case typ == 'k' && len(body) == 1:
				kill(syscall.Signal(body[0]))
			}
		}
	}()

	var out sync.WaitGroup
	pump := func(typ byte, r io.Reader) {
		defer out.Done()
		buf := make([]byte, 64<<10)
		for {
			n, err := r.Read(buf)
			if n > 0 && c.send(typ, buf[:n]) != nil {
				return
			}
			if err != nil {
				return
			}
		}
	}
	out.Add(2)
	go pump('o', stdout)
	go pump('r', stderr)
	out.Wait()

	status := 0
	if err := cmd.Wait(); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			if ws, ok := exit.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
				status = 128 + int(ws.Signal())
			} else {
				status = exit.ExitCode()
			}
		} else {
			status = 255
		}
	}
	code := make([]byte, 4)
	binary.BigEndian.PutUint32(code, uint32(status))
	c.send('q', code)
}
