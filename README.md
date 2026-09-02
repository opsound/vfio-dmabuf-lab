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
all three KVM tests. It builds two exact Linux revisions: Matt's v5 as the
deadlock control and the proposed core-only v6 locking fix. The v6 kernel keeps
nvgrace's direct user access under `memory_lock`; it does not add a bounce
buffer. Build products and serial logs are written under `out/`. The first
build is large; subsequent builds are incremental.

The host needs a C compiler and static libc development files, GNU make,
binutils, flex, bison, bc, OpenSSL and ELF development files, Python, Meson,
Ninja, pkg-config, GLib and Pixman development files, `cpio`, gzip, and access
to `/dev/kvm`.

The Linux and QEMU submodules are shallow. The build fetches only the exact v5
control tip in addition to the v6 gitlink, rather than cloning full histories.

Useful narrower commands:

```sh
./run build
./run test nvgrace-v6
./run test dmabuf
./run test nvgrace-v5
make clean
```

## Repository shape

- `linux/` tracks the clean v6 series on top of upstream Linux v7.2. It has the
  VFIO DMA-BUF shadow-state fix, leaves nvgrace's user-access behavior
  unchanged, and has no test hooks or runtime locking controls. The
  `opsound/linux` fork's parent is `torvalds/linux`.
- `out/src/linux-v5/` is an automatically created worktree at Matt's exact v5
  tip. It shares the `linux/` Git object store rather than duplicating the
  repository. Exact revisions are recorded in `configs/versions.env`.
- `qemu/` tracks `opsound/qemu:vfio-dmabuf-mmap-v6-qemu-lab`. It currently
  extends EDU with an opt-in nvgrace test personality and pins the GitHub
  mirror of QEMU's `keycodemapdb` build dependency.
- `tests/` contains the static PID 1 guest orchestrator and the deterministic
  userfaultfd concurrency harness.
- `configs/` contains the exact lockdep-enabled x86 kernel configuration.
- `scripts/` owns host builds and QEMU launch/result checking.

To edit the v6 Linux or QEMU source, commit and push in that nested repository,
then commit the updated submodule pointer and revision manifest here. This is
deliberately the same workflow for Linux and QEMU. The v5 worktree is a pinned
control and is never patched during a build.

## Tests

`nvgrace-v6` boots the clean v6 kernel and binds the QEMU EDU device to the
unmodified nvgrace VFIO driver. QEMU supplies the firmware memory properties,
reserved guest RAM, and device-ready registers that real Grace hardware would
supply. The test first confirms that faulting nvgrace user access can
legitimately hold `memory_lock(R)` and block a config-space writer. It then
queues that writer behind a faulting read and verifies that a third thread can
complete mmap-triggered DMA-BUF export without taking `memory_lock`. The fixed
three-thread case runs ten times.

`dmabuf` binds `bochs-display` to vfio-pci and runs the v6 mmap, alias,
revocation, and cleanup test ten times.

`nvgrace-v5` boots Matt's exact v5 kernel with the same QEMU device. A VFIO
pread holds `memory_lock(R)` while userfaultfd suspends its user access, a
config-space writer queues for `memory_lock(W)`, and a concurrent mmap holds
`mmap_lock(W)` while v5 DMA-BUF export waits for `memory_lock`. Resolving the
user fault then needs `mmap_lock`, closing the cycle. Success means lockdep
reports the circular dependency and the guest remains deadlocked until the
15-second host timeout.

The setup exercises the real kernel VFIO, rwsem, mmap, DMA-BUF, userfaultfd,
and IOMMU paths. QEMU owns only the hardware/firmware emulation. It does not
validate Grace hardware, CXL behavior, cache attributes, or performance.
