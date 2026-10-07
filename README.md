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
the device is reset, enters D3hot, or has memory decoding disabled, and
`vfio_pci_dma_buf_cleanup()` calls it when the device is closed.

The fix is one patch on v7.3-rc6, branch `dmabuf-stale-file-fix` in
`opsound/linux`:

- `dma-buf: fix use-after-free of dmabuf->file while the dentry is held`

It runs the exporter's `->release()` from the file release again and leaves
only the name and the `struct dma_buf` itself for `d_release`, because
`dmabuffs_dname()` reads nothing else.

To reproduce on stock v7.3-rc6 and check the fixes:

```sh
./run build
./run test dmabuf-opath-uaf
```

This boots every kernel with a `dmabuf-opath-uaf` entry. rc6 and v8 are
expected to hit the use-after-free; rc6-fix, rc6-matt and v8-b1lite carry a
fix and are expected to run clean:

```
==> Running rc6:dmabuf-opath-uaf (expect kasan-uaf)
PASS: rc6:dmabuf-opath-uaf; expected KASAN use-after-free reproduced; log: .../out/logs/rc6-dmabuf-opath-uaf.log
==> Running rc6-fix:dmabuf-opath-uaf (expect clean)
PASS: rc6-fix:dmabuf-opath-uaf; log: .../out/logs/rc6-fix-dmabuf-opath-uaf.log
==> Running rc6-matt:dmabuf-opath-uaf (expect clean)
PASS: rc6-matt:dmabuf-opath-uaf; log: .../out/logs/rc6-matt-dmabuf-opath-uaf.log
==> Running v8:dmabuf-opath-uaf (expect kasan-uaf)
PASS: v8:dmabuf-opath-uaf; expected KASAN use-after-free reproduced; log: .../out/logs/v8-dmabuf-opath-uaf.log
==> Running v8-b1lite:dmabuf-opath-uaf (expect clean)
PASS: v8-b1lite:dmabuf-opath-uaf; log: .../out/logs/v8-b1lite-dmabuf-opath-uaf.log
```

`tests/vfio_dmabuf_opath_uaf_test.c` is the whole reproducer, with no loop:
export one page of BAR0 as a dma-buf, open `/proc/self/fd/N` with O_PATH,
close N, sleep 100 ms, close the VFIO device. The device close runs
`vfio_pci_dma_buf_cleanup()`, which walks the entry whose file is gone.
One pass is enough: it reproduced on 10 of 10 boots each on rc6 and v8.

The rc6, rc6-fix, rc6-matt, v8 and v8-b1lite kernels use
`configs/kasan.config` on top of the lab config. `CONFIG_SLUB_RCU_DEBUG`
frees `struct file` only after an RCU grace period, which is what the sleep
waits for; without the sleep, 0 of 10 boots each on rc6 and v8 reported
anything. Without `SLUB_RCU_DEBUG` the freed slot can be reused instead:
the walk then takes a reference on an unrelated file, which leaves no trace
to observe. The unfixed kernel reports (trimmed from
`out/logs/rc6-dmabuf-opath-uaf.log`):

```
BUG: KASAN: slab-use-after-free in get_file_active+0x79/0x250
Write of size 8 at addr ff11000001d879d8 by task vfio_dmabuf_opa/89
Call Trace:
 get_file_active+0x79/0x250
 vfio_pci_dma_buf_move+0x29a/0x650
 vfio_pci_dma_buf_cleanup+0x3c/0x270
 vfio_pci_core_close_device+0x17e/0x240
 vfio_df_close+0x216/0x420
 vfio_df_unbind_iommufd+0x91/0x160
 vfio_device_fops_release+0x92/0xc0
 __fput+0x363/0xa90
 fput_close_sync+0xd8/0x190
 __x64_sys_close+0x78/0xd0
The buggy address belongs to the object at ff11000001d87880
 which belongs to the cache filp of size 352
```

Matt Evans posted a different dma-buf fix, `dma-buf: Annul dmabuf->file on
file release` (Message-ID `f8efaabd-c06e-4f04-8cfa-489c148e37ba@ozlabs.org`),
which clears `dmabuf->file` in `dma_buf_file_release()`. The `rc6-matt`
kernel is v7.3-rc6 with that patch (branch `dmabuf-matt-annul`), and it
passes the same test:

