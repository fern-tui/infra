# Custom Go binary locations
GO    := <CUSTOM_PATH>
GOFMT := <CUSTOM_PATH>
BIN     := zcm
CMD     := ./cmd/zcm
VERSION ?= 0.0.045-beta.10

LDFLAGS := -s -w -X 'zig-cache-manager/internal/cli.Version=$(VERSION)'
BUILD   := CGO_ENABLED=0 $(GO) build -trimpath -tags netgo,osusergo -ldflags="$(LDFLAGS)"

.PHONY: all build test test-race vet fmt clean install dist

all: build

## build: static stripped binary for the current platform.
build:
	$(BUILD) -o $(BIN) $(CMD)

## test: run all tests (no cache).
test:
	$(GO) test -count=1 ./...

## test-race: run all tests with the race detector.
test-race:
	$(GO) test -count=1 -race ./...

## vet: go vet across all packages.
vet:
	$(GO) vet ./...

## fmt: gofmt all source files in place.
fmt:
	$(GOFMT) -s -w .

## clean: remove build artifacts.
clean:
	rm -rf bin/ $(BIN)

## install: install to $GOPATH/bin (or $GOBIN).
install:
	CGO_ENABLED=0 $(GO) install -trimpath -tags netgo,osusergo -ldflags="$(LDFLAGS)" $(CMD)

## dist: cross-compile static binaries for all supported targets.
dist:
	@mkdir -p bin
	@echo "Building for Linux (x86_64)..."
	GOOS=linux   GOARCH=amd64 $(BUILD) -o bin/$(BIN)-linux-amd64   $(CMD)
	@echo "Building for Linux (arm64)..."
	GOOS=linux   GOARCH=arm64 $(BUILD) -o bin/$(BIN)-linux-arm64   $(CMD)
	@echo "Building for macOS (Apple Silicon)..."
	GOOS=darwin  GOARCH=arm64 $(BUILD) -o bin/$(BIN)-darwin-arm64  $(CMD)
	@echo "Building for macOS (Intel)..."
	GOOS=darwin  GOARCH=amd64 $(BUILD) -o bin/$(BIN)-darwin-amd64  $(CMD)
	@echo "Building for Windows (x86_64)..."
	GOOS=windows GOARCH=amd64 $(BUILD) -o bin/$(BIN)-windows-amd64.exe $(CMD)
	@echo "Done! Check bin/"
	@ls -lh bin/

## help: list available targets.
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
