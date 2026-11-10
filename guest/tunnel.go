package main

import (
	"errors"
	"fmt"
	"net"
	"syscall"
	"time"
)

// A 't' request, {"port": n}: a TCP connection to 127.0.0.1:n in the VM,
// carried over this one, so the host can reach a service that listens on
// loopback only (the browser's VNC) without the VM's network. The host
// connects to the VM, never the other way round, and only to loopback.
//
// After the request: 'i' frames are written to the TCP connection, 'e'
// closes its writing half; what it sends comes back as 'o' frames, then 'q'
// when it closes. 'f' if it could not connect: "econnrefused" when nothing
// listens on the port.
type tunnelRequest struct {
	Port int `json:"port"`
}

func tunnel(c *conn, body []byte) {
	var req tunnelRequest
	if err := decode(body, &req); err != nil || req.Port < 1 || req.Port > 65535 {
		c.fail("bad tunnel request")
		return
	}
	tc, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", req.Port), 3*time.Second)
	if err != nil {
		if errors.Is(err, syscall.ECONNREFUSED) {
			c.fail("econnrefused")
		} else {
			c.fail(err.Error())
		}
		return
	}
	tcp := tc.(*net.TCPConn)
	defer tcp.Close()

	// The host going away closes the TCP connection, which ends copyOut.
	go func() {
		defer tcp.Close()
		for {
			typ, data, err := c.read()
			if err != nil {
				return
			}
			switch typ {
			case 'i':
				if _, err := tcp.Write(data); err != nil {
					return
				}
			case 'e':
				tcp.CloseWrite()
			}
		}
	}()
	if c.copyOut('o', tcp) == nil {
		c.done(0)
	}
}
