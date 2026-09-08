.PHONY: all build test clean

all: test

build:
	./scripts/build.sh

test: build
	./scripts/run-tests.sh all

clean:
	rm -rf -- "$(CURDIR)/out/linux" "$(CURDIR)/out/linux-v5" "$(CURDIR)/out/linux-v6" \
		"$(CURDIR)/out/linux-david-base" "$(CURDIR)/out/linux-david-fix" \
		"$(CURDIR)/out/qemu" "$(CURDIR)/out/tests" \
		"$(CURDIR)/out/headers" "$(CURDIR)/out/rootfs" \
		"$(CURDIR)/out/logs" "$(CURDIR)/out/initramfs.cpio.gz"
