#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Fast QEMU-free checks for the run-tests.sh harness: matrix enumeration and
# flag validation. Needs no build artifacts and no KVM.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
runner="${root}/scripts/run-tests.sh"
fail=0

check() # name expected actual
{
	if [ "$2" = "$3" ]; then
		echo "ok: $1"
	else
		echo "NOT OK: $1"
		echo "--- expected ---"
		echo "$2"
		echo "--- actual ---"
		echo "$3"
		fail=1
	fi
}

expect_fail() # name args...
{
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		echo "NOT OK: ${name} (expected failure, got success)"
		fail=1
	else
		echo "ok: ${name}"
	fi
}

all="v7:nvgrace-v7
v7:dmabuf
v5:nvgrace-v5
rc6:dmabuf-opath-uaf
rc6-fix:dmabuf-opath-uaf
rc6-annul:dmabuf-opath-uaf
v8:dmabuf-v8
v8:dmabuf-opath-uaf
v8-annul:dmabuf-v8
v8-annul:dmabuf-opath-uaf
v8:nvgrace-v7
v8-annul:nvgrace-v7"
check "dry-run all" "${all}" "$("${runner}" --dry-run all)"
check "dry-run all with --jobs" "${all}" "$("${runner}" --jobs 4 --dry-run all)"
check "dry-run default selection" "${all}" "$("${runner}" --dry-run)"

check "dry-run kernel" "v7:nvgrace-v7
v7:dmabuf" "$("${runner}" --dry-run v7)"

# A bare test name runs every matrix entry for that test.
check "dry-run test" "v7:dmabuf" "$("${runner}" --dry-run dmabuf)"
check "dry-run test, several kernels" "rc6:dmabuf-opath-uaf
rc6-fix:dmabuf-opath-uaf
rc6-annul:dmabuf-opath-uaf
v8:dmabuf-opath-uaf
v8-annul:dmabuf-opath-uaf" "$("${runner}" --dry-run dmabuf-opath-uaf)"
check "dry-run kernel rc6-fix" "rc6-fix:dmabuf-opath-uaf" "$("${runner}" --dry-run rc6-fix)"
check "dry-run k:t" "v5:nvgrace-v5" "$("${runner}" --dry-run v5:nvgrace-v5)"

expect_fail "dry-run unknown k:t" "${runner}" --dry-run v5:dmabuf
expect_fail "dry-run unknown k:t, new kernel" "${runner}" --dry-run rc6:dmabuf
expect_fail "dry-run unknown selection" "${runner}" --dry-run bogus
expect_fail "dry-run empty k:t part" "${runner}" --dry-run 'v7:'
expect_fail "jobs 0" "${runner}" --jobs 0 all
expect_fail "jobs non-numeric" "${runner}" --jobs x all
expect_fail "jobs missing value" "${runner}" --jobs
expect_fail "bogus flag" "${runner}" --frobnicate all
expect_fail "extra selection" "${runner}" v7 v5

if [ "${fail}" -ne 0 ]; then
	exit 1
fi
echo "selftest: all checks passed"
