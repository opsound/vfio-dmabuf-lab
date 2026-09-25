#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
qemu="${root}/out/qemu/qemu-system-x86_64"
initramfs="${root}/out/initramfs.cpio.gz"
logs="${root}/out/logs"
have_flock=0

usage()
{
	echo "usage: $0 [--jobs N] [--dry-run] [all|<kernel>|<test>|<kernel>:<test>]" >&2
	echo "  kernels: v5 v7 david-base david-fix" >&2
	echo "  tests: nvgrace-v7 dmabuf reset-lockdep nvgrace-v5" >&2
	exit 2
}

jobs=1
dry_run=0
while [ $# -gt 0 ]; do
	case "$1" in
	--jobs=*)
		jobs="${1#--jobs=}"
		shift
		;;
	--jobs|-j)
		if [ $# -lt 2 ]; then
			usage
		fi
		jobs="$2"
		shift 2
		;;
	-j?*)
		jobs="${1#-j}"
		shift
		;;
	--dry-run)
		dry_run=1
		shift
		;;
	--help|-h)
		usage
		;;
	-*)
		usage
		;;
	*)
		break
		;;
	esac
done
if [ $# -gt 1 ]; then
	usage
fi
selection="${1:-all}"
case "${jobs}" in
''|*[!0-9]*)
	usage
	;;
