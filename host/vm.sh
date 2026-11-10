#!/usr/bin/env bash
# vm.sh <name> <n> — create and start tenant VM <name> as systemd unit weaver-vm@<name>.
# <n> (1..250) picks its network: tap fc<n>, host 172.16.<n>.1, guest 172.16.<n>.2, outbound NAT.
# Control channel: vsock, host side /opt/weaver/vms/<name>/vsock.sock.
set -euo pipefail
name=$1 n=$2 dir=/opt/weaver/vms/$1
mkdir -p $dir && cd $dir

if [ ! -f rootfs.ext4 ]; then
  command -v unsquashfs >/dev/null || sudo apt-get install -qq -y squashfs-tools >/dev/null
  rm -rf root && sudo unsquashfs -q -d root /opt/weaver/ubuntu.squashfs
  echo $name | sudo tee root/etc/hostname >/dev/null
  printf 'nameserver 1.1.1.1\n' | sudo tee root/etc/resolv.conf >/dev/null
  truncate -s 4G rootfs.ext4 && sudo mkfs.ext4 -q -d root -F rootfs.ext4 && sudo rm -rf root
  sudo chown ubuntu: rootfs.ext4
fi

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
rm -f vsock.sock api.sock
sudo systemd-run --unit weaver-vm@$name --uid ubuntu --gid kvm --working-directory $dir \
  -p StandardOutput=file:$dir/console.log -p StandardError=file:$dir/console.log \
  firecracker --api-sock $dir/api.sock --config-file $dir/config.json
