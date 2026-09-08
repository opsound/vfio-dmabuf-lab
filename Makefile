.PHONY: all build test clean fetch kernels

KERNELS := v5 v6 david-base david-fix
# Ninja cannot join make's jobserver, so QEMU takes a fixed slice on top
# of the shared pool. Overridable: make build QEMU_JOBS=16.
QEMU_JOBS ?= 8
export QEMU_JOBS
# Test guests per run-tests.sh invocation. Builds parallelize by default;
# test runs stay serial unless requested: make test TEST_JOBS=4.
TEST_JOBS ?= 1

all: test

# fetch (serial git) runs first; the four kernels and QEMU then build in
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

headers: kernel-v6
	+./scripts/build.sh headers

testsuite: headers
	./scripts/build.sh tests

initramfs: testsuite
	./scripts/build.sh initramfs

test: build
	./scripts/selftest.sh
	./scripts/run-tests.sh --jobs $(TEST_JOBS) all

clean:
	rm -rf -- "$(CURDIR)/out/linux" "$(CURDIR)/out/linux-v5" "$(CURDIR)/out/linux-v6" \
		"$(CURDIR)/out/linux-david-base" "$(CURDIR)/out/linux-david-fix" \
		"$(CURDIR)/out/qemu" "$(CURDIR)/out/tests" \
		"$(CURDIR)/out/headers" "$(CURDIR)/out/rootfs" \
		"$(CURDIR)/out/logs" "$(CURDIR)/out/initramfs.cpio.gz"
