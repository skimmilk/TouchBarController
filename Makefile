CC = clang
CFLAGS = -fobjc-arc -Wall -Wextra
BUILD_DIR = build
CLI = $(BUILD_DIR)/touchbarctl
APP = $(BUILD_DIR)/TouchBarController.app
APP_BINARY = $(APP)/Contents/MacOS/TouchBarController
INSTALL_APP = $(HOME)/Applications/TouchBarController.app
INSTALLED_BINARY = $(INSTALL_APP)/Contents/MacOS/TouchBarController
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
	$(CC) $(CFLAGS) -fblocks -framework AppKit -framework ApplicationServices -framework Carbon TouchBarController/main.m TouchBarController/GestureDetector.c -o $@
	codesign --force --sign - $(APP)

install: all
	@if launchctl print gui/$$(id -u)/$(AGENT_LABEL) >/dev/null 2>&1; then launchctl bootout gui/$$(id -u)/$(AGENT_LABEL); fi
	@pkill -TERM -u $$(id -u) -f -x "$(INSTALLED_BINARY)" 2>/dev/null; result=$$?; if [ $$result -gt 1 ]; then echo "Could not stop Touch Bar Controller" >&2; exit $$result; fi
	@for attempt in 1 2 3 4 5; do \
		pgrep -u $$(id -u) -f -x "$(INSTALLED_BINARY)" >/dev/null 2>&1; result=$$?; \
		if [ $$result -eq 1 ]; then exit 0; fi; \
		if [ $$result -ne 0 ]; then echo "Could not check whether Touch Bar Controller exited" >&2; exit $$result; fi; \
		sleep 1; \
	done; \
	echo "Touch Bar Controller did not exit; installation stopped" >&2; exit 1
	mkdir -p "$(HOME)/Applications" "$(HOME)/Library/LaunchAgents"
	rm -rf "$(INSTALL_APP)"
	ditto "$(APP)" "$(INSTALL_APP)"
	cp TouchBarController/LaunchAgent.plist "$(AGENT_PLIST)"
	plutil -insert ProgramArguments.0 -string "$(INSTALLED_BINARY)" "$(AGENT_PLIST)"
	@tccutil reset Accessibility $(AGENT_LABEL) || echo "Warning: could not reset Accessibility access for $(AGENT_LABEL)" >&2
	@tccutil reset PostEvent $(AGENT_LABEL) || echo "Warning: could not reset keyboard event-posting access for $(AGENT_LABEL)" >&2
	launchctl bootstrap gui/$$(id -u) "$(AGENT_PLIST)"

clean:
	rm -rf $(BUILD_DIR)
