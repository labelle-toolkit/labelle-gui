.PHONY: all build test run clean release release-all release-linux release-macos release-macos-arm release-windows release-native

# Default target
all: build

# Development build
build:
	zig build

# Run tests
test:
	zig build test

# Run the application
run:
	zig build run

# Clean build artifacts
clean:
	rm -rf zig-out .zig-cache release

# Quick release (native platform, optimized)
release:
	zig build -Doptimize=ReleaseSafe

# Build all platform releases
release-all: release-linux release-macos release-macos-arm release-windows
	@echo "All releases built in release/"

release-linux:
	@echo "Building for Linux x86_64..."
	zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu -Dcpu=baseline
	@mkdir -p release/linux
	cp zig-out/bin/labelle-gui release/linux/
	cp -r assets release/linux/
	cd release/linux && tar -czvf ../labelle-gui-linux-x86_64.tar.gz .
	@echo "Created release/labelle-gui-linux-x86_64.tar.gz"

release-macos:
	@echo "Building for macOS x86_64..."
	zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos -Dcpu=baseline
	@mkdir -p release/macos-x86_64
	cp zig-out/bin/labelle-gui release/macos-x86_64/
	cp -r assets release/macos-x86_64/
	cd release/macos-x86_64 && zip -r ../labelle-gui-macos-x86_64.zip .
	@echo "Created release/labelle-gui-macos-x86_64.zip"

release-macos-arm:
	@echo "Building for macOS ARM64..."
	zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
	@mkdir -p release/macos-arm64
	cp zig-out/bin/labelle-gui release/macos-arm64/
	cp -r assets release/macos-arm64/
	cd release/macos-arm64 && zip -r ../labelle-gui-macos-aarch64.zip .
	@echo "Created release/labelle-gui-macos-aarch64.zip"

release-windows:
	@echo "Building for Windows x86_64..."
	zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows-gnu -Dcpu=baseline
	@mkdir -p release/windows
	cp zig-out/bin/labelle-gui.exe release/windows/
	cp -r assets release/windows/
	cd release/windows && zip -r ../labelle-gui-windows-x86_64.zip .
	@echo "Created release/labelle-gui-windows-x86_64.zip"

release-native:
	@echo "Building native release..."
	zig build -Doptimize=ReleaseSafe
	@mkdir -p release/native
	cp zig-out/bin/labelle-gui* release/native/
	cp -r assets release/native/
	@echo "Built to release/native/"
