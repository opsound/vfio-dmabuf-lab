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
the full kernel x test matrix. It builds four exact Linux revisions: Matt's v5
as the deadlock control, the proposed core-only v6 locking fix, David
Matlack's reported base as the reset-lockdep positive control, and the base
plus his `reset_mutex` fix. The v6 kernel keeps
nvgrace's direct user access under `memory_lock`; it does not add a bounce
buffer. Build products and serial logs are written under `out/`. Each PASS
summary names its serial log under `out/logs/`. The first
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
./run test nvgrace-v6            # bare test: default kernel (v6 here)
./run test dmabuf
./run test reset-lockdep
./run test nvgrace-v5
./run test david-fix:reset-lockdep   # one kernel:test matrix entry
./run test david-fix                 # every matrix entry for one kernel
./run test --jobs 4 all              # up to 4 guests at once, fail-fast
./run test --dry-run all             # list the matrix without running it
make clean
```

Builds parallelize by default: `./run build` runs `make -j$(nproc)`, which
fetches sources serially, then builds the four kernels and QEMU
concurrently (the kernels share one jobserver pool; QEMU's Ninja build
takes a fixed `QEMU_JOBS` slice, default 8), then headers, guest tests,
and the initramfs. `JOBS` sets the global budget (`JOBS=16 ./run
build`); bare `make build` and bare `scripts/build.sh` keep the legacy
serial flow. `make test` runs `scripts/selftest.sh` (fast QEMU-free
harness checks) before the matrix.

Test runs stay serial by default and parallelize on request: `./run test
--jobs 4 all` (or `make test TEST_JOBS=4`) runs up to four guests at once
with fail-fast and a closing per-entry summary.

## Repository shape

- `linux/` tracks Matt Evans's v6 series on top of upstream Linux v7.2. It has
  the VFIO DMA-BUF shadow-state fix, leaves nvgrace's user-access behavior
  unchanged, and has no test hooks or runtime locking controls. The pinned tip
  adds only a lab build fix for stale MEMATTR coverage in the standalone
  selftest; the kernel code is Matt's exact tip. The `opsound/linux` fork's
  parent is `torvalds/linux`.
- `out/src/linux-v5/` is an automatically created worktree at Matt's exact v5
  tip. It shares the `linux/` Git object store rather than duplicating the
  repository. Exact revisions are recorded in `configs/versions.env`.
- `out/src/linux-david-base/` and `out/src/linux-david-fix/` are worktrees
  for the reset-lockdep fix validation: David Matlack's reported upstream
  base and the base plus his `reset_mutex` patch. The branches are local
  until pushed to origin.
- `qemu/` tracks `opsound/qemu:vfio-dmabuf-mmap-v6-qemu-lab`. It currently
  extends EDU with an opt-in nvgrace test personality and pins the GitHub
  mirror of QEMU's `keycodemapdb` build dependency.
- `tests/` contains the static PID 1 guest orchestrator (`guest-init.c`),
  the nvgrace user-access test, and the VFIO BAR fault/reset reproducer.
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

`reset-lockdep` binds an ATS- and FLR-capable `virtio-net-pci` device to
vfio-pci, faults its mmapable BARs, and issues `VFIO_DEVICE_RESET`. It is the
reproducer from Vipin Sharma's
[VFIO reset lockdep report](https://lore.kernel.org/20260821193502.92431-1-vipinsh@google.com/),
adapted to the lab's legacy VFIO-container harness. A CPU-bound perf read
and a two-step `getdents64()` into unfaulted pages, plus a CPU offline/online
cycle and the perf hard-lockup detector, make the report's
`cpu_hotplug_lock` to `mmap_lock` history deterministic in the minimal guest,
which uses a translated IOMMU domain for this case so the IOVA CPU-hotplug
dependency is also exercised. The guest fails fast when the device lacks ATS.
Success means lockdep reports the known `memory_lock` to IOMMU-group circular
dependency and the reset completes.

`nvgrace-v5` boots Matt's exact v5 kernel with the same QEMU device. A VFIO
pread holds `memory_lock(R)` while userfaultfd suspends its user access, a
config-space writer queues for `memory_lock(W)`, and a concurrent mmap holds
`mmap_lock(W)` while v5 DMA-BUF export waits for `memory_lock`. Resolving the
user fault then needs `mmap_lock`, closing the cycle. Success means lockdep
reports the circular dependency and the guest remains deadlocked until the
15-second host timeout.

The runner executes a kernel x test x expectation matrix; only the listed
combinations run:

| kernel     | test          | expected outcome            |
|------------|---------------|-----------------------------|
| v6         | nvgrace-v6    | clean PASS                  |
| v6         | dmabuf        | clean PASS                  |
| v6         | reset-lockdep | lockdep warning, reset done |
| v5         | nvgrace-v5    | deadlock, host timeout      |
| v5         | reset-lockdep | lockdep warning, reset done |
| david-base | reset-lockdep | lockdep warning, reset done |
| david-fix  | reset-lockdep | clean PASS                  |

`david-fix` currently fails `clean`: the patch removes the circular
dependency but trips stale `lockdep_assert_held(&group->mutex)`
assertions in the reset path, so the bar stays red pending a respin.

The setup exercises the real kernel VFIO, rwsem, mmap, DMA-BUF, userfaultfd,
and IOMMU paths. QEMU owns only the hardware/firmware emulation. It does not
validate Grace hardware, CXL behavior, cache attributes, or performance.
