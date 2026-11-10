# Weaver

> The Loom had done its work and travelled on.

Many Looms, one control plane. Each tenant gets a Firecracker microVM — their
own computer, holding their sessions, files, apps and jobs, running
[Loom](https://github.com/EthanLLL/loom) inside. Weaver is the Elixir control plane that
starts, stops, snapshots and routes to those VMs across a fleet of hosts.

Status: experiment.

## Layout

    control plane  ── Erlang distribution ──  host node (weaver.service, one per host)
                                                 │ vsock (Unix socket per VM)
                                              tenant VM ── weaver-guest (Go) ── processes

- `lib/` — the Elixir node every host runs. `Weaver` is the cluster-wide API
  (`tenants/0`, `start/1`, `stop/1`, `run/2`); `Weaver.Exec` is a process in a
  VM held like a port, from any node; `Weaver.Host` is this host's VMs.
- `guest/` — `weaver-guest`, the daemon inside each VM: one vsock connection
  per process, framed stdio. Wire format in `guest/main.go`.
- `host/` — `setup.sh` prepares a host (Firecracker, kernel, rootfs, Erlang,
  Elixir); `vm.sh` makes and boots a tenant VM.
- `bin/` — run from the Loom machine: `w` (shell on a host via SSM), `put`
  (copy a file over), `deploy` (ship `lib/` and restart the nodes), `ctl`
  (evaluate Elixir on a host's node).

A VM never joins the Erlang cluster: distribution trusts every node fully, and
a guest runs untrusted code. It speaks only the guest protocol.
