# Weaver

> The Loom had done its work and travelled on.

Many Looms, one control plane. Each tenant gets a Firecracker microVM — their
own computer, holding their sessions, files, apps and jobs, running
[Loom](https://github.com/EthanLLL/loom) inside. Weaver is the Elixir control plane that
starts, stops, snapshots and routes to those VMs across a fleet of hosts.

Status: experiment.
