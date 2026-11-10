package main

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"sync"
)

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

func (c *conn) read() (byte, []byte, error) {
	var n uint32
	if err := binary.Read(c, binary.BigEndian, &n); err != nil {
		return 0, nil, err
	}
	if n == 0 || n > 16<<20 {
		return 0, nil, errors.New("bad frame length")
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(c, buf); err != nil {
		return 0, nil, err
	}
	return buf[0], buf[1:], nil
}

func (c *conn) done(status int) {
	code := make([]byte, 4)
	binary.BigEndian.PutUint32(code, uint32(status))
	c.send('q', code)
}

func (c *conn) fail(why string) { c.send('f', []byte(why)) }

// copyOut sends everything read from r as frames of type typ.
func (c *conn) copyOut(typ byte, r io.Reader) error {
	buf := make([]byte, 64<<10)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			if err := c.send(typ, buf[:n]); err != nil {
				return err
			}
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
	}
}
