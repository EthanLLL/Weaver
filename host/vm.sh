#!/usr/bin/env bash
# vm.sh <name> <n> — create and start tenant VM <name> as systemd unit weaver-vm@<name>.
# <n> (1..250) picks its network: tap fc<n>, host 172.16.<n>.1, guest 172.16.<n>.2, outbound NAT.
# Control channel: weaver-guest on vsock port 1024, host side /opt/weaver/vms/<name>/vsock.sock.
set -euo pipefail
name=$1 n=$2 dir=/opt/weaver/vms/$1
if systemctl is-active -q weaver-vm@$name; then echo "$name is running" >&2; exit 1; fi
mkdir -p $dir && cd $dir && echo $n > net

if [ ! -f rootfs.ext4 ]; then
  command -v unsquashfs >/dev/null || sudo apt-get install -qq -y squashfs-tools >/dev/null
  rm -rf root && sudo unsquashfs -q -d root /opt/weaver/ubuntu.squashfs
  echo $name | sudo tee root/etc/hostname >/dev/null
  printf 'nameserver 1.1.1.1\n' | sudo tee root/etc/resolv.conf >/dev/null
  truncate -s 4G rootfs.ext4 && sudo mkfs.ext4 -q -d root -F rootfs.ext4 && sudo rm -rf root
  sudo chown ubuntu: rootfs.ext4
fi

# The guest daemon is the platform's, not the tenant's: every boot puts in
# the host's current one.
mkdir -p mnt && sudo mount -o loop rootfs.ext4 mnt
sudo install -m 755 /opt/weaver/weaver-guest mnt/usr/local/bin/weaver-guest
sudo ln -sf weaver-guest mnt/usr/local/bin/weaver
sudo tee mnt/etc/systemd/system/weaver-guest.service >/dev/null <<U
[Unit]
Description=Weaver guest daemon (vsock port 1024)
[Service]
ExecStart=/usr/local/bin/weaver-guest
Restart=always
[Install]
WantedBy=multi-user.target
U
sudo ln -sf /etc/systemd/system/weaver-guest.service mnt/etc/systemd/system/multi-user.target.wants/weaver-guest.service
sudo umount mnt && rmdir mnt

tap=fc$n
ip link show $tap >/dev/null 2>&1 || {
  sudo ip tuntap add $tap mode tap user ubuntu
  sudo ip addr add 172.16.$n.1/30 dev $tap
  sudo ip link set $tap up
}
sudo sysctl -qw net.ipv4.ip_forward=1
out=$(ip route show default | awk '{print $5; exit}')
sudo iptables -t nat -C POSTROUTING -s 172.16.$n.0/30 -o $out -j MASQUERADE 2>/dev/null ||
  sudo iptables -t nat -A POSTROUTING -s 172.16.$n.0/30 -o $out -j MASQUERADE
sudo iptables -C FORWARD -i $tap -o $out -j ACCEPT 2>/dev/null || sudo iptables -A FORWARD -i $tap -o $out -j ACCEPT
sudo iptables -C FORWARD -i $out -o $tap -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
  sudo iptables -A FORWARD -i $out -o $tap -m state --state RELATED,ESTABLISHED -j ACCEPT

# A guest must never reach the host's instance metadata, and with it the
# host's role. (The instance's hop limit of 1 already stops IMDSv2 tokens
# that crossed the NAT; this drops the packets outright.)
sudo iptables -C FORWARD -i fc+ -d 169.254.169.254 -j DROP 2>/dev/null ||
  sudo iptables -I FORWARD -i fc+ -d 169.254.169.254 -j DROP

mac=$(printf '06:00:AC:10:%02X:02' $n)
cat > config.json <<J
{
  "boot-source": {
    "kernel_image_path": "/opt/weaver/vmlinux",
    "boot_args": "console=ttyS0 reboot=k panic=1 ip=172.16.$n.2::172.16.$n.1:255.255.255.252::eth0:off"
  },
  "drives": [{"drive_id": "rootfs", "path_on_host": "$dir/rootfs.ext4", "is_root_device": true, "is_read_only": false}],
  "network-interfaces": [{"iface_id": "eth0", "guest_mac": "$mac", "host_dev_name": "$tap"}],
  "machine-config": {"vcpu_count": 2, "mem_size_mib": 1024},
  "vsock": {"guest_cid": 3, "uds_path": "$dir/vsock.sock"}
}
J
# A tenant VM is never restarted behind its back: needrestart, after an apt
# upgrade, would restart the unit and with it the guest.
[ -f /etc/needrestart/conf.d/weaver.conf ] ||
  echo '$nrconf{override_rc}{qr(^weaver-vm@)} = 0;' | sudo tee /etc/needrestart/conf.d/weaver.conf >/dev/null
sudo systemctl reset-failed weaver-vm@$name 2>/dev/null || true
sudo systemd-run --unit weaver-vm@$name --uid ubuntu --gid kvm --working-directory $dir \
  -p StandardOutput=append:$dir/console.log -p StandardError=append:$dir/console.log \
  sh -c "rm -f vsock.sock api.sock; exec firecracker --api-sock api.sock --config-file config.json"
