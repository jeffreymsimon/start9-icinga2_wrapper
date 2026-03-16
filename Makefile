# Icinga2 StartOS 0.4.0 Package Makefile
#
# Build and deployment automation for Icinga2 s9pk package
#
# Usage:
#   make          - Build the s9pk package
#   make install  - Deploy to local StartOS server
#   make clean    - Remove build artifacts
#   make verify   - Inspect the built package
#

# StartOS 0.4.0 CLI location
START_CLI := $(shell command -v start-cli 2>/dev/null || echo "$(HOME)/.local/bin/start-cli")

PACKAGE_ID := $(shell awk -F"'" '/id:/ {print $$2}' startos/manifest.ts)
INGREDIENTS := $(shell $(START_CLI) s9pk list-ingredients 2>/dev/null)

.PHONY: all aarch64 x86_64 riscv64 arm arm64 x86 riscv arch/* clean install verify check-deps check-init package ingredients

.DELETE_ON_ERROR:
.SECONDARY:

# ============================================================
# Build Summary Display
# ============================================================

define SUMMARY
	@manifest=$$($(START_CLI) s9pk inspect $(1) manifest); \
	size=$$(du -h $(1) | awk '{print $$1}'); \
	title=$$(printf '%s' "$$manifest" | jq -r .title); \
	version=$$(printf '%s' "$$manifest" | jq -r .version); \
	arches=$$(printf '%s' "$$manifest" | jq -r '[.images[].arch // []] | flatten | unique | join(", ")'); \
	sdkv=$$(printf '%s' "$$manifest" | jq -r .sdkVersion); \
	gitHash=$$(printf '%s' "$$manifest" | jq -r .gitHash | sed -E 's/(.*-modified)$$/\x1b[0;31m\1\x1b[0m/'); \
	printf "\n"; \
	printf "\033[1;32m✅ Build Complete!\033[0m\n"; \
	printf "\n"; \
	printf "\033[1;37m📦 $$title\033[0m   \033[36mv$$version\033[0m\n"; \
	printf "───────────────────────────────\n"; \
	printf " \033[1;36mFilename:\033[0m   %s\n" "$(1)"; \
	printf " \033[1;36mSize:\033[0m       %s\n" "$$size"; \
	printf " \033[1;36mArch:\033[0m       %s\n" "$$arches"; \
	printf " \033[1;36mSDK:\033[0m        %s\n" "$$sdkv"; \
	printf " \033[1;36mGit:\033[0m        %s\n" "$$gitHash"; \
	echo ""
endef

# ============================================================
# Build Targets
# ============================================================

all: $(PACKAGE_ID).s9pk
	$(call SUMMARY,$<)

arch/%: $(PACKAGE_ID)_%.s9pk
	$(call SUMMARY,$<)

x86 x86_64: arch/x86_64
arm arm64 aarch64: arch/aarch64
riscv riscv64: arch/riscv64

$(PACKAGE_ID).s9pk: $(INGREDIENTS) .git/HEAD .git/index
	@$(MAKE) --no-print-directory ingredients
	@echo "   Packing '$@'..."
	$(START_CLI) s9pk pack -o $@

$(PACKAGE_ID)_%.s9pk: $(INGREDIENTS) .git/HEAD .git/index
	@$(MAKE) --no-print-directory ingredients
	@echo "   Packing '$@' for $* architecture..."
	$(START_CLI) s9pk pack --arch=$* -o $@

ingredients: $(INGREDIENTS)
	@echo "   Validating build ingredients..."

# ============================================================
# Deployment Targets
# ============================================================

install: | check-deps check-init
	@HOST=$$(awk -F'/' '/^host:/ {print $$3}' ~/.startos/config.yaml); \
	if [ -z "$$HOST" ]; then \
		echo "Error: You must define \"host: http://server-name.local\" in ~/.startos/config.yaml"; \
		exit 1; \
	fi; \
	S9PK=$$(ls -t *.s9pk 2>/dev/null | head -1); \
	if [ -z "$$S9PK" ]; then \
		echo "Error: No .s9pk file found. Run 'make' first."; \
		exit 1; \
	fi; \
	printf "\n🚀 Installing %s to %s ...\n" "$$S9PK" "$$HOST"; \
	$(START_CLI) package install -s "$$S9PK"

verify:
	@S9PK=$$(ls -t *.s9pk 2>/dev/null | head -1); \
	if [ -z "$$S9PK" ]; then \
		echo "Error: No .s9pk file found. Run 'make' first."; \
		exit 1; \
	fi; \
	echo "Inspecting $$S9PK..."; \
	$(START_CLI) s9pk inspect "$$S9PK"

# ============================================================
# Dependency Checks
# ============================================================

check-deps:
	@command -v $(START_CLI) >/dev/null || \
		(echo "Error: $(START_CLI) not found. Please see https://docs.start9.com/latest/developer-guide/sdk/installing-the-sdk" && exit 1)
	@command -v npm >/dev/null || \
		(echo "Error: npm not found. Please install Node.js and npm." && exit 1)
	@command -v jq >/dev/null || \
		(echo "Error: jq not found. Please install jq." && exit 1)

check-init:
	@if [ ! -f ~/.startos/developer.key.pem ]; then \
		echo "Initializing StartOS developer environment..."; \
		$(START_CLI) init-key; \
	fi

# ============================================================
# Build Dependencies
# ============================================================

javascript/index.js: $(shell find startos -type f) tsconfig.json node_modules
	npm run build

node_modules: package-lock.json
	npm ci

package-lock.json: package.json
	npm i

# ============================================================
# Cleanup
# ============================================================

clean:
	@echo "Cleaning up build artifacts..."
	@rm -rf $(PACKAGE_ID).s9pk $(PACKAGE_ID)_x86_64.s9pk $(PACKAGE_ID)_aarch64.s9pk $(PACKAGE_ID)_riscv64.s9pk javascript node_modules
	@echo "Clean complete."

# ============================================================
# Development Helpers
# ============================================================

typecheck:
	npm run check

format:
	npm run prettier

info:
	@echo "Package ID: $(PACKAGE_ID)"
	@echo "Build ingredients: $(INGREDIENTS)"
