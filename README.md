# UML kernel for TIKE

Builds a User Mode Linux kernel with FUSE and rootless networking for TIKE, where EKS pods do not expose the host's `/dev/fuse` device.

The default build follows the Linux 6.18 LTS series, supported through December 2028. Linux 6.12 remains available as a fallback from the manual workflow form.

## Install on TIKE

One-liner (requires the `gh` CLI, already available on TIKE):

```bash
gh release download --repo lars-hagen/uml-kernel-build \
  --pattern "linux-*-$(uname -m)-amazonlinux-2023" \
  --output ~/linux-fuse.um \
  --clobber \
  --skip-existing 2>/dev/null || \
gh release download --repo lars-hagen/uml-kernel-build --latest \
  --pattern "linux-*-$(uname -m)-amazonlinux-2023" \
  --output ~/linux-fuse.um --clobber
chmod +x ~/linux-fuse.um
```

Each release also includes a pre-filled one-liner in its `release-notes.md` for environments without the `gh` CLI.

Verify the download against the release checksum:

```bash
sha256sum ~/linux-fuse.um
```

Start UML using hostfs, for example:

```bash
~/linux-fuse.um rootfstype=hostfs rw init=/bin/bash
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

Install VDE SLiRP support in the persistent TIKE environment from the
[`Build VDE SLiRP networking toolchain`](.github/workflows/build-vde-net.yml)
workflow's prebuilt release (no packaged builds exist upstream, and building
`vdeplug4`, `libslirp`, `libvdeslirp`, and `vdeplug_slirp` from source takes a
five-stage autotools/cmake/meson toolchain):

```bash
mkdir -p ~/vde-net
gh release download vde-net-x86_64-amazonlinux-2023 \
  --repo lars-hagen/uml-kernel-build \
  --pattern "vde-slirp-net-x86_64-amazonlinux-2023.tar.gz" \
  --output ~/vde-net.tar.gz --clobber
tar -xzf ~/vde-net.tar.gz -C ~/vde-net --strip-components=1

export PATH="$HOME/vde-net/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/vde-net/lib:$LD_LIBRARY_PATH"
```

VDE's `slirp://` VNL provides the same rootless outbound networking previously
supplied by `CONFIG_UML_NET_SLIRP`, now suitable for HTTPS calls to the
Databricks API. The UML guest must also configure its interface, default
route, DNS, and CA certificates. Pass the installed VDE SLiRP helper to UML
with an `eth0=vde,vnl=slirp://` boot argument appropriate for the environment:

```bash
~/linux-fuse.um mem=2G rootfstype=hostfs rootflags=/ rw init=/bin/bash eth0=vde,vnl=slirp://
```

Then, inside the guest, bring up `eth0` with the standard SLiRP defaults
(gateway/DNS at 10.0.2.2/10.0.2.3):

```bash
ip link set lo up
ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2 dev eth0
echo "nameserver 10.0.2.3" > /etc/resolv.conf
```

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
