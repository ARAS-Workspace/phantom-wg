BINARY_NAME = compose_bridge
GO_FLAGS    = -buildmode=c-shared -trimpath
GO_LDFLAGS  = -s -w

# Signing identity: ad-hoc (-) for dev, "Developer ID Application" for production
CODESIGN_IDENTITY ?= -

.PHONY: build-darwin-arm64 build-linux-amd64 build-linux-arm64 \
        docker-build-linux-amd64 docker-build-linux-arm64 clean

# --- Host builds (macOS) ---

build-darwin-arm64:
	mkdir -p build/darwin-arm64
	cd src && CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 \
		go build $(GO_FLAGS) -ldflags="$(GO_LDFLAGS)" \
		-o ../build/darwin-arm64/$(BINARY_NAME).dylib .
	codesign --force --sign "$(CODESIGN_IDENTITY)" \
		build/darwin-arm64/$(BINARY_NAME).dylib

# --- Linux cross-compile ---

build-linux-amd64:
	mkdir -p build/linux-amd64
	cd src && CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
		go build $(GO_FLAGS) -ldflags="$(GO_LDFLAGS)" \
		-o ../build/linux-amd64/$(BINARY_NAME).so .

build-linux-arm64:
	mkdir -p build/linux-arm64
	cd src && CC=aarch64-linux-gnu-gcc \
		CGO_ENABLED=1 GOOS=linux GOARCH=arm64 \
		go build $(GO_FLAGS) -ldflags="$(GO_LDFLAGS)" \
		-o ../build/linux-arm64/$(BINARY_NAME).so .

# --- Docker builds (Linux targets from any host) ---

docker-build-linux-amd64:
	docker run --rm -v $(PWD):/workspace -w /workspace \
		golang:1.27.3-trixie make build-linux-amd64

docker-build-linux-arm64:
	docker run --rm -v $(PWD):/workspace -w /workspace \
		golang:1.27.3-trixie make build-linux-arm64

clean:
	rm -rf build/