#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
qemu="${root}/out/qemu/qemu-system-x86_64"
initramfs="${root}/out/initramfs.cpio.gz"
logs="${root}/out/logs"
selection="${1:-all}"

for path in "${qemu}" "${initramfs}"; do
	if [ ! -e "${path}" ]; then
		echo "missing build artifact: ${path}; run ./run build first" >&2
		exit 1
	fi
done

if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
	echo "/dev/kvm is not accessible" >&2
	exit 1
fi

mkdir -p "${logs}"

# Formal test matrix: "kernel test expectation" triples.  Only listed
# combinations run; any other kernel:test pair is rejected.
MATRIX=(
	"v6 nvgrace-v6 clean"
	"v6 dmabuf clean"
	"v6 reset-lockdep lockdep-warning"
	"v5 nvgrace-v5 deadlock-timeout"
	"v5 reset-lockdep lockdep-warning"
	"david-base reset-lockdep lockdep-warning"
	"david-fix reset-lockdep clean"
)

matrix_expectation()
{
	local entry kernel test expectation

	for entry in "${MATRIX[@]}"; do
		read -r kernel test expectation <<< "${entry}"
		if [ "${kernel}" = "$1" ] && [ "${test}" = "$2" ]; then
			echo "${expectation}"
			return 0
		fi
	done
	return 1
}

default_kernel()
{
	case "$1" in
	nvgrace-v6|dmabuf|reset-lockdep)
		echo v6
		;;
	nvgrace-v5)
		echo v5
		;;
	*)
		return 1
		;;
	esac
}

kernel_image()
{
	case "$1" in
	v5)
		echo "${root}/out/linux-v5/arch/x86/boot/bzImage"
		;;
	v6)
		echo "${root}/out/linux-v6/arch/x86/boot/bzImage"
		;;
	david-base)
		echo "${root}/out/linux-david-base/arch/x86/boot/bzImage"
		;;
	david-fix)
		echo "${root}/out/linux-david-fix/arch/x86/boot/bzImage"
		;;
	*)
		return 1
		;;
	esac
}

check_clean()
{
	local label="$1"
	local log="$2"
	local qemu_status="$3"
	local result="$4"

	if [ "${qemu_status}" -ne 0 ] || ! grep -q "${result}" "${log}"; then
		echo "FAIL: ${label}; QEMU status ${qemu_status}" >&2
		tail -n 80 "${log}" >&2
		return 1
	fi

	if grep -Eq 'WARNING:|BUG:|KASAN:|UBSAN:|possible circular locking|hung task|soft lockup|hard LOCKUP' "${log}"; then
		echo "FAIL: ${label}; kernel warning or fault signature found" >&2
		tail -n 80 "${log}" >&2
		return 1
	fi

	echo "PASS: ${label}; log: ${log}"
}

check_lockdep_warning()
{
	local label="$1"
	local log="$2"
	local qemu_status="$3"
	local result="$4"
	local frames="$5"
	local frame

	if [ -z "${frames}" ]; then
		echo "FAIL: ${label}; no lockdep frames configured" >&2
		return 1
	fi
	if [ "${qemu_status}" -ne 0 ] ||
	   ! grep -q "${result}" "${log}" ||
	   ! grep -q 'possible circular locking dependency detected' "${log}"; then
		echo "FAIL: ${label}; expected lockdep warning was not reproduced" >&2
		tail -n 100 "${log}" >&2
		return 1
	fi
	while IFS= read -r frame; do
		if [ -n "${frame}" ] && ! grep -qE "${frame}" "${log}"; then
			echo "FAIL: ${label}; expected lockdep frame '${frame}' not found" >&2
			tail -n 100 "${log}" >&2
			return 1
		fi
	done <<< "${frames}"

	echo "PASS: ${label}; expected lockdep warning reproduced; log: ${log}"
}

check_deadlock_timeout()
{
	local label="$1"
	local log="$2"
	local qemu_status="$3"
	local marker="$4"

	if [ "${qemu_status}" -eq 124 ] &&
	   grep -q 'possible circular locking dependency detected' "${log}" &&
	   grep -q '\*\*\* DEADLOCK \*\*\*' "${log}" &&
	   grep -q "${marker}" "${log}"; then
		echo "PASS: ${label}; expected deadlock reproduced; log: ${log}"
		return 0
	fi
	echo "FAIL: ${label}; expected deadlock was not reproduced" >&2
	tail -n 80 "${log}" >&2
	return 1
}

