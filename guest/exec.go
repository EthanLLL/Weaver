package main

import (
	"encoding/binary"
	"errors"
	"io"
	"os"
	"os/exec"
	"os/user"
	"strconv"
	"sync"
	"syscall"

	"github.com/creack/pty"
)

// An 'x' request: {"argv": [...], "user": "...", "cwd": "...", "env": ["K=V"], "pty": {"rows": r, "cols": c}}.
// With "user" the process runs as that user, with their HOME, and in it
// unless "cwd" says otherwise; without, as root.
// With "pty" the process gets a terminal; its output, stdout and stderr
// alike, comes back as 'o', and 'z' resizes it. Closing the connection kills
// the process group.
type execRequest struct {
	Argv []string `json:"argv"`
	User string   `json:"user"`
	Cwd  string   `json:"cwd"`
	Env  []string `json:"env"`
	Pty  *struct {
		Rows uint16 `json:"rows"`
		Cols uint16 `json:"cols"`
	} `json:"pty"`
}

func execute(c *conn, body []byte) {
	var req execRequest
	if decode(body, &req) != nil || len(req.Argv) == 0 {
		c.fail("bad exec request")
		return
	}
	cmd := exec.Command(req.Argv[0], req.Argv[1:]...)
	cmd.Dir = req.Cwd
	cmd.Env = os.Environ()
	cmd.SysProcAttr = &syscall.SysProcAttr{}
	if req.User != "" {
		u, err := user.Lookup(req.User)
		if err != nil {
			c.fail(err.Error())
			return
		}
		uid, _ := strconv.Atoi(u.Uid)
		gid, _ := strconv.Atoi(u.Gid)
		cmd.SysProcAttr.Credential = &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid)}
		cmd.Env = append(cmd.Env, "HOME="+u.HomeDir, "USER="+u.Username, "LOGNAME="+u.Username)
		if cmd.Dir == "" {
			cmd.Dir = u.HomeDir
		}
	}
	cmd.Env = append(cmd.Env, req.Env...)

	var (
		stdin  io.WriteCloser
		resize func(rows, cols uint16)
		out    sync.WaitGroup
	)
	if req.Pty != nil {
		cmd.Env = append(cmd.Env, "TERM=xterm-256color")
		// pty.Start makes the process a session leader with the terminal as
		// its controlling one, so its group is its own.
		tty, err := pty.StartWithSize(cmd, &pty.Winsize{Rows: req.Pty.Rows, Cols: req.Pty.Cols})
		if err != nil {
			c.fail(err.Error())
			return
		}
		defer tty.Close()
		stdin = tty
		resize = func(rows, cols uint16) { pty.Setsize(tty, &pty.Winsize{Rows: rows, Cols: cols}) }
		out.Add(1)
		// Reading a terminal whose process has gone ends in EIO, not EOF.
		go func() { defer out.Done(); c.copyOut('o', tty) }()
	} else {
		cmd.SysProcAttr.Setpgid = true
		in, _ := cmd.StdinPipe()
		stdout, _ := cmd.StdoutPipe()
		stderr, _ := cmd.StderrPipe()
		if err := cmd.Start(); err != nil {
			c.fail(err.Error())
			return
		}
		stdin = in
		resize = func(uint16, uint16) {}
		out.Add(2)
		go func() { defer out.Done(); c.copyOut('o', stdout) }()
		go func() { defer out.Done(); c.copyOut('r', stderr) }()
	}
	kill := func(sig syscall.Signal) { syscall.Kill(-cmd.Process.Pid, sig) }

	// The host's side: input, signals, resizes. When it goes away, so does the process.
	go func() {
		for {
			typ, body, err := c.read()
			if err != nil {
				kill(syscall.SIGKILL)
				return
			}
			switch {
			case typ == 'i':
				stdin.Write(body)
			case typ == 'e' && req.Pty != nil:
				stdin.Write([]byte{4}) // ^D: a terminal has no end of its own
			case typ == 'e':
				stdin.Close()
			case typ == 'k' && len(body) == 1:
				kill(syscall.Signal(body[0]))
			case typ == 'z' && len(body) == 4:
				resize(binary.BigEndian.Uint16(body), binary.BigEndian.Uint16(body[2:]))
			}
		}
	}()

	// Output first: Wait closes the pipes. (A terminal's reader ends once
	// every process holding the terminal has gone.)
	out.Wait()
	err := cmd.Wait()
	status := 0
	var exit *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &exit):
		if ws, ok := exit.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			status = 128 + int(ws.Signal())
		} else {
			status = exit.ExitCode()
		}
	default:
		status = 255
	}
	c.done(status)
}
