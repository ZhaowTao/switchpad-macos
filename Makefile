CC ?= clang
CFLAGS ?= -O2 -Wall -Wextra -std=c11 -Iinclude
FW = -framework Foundation -framework IOKit -framework CoreFoundation

all: build/t_swrumble build/swr-haptic

build:
	@mkdir -p build

build/swrumble.o: src/swrumble.c include/swrumble.h | build
	$(CC) $(CFLAGS) -c $< -o $@

build/t_swrumble: tests/t_swrumble.c build/swrumble.o | build
	$(CC) $(CFLAGS) $< build/swrumble.o -o $@

build/swr-haptic: tools/swr-haptic.m build/swrumble.o | build
	$(CC) -fobjc-arc $(CFLAGS) $< build/swrumble.o $(FW) -o $@

build/probe: tools/probe/probe.m | build
	$(CC) -fobjc-arc $(CFLAGS) $< $(FW) -o $@

test: build/t_swrumble
	@./build/t_swrumble

clean:
	rm -rf build

.PHONY: all test clean