run_entry()
{
	local kernel="$1"
	local test="$2"
	local expectation
	local image
	local device timeout_seconds result log qemu_status memory
	local extra_append=""
	local iommu="intel-iommu,intremap=on,caching-mode=on"
	local iommu_cmdline="iommu=pt"
	local lockdep_frames=""
	local deadlock_marker=""

	if ! expectation="$(matrix_expectation "${kernel}" "${test}")"; then
		echo "no matrix entry for ${kernel}:${test}" >&2
		return 2
	fi
	if ! image="$(kernel_image "${kernel}")"; then
		echo "unknown kernel: ${kernel}" >&2
		return 2
	fi

	case "${test}" in
	nvgrace-v6)
		device="edu,nvgrace-test=on,nvgrace-mem-base=0x40000000,nvgrace-mem-size=0x60000000,bus=rp1,addr=0x0"
		memory=4096M
		extra_append='memmap=1536M$1G'
		timeout_seconds=180
		result="NVGRACE_V6_RESULT=PASS"
		;;
	dmabuf)
		device="bochs-display,bus=rp1,addr=0x0,vgamem=64M"
		memory=2048M
		timeout_seconds=180
		result="VFIO_DMABUF_RESULT=PASS"
		;;
	reset-lockdep)
		device="virtio-net-pci,ats=on,iommu_platform=on,disable-legacy=on,bus=rp1,addr=0x0"
		memory=2048M
		iommu="intel-iommu,intremap=on,caching-mode=on,device-iotlb=on"
		iommu_cmdline=""
		extra_append="nmi_watchdog=1"
		timeout_seconds=180
		result="VFIO_RESET_LOCKDEP_RESULT=PASS"
		lockdep_frames="pci_dev_reset_iommu_prepare
vfio_pci_ioctl_reset|vfio_pci_core_ioctl"
		;;
	nvgrace-v5)
		device="edu,nvgrace-test=on,nvgrace-mem-base=0x40000000,nvgrace-mem-size=0x60000000,bus=rp1,addr=0x0"
		memory=4096M
		extra_append='memmap=1536M$1G'
		timeout_seconds=15
		result=""
		deadlock_marker="export: writer blocked, mmap blocked while user fault is unresolved"
		;;
	*)
		echo "unknown test: ${test}" >&2
		return 2
		;;
	esac
	if [ ! -e "${image}" ]; then
		echo "missing build artifact: ${image}; run ./run build first" >&2
		return 1
	fi

	log="${logs}/${kernel}-${test}.log"
	: > "${log}"
	echo "==> Running ${kernel}:${test} (expect ${expectation})"
	set +e
	timeout "${timeout_seconds}" "${qemu}" \
		-machine q35,kernel-irqchip=split \
		-accel kvm -cpu host -m "${memory}" -smp 4 \
		-nodefaults -no-user-config -no-reboot \
		-display none -monitor none -serial "file:${log}" \
		-kernel "${image}" -initrd "${initramfs}" \
		-append "console=ttyS0 earlyprintk=serial panic=-1 oops=panic intel_iommu=on ${iommu_cmdline} vfio_iommu_type1.allow_unsafe_interrupts=1 ${extra_append} -- ${test}" \
		-device "${iommu}" \
		-device pcie-root-port,id=rp1,chassis=1,slot=1 \
		-device "${device}" </dev/null >> "${log}" 2>&1
	qemu_status="$?"
	set -e

	case "${expectation}" in
	clean)
		check_clean "${kernel}:${test}" "${log}" "${qemu_status}" "${result}"
		;;
	lockdep-warning)
		check_lockdep_warning "${kernel}:${test}" "${log}" "${qemu_status}" "${result}" "${lockdep_frames}"
		;;
	deadlock-timeout)
		check_deadlock_timeout "${kernel}:${test}" "${log}" "${qemu_status}" "${deadlock_marker}"
		;;
	*)
		echo "unknown expectation: ${expectation}" >&2
		return 2
		;;
	esac
}

usage()
{
	echo "usage: $0 [all|<kernel>|<test>|<kernel>:<test>]" >&2
	echo "  kernels: v5 v6 david-base david-fix" >&2
	echo "  tests: nvgrace-v6 dmabuf reset-lockdep nvgrace-v5" >&2
	exit 2
}

case "${selection}" in
all)
	for entry in "${MATRIX[@]}"; do
		read -r kernel test expectation <<< "${entry}"
		run_entry "${kernel}" "${test}" || exit 1
	done
	;;
*:*)
	kernel="${selection%%:*}"
	test="${selection#*:}"
	if [ -z "${kernel}" ] || [ -z "${test}" ]; then
		usage
	fi
	run_entry "${kernel}" "${test}"
	;;
*)
	if kernel_image "${selection}" >/dev/null; then
		ran=0
		for entry in "${MATRIX[@]}"; do
			read -r kernel test expectation <<< "${entry}"
			if [ "${kernel}" = "${selection}" ]; then
				run_entry "${kernel}" "${test}" || exit 1
				ran=1
			fi
		done
		if [ "${ran}" -eq 0 ]; then
			echo "no matrix entries for kernel: ${selection}" >&2
			exit 2
		fi
	elif kernel="$(default_kernel "${selection}")"; then
		run_entry "${kernel}" "${selection}"
	else
		usage
	fi
	;;
esac
