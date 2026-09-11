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

# 安装到 /usr/local/bin（可按需改 PREFIX）
PREFIX ?= /usr/local
install: $(BIN)
	install -d $(PREFIX)/bin
	install -m 755 $(BIN) $(PREFIX)/bin/music-cli

# 只读自检：不修改资料库，仅验证各读命令可用
test: $(BIN)
	@echo "--- verify (统计幽灵条目) ---"
	@$(BIN) verify || true
	@echo "--- find (模糊查，取前 5 条) ---"
	@$(BIN) find "" | head -5 || true

clean:
	rm -rf $(BUILD)
