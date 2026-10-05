# VFIO DMA-BUF lab

This repository reproduces VFIO DMA-BUF bugs in a QEMU guest, without special
hardware. It covers a dma-buf use-after-free fix (below) and the VFIO DMA-BUF
mmap and nvgrace locking experiments. It is a superproject with editable,
pinned Linux and QEMU repositories. No source patches are applied during a
build: the pinned commits are exactly what gets compiled.

## dma-buf stale file pointer fix

Since commit 4ab59c3c638c ("dma-buf: Move dma_buf_release() from fops to
dentry_ops"), a dma_buf outlives its `struct file` while anything else holds
the dentry. An O_PATH fd on `/proc/self/fd/N` is enough: closing N frees the
file, but `dma_buf_release()` and the exporter's `->release()` wait for the
O_PATH fd, so `dmabuf->file` keeps pointing at freed memory.
`vfio_pci_dma_buf_move()` calls `get_file_active()` on that pointer whenever
the device is reset, enters D3hot, or has memory decoding disabled.

The fix is one patch on v7.3-rc6, branch `dmabuf-stale-file-fix` in
`opsound/linux`:

- `dma-buf: fix use-after-free of dmabuf->file while the dentry is held`

It runs the exporter's `->release()` from the file release again and leaves
only the name and the `struct dma_buf` itself for `d_release`, because
`dmabuffs_dname()` reads nothing else.

To reproduce on stock v7.3-rc6 and check the fix:

```sh
./run build
./run test dmabuf-opath-uaf
```

```
==> Running rc6:dmabuf-opath-uaf (expect kasan-uaf)
PASS: rc6:dmabuf-opath-uaf; expected KASAN use-after-free reproduced; log: .../out/logs/rc6-dmabuf-opath-uaf.log
==> Running rc6-fix:dmabuf-opath-uaf (expect clean)
PASS: rc6-fix:dmabuf-opath-uaf; log: .../out/logs/rc6-fix-dmabuf-opath-uaf.log
```

`tests/vfio_dmabuf_opath_uaf_test.c` binds `bochs-display` to vfio-pci and
exports one dma-buf that stays open. Ten times, it exports another, holds
it with O_PATH, closes the dma-buf fd, sleeps 200 ms, and clears
`PCI_COMMAND_MEMORY` through the VFIO config region.

Both kernels use `configs/kasan.config` on top of the lab config.
`CONFIG_SLUB_RCU_DEBUG` delays `struct file` frees by an RCU grace period so
KASAN can see them. Without it, the freed slot is usually reused instead:
the walk then takes a reference on an unrelated file, which leaves no trace
to observe. The unfixed kernel reports (trimmed from `out/logs/rc6-dmabuf-opath-uaf.log`):

```
BUG: KASAN: slab-use-after-free in get_file_active+0x79/0x250
Write of size 8 at addr ff110000029df118 by task vfio_dmabuf_opa/90
Call Trace:
 get_file_active+0x79/0x250
 vfio_pci_dma_buf_move+0x29a/0x650
 vfio_basic_config_write+0x245/0xa80
 vfio_pci_config_rw_single+0x37d/0x7a0
 vfio_pci_config_rw+0xdb/0x180
 vfio_pci_rw+0x20b/0x390
 vfs_write+0x20a/0xff0
 __x64_sys_pwrite64+0x185/0x1e0
The buggy address belongs to the object at ff110000029defc0
 which belongs to the cache filp of size 352
```

vmwgfx's cached `prime->dma_buf` has the same stale-file problem, and the fix
covers it as well. That path is not exercised here: QEMU's `vmware-svga` has
no pitchlock capability, so vmwgfx refuses to probe ("Hardware has no
pitchlock").

## One-command run

```sh
git clone https://github.com/opsound/vfio-dmabuf-lab.git
cd vfio-dmabuf-lab
./run
```

`./run` builds Linux, QEMU, static guest programs, and an initramfs, then runs
the full kernel x test matrix. It builds four exact Linux revisions: stock
v7.3-rc6 and the same base with the dma-buf fix, both with KASAN, plus Matt's
v7 series and Matt's v5 as the deadlock control. The v7 kernel keeps
nvgrace's direct user access under `memory_lock`; it does not add a bounce
buffer. Build products and serial logs are written under `out/`. Each PASS
summary names its serial log under `out/logs/`. The first
build is large; subsequent builds are incremental.

The host needs a C compiler and static libc development files, GNU make,
binutils, flex, bison, bc, OpenSSL and ELF development files, Python, Meson,
Ninja, pkg-config, GLib and Pixman development files, `cpio`, gzip, and access
to `/dev/kvm`.

The Linux and QEMU submodules are shallow. Besides the v7 gitlink, the build
fetches only the v5 control tip and the `dmabuf-stale-file-fix` branch (which
also contains its v7.3-rc6 base), rather than cloning full histories.

Useful narrower commands:

```sh
./run build
./run test nvgrace-v7            # bare test: every matrix entry for it
./run test dmabuf-opath-uaf      # runs on both rc6 and rc6-fix
./run test dmabuf
./run test nvgrace-v5
./run test v7:dmabuf             # one kernel:test matrix entry
./run test v7                    # every matrix entry for one kernel
./run test --jobs 4 all          # up to 4 guests at once, fail-fast
./run test --dry-run all         # list the matrix without running it
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

- `linux/` tracks Matt Evans's v7 series on top of upstream Linux v7.3-rc4. It
  has the VFIO DMA-BUF shadow-state fix, leaves nvgrace's user-access behavior
  unchanged, and has no test hooks or runtime locking controls. The pinned tip
  adds only a lab build fix (`stdbool.h` include, sign-compare) for `-Werror`
  in the standalone selftest; the kernel code is Matt's exact tip. The
  `opsound/linux` fork's parent is `torvalds/linux`.
- `out/src/linux-v5/`, `out/src/linux-rc6/` and `out/src/linux-rc6-fix/` are
  automatically created worktrees at Matt's exact v5 tip, stock v7.3-rc6, and
  the dma-buf fix. They share the `linux/` Git object store rather than
  duplicating the repository. Exact revisions are recorded in
  `configs/versions.env`.
- `qemu/` tracks `opsound/qemu:vfio-dmabuf-mmap-v6-qemu-lab`. It currently
  extends EDU with an opt-in nvgrace test personality and pins the GitHub
  mirror of QEMU's `keycodemapdb` build dependency.
- `tests/` contains the static PID 1 guest orchestrator (`guest-init.c`),
  the nvgrace user-access test, the dma-buf O_PATH use-after-free test, and
  shared helpers for opening legacy VFIO container/group devices.
- `configs/` contains the exact lockdep-enabled x86 kernel configuration and
  the KASAN fragment merged on top of it for the rc6 kernels.
- `scripts/` owns host builds and QEMU launch/result checking.

To edit the v7 Linux or QEMU source, commit and push in that nested repository,
then commit the updated submodule pointer and revision manifest here. This is
deliberately the same workflow for Linux and QEMU. The v5, rc6 and rc6-fix
worktrees are pinned and never patched during a build.

## Tests

`nvgrace-v7` boots the clean v7 kernel and binds the QEMU EDU device to the
unmodified nvgrace VFIO driver. QEMU supplies the firmware memory properties,
reserved guest RAM, and device-ready registers that real Grace hardware would
supply. The test first confirms that faulting nvgrace user access can
legitimately hold `memory_lock(R)` and block a config-space writer. It then
queues that writer behind a faulting read and verifies that a third thread can
complete mmap-triggered DMA-BUF export without taking `memory_lock`. The fixed
three-thread case runs ten times.

`dmabuf` binds `bochs-display` to vfio-pci and runs the v7 mmap, alias,
revocation, and cleanup test ten times.

`nvgrace-v5` boots Matt's exact v5 kernel with the same QEMU device. A VFIO
pread holds `memory_lock(R)` while userfaultfd suspends its user access, a
config-space writer queues for `memory_lock(W)`, and a concurrent mmap holds
`mmap_lock(W)` while v5 DMA-BUF export waits for `memory_lock`. Resolving the
user fault then needs `mmap_lock`, closing the cycle. Success means lockdep
reports the circular dependency and the guest remains deadlocked until the
15-second host timeout.

`dmabuf-opath-uaf` is described in the dma-buf section above. On rc6, success
means KASAN reports a `filp` use-after-free in `get_file_active()` called from
`vfio_pci_dma_buf_move()`. On rc6-fix, it means a clean run.

The runner executes a kernel x test x expectation matrix; only the listed
combinations run:

| kernel     | test          | expected outcome            |
|------------|---------------|-----------------------------|
| v7         | nvgrace-v7    | clean PASS                  |
| v7         | dmabuf        | clean PASS                  |
| v5         | nvgrace-v5    | deadlock, host timeout      |
| rc6        | dmabuf-opath-uaf | KASAN use-after-free     |
| rc6-fix    | dmabuf-opath-uaf | clean PASS               |

Verdicts read result markers from a dedicated channel, not the shared serial
console: QEMU attaches a second serial port, guest PID 1 writes exactly one
`RESULT=PASS` line to `/dev/ttyS1`, and the runner checks
`out/logs/<kernel>-<test>.markers`. The kernel never writes to that port
(`console=ttyS0`), so a printk cannot land mid-line inside the marker the way
it can on the serial log, whose stdout copy is kept for context. The deadlock
expectation needs no marker: it greps the serial log for the test's progress
lines and the lockdep report. The KASAN expectation needs both the marker and
the KASAN report in the serial log.

The setup exercises the real kernel VFIO, rwsem, mmap, DMA-BUF, userfaultfd,
and IOMMU paths. QEMU owns only the hardware/firmware emulation. It does not
validate Grace hardware, CXL behavior, cache attributes, or performance.
