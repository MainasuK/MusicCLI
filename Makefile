CC      ?= clang
CFLAGS  ?= -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter
FRAMEWORKS = -framework Foundation -framework iTunesLibrary
BUILD   := build
BIN     := $(BUILD)/music-cli
SRC     := Sources/main.m

.PHONY: all clean install test

all: $(BIN)

$(BIN): $(SRC) | $(BUILD)
	$(CC) $(CFLAGS) $(FRAMEWORKS) -o $@ $<

$(BUILD):
	mkdir -p $(BUILD)

# Install into /usr/local/bin (override with PREFIX=...)
PREFIX ?= /usr/local
install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/music-cli

# Read-only self-check: never modifies the library, only exercises the read commands.
test: $(BIN)
	@echo "--- verify (count ghost entries) ---"
	@$(BIN) verify || true
	@echo "--- find (fuzzy search, first 5) ---"
	@$(BIN) find "" | head -5 || true

clean:
	rm -rf $(BUILD)
