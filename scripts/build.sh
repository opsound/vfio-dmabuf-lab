#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
linux_src="${root}/linux"
qemu_src="${root}/qemu"
out="${root}/out"
linux_v5_src="${out}/src/linux-v5"
linux_v5_build="${out}/linux-v5"
linux_v7_build="${out}/linux-v7"
qemu_build="${out}/qemu"
test_build="${out}/tests"
headers="${out}/headers"
rootfs="${out}/rootfs"
jobs="${JOBS:-16}"
cc="${CC:-cc}"

# shellcheck source=../configs/versions.env
. "${root}/configs/versions.env"

# Serial git phase: submodules, pins, and generated worktrees. Always runs
# before any compile so parallel steps never contend on git metadata.
fetch_all()
{
	if [ ! -e "${linux_src}/.git" ] || [ ! -e "${qemu_src}/.git" ]; then
		git -C "${root}" submodule update --init --depth 1 \
			--single-branch linux qemu
	fi
	if [ ! -f "${qemu_src}/subprojects/keycodemapdb/README" ]; then
		git -C "${qemu_src}" submodule update --init --depth=1 \
			subprojects/keycodemapdb
	fi

	if [ "$(git -C "${linux_src}" rev-parse HEAD)" != "${LINUX_V7_COMMIT}" ]; then
		echo "linux/ is not pinned to LINUX_V7_COMMIT; update submodules" >&2
		exit 1
	fi
	if [ "$(git -C "${qemu_src}" rev-parse HEAD)" != "${QEMU_COMMIT}" ]; then
		echo "qemu/ is not pinned to QEMU_COMMIT; update submodules" >&2
		exit 1
	fi

	mkdir -p "${out}/src"
	ensure_kernel_source v5 "${linux_v5_src}" "${LINUX_V5_COMMIT}" "${LINUX_V5_REF}"
}

ensure_kernel_source()
{
	local label="$1"
	local source="$2"
	local commit="$3"
	local ref="$4"
	local fetch_rounds

	if ! git -C "${linux_src}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
		echo "==> Fetching the exact Linux ${label} revision"
		git -C "${linux_src}" fetch --no-tags --depth=1 origin "${ref}"
	fi
	if ! git -C "${linux_src}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
		# The pinned commit may sit below the branch tip (e.g. a
		# follow-up was pushed after the pin); deepen in bounded
		# steps until it is available.  (Raw-SHA fetch is not
		# supported by the hosting protocol, so deepen instead.)
		fetch_rounds=0
		while ! git -C "${linux_src}" cat-file -e "${commit}^{commit}" 2>/dev/null; do
			fetch_rounds=$((fetch_rounds + 1))
			if [ "${fetch_rounds}" -gt 10 ]; then
				break
			fi
			git -C "${linux_src}" fetch --no-tags --deepen=10 origin "${ref}"
		done
	fi
	if ! git -C "${linux_src}" cat-file -e "${commit}^{commit}" 2>/dev/null; then
		echo "Linux ${label} commit ${commit} is unavailable from origin" >&2
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

build_one_kernel() # name
{
	local name="$1"
	local source build

	case "${name}" in
	v5)
		source="${linux_v5_src}"
		build="${linux_v5_build}"
		;;
	v7)
		source="${linux_src}"
		build="${linux_v7_build}"
		;;
	*)
		echo "unknown kernel: ${name}" >&2
		exit 2
		;;
	esac

	echo "==> Building Linux ${name} ($(git -C "${source}" rev-parse --short HEAD))"
	mkdir -p "${build}"
	install -m 0644 "${root}/configs/linux-x86_64.config" "${build}/.config"
	make -C "${source}" O="${build}" olddefconfig
	case "${MAKEFLAGS:-}" in
	*jobserver*)
		# Running under a parallel make: join its jobserver pool
		# instead of taking a fixed slice, so all kernels share one
		# global budget.
		make -C "${source}" O="${build}" bzImage
		;;
	*)
		make -C "${source}" O="${build}" -j"${jobs}" bzImage
		;;
	esac
}
build_headers()
{
	mkdir -p "${headers}"
	make -C "${linux_src}" O="${linux_v7_build}" \
		INSTALL_HDR_PATH="${headers}" headers_install
}

build_qemu()
{
	echo "==> Building QEMU ($(git -C "${qemu_src}" rev-parse --short HEAD))"
	mkdir -p "${qemu_build}"
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
	# Ninja cannot join make's jobserver, so it takes a fixed slice.
	ninja -C "${qemu_build}" -j "${QEMU_JOBS:-${jobs}}" qemu-system-x86_64
}

build_tests()
{
	echo "==> Building static guest test programs"
	mkdir -p "${test_build}"
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
}

build_initramfs()
{
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
}

usage()
{
	echo "usage: $0 [all|fetch|kernel <name>|headers|qemu|tests|initramfs]" >&2
	exit 2
}

step="${1:-all}"
case "${step}" in
fetch)
	fetch_all
	;;
kernel)
	if [ $# -lt 2 ]; then
		usage
	fi
	build_one_kernel "$2"
	;;
headers)
	build_headers
	;;
qemu)
	build_qemu
	;;
tests)
	build_tests
	;;
initramfs)
	build_initramfs
	;;
all)
	fetch_all
	build_one_kernel v5
	build_one_kernel v7
	build_headers
	build_qemu
	build_tests
	build_initramfs
	echo "Build complete: ${out}"
	;;
*)
	usage
	;;
esac
