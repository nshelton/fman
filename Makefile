CC = clang
CFLAGS = -O3 -g -Wall -Wextra -Werror -mmacosx-version-min=13.0
APP = build/Fman.app
SIGN_IDENTITY ?= Fman Development

.PHONY: all run test clean setup-signing
all: $(APP)/Contents/MacOS/Fman build/fman-scan

build/scanner.o: src/scanner.c src/scanner.h
	mkdir -p build
	$(CC) $(CFLAGS) -std=c11 -c $< -o $@

build/disk_health.o: src/disk_health.c src/disk_health.h
	mkdir -p build
	$(CC) $(CFLAGS) -std=c11 -c $< -o $@

$(APP)/Contents/MacOS/Fman: src/app.m src/disk_health.h build/scanner.o build/disk_health.o Info.plist Makefile
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	$(CC) $(CFLAGS) -fobjc-arc -framework Cocoa -framework IOKit src/app.m build/scanner.o build/disk_health.o -o $@
	codesign --force --sign "$(SIGN_IDENTITY)" $(APP)

setup-signing:
	/bin/sh scripts/setup-signing.sh

build/fman-scan: src/cli.c build/scanner.o
	$(CC) $(CFLAGS) $^ -o $@

build/scanner-test: tests/scanner_test.c build/scanner.o
	$(CC) $(CFLAGS) $^ -o $@

test: build/scanner-test
	./build/scanner-test

run: all
	open $(APP)

clean:
	rm -rf build