esac
jobs=$((10#${jobs}))
if [ "${jobs}" -lt 1 ]; then
	usage
fi

# --dry-run only enumerates the matrix; it needs no build artifacts or KVM.
if [ "${dry_run}" -eq 0 ]; then
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
	if command -v flock >/dev/null 2>&1; then
		have_flock=1
		exec 9>>"${logs}/.progress.lock"
	fi
fi

# Formal test matrix: "kernel test expectation" triples.  Only listed
# combinations run; any other kernel:test pair is rejected.
MATRIX=(
	"v7 nvgrace-v7 clean"
	"v7 dmabuf clean"
	"v7 reset-lockdep lockdep-warning"
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
	nvgrace-v7|dmabuf|reset-lockdep)
		echo v7
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
	v7)
		echo "${root}/out/linux-v7/arch/x86/boot/bzImage"
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

# Serialized console output. Parallel workers share stdout/stderr; every
# console line goes through say()/say_err() so lines never interleave.
# Serial runs take the same path with an uncontended lock (identical bytes).
say()
{
	if [ "${have_flock}" -eq 1 ]; then
		flock -x 9
	fi
	echo "$1"
	if [ "${have_flock}" -eq 1 ]; then
		flock -u 9
	fi
}
say_err()
{
	if [ "${have_flock}" -eq 1 ]; then
		flock -x 9
	fi
	echo "$1" >&2
	if [ "${have_flock}" -eq 1 ]; then
		flock -u 9
	fi
}
say_lines() # stdin -> stderr, one locked line at a time
{
	local line
	while IFS= read -r line || [ -n "${line}" ]; do
		say_err "${line}"
	done
}

# The markers file must contain exactly the expected line.  guest-init writes
# one line to the markers-only serial channel per boot and the kernel never
# writes there, so anything else (empty, FAIL value, extra lines) fails.
marker_ok() # markers result
{
	[ "$(wc -l <"$1" | tr -d ' ')" -eq 1 ] && grep -q "$2" "$1"
}

show_markers() # markers
{
	local content

	content="$(tr -d '\r' <"$1" 2>/dev/null)"
	if [ -z "${content}" ]; then
		say_err "markers ($(basename "$1")): (empty or unreadable)"
	else
		say_err "markers ($(basename "$1")): ${content}"
	fi
}

check_clean()
{
	local label="$1"
	local log="$2"
	local markers="$3"
	local qemu_status="$4"
	local result="$5"

	if [ "${qemu_status}" -ne 0 ] || ! marker_ok "${markers}" "${result}"; then
		say_err "FAIL: ${label}; QEMU status ${qemu_status}"
		show_markers "${markers}"
		tail -n 80 "${log}" | say_lines
		return 1
	fi

	if grep -Eq 'WARNING:|BUG:|KASAN:|UBSAN:|possible circular locking|hung task|soft lockup|hard LOCKUP' "${log}"; then
		say_err "FAIL: ${label}; kernel warning or fault signature found"
		show_markers "${markers}"
		tail -n 80 "${log}" | say_lines
		return 1
	fi

	say "PASS: ${label}; log: ${log}"
}

check_lockdep_warning()
{
	local label="$1"
	local log="$2"
	local markers="$3"
	local qemu_status="$4"
	local result="$5"
	local frames="$6"
	local frame

	if [ -z "${frames}" ]; then
		say_err "FAIL: ${label}; no lockdep frames configured"
		return 1
	fi
	if [ "${qemu_status}" -ne 0 ] ||
	   ! marker_ok "${markers}" "${result}" ||
	   ! grep -q 'possible circular locking dependency detected' "${log}"; then
		say_err "FAIL: ${label}; expected lockdep warning was not reproduced"
		show_markers "${markers}"
		tail -n 100 "${log}" | say_lines
		return 1
	fi
	while IFS= read -r frame; do
		if [ -n "${frame}" ] && ! grep -qE "${frame}" "${log}"; then
			say_err "FAIL: ${label}; expected lockdep frame '${frame}' not found"
			show_markers "${markers}"
			tail -n 100 "${log}" | say_lines
			return 1
		fi
	done <<< "${frames}"

	say "PASS: ${label}; expected lockdep warning reproduced; log: ${log}"
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
		say "PASS: ${label}; expected deadlock reproduced; log: ${log}"
		return 0
	fi
	say_err "FAIL: ${label}; expected deadlock was not reproduced"
	tail -n 80 "${log}" | say_lines
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
		say_err "no matrix entry for ${kernel}:${test}"
		return 2
	fi
	if ! image="$(kernel_image "${kernel}")"; then
		say_err "unknown kernel: ${kernel}"
		return 2
	fi

	case "${test}" in
	nvgrace-v7)
		device="edu,nvgrace-test=on,nvgrace-mem-base=0x40000000,nvgrace-mem-size=0x60000000,bus=rp1,addr=0x0"
		memory=4096M
		extra_append='memmap=1536M$1G'
		timeout_seconds=180
		result="NVGRACE_V7_RESULT=PASS"
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
		say_err "unknown test: ${test}"
		return 2
		;;
	esac
	if [ ! -e "${image}" ]; then
		say_err "missing build artifact: ${image}; run ./run build first"
		return 1
	fi

	log="${logs}/${kernel}-${test}.log"
	markers="${logs}/${kernel}-${test}.markers"
	: > "${log}"
	: > "${markers}"
	say "==> Running ${kernel}:${test} (expect ${expectation})"
	set +e
	# First serial is the ttyS0 console log; the second is the ttyS1
	# markers channel, which carries only guest-init's result line.
	timeout "${timeout_seconds}" "${qemu}" \
		-machine q35,kernel-irqchip=split \
		-accel kvm -cpu host -m "${memory}" -smp 4 \
		-nodefaults -no-user-config -no-reboot \
		-display none -monitor none -serial "file:${log}" \
		-serial "file:${markers}" \
		-kernel "${image}" -initrd "${initramfs}" \
		-append "console=ttyS0 earlyprintk=serial panic=-1 oops=panic intel_iommu=on ${iommu_cmdline} vfio_iommu_type1.allow_unsafe_interrupts=1 ${extra_append} -- ${test}" \
		-device "${iommu}" \
		-device pcie-root-port,id=rp1,chassis=1,slot=1 \
		-device "${device}" </dev/null >> "${log}" 2>&1
	qemu_status="$?"
	set -e

	case "${expectation}" in
	clean)
		check_clean "${kernel}:${test}" "${log}" "${markers}" "${qemu_status}" "${result}"
		;;
	lockdep-warning)
		check_lockdep_warning "${kernel}:${test}" "${log}" "${markers}" "${qemu_status}" "${result}" "${lockdep_frames}"
		;;
	deadlock-timeout)
		check_deadlock_timeout "${kernel}:${test}" "${log}" "${qemu_status}" "${deadlock_marker}"
		;;
	*)
		say_err "unknown expectation: ${expectation}"
		return 2
		;;
	esac
}

# Collect the matrix entries for the selection. Order matches MATRIX.
entries=()
case "${selection}" in
all)
	for entry in "${MATRIX[@]}"; do
		read -r kernel test expectation <<< "${entry}"
		entries+=("${kernel} ${test}")
	done
	;;
