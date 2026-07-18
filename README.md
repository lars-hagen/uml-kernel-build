# UML kernel for TIKE

Builds a User Mode Linux kernel with FUSE and rootless networking for TIKE, where EKS pods do not expose the host's `/dev/fuse` device.

The default build follows the Linux 6.18 LTS series, supported through December 2028. Linux 6.12 remains available as a fallback from the manual workflow form.

## Install on TIKE

One-liner, needs only `curl`, `python3`, and `tar` (no `gh` CLI required):

```bash
curl -fsSL https://raw.githubusercontent.com/lars-hagen/uml-kernel-build/master/install.sh | bash
```

This downloads the latest kernel release, the [VDE SLiRP networking
toolchain](#networking), and writes `~/uml-init.sh`, a wrapper that keeps PID 1
alive so the guest doesn't panic when a shell inside it exits (see
[Networking](#networking)).

If you have the `gh` CLI and only want the kernel binary itself:

```bash
gh release download --repo lars-hagen/uml-kernel-build --latest \
  --pattern "linux-*-$(uname -m)-amazonlinux-2023" \
  --output ~/linux-fuse.um --clobber
chmod +x ~/linux-fuse.um
```

Verify the download against the release checksum:

```bash
sha256sum ~/linux-fuse.um
```

Start UML using hostfs, for example:

```bash
~/linux-fuse.um rootfstype=hostfs rw init=~/uml-init.sh
```

The root filesystem and exact boot arguments depend on the userspace being run. A FUSE mount created inside UML is visible only to programs running inside UML. It does not appear in the surrounding TIKE pod.

## Networking

The kernel enables:

```text
CONFIG_UML_NET_VECTOR=y
```

`CONFIG_UML_NET` and `CONFIG_UML_NET_SLIRP` no longer exist upstream: the legacy
UML network transports (ethertap, tuntap, slip, daemon, mcast, slirp) were
removed from the kernel in May 2025 (`e619e18ed462`, "um: Remove legacy network
transport infrastructure") in favor of the vector driver.

`install.sh` (see [Install on TIKE](#install-on-tike)) already downloads the
prebuilt toolchain from the
[`Build VDE SLiRP networking toolchain`](.github/workflows/build-vde-net.yml)
workflow into `~/vde-net`. No packaged builds exist upstream; building
`vdeplug4`, `libslirp`, `libvdeslirp`, and `vdeplug_slirp` from source takes a
five-stage autotools/cmake/meson toolchain, that only needs to happen once, in
CI. To fetch it manually instead:

```bash
mkdir -p ~/vde-net
curl -fL -o ~/vde-net.tar.gz \
  https://github.com/lars-hagen/uml-kernel-build/releases/download/vde-net-x86_64-amazonlinux-2023/vde-slirp-net-x86_64-amazonlinux-2023.tar.gz
tar -xzf ~/vde-net.tar.gz -C ~/vde-net --strip-components=1

export PATH="$HOME/vde-net/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/vde-net/lib:$LD_LIBRARY_PATH"
```

VDE's `slirp://` VNL provides the same rootless outbound networking previously
supplied by `CONFIG_UML_NET_SLIRP`, now suitable for HTTPS calls to the
Databricks API. Pass the installed VDE SLiRP helper to UML on the vector
driver's own command line, **not** the removed legacy `eth0=` syntax (the
kernel silently ignores it as an unrecognized parameter):

```bash
~/linux-fuse.um mem=2G rootfstype=hostfs rootflags=/ rw init=~/uml-init.sh 'vec0:transport=vde,vnl=slirp://'
```

The interface comes up named `vec0`, not `eth0`. `ip` may not be installed in
a minimal guest, use `ifconfig`/`route` (net-tools) instead, with the standard
SLiRP gateway/DNS at 10.0.2.2/10.0.2.3:

```bash
ifconfig lo up
ifconfig vec0 10.0.2.15 netmask 255.255.255.0 up
route add default gw 10.0.2.2 vec0
```

hostfs enforces the real host user's file permissions even for guest-root, so
writing `/etc/resolv.conf` directly usually fails with `Permission denied` if
it's not owned by that user. Bind-mount a writable copy over it instead:

```bash
mkdir -p /tmp
printf 'nameserver 10.0.2.3\n' > /tmp/resolv.conf
mount --bind /tmp/resolv.conf /etc/resolv.conf
```

### Avoiding the "Attempted to kill init!" panic

PID 1 exiting always panics a Linux kernel, this is standard behavior, not a
bug in this build. Typing `exit` at an `init=/bin/bash` shell will panic UML.
`install.sh` writes `~/uml-init.sh`, which respawns a fresh shell in a loop
instead of letting PID 1 exit, use it as the `init=` target instead of
`/bin/bash` directly.

## Custom builds

1. Open **Actions**, select **Build UML kernel**, and choose **Run workflow**.
2. Select the kernel series and customize the other inputs if needed.

Inputs:

- `kernel_series`: Linux 6.18 by default, or Linux 6.12 as a fallback.
- `kernel_version`: `latest-lts` or an exact point release from the selected series.
- `base_image`: controls the target glibc. The default `amazonlinux:2023` uses glibc 2.34 and avoids the glibc 2.43 or newer UML regression affecting Linux 6.18.17 and later. Apt, dnf, and yum based images are auto-detected.
- `extra_configs`: space-separated Kconfig overrides, such as `CONFIG_LTO_CLANG_THIN=y`.
- `release_tag`: optional unique tag for custom rebuilds of an otherwise identical version.

Required configurations are applied and verified after `olddefconfig` but before compilation:

```text
CONFIG_FUSE_FS=y
CONFIG_HOSTFS=y
CONFIG_CUSE=y
CONFIG_UML_NET_VECTOR=y
```

The kernel is compiled with `KCFLAGS=-O3`. Neither Linux 6.12 nor Linux 6.18 provides `CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3`.

## Automatic updates

The weekly workflow runs at `17 9 * * 1`, reads kernel.org's release JSON, and checks for a newer Linux 6.18 point release. It triggers the default Amazon Linux 2023 build only when the corresponding release asset does not already exist.

## Architecture support

Upstream `ARCH=um` supports x86_64 hosts only. AArch64 UML is not implemented. The workflow rejects non-x86_64 build hosts with a clear error rather than publishing a mislabeled binary.

## Release files

Each release contains:

- `linux-VERSION-x86_64-BASE_IMAGE_SLUG`
- `linux.sha256`
- `.config`
- `release-notes.md`

Release notes record the exact kernel version, source tarball SHA-256, target build image, verified configuration, and TIKE install command.

The separate [`vde-net-x86_64-amazonlinux-2023`](.github/workflows/build-vde-net.yml) release contains:

- `vde-slirp-net-x86_64-amazonlinux-2023.tar.gz`
- `vde-slirp-net.sha256`
- `release-notes.md`
