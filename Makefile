.PHONY: run build clean release

# Default target
run:
	zig build run

build:
	zig build

release:
	zig build -Doptimize=ReleaseFast

clean:
	rm -rf zig-out .zig-cache
