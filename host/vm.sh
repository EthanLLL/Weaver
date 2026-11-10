#!/usr/bin/env bash
# vm.sh <name> <n> — boot tenant VM <name>, whose disk is /opt/weaver/vms/<name>/rootfs.ext4, as systemd unit weaver-vm@<name>.
# <n> (1..250) picks its network: tap fc<n>, host 172.16.<n>.1, guest 172.16.<n>.2, outbound NAT.
# Control channel: weaver-guest on vsock port 1024, host side /opt/weaver/vms/<name>/vsock.sock.
set -euo pipefail
name=$1 n=$2 dir=/opt/weaver/vms/$1
if systemctl is-active -q weaver-vm@$name; then echo "$name is running" >&2; exit 1; fi
mkdir -p $dir && cd $dir && echo $n > net

# The disk is made once, at sign-up, as a copy of image.sh's image (`Weaver.Host.create/1`).
[ -f rootfs.ext4 ] || { echo "$name has no disk" >&2; exit 1; }

# What the platform puts in the VM is the platform's, not the tenant's: every
# boot puts in the host's current one. The guest daemon; ripgrep for
# Weaver.Search; the browser, its unit only, installed on its first start.
mkdir -p mnt && sudo mount -o loop rootfs.ext4 mnt
sudo install -m 755 /opt/weaver/weaver-guest mnt/usr/local/bin/weaver-guest
sudo ln -sf weaver-guest mnt/usr/local/bin/weaver
sudo install -d mnt/usr/local/lib/weaver
sudo install -m 755 /opt/weaver/rg /opt/weaver/app/host/vm/weaver-browser \
  /opt/weaver/app/host/vm/weaver-browser-install mnt/usr/local/lib/weaver/
sudo install -m 644 /opt/weaver/app/host/vm/weaver-browser.service mnt/etc/systemd/system/
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
# The VM has no DHCP, so nothing tells systemd-resolved where DNS is, and an
# apt install can bring resolved in (Chrome's did) and point resolv.conf at
# its stub: give it the same servers the static resolv.conf names.
sudo install -d mnt/etc/systemd/resolved.conf.d
printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\n' | sudo tee mnt/etc/systemd/resolved.conf.d/weaver.conf >/dev/null
echo $name | sudo tee mnt/etc/hostname >/dev/null
grep -q " $name\$" mnt/etc/hosts || echo "127.0.1.1 $name" | sudo tee -a mnt/etc/hosts >/dev/null
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

# The tap carries one thing: the guest's traffic to the internet. Everything
# between host and guest goes over vsock. So a guest reaches nothing on the
# host itself (epmd and Erlang distribution listen there), no private address
# (the NAT would make it look like the host to the other host's security
# group), no other guest, and not the instance metadata, which would give it
# the host's role. Inserted ahead of the ACCEPT above.
drop() { sudo iptables -C "$@" -j DROP 2>/dev/null || sudo iptables -I "$@" -j DROP; }
drop INPUT -i fc+
for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
  drop FORWARD -i fc+ -d $net
done

mac=$(printf '06:00:AC:10:%02X:02' $n)
cat > config.json <<J
{
  "boot-source": {
    "kernel_image_path": "/opt/weaver/vmlinux",
    "boot_args": "console=ttyS0 reboot=k panic=1 ip=172.16.$n.2::172.16.$n.1:255.255.255.252::eth0:off"
  },
  "drives": [{"drive_id": "rootfs", "path_on_host": "$dir/rootfs.ext4", "is_root_device": true, "is_read_only": false}],
  "network-interfaces": [{"iface_id": "eth0", "guest_mac": "$mac", "host_dev_name": "$tap"}],
  "machine-config": {"vcpu_count": 2, "mem_size_mib": 2048},
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
