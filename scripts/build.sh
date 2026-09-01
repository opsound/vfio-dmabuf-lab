#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
linux_src="${root}/linux"
qemu_src="${root}/qemu"
out="${root}/out"
linux_build="${out}/linux"
qemu_build="${out}/qemu"
test_build="${out}/tests"
headers="${out}/headers"
rootfs="${out}/rootfs"
jobs="${JOBS:-16}"
cc="${CC:-cc}"

if ! git -C "${linux_src}" rev-parse --git-dir >/dev/null 2>&1 ||
   ! git -C "${qemu_src}" rev-parse --git-dir >/dev/null 2>&1; then
	git -C "${root}" submodule update --init linux qemu
fi
if [ ! -f "${qemu_src}/subprojects/keycodemapdb/README" ]; then
	git -C "${qemu_src}" submodule update --init subprojects/keycodemapdb
fi

mkdir -p "${linux_build}" "${qemu_build}" "${test_build}" "${headers}"

echo "==> Building Linux ($(git -C "${linux_src}" rev-parse --short HEAD))"
install -m 0644 "${root}/configs/linux-x86_64.config" "${linux_build}/.config"
make -C "${linux_src}" O="${linux_build}" olddefconfig
make -C "${linux_src}" O="${linux_build}" -j"${jobs}" bzImage
make -C "${linux_src}" O="${linux_build}" \
	INSTALL_HDR_PATH="${headers}" headers_install

echo "==> Building QEMU ($(git -C "${qemu_src}" rev-parse --short HEAD))"
if [ ! -f "${qemu_build}/build.ninja" ]; then
	(
		cd "${qemu_build}"
		"${qemu_src}/configure" \
			--target-list=x86_64-softmmu \
			--enable-kvm \
			--disable-tcg \
			--disable-fdt \
			--disable-docs \
			--disable-werror
	)
fi
ninja -C "${qemu_build}" -j "${jobs}" qemu-system-x86_64

echo "==> Building static guest test programs"
"${cc}" -O2 -g -Wall -Wextra -Werror -static -pthread \
	-I"${headers}/include" \
	-o "${test_build}/nvgrace_uaccess_test" \
	"${root}/tests/nvgrace_uaccess_test.c"
"${cc}" -O2 -g -Wall -Wextra -Werror -static \
	-I"${headers}/include" \
	-o "${test_build}/vfio_dmabuf_mmap_test" \
	"${linux_src}/tools/testing/selftests/vfio/standalone/vfio_dmabuf_mmap_test.c"
"${cc}" -O2 -g -Wall -Wextra -Werror -static \
	-o "${test_build}/guest-init" "${root}/tests/guest-init.c"

echo "==> Building initramfs"
rm -rf -- "${rootfs}"
mkdir -p "${rootfs}/dev" "${rootfs}/proc" "${rootfs}/sys" \
	"${rootfs}/tmp" "${rootfs}/run"
install -m 0755 "${test_build}/guest-init" "${rootfs}/init"
install -m 0755 "${test_build}/nvgrace_uaccess_test" \
	"${rootfs}/nvgrace_uaccess_test"
install -m 0755 "${test_build}/vfio_dmabuf_mmap_test" \
	"${rootfs}/vfio_dmabuf_mmap_test"
(
	cd "${rootfs}"
	find . -print0 | LC_ALL=C sort -z | cpio --null -o --format=newc
) | gzip -n > "${out}/initramfs.cpio.gz"

echo "Build complete: ${out}"
