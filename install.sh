#!/usr/bin/env bash
# Bootstraps a fresh TIKE (or any AL2023-glibc-compatible) host with:
#   - the latest UML kernel release (~/linux-fuse.um)
#   - the VDE SLiRP networking toolchain (~/vde-net)
#   - ~/uml-init.sh, a PID-1-safe init wrapper
#
# Usage: curl -fsSL https://raw.githubusercontent.com/lars-hagen/uml-kernel-build/master/install.sh | bash
set -euo pipefail

REPO="lars-hagen/uml-kernel-build"
DEST="${UML_INSTALL_DIR:-$HOME}"

if [[ "$(uname -m)" != "x86_64" ]]; then
  echo "error: this toolchain only targets x86_64 hosts (detected $(uname -m))." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required (used to parse the GitHub releases API)." >&2
  exit 1
fi

echo "==> Installing into $DEST"
mkdir -p "$DEST"

echo "==> Resolving latest kernel release asset"
KERNEL_URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases" | python3 -c '
import json, sys
releases = json.load(sys.stdin)
for rel in releases:
    for asset in rel.get("assets", []):
        name = asset["name"]
        if name.startswith("linux-") and name.endswith("-x86_64-amazonlinux-2023"):
            print(asset["browser_download_url"])
            sys.exit(0)
')"
if [[ -z "$KERNEL_URL" ]]; then
  echo "error: no kernel release asset found (linux-*-x86_64-amazonlinux-2023)." >&2
  exit 1
fi
echo "==> Downloading kernel: $KERNEL_URL"
curl -fL "$KERNEL_URL" -o "$DEST/linux-fuse.um"
chmod +x "$DEST/linux-fuse.um"

echo "==> Downloading VDE SLiRP networking toolchain"
rm -rf "$DEST/vde-net" "$DEST/vde-net.tar.gz"
mkdir -p "$DEST/vde-net"
curl -fL "https://github.com/$REPO/releases/download/vde-net-x86_64-amazonlinux-2023/vde-slirp-net-x86_64-amazonlinux-2023.tar.gz" \
  -o "$DEST/vde-net.tar.gz"
tar -xzf "$DEST/vde-net.tar.gz" -C "$DEST/vde-net" --strip-components=1
rm -f "$DEST/vde-net.tar.gz"

echo "==> Writing $DEST/uml-init.sh"
cat > "$DEST/uml-init.sh" <<EOF
#!/bin/bash
# PID 1 must never exit or the kernel panics ("Attempted to kill init!").
# Respawn a fresh shell instead of letting one exit take the guest down.
export HOME="$HOME"
export USER="${USER:-$(id -un)}"
export PATH="$DEST/vde-net/bin:\$PATH"
export LD_LIBRARY_PATH="$DEST/vde-net/lib:\$LD_LIBRARY_PATH"
cd "\$HOME" 2>/dev/null || cd /
while true; do
  bash --noprofile --norc
done
EOF
chmod +x "$DEST/uml-init.sh"

cat <<EOF

==> Done.

Boot with:

  $DEST/linux-fuse.um mem=2G rootfstype=hostfs rootflags=/ rw init=$DEST/uml-init.sh 'vec0:transport=vde,vnl=slirp://'

Then inside the guest:

  mount -t proc proc /proc
  mount -t devtmpfs devtmpfs /dev
  mknod /dev/fuse c 10 229 && chmod 666 /dev/fuse

  ifconfig lo up
  ifconfig vec0 10.0.2.15 netmask 255.255.255.0 up
  route add default gw 10.0.2.2 vec0
  mkdir -p /tmp && printf 'nameserver 10.0.2.3\n' > /tmp/resolv.conf
  mount --bind /tmp/resolv.conf /etc/resolv.conf
EOF
