# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  AI CLI — Makefile                                                          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

SHELL       := /bin/bash
PREFIX      ?= /usr/local
BINDIR      := $(PREFIX)/bin
SHAREDIR    := $(PREFIX)/share/ai-cli
VERSION     := $(shell grep -m1 '^VERSION=' src/lib/00-env.sh | cut -d'"' -f2)
OUTPUT      := dist/ai

.PHONY: all build install uninstall dev clean verify lint help

## Default target
all: build

## ── Build ────────────────────────────────────────────────────────────────────

## Assemble src/lib/*.sh modules into dist/ai (single distributable binary)
build:
	@bash build/build.sh --output $(OUTPUT)

## Build + run syntax verification
verify:
	@bash build/build.sh --output $(OUTPUT) --verify

## ── Development ──────────────────────────────────────────────────────────────

## Run directly from source (no build needed — fast iteration)
dev:
	@bash src/main.sh $(filter-out $@,$(MAKECMDGOALS))

## Check bash syntax on all source files
lint:
	@echo "Checking syntax of all source modules..."
	@errors=0; \
	for f in src/lib/*.sh; do \
	  if bash -n "$$f" 2>&1; then \
	    printf "  ✓ %-35s OK\n" "$$(basename $$f)"; \
	  else \
	    printf "  ✗ %-35s FAIL\n" "$$(basename $$f)" >&2; \
	    errors=$$((errors+1)); \
	  fi; \
	done; \
	if [[ $$errors -gt 0 ]]; then \
	  echo "  $$errors file(s) with syntax errors" >&2; exit 1; \
	else \
	  echo "  All modules OK"; \
	fi

## ── Install ──────────────────────────────────────────────────────────────────

## Install dist/ai to PREFIX/bin (default: /usr/local/bin/ai)
install: build
	@echo "Installing AI CLI v$(VERSION) to $(BINDIR)/ai"
	@install -d $(BINDIR)
	@install -m 0755 $(OUTPUT) $(BINDIR)/ai
	@echo "  ✓ Installed: $(BINDIR)/ai"
	@echo ""
	@echo "  Run 'ai install-deps' to set up Python dependencies"

## Install for development: symlink src/main.sh so edits take effect instantly
install-dev:
	@echo "Installing development symlink: $(BINDIR)/ai → $(CURDIR)/src/main.sh"
	@install -d $(BINDIR)
	@ln -sf "$(CURDIR)/src/main.sh" $(BINDIR)/ai
	@echo "  ✓ Dev symlink installed. Edit src/lib/*.sh and changes are instant."

## Uninstall
uninstall:
	@echo "Removing $(BINDIR)/ai"
	@rm -f $(BINDIR)/ai
	@echo "  ✓ Uninstalled"
	@echo "  Note: config/models in ~/.config/ai-cli and ~/.ai-cli/models are kept"

## ── Packaging ────────────────────────────────────────────────────────────────

## Create release archive: dist/ai-cli-vVERSION.tar.gz
release: build
	@echo "Creating release archive for v$(VERSION)..."
	@tar czf dist/ai-cli-v$(VERSION).tar.gz \
	  -C dist ai \
	  --transform 's|^ai$$|ai-cli-v$(VERSION)/ai|'
	@echo "  ✓ dist/ai-cli-v$(VERSION).tar.gz"

## ── Housekeeping ─────────────────────────────────────────────────────────────

## Remove build artifacts
clean:
	@rm -rf dist/
	@echo "  ✓ dist/ removed"

## Show this help
help:
	@echo ""
	@echo "  AI CLI v$(VERSION) — Build targets"
	@echo ""
	@printf "  %-20s %s\n" "make build"       "Assemble dist/ai from src/lib/*.sh"
	@printf "  %-20s %s\n" "make verify"      "Build + syntax check"
	@printf "  %-20s %s\n" "make install"     "Install to $(BINDIR)/ai"
	@printf "  %-20s %s\n" "make install-dev" "Symlink src/main.sh (for hacking)"
	@printf "  %-20s %s\n" "make uninstall"   "Remove from $(BINDIR)"
	@printf "  %-20s %s\n" "make dev CMD=ask" "Run from source (fast iteration)"
	@printf "  %-20s %s\n" "make lint"        "Check bash syntax on all modules"
	@printf "  %-20s %s\n" "make release"     "Create dist/ai-cli-v$(VERSION).tar.gz"
	@printf "  %-20s %s\n" "make clean"       "Remove dist/"
	@echo ""
	@echo "  Modules in src/lib/: $(words $(wildcard src/lib/*.sh))"
	@echo ""

# Allow 'make dev ask "some question"' style invocation
%:
	@:
