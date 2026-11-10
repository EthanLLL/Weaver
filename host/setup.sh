#!/usr/bin/env bash
# Prepare a weaver host: Firecracker, a guest kernel and a base rootfs, under /opt/weaver.
set -euo pipefail
arch=$(uname -m)
sudo usermod -aG kvm ubuntu
sudo apt-get update -qq
command -v aws >/dev/null || {
  sudo apt-get install -qq -y unzip >/dev/null
  curl -fsSL -o /tmp/awscli.zip https://awscli.amazonaws.com/awscli-exe-linux-$arch.zip
  (cd /tmp && unzip -q -o awscli.zip && sudo ./aws/install >/dev/null && rm -rf aws awscli.zip)
}
sudo mkdir -p /opt/weaver && sudo chown ubuntu: /opt/weaver && cd /opt/weaver

tag=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/firecracker-microvm/firecracker/releases/latest | sed 's#.*/##')
curl -fsSL https://github.com/firecracker-microvm/firecracker/releases/download/$tag/firecracker-$tag-$arch.tgz | tar xz
sudo install release-$tag-$arch/firecracker-$tag-$arch /usr/local/bin/firecracker
rm -rf release-$tag-$arch

# Guest kernel and Ubuntu rootfs from Firecracker's CI artifacts (as in its getting-started guide).
s3=https://s3.amazonaws.com/spec.ccfc.min
ci=$(curl -fsSL "$s3?list-type=2&prefix=firecracker-ci/&delimiter=/" | grep -oP "(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)" | sort | tail -1)
key=$(curl -fsSL "$s3?list-type=2&prefix=${ci}$arch/vmlinux-" | grep -oP "(?<=<Key>)${ci}$arch/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3}(?=</Key>)" | sort -V | tail -1)
img=$(curl -fsSL "$s3?list-type=2&prefix=${ci}$arch/ubuntu-" | grep -oP "(?<=<Key>)${ci}$arch/ubuntu-[0-9]+\.[0-9]+\.squashfs(?=</Key>)" | sort -V | tail -1)
curl -fsSL -o vmlinux "$s3/$key"
curl -fsSL -o ubuntu.squashfs "$s3/$img"
# Erlang from Ubuntu, Elixir's precompiled build for that OTP.
command -v elixir >/dev/null || {
  sudo apt-get install -qq -y erlang-nox erlang-dev erlang-src >/dev/null
  otp=$(erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().')
  curl -fsSL -o /tmp/elixir.zip https://github.com/elixir-lang/elixir/releases/latest/download/elixir-otp-$otp.zip
  sudo rm -rf /opt/elixir && sudo unzip -q -d /opt/elixir /tmp/elixir.zip && rm /tmp/elixir.zip
  for b in elixir elixirc iex mix; do sudo ln -sf /opt/elixir/bin/$b /usr/local/bin/$b; done
}

echo "elixir $(elixir --short-version), firecracker $tag, kernel $(basename $key), rootfs $(basename $img)"
