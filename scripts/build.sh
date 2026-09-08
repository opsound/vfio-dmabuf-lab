#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
linux_src="${root}/linux"
qemu_src="${root}/qemu"
out="${root}/out"
linux_v5_src="${out}/src/linux-v5"
linux_v5_build="${out}/linux-v5"
linux_v6_build="${out}/linux-v6"
linux_david_base_src="${out}/src/linux-david-base"
linux_david_base_build="${out}/linux-david-base"
linux_david_fix_src="${out}/src/linux-david-fix"
linux_david_fix_build="${out}/linux-david-fix"
qemu_build="${out}/qemu"
test_build="${out}/tests"
headers="${out}/headers"
rootfs="${out}/rootfs"
jobs="${JOBS:-16}"
cc="${CC:-cc}"

# shellcheck source=../configs/versions.env
. "${root}/configs/versions.env"

if ! git -C "${linux_src}" rev-parse --git-dir >/dev/null 2>&1 ||
   ! git -C "${qemu_src}" rev-parse --git-dir >/dev/null 2>&1; then
	git -C "${root}" submodule update --init linux qemu
fi
if [ ! -f "${qemu_src}/subprojects/keycodemapdb/README" ]; then
	git -C "${qemu_src}" submodule update --init --depth=1 \
		subprojects/keycodemapdb
fi

if [ "$(git -C "${linux_src}" rev-parse HEAD)" != "${LINUX_V6_COMMIT}" ]; then
	echo "linux/ is not pinned to LINUX_V6_COMMIT; update submodules" >&2
	exit 1
fi
if [ "$(git -C "${qemu_src}" rev-parse HEAD)" != "${QEMU_COMMIT}" ]; then
	echo "qemu/ is not pinned to QEMU_COMMIT; update submodules" >&2
	exit 1
fi

ensure_kernel_source()
{
	local label="$1"
	local source="$2"
	local commit="$3"
	local ref="$4"

	if ! git -C "${linux_src}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
		echo "==> Fetching the exact Linux ${label} revision"
		git -C "${linux_src}" fetch --no-tags --depth=1 origin "${ref}"
	fi
	if ! git -C "${linux_src}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
		echo "Linux ${label} commit ${commit} is unavailable after fetching ${ref}" >&2
		exit 1
	fi

	if [ -e "${source}/.git" ]; then
		if [ -n "$(git -C "${source}" status --porcelain)" ]; then
			echo "generated ${label} worktree is dirty: ${source}" >&2
			exit 1
		fi
		if [ "$(git -C "${source}" rev-parse HEAD)" != "${commit}" ]; then
			git -C "${source}" switch --detach "${commit}"
		fi
	else
		# Recover after a previous out/ directory was removed without unregistering
		# its generated worktree.
		git -C "${linux_src}" worktree prune
		git -C "${linux_src}" worktree add --detach "${source}" \
			"${commit}"
	fi
}

mkdir -p "${out}/src"
ensure_kernel_source v5 "${linux_v5_src}" "${LINUX_V5_COMMIT}" "${LINUX_V5_REF}"
ensure_kernel_source david-base "${linux_david_base_src}" "${DAVID_BASE_COMMIT}" "${DAVID_BASE_REF}"
ensure_kernel_source david-fix "${linux_david_fix_src}" "${DAVID_FIX_COMMIT}" "${DAVID_FIX_REF}"

mkdir -p "${linux_v5_build}" "${linux_v6_build}" \
	"${linux_david_base_build}" "${linux_david_fix_build}" \
	"${qemu_build}" "${test_build}" "${headers}"

build_linux()
{
	local label="$1"
	local source="$2"
	local build="$3"

	echo "==> Building Linux ${label} ($(git -C "${source}" rev-parse --short HEAD))"
	install -m 0644 "${root}/configs/linux-x86_64.config" "${build}/.config"
	make -C "${source}" O="${build}" olddefconfig
	make -C "${source}" O="${build}" -j"${jobs}" bzImage
}

build_linux v5 "${linux_v5_src}" "${linux_v5_build}"
build_linux v6 "${linux_src}" "${linux_v6_build}"
build_linux david-base "${linux_david_base_src}" "${linux_david_base_build}"
build_linux david-fix "${linux_david_fix_src}" "${linux_david_fix_build}"
make -C "${linux_src}" O="${linux_v6_build}" \
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
	-I"${headers}/include" \
	-o "${test_build}/vfio_pci_mmap_reset_test" \
	"${root}/tests/vfio_pci_mmap_reset_test.c"
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
install -m 0755 "${test_build}/vfio_pci_mmap_reset_test" \
	"${rootfs}/vfio_pci_mmap_reset_test"
(
	cd "${rootfs}"
	find . -print0 | LC_ALL=C sort -z | cpio --null -o --format=newc
) | gzip -n > "${out}/initramfs.cpio.gz"

echo "Build complete: ${out}"
