package main

import (
	"encoding/json"
	"io/fs"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
)

// An 'F' request: {"op": "...", "path": "/abs/path", "to": "/abs/path", "user": "..."}.
// Paths must be absolute. With "user", whatever the operation creates —
// files, directories made on the way — belongs to that user, so the tenant's
// own programs can use it; the guest itself runs as root.
//
//	read    the contents as 'o' frames, then 'q'
//	write   the host sends the contents as 'i' frames and 'e'; written to a
//	        temporary file and renamed into place, parents made; then 'q'
//	append  every 'i' frame is appended to the file, made if missing, and
//	        synced before the next is read; 'e' ends it with 'q'. For logs
//	        held open as long as their writer lives
//	list    one 'o': JSON [entry], then 'q'
//	stat    one 'o': JSON entry, then 'q'. Of the path itself: a symlink is
//	        "symlink", not what it points at
//	walk    one 'o': JSON [entry] for everything under the directory, "name"
//	        the path relative to it; symlinks are listed, never followed
//	rename  the path to "to", then 'q'
//	remove  the path and anything under it, then 'q'
//	mkdir   the directory and its parents, then 'q'
//
// An entry is {"name", "type": "file"|"dir"|"symlink"|"other", "size", "mtime"},
// mtime in Unix milliseconds. Anything that goes wrong is 'f'; a missing path
// says "enoent", an existing one where none may be "eexist".
type fileRequest struct {
	Op   string `json:"op"`
	Path string `json:"path"`
	To   string `json:"to"`
	User string `json:"user"`
}

type entry struct {
	Name  string `json:"name"`
	Type  string `json:"type"`
	Size  int64  `json:"size"`
	Mtime int64  `json:"mtime"`
}

func describe(name string, fi fs.FileInfo) entry {
	t := "other"
	switch {
	case fi.Mode().IsRegular():
		t = "file"
	case fi.IsDir():
		t = "dir"
	case fi.Mode()&fs.ModeSymlink != 0:
		t = "symlink"
	}
	return entry{name, t, fi.Size(), fi.ModTime().UnixMilli()}
}

// owner is who new files belong to: nobody in particular (root) by default.
type owner struct{ uid, gid int }

func (o *owner) chown(p string) {
	if o != nil {
		os.Lchown(p, o.uid, o.gid)
	}
}

// mkdirAll makes p and its missing parents, each owned by o.
func (o *owner) mkdirAll(p string) error {
	if fi, err := os.Stat(p); err == nil && fi.IsDir() {
		return nil
	}
	if err := o.mkdirAll(filepath.Dir(p)); err != nil {
		return err
	}
	if err := os.Mkdir(p, 0o755); err != nil && !os.IsExist(err) {
		return err
	}
	o.chown(p)
	return nil
}

func file(c *conn, body []byte) {
	var req fileRequest
	if decode(body, &req) != nil || !filepath.IsAbs(req.Path) || (req.To != "" && !filepath.IsAbs(req.To)) {
		c.fail("bad file request")
		return
	}
	var o *owner
	if req.User != "" {
		u, err := user.Lookup(req.User)
		if err != nil {
			c.fail(err.Error())
			return
		}
		uid, _ := strconv.Atoi(u.Uid)
		gid, _ := strconv.Atoi(u.Gid)
		o = &owner{uid, gid}
	}
	if err := fileOp(c, req, o); err != nil {
		switch {
		case os.IsNotExist(err):
			c.fail("enoent")
		case os.IsExist(err):
			c.fail("eexist")
		default:
			c.fail(err.Error())
		}
		return
	}
	c.done(0)
}

func fileOp(c *conn, req fileRequest, o *owner) error {
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
		return write(c, p, o)
	case "append":
		return appendTo(c, p, o)
	case "list":
		des, err := os.ReadDir(p)
		if err != nil {
			return err
		}
		list := make([]entry, 0, len(des))
		for _, de := range des {
			if fi, err := de.Info(); err == nil {
				list = append(list, describe(de.Name(), fi))
			}
		}
		return reply(c, list)
	case "stat":
		fi, err := os.Lstat(p)
		if err != nil {
			return err
		}
		return reply(c, describe(fi.Name(), fi))
	case "walk":
		list := []entry{}
		err := filepath.WalkDir(p, func(path string, de fs.DirEntry, err error) error {
			if err != nil {
				if path == p {
					return err
				}
				return nil
			}
			if path == p {
				return nil
			}
			if fi, err := de.Info(); err == nil {
				rel, _ := filepath.Rel(p, path)
				list = append(list, describe(rel, fi))
			}
			return nil
		})
		if err != nil {
			return err
		}
		return reply(c, list)
	case "rename":
		if req.To == "" {
			return os.ErrInvalid
		}
		if err := o.mkdirAll(filepath.Dir(req.To)); err != nil {
			return err
		}
		return os.Rename(p, filepath.Clean(req.To))
	case "remove":
		if _, err := os.Lstat(p); err != nil {
			return err
		}
		return os.RemoveAll(p)
	case "mkdir":
		return o.mkdirAll(p)
	}
	return os.ErrInvalid
}

func write(c *conn, p string, o *owner) error {
	if err := o.mkdirAll(filepath.Dir(p)); err != nil {
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
	o.chown(tmp.Name())
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), p)
}

func appendTo(c *conn, p string, o *owner) error {
	if err := o.mkdirAll(filepath.Dir(p)); err != nil {
		return err
	}
	_, statErr := os.Lstat(p)
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if os.IsNotExist(statErr) {
		o.chown(p)
	}
	for {
		typ, body, err := c.read()
		if err != nil {
			return err
		}
		switch typ {
		case 'e':
			return f.Sync()
		case 'i':
			if _, err := f.Write(body); err != nil {
				return err
			}
			if err := f.Sync(); err != nil {
				return err
			}
		}
	}
}

func reply(c *conn, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return c.send('o', b)
}
