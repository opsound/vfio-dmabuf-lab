#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
qemu="${root}/out/qemu/qemu-system-x86_64"
kernel="${root}/out/linux/arch/x86/boot/bzImage"
initramfs="${root}/out/initramfs.cpio.gz"
logs="${root}/out/logs"
selection="${1:-all}"

for path in "${qemu}" "${kernel}" "${initramfs}"; do
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

run_mode()
{
	local mode="$1"
	local device timeout_seconds result log qemu_status

	case "${mode}" in
	nvgrace)
		device="edu,bus=rp1,addr=0x0"
		timeout_seconds=180
		result="NVGRACE_UACCESS_RESULT=PASS"
		;;
	dmabuf)
		device="bochs-display,bus=rp1,addr=0x0,vgamem=64M"
		timeout_seconds=180
		result="VFIO_DMABUF_RESULT=PASS"
		;;
	legacy-export)
		device="edu,bus=rp1,addr=0x0"
		timeout_seconds=15
		result=""
		;;
	*)
		echo "unknown test mode: ${mode}" >&2
		return 2
		;;
	esac

	log="${logs}/${mode}.log"
	: > "${log}"
	echo "==> Running ${mode}"
	set +e
	timeout "${timeout_seconds}" "${qemu}" \
		-machine q35,kernel-irqchip=split \
		-accel kvm -cpu host -m 2048M -smp 4 \
		-nodefaults -no-user-config -no-reboot \
		-display none -monitor none -serial "file:${log}" \
		-kernel "${kernel}" -initrd "${initramfs}" \
		-append "console=ttyS0 earlyprintk=serial panic=-1 oops=panic intel_iommu=on iommu=pt vfio_iommu_type1.allow_unsafe_interrupts=1 -- ${mode}" \
		-device intel-iommu,intremap=on,caching-mode=on \
		-device pcie-root-port,id=rp1,chassis=1,slot=1 \
		-device "${device}" </dev/null >> "${log}" 2>&1
	qemu_status="$?"
	set -e

	if [ "${mode}" = legacy-export ]; then
		if [ "${qemu_status}" -eq 124 ] &&
		   grep -q 'possible circular locking dependency detected' "${log}" &&
		   grep -q '\*\*\* DEADLOCK \*\*\*' "${log}" &&
		   grep -q 'mmap blocked while user fault is unresolved' "${log}"; then
			echo "PASS: ${mode}; expected deadlock reproduced"
			return 0
		fi
		echo "FAIL: ${mode}; expected deadlock was not reproduced" >&2
		tail -n 80 "${log}" >&2
		return 1
	fi

	if [ "${qemu_status}" -ne 0 ] || ! grep -q "${result}" "${log}"; then
		echo "FAIL: ${mode}; QEMU status ${qemu_status}" >&2
		tail -n 80 "${log}" >&2
		return 1
	fi

	if grep -Eq 'WARNING:|BUG:|KASAN:|UBSAN:|possible circular locking|hung task|soft lockup|hard LOCKUP' "${log}"; then
		echo "FAIL: ${mode}; kernel warning or fault signature found" >&2
		tail -n 80 "${log}" >&2
		return 1
	fi

	echo "PASS: ${mode}; log: ${log}"
}

case "${selection}" in
all)
	run_mode nvgrace
	run_mode dmabuf
	run_mode legacy-export
	;;
nvgrace|dmabuf|legacy-export)
	run_mode "${selection}"
	;;
*)
	echo "usage: $0 [all|nvgrace|dmabuf|legacy-export]" >&2
	exit 2
	;;
esac
