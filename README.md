# VFIO DMA-BUF mmap locking lab

This repository reproduces the VFIO DMA-BUF mmap and nvgrace locking
experiments without nvgrace hardware. It is a superproject with editable,
pinned Linux and QEMU repositories. No source patches are applied during a
build: the checked-out submodule commits are exactly what gets compiled.

## One-command run

```sh
git clone https://github.com/opsound/vfio-dmabuf-lab.git
cd vfio-dmabuf-lab
./run
```

`./run` builds Linux, QEMU, static guest programs, and an initramfs, then runs
all three KVM tests. Build products and serial logs are written under `out/`.
The first build is large; subsequent builds are incremental.

The host needs a C compiler and static libc development files, GNU make,
binutils, flex, bison, bc, OpenSSL and ELF development files, Python, Meson,
Ninja, pkg-config, GLib and Pixman development files, `cpio`, gzip, and access
to `/dev/kvm`.

Useful narrower commands:

```sh
./run build
./run test nvgrace
./run test dmabuf
./run test legacy-export
make clean
```

## Repository shape

- `linux/` tracks `opsound/linux:vfio-dmabuf-mmap-v6-qemu-lab`. It contains
  the v6 series on top of upstream Linux v7.2, the locking changes,
  bounce-buffer nvgrace experiment, and explicit QEMU-only test hooks. The
  `opsound/linux` fork's parent is `torvalds/linux`.
- `qemu/` tracks `opsound/qemu:vfio-dmabuf-mmap-v6-qemu-lab`. It currently
  has no runtime source changes; its lab commit pins the GitHub mirror of
  QEMU's `keycodemapdb` build dependency so builds work on this network.
- `tests/` contains the static PID 1 guest orchestrator and the deterministic
  userfaultfd concurrency harness.
- `configs/` contains the exact lockdep-enabled x86 kernel configuration.
- `scripts/` owns host builds and QEMU launch/result checking.

To edit either source tree, commit and push in that nested repository, then
commit the updated submodule pointer in this repository. This is deliberately
the same workflow for Linux and QEMU.

## Tests

`nvgrace` binds QEMU EDU to the nvgrace VFIO driver in test mode. It first
proves that faulting user access under `memory_lock(R)` blocks a queued config
writer. It then verifies that the bounce-buffer read and write paths let the
writer finish while the userfault remains unresolved. Finally, it constructs
the reader/writer/mmap sequence and verifies that mmap-triggered DMA-BUF export
does not wait for `memory_lock`. Fixed cases run ten times each.

`dmabuf` binds `bochs-display` to vfio-pci and runs the v6 mmap, alias,
revocation, and cleanup test ten times.

`legacy-export` re-enables the old export-side `memory_lock(R)` acquisition.
Success means lockdep reports the circular dependency and mmap remains blocked
until the 15-second host timeout.

The setup exercises the real VFIO, rwsem, mmap, DMA-BUF, userfaultfd, and IOMMU
paths. It substitutes allocated RAM for Grace GPU memory and therefore does not
validate Grace hardware, CXL readiness, cache attributes, or performance.
