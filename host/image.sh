#!/usr/bin/env bash
# image.sh — build /opt/weaver/image.ext4, the disk every new tenant VM starts as a copy of
# (`Weaver.Host.create/1`). Ubuntu from setup.sh's squashfs, plus what a tenant needs
# before their first login: the `tenant` user, apt that works here, Claude Code and Codex.
# No credentials: each tenant configures their own, in their VM.
# What the platform owns in a VM (the guest daemon, rg, the browser unit) is not in here;
# vm.sh puts the current one in at every boot.
set -euo pipefail
cd /opt/weaver
size=4G codex=0.162.1
work=$(mktemp -d /opt/weaver/image.XXXX)
trap 'for m in dev/pts dev proc sys; do sudo umount -q $work/root/$m 2>/dev/null || true; done; sudo rm -rf $work' EXIT
command -v unsquashfs >/dev/null || sudo apt-get install -qq -y squashfs-tools >/dev/null
sudo unsquashfs -q -no-progress -d $work/root ubuntu.squashfs
r=$work/root
# The squashfs's /tmp is not world-writable; in a VM a tmpfs covers it, in the chroot nothing does.
sudo install -d -m 1777 $r/tmp

# No IPv6 in the VM; apt would try it first and stall. The region's EC2
# mirror is the fast one, but some of its nodes answer only 503, so
# Canonical's own archive follows it: apt moves to the next URI of a source
# when one fails. (Canonical's Singapore mirror, tried before, crawls.)
echo 'Acquire::ForceIPv4 "true";' | sudo tee $r/etc/apt/apt.conf.d/99ipv4 >/dev/null
sudo sed -i -E 's#^URIs: .*#URIs: http://ap-southeast-1.ec2.archive.ubuntu.com/ubuntu http://archive.ubuntu.com/ubuntu#' $r/etc/apt/sources.list.d/ubuntu.sources
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' | sudo tee $r/etc/resolv.conf >/dev/null

for m in dev dev/pts proc sys; do sudo mount --bind /$m $r/$m; done
sudo chroot $r /bin/bash -euo pipefail <<EOF
export DEBIAN_FRONTEND=noninteractive HOME=/root
mkdir -p /var/cache/apt/archives/partial /var/lib/apt/lists/partial /var/log/apt
apt-get update -qq
apt-get install -qq -y --no-install-recommends sudo curl ca-certificates vim git less >/dev/null
apt-get clean && rm -rf /var/lib/apt/lists/*
id tenant >/dev/null 2>&1 || useradd -m -s /bin/bash tenant
echo 'tenant ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/tenant && chmod 440 /etc/sudoers.d/tenant
su - tenant -c 'curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1; ~/.local/bin/claude --version'
su - tenant -c 'set -e; cd /tmp; curl -fsSL -o codex.tgz https://github.com/openai/codex/releases/download/rust-v$codex/codex-x86_64-unknown-linux-musl.tar.gz
  tar xzf codex.tgz; install -m 755 codex-x86_64-unknown-linux-musl ~/.local/bin/codex; rm -f codex.tgz codex-x86_64-unknown-linux-musl; ~/.local/bin/codex --version'
EOF
for m in dev/pts dev proc sys; do sudo umount $r/$m; done

truncate -s $size $work/image.ext4 && sudo mkfs.ext4 -q -d $r -F $work/image.ext4
sudo chown ubuntu: $work/image.ext4 && mv $work/image.ext4 image.ext4
echo "image.ext4: $(du -h image.ext4 | cut -f1) used of $size"