```sh
./run test rc6-matt:dmabuf-opath-uaf
```

vmwgfx's cached `prime->dma_buf` has the same stale-file problem. The
`dmabuf-stale-file-fix` patch covers it, because vmwgfx clears that pointer
in `->release()`, which then runs before the file is freed. Matt's patch
does not: vmwgfx would read a NULL `dmabuf->file` instead, as his posting
points out. That path is not exercised here: QEMU's `vmware-svga` has no
pitchlock capability, so vmwgfx refuses to probe ("Hardware has no
pitchlock").

### vfio-only variant on Matt's v8 (B1-lite)

`vfio-dmabuf-mmap-v8-b1lite` stages a vfio-only fix under Matt's v8 series
instead of changing dma-buf. Both branches are based on v7.3-rc5. The first
patch, `vfio/pci: fix use-after-free of dmabuf->file in revoke and cleanup`,
is a mainline patch: cleanup and `->release()` decide who removes an entry
under the dma-buf's resv lock, and the walks stop using `get_file_active()`.
Matt's v8 patches follow with two conflicts resolved, one against his
`dmabuf_lock` rename and one against his `vfio_pci_dma_buf_set_status()`
refactor. A `fixup!` makes the revoke path unmap through an inode reference
taken at export, because walks now also visit dma-bufs whose file is gone.

```sh
./run test v8          # Matt's v8 as posted
./run test v8-b1lite   # the same series on top of B1-lite
```

| kernel    | dmabuf-v8 (Matt's selftest) | dmabuf-opath-uaf      | nvgrace-v7 |
|-----------|-----------------------------|-----------------------|------------|
| v8        | clean PASS                  | KASAN use-after-free  | clean PASS |
| v8-b1lite | clean PASS                  | clean PASS            | clean PASS |

Because the O_PATH fd outlives the device close, on v8-b1lite
`vfio_pci_dma_buf_cleanup()` detaches an entry whose file is gone, and
`->release()` runs at process exit with `priv->vdev` already cleared.

## One-command run

```sh
git clone https://github.com/opsound/vfio-dmabuf-lab.git
cd vfio-dmabuf-lab
./run
```

`./run` builds Linux, QEMU, static guest programs, and an initramfs, then runs
the full kernel x test matrix. It builds seven exact Linux revisions, all
with lockdep: Matt's v7 series, Matt's v5 as the deadlock control, and,
with KASAN as well, stock v7.3-rc6, v7.3-rc6 with each of the two dma-buf
fixes, Matt's v8 series, and v8 on top of B1-lite. The v7 kernel keeps
nvgrace's direct user access under `memory_lock`; it does not add a bounce
buffer. Build products and serial logs are written under `out/`. Each PASS
summary names its serial log under `out/logs/`. The first
build is large; subsequent builds are incremental.

The host needs a C compiler and static libc development files, GNU make,
binutils, flex, bison, bc, OpenSSL and ELF development files, Python, Meson,
Ninja, pkg-config, GLib and Pixman development files, `cpio`, gzip, and access
to `/dev/kvm`.

The Linux and QEMU submodules are shallow. Besides the v7 gitlink, the build
fetches only the branches the other kernels are pinned to: the v5 control,
`dmabuf-stale-file-fix` (which also contains its v7.3-rc6 base),
`dmabuf-matt-annul`, `vfio-dmabuf-mmap-v8` and `vfio-dmabuf-mmap-v8-b1lite`.
It does not clone full histories.

Useful narrower commands:

```sh
./run build
./run test nvgrace-v7            # bare test: every matrix entry (v7, v8, v8-b1lite)
./run test dmabuf-opath-uaf      # rc6, rc6-fix, rc6-matt, v8, v8-b1lite
./run test dmabuf
./run test dmabuf-v8
./run test nvgrace-v5
./run test v7:dmabuf             # one kernel:test matrix entry
./run test v7                    # every matrix entry for one kernel
./run test --jobs 4 all          # up to 4 guests at once, fail-fast
./run test --dry-run all         # list the matrix without running it
make clean
```

Builds parallelize by default: `./run build` runs `make -j$(nproc)`, which
fetches sources serially, then builds the seven kernels and QEMU
concurrently (the kernels share one jobserver pool; QEMU's Ninja build
takes a fixed `QEMU_JOBS` slice, default 8), then the v7 and v8 uapi
headers, guest tests, and the initramfs. `JOBS` sets the global budget (`JOBS=16 ./run
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
- `out/src/linux-<kernel>/` are automatically created worktrees for v5, rc6,
  rc6-fix, rc6-matt, v8 and v8-b1lite, at the exact commits recorded in
  `configs/versions.env`. They share the `linux/` Git object store rather
  than duplicating the repository.
- `qemu/` tracks `opsound/qemu:vfio-dmabuf-mmap-v6-qemu-lab`. It currently
  extends EDU with an opt-in nvgrace test personality and pins the GitHub
  mirror of QEMU's `keycodemapdb` build dependency.
- `tests/` contains the static PID 1 guest orchestrator (`guest-init.c`),
  the nvgrace user-access test, the dma-buf O_PATH use-after-free test, and
  shared helpers that open a device through its VFIO cdev, bound to an
  iommufd with an empty IOAS attached. Matt's v7 and v8 selftests, which
  live in his kernel trees, still use the VFIO group and container API, so
  the lab config enables both.
- `configs/` contains the exact lockdep-enabled x86 kernel configuration,
  which also enables the VFIO cdev, and the KASAN fragment merged on top of
  it for the rc6 and v8 kernels.
- `scripts/` owns host builds and QEMU launch/result checking.

To edit the v7 Linux or QEMU source, commit and push in that nested repository,
then commit the updated submodule pointer and revision manifest here. This is
deliberately the same workflow for Linux and QEMU. The generated worktrees
are pinned and never patched during a build.

## Tests

`nvgrace-v7` boots the v7 kernel (and, as a regression check, v8 and
v8-b1lite) and binds the QEMU EDU device to the unmodified nvgrace VFIO
driver. QEMU supplies the firmware memory properties,
reserved guest RAM, and device-ready registers that real Grace hardware would
supply. The test first confirms that faulting nvgrace user access can
legitimately hold `memory_lock(R)` and block a config-space writer. It then
queues that writer behind a faulting read and verifies that a third thread can
complete mmap-triggered DMA-BUF export without taking `memory_lock`. The fixed
three-thread case runs ten times.

`dmabuf` binds `bochs-display` to vfio-pci and runs the v7 mmap, alias,
revocation, and cleanup test ten times.

`dmabuf-v8` does the same with Matt's v8 version of that selftest, built
against v8 uapi headers. The posted file misses `<stdbool.h>` and trips
`-Wsign-compare`, so the lab builds it with `-include stdbool.h
-Wno-sign-compare` instead of patching the pinned tree.

`nvgrace-v5` boots Matt's exact v5 kernel with the same QEMU device. A VFIO
pread holds `memory_lock(R)` while userfaultfd suspends its user access, a
config-space writer queues for `memory_lock(W)`, and a concurrent mmap holds
`mmap_lock(W)` while v5 DMA-BUF export waits for `memory_lock`. Resolving the
user fault then needs `mmap_lock`, closing the cycle. Success means lockdep
reports the circular dependency and the guest remains deadlocked until the
15-second host timeout.

`dmabuf-opath-uaf` is described in the dma-buf section above. On rc6 and v8, success
means KASAN reports a `filp` use-after-free in `get_file_active()` called from
`vfio_pci_dma_buf_move()`. On rc6-fix, rc6-matt and v8-b1lite, it means a
clean run.

The runner executes a kernel x test x expectation matrix; only the listed
combinations run:

| kernel     | test          | expected outcome            |
|------------|---------------|-----------------------------|
| v7         | nvgrace-v7    | clean PASS                  |
| v7         | dmabuf        | clean PASS                  |
| v5         | nvgrace-v5    | deadlock, host timeout      |
| rc6        | dmabuf-opath-uaf | KASAN use-after-free     |
| rc6-fix    | dmabuf-opath-uaf | clean PASS               |
| rc6-matt   | dmabuf-opath-uaf | clean PASS               |
| v8         | dmabuf-v8        | clean PASS               |
| v8         | dmabuf-opath-uaf | KASAN use-after-free     |
| v8         | nvgrace-v7       | clean PASS               |
| v8-b1lite  | dmabuf-v8        | clean PASS               |
| v8-b1lite  | dmabuf-opath-uaf | clean PASS               |
| v8-b1lite  | nvgrace-v7       | clean PASS               |

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
