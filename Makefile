BINARY_NAME = wireguard_go_bridge
SRC_DIR     = src
BUILD_DIR   = build
GO          = go

# Go build flags; src/exports.map leaves the bridge's exports global and
# every other symbol of the .so local.
GO_FLAGS    = -buildmode=c-shared -trimpath
GO_LDFLAGS  = -s -w -extldflags=-Wl,--version-script=$(CURDIR)/$(SRC_DIR)/exports.map

# Targets
.PHONY: all build-linux-amd64 build-linux-arm64 checksum verify clean go-tidy

all: build-linux-amd64

# --- Native Linux builds (run on Linux or in CI) ---

build-linux-amd64:
	@mkdir -p $(BUILD_DIR)/linux-amd64
	cd $(SRC_DIR) && \
	CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
	$(GO) build $(GO_FLAGS) -ldflags="$(GO_LDFLAGS)" \
		-o ../$(BUILD_DIR)/linux-amd64/$(BINARY_NAME).so .
	@echo "Built: $(BUILD_DIR)/linux-amd64/$(BINARY_NAME).so"
	@echo "Header: $(BUILD_DIR)/linux-amd64/$(BINARY_NAME).h"

build-linux-arm64:
	@mkdir -p $(BUILD_DIR)/linux-arm64
	cd $(SRC_DIR) && \
	CGO_ENABLED=1 GOOS=linux GOARCH=arm64 \
	CC=aarch64-linux-gnu-gcc \
	$(GO) build $(GO_FLAGS) -ldflags="$(GO_LDFLAGS)" \
		-o ../$(BUILD_DIR)/linux-arm64/$(BINARY_NAME).so .
	@echo "Built: $(BUILD_DIR)/linux-arm64/$(BINARY_NAME).so"

# --- Docker-based cross-compilation (from macOS) ---

docker-build-linux-amd64:
	docker run --rm \
		-v $(PWD):/workspace \
		-w /workspace \
		golang:1.27.3-trixie \
		make build-linux-amd64

docker-build-linux-arm64:
	docker run --rm \
		--platform linux/arm64 \
		-v $(PWD):/workspace \
		-w /workspace \
		golang:1.27.3-trixie \
		make build-linux-arm64

# --- Checksum ---

checksum:
	@echo "Generating checksums..."
	@cd $(BUILD_DIR) && find . -name "*.so" -exec sha256sum {} \; > CHECKSUMS.sha256
	@cat $(BUILD_DIR)/CHECKSUMS.sha256
	@echo "Checksums written to $(BUILD_DIR)/CHECKSUMS.sha256"

verify:
	@echo "Verifying checksums..."
	@cd $(BUILD_DIR) && sha256sum -c CHECKSUMS.sha256

# --- Go module ---

go-tidy:
	cd $(SRC_DIR) && $(GO) mod tidy

go-deps:
	cd $(SRC_DIR) && $(GO) mod download

# --- Inspect ---

inspect-symbols:
	@echo "=== Exported symbols ==="
	nm -D $(BUILD_DIR)/linux-amd64/$(BINARY_NAME).so 2>/dev/null | grep " T wg_" || true
	@echo ""
	@echo "=== Library info ==="
	file $(BUILD_DIR)/linux-amd64/$(BINARY_NAME).so 2>/dev/null || true

inspect-header:
	@echo "=== Generated C header ==="
	@cat $(BUILD_DIR)/linux-amd64/$(BINARY_NAME).h 2>/dev/null || echo "Header not found. Build first."

# --- Clean ---

clean:
	rm -rf $(BUILD_DIR)
	cd $(SRC_DIR) && $(GO) clean -cache