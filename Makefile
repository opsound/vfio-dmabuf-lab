.PHONY: all build test clean

all: test

build:
	./scripts/build.sh

test: build
	./scripts/run-tests.sh all

clean:
	rm -rf -- "$(CURDIR)/out"
