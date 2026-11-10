package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// An 'F' request: {"op": "...", "path": "/abs/path"}. Paths must be absolute.
//
//	read    the contents as 'o' frames, then 'q'
//	write   the host sends the contents as 'i' frames and 'e'; written to a
//	        temporary file and renamed into place, parents made; then 'q'
//	list    one 'o': JSON [{"name", "dir", "size", "mtime"}], then 'q'
//	stat    one 'o': JSON {"name", "dir", "size", "mtime"}, then 'q'
//	remove  the path and anything under it, then 'q'
//	mkdir   the directory and its parents, then 'q'
//
// Anything that goes wrong is 'f'; a missing path says "enoent".
type fileRequest struct {
	Op   string `json:"op"`
	Path string `json:"path"`
}

type entry struct {
	Name  string `json:"name"`
	Dir   bool   `json:"dir"`
	Size  int64  `json:"size"`
	Mtime int64  `json:"mtime"` // Unix milliseconds
}

func describe(fi os.FileInfo) entry {
	return entry{fi.Name(), fi.IsDir(), fi.Size(), fi.ModTime().UnixMilli()}
}

func file(c *conn, body []byte) {
	var req fileRequest
	if decode(body, &req) != nil || !filepath.IsAbs(req.Path) {
		c.fail("bad file request")
		return
	}
	if err := fileOp(c, req); err != nil {
		if os.IsNotExist(err) {
			c.fail("enoent")
		} else {
			c.fail(err.Error())
		}
		return
	}
	c.done(0)
}

func fileOp(c *conn, req fileRequest) error {
	p := filepath.Clean(req.Path)
	switch req.Op {
	case "read":
		f, err := os.Open(p)
		if err != nil {
			return err
		}
		defer f.Close()
		return c.copyOut('o', f)
	case "write":
		return write(c, p)
	case "list":
		des, err := os.ReadDir(p)
		if err != nil {
			return err
		}
		list := make([]entry, 0, len(des))
		for _, de := range des {
			if fi, err := de.Info(); err == nil {
				list = append(list, describe(fi))
			}
		}
		return reply(c, list)
	case "stat":
		fi, err := os.Stat(p)
		if err != nil {
			return err
		}
		return reply(c, describe(fi))
	case "remove":
		if _, err := os.Lstat(p); err != nil {
			return err
		}
		return os.RemoveAll(p)
	case "mkdir":
		return os.MkdirAll(p, 0o755)
	}
	return os.ErrInvalid
}

func write(c *conn, p string) error {
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(p), "."+filepath.Base(p)+".*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	for {
		typ, body, err := c.read()
		if err != nil {
			tmp.Close()
			return err
		}
		if typ == 'e' {
			break
		}
		if typ == 'i' {
			if _, err := tmp.Write(body); err != nil {
				tmp.Close()
				return err
			}
		}
	}
	if err := tmp.Chmod(0o644); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), p)
}

func reply(c *conn, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return c.send('o', b)
}
