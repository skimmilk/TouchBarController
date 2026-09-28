CC = clang
CFLAGS = -fobjc-arc -Wall -Wextra
BUILD_DIR = build
CLI = $(BUILD_DIR)/touchbarctl
APP = $(BUILD_DIR)/TouchBarController.app
APP_BINARY = $(APP)/Contents/MacOS/TouchBarController
INSTALL_APP = $(HOME)/Applications/TouchBarController.app
AGENT_PLIST = $(HOME)/Library/LaunchAgents/com.local.touchbar.controller.plist
AGENT_LABEL = local.touchbar.controller

.PHONY: all app install clean
all: $(CLI) $(APP_BINARY)
app: $(APP_BINARY)

$(CLI): CLI/main.m
	mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -framework Foundation -framework IOKit $< -o $@
	codesign --force --sign - $@

$(APP_BINARY): TouchBarController/main.m TouchBarController/GestureDetector.c TouchBarController/GestureDetector.h TouchBarController/Info.plist $(CLI)
	mkdir -p $(APP)/Contents/MacOS
	cp TouchBarController/Info.plist $(APP)/Contents/Info.plist
	cp $(CLI) $(APP)/Contents/MacOS/touchbarctl
	$(CC) $(CFLAGS) -fblocks -framework AppKit -framework ApplicationServices -framework Carbon -framework IOKit TouchBarController/main.m TouchBarController/GestureDetector.c -o $@
	codesign --force --sign - $(APP)

install: all
	@if launchctl print gui/$$(id -u)/$(AGENT_LABEL) >/dev/null 2>&1; then launchctl bootout gui/$$(id -u)/$(AGENT_LABEL); fi
	mkdir -p "$(HOME)/Applications" "$(HOME)/Library/LaunchAgents"
	rm -rf "$(INSTALL_APP)"
	ditto "$(APP)" "$(INSTALL_APP)"
	cp TouchBarController/LaunchAgent.plist "$(AGENT_PLIST)"
	plutil -replace ProgramArguments.0 -string "$(INSTALL_APP)/Contents/MacOS/TouchBarController" "$(AGENT_PLIST)"
	launchctl bootstrap gui/$$(id -u) "$(AGENT_PLIST)"

clean:
	rm -rf $(BUILD_DIR)