*:*)
	kernel="${selection%%:*}"
	test="${selection#*:}"
	if [ -z "${kernel}" ] || [ -z "${test}" ]; then
		usage
	fi
	if ! matrix_expectation "${kernel}" "${test}" >/dev/null; then
		say_err "no matrix entry for ${kernel}:${test}"
		exit 2
	fi
	entries+=("${kernel} ${test}")
	;;
*)
	if kernel_image "${selection}" >/dev/null; then
		for entry in "${MATRIX[@]}"; do
			read -r kernel test expectation <<< "${entry}"
			if [ "${kernel}" = "${selection}" ]; then
				entries+=("${kernel} ${test}")
			fi
		done
		if [ "${#entries[@]}" -eq 0 ]; then
			say_err "no matrix entries for kernel: ${selection}"
			exit 2
		fi
	elif kernel="$(default_kernel "${selection}")"; then
		entries+=("${kernel} ${selection}")
	else
		usage
	fi
	;;
esac

if [ "${dry_run}" -eq 1 ]; then
	for entry in "${entries[@]}"; do
		read -r kernel test <<< "${entry}"
		echo "${kernel}:${test}"
	done
	exit 0
fi

if [ "${jobs}" -eq 1 ]; then
	if [ "${#entries[@]}" -eq 1 ]; then
		read -r kernel test <<< "${entries[0]}"
		run_entry "${kernel}" "${test}"
		exit $?
	fi
	for entry in "${entries[@]}"; do
		read -r kernel test <<< "${entry}"
		run_entry "${kernel}" "${test}" || exit 1
	done
	exit 0
fi

# Parallel runs: up to ${jobs} QEMU guests at once, fail-fast (no new
# launches after the first failure; in-flight guests run to completion).
if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 403 )); then
	echo "run-tests.sh: --jobs needs bash 4.3 or newer (for wait -n)" >&2
	exit 2
fi
if [ "${have_flock}" -eq 0 ]; then
	echo "run-tests.sh: --jobs needs flock(1)" >&2
	exit 2
fi
rm -f "${logs}"/.status-*

run_and_record() # kernel test
{
	local kernel="$1"
	local test="$2"
	local rc

	if run_entry "${kernel}" "${test}"; then
		rc=0
	else
		rc=$?
	fi
	echo "${rc}" > "${logs}/.status-${kernel}-${test}"
	return "${rc}"
}

active=0
failed=0
for entry in "${entries[@]}"; do
	if [ "${failed}" -ne 0 ]; then
		break
	fi
	read -r kernel test <<< "${entry}"
	echo pending > "${logs}/.status-${kernel}-${test}"
	run_and_record "${kernel}" "${test}" &
	active=$((active + 1))
	if [ "${active}" -ge "${jobs}" ]; then
		if ! wait -n; then
			failed=1
		fi
		active=$((active - 1))
	fi
done
while [ "${active}" -gt 0 ]; do
	if ! wait -n; then
		failed=1
	fi
	active=$((active - 1))
done

passed=0
failed_count=0
interrupted=0
skipped=0
for entry in "${entries[@]}"; do
	read -r kernel test <<< "${entry}"
	status_file="${logs}/.status-${kernel}-${test}"
	if [ ! -e "${status_file}" ]; then
		skipped=$((skipped + 1))
	elif [ "$(cat "${status_file}")" = "pending" ]; then
		interrupted=$((interrupted + 1))
	elif [ "$(cat "${status_file}")" -eq 0 ]; then
		passed=$((passed + 1))
	else
		failed_count=$((failed_count + 1))
	fi
done
say "==> Summary: ${passed} passed, ${failed_count} failed, ${interrupted} interrupted, ${skipped} skipped"
for entry in "${entries[@]}"; do
	read -r kernel test <<< "${entry}"
	status_file="${logs}/.status-${kernel}-${test}"
	if [ ! -e "${status_file}" ]; then
		say "==>   skipped: ${kernel}:${test}"
	elif [ "$(cat "${status_file}")" = "pending" ]; then
		say "==>   interrupted: ${kernel}:${test}"
	elif [ "$(cat "${status_file}")" -eq 0 ]; then
		say "==>   ok: ${kernel}:${test}"
	else
		say "==>   FAILED: ${kernel}:${test}"
	fi
done
if [ "${failed}" -ne 0 ] || [ "${failed_count}" -ne 0 ] || [ "${interrupted}" -ne 0 ]; then
	exit 1
fi
exit 0
