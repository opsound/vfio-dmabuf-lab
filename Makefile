.PHONY: all build test clean fetch kernels

KERNELS := v5 v7 rc6 rc6-fix rc6-annul v8 v8-annul
# Ninja cannot join make's jobserver, so QEMU takes a fixed slice on top
# of the shared pool. Overridable: make build QEMU_JOBS=16.
QEMU_JOBS ?= 8
export QEMU_JOBS
# Test guests per run-tests.sh invocation. Builds parallelize by default;
# test runs stay serial unless requested: make test TEST_JOBS=4.
TEST_JOBS ?= 1

all: test

# fetch (serial git) runs first; the kernels and QEMU then build in
# parallel sharing one jobserver pool, followed by the serial tail.
build: kernels qemu testsuite initramfs
	@echo "Build complete: $(CURDIR)/out"

fetch:
	./scripts/build.sh fetch

kernels: $(addprefix kernel-,$(KERNELS))

$(addprefix kernel-,$(KERNELS)): fetch

# The '+' marks recipes that (transitively) invoke make: without it, make
# closes the jobserver pipe for the recipe child, so submakes behind the
# script wrapper could not join the pool ("jobserver unavailable: -j1").
kernel-%:
	+./scripts/build.sh kernel $*

qemu: fetch
	./scripts/build.sh qemu

headers: kernel-v7
	+./scripts/build.sh headers

headers-v8: kernel-v8
	+./scripts/build.sh headers-v8

testsuite: headers headers-v8
	./scripts/build.sh tests

initramfs: testsuite
	./scripts/build.sh initramfs

test: build
	./scripts/selftest.sh
	./scripts/run-tests.sh --jobs $(TEST_JOBS) all

clean:
	rm -rf -- "$(CURDIR)/out/linux" "$(CURDIR)/out/linux-v5" "$(CURDIR)/out/linux-v7" \
		"$(CURDIR)/out/linux-rc6" "$(CURDIR)/out/linux-rc6-fix" \
		"$(CURDIR)/out/linux-rc6-annul" \
		"$(CURDIR)/out/linux-v8" "$(CURDIR)/out/linux-v8-annul" \
		"$(CURDIR)/out/headers-v8" \
		"$(CURDIR)/out/qemu" "$(CURDIR)/out/tests" \
		"$(CURDIR)/out/headers" "$(CURDIR)/out/rootfs" \
		"$(CURDIR)/out/logs" "$(CURDIR)/out/initramfs.cpio.gz"
