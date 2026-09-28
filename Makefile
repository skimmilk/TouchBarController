CC = clang
CFLAGS = -fobjc-arc -Wall -Wextra
BUILD_DIR = build
CLI = $(BUILD_DIR)/touchbarctl
APP = $(BUILD_DIR)/TouchBarController.app
APP_BINARY = $(APP)/Contents/MacOS/TouchBarController
INSTALL_APP = $(HOME)/Applications/TouchBarController.app
INSTALLED_BINARY = $(INSTALL_APP)/Contents/MacOS/TouchBarController
INSTALLED_CLI = $(INSTALL_APP)/Contents/MacOS/touchbarctl
AGENT_PLIST = $(HOME)/Library/LaunchAgents/com.local.touchbar.controller.plist
AGENT_LABEL = local.touchbar.controller

.PHONY: all app install uninstall clean
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

uninstall:
	@if launchctl print gui/$$(id -u)/$(AGENT_LABEL) >/dev/null 2>&1; then launchctl bootout gui/$$(id -u)/$(AGENT_LABEL); fi
	@pkill -TERM -u $$(id -u) -f -x "$(INSTALLED_BINARY)" 2>/dev/null; result=$$?; if [ $$result -gt 1 ]; then echo "Could not stop Touch Bar Controller" >&2; exit $$result; fi
	@for attempt in 1 2 3 4 5; do \
		pgrep -u $$(id -u) -f -x "$(INSTALLED_BINARY)" >/dev/null 2>&1; result=$$?; \
		if [ $$result -eq 1 ]; then exit 0; fi; \
		if [ $$result -ne 0 ]; then echo "Could not check whether Touch Bar Controller exited" >&2; exit $$result; fi; \
		sleep 1; \
	done; \
	echo "Touch Bar Controller did not exit; uninstall stopped" >&2; exit 1
	@if [ -x "$(INSTALLED_CLI)" ]; then "$(INSTALLED_CLI)" on || echo "Warning: could not restore Touch Bar backlight" >&2; \
	elif [ -x "$(CLI)" ]; then "$(CLI)" on || echo "Warning: could not restore Touch Bar backlight" >&2; \
	else echo "Warning: touchbarctl is unavailable; could not restore Touch Bar backlight" >&2; fi
	@tccutil reset Accessibility $(AGENT_LABEL) || echo "Warning: could not reset Accessibility access for $(AGENT_LABEL)" >&2
	@tccutil reset PostEvent $(AGENT_LABEL) || echo "Warning: could not reset keyboard event-posting access for $(AGENT_LABEL)" >&2
	@if defaults read "$(AGENT_LABEL)" >/dev/null 2>&1; then defaults delete "$(AGENT_LABEL)"; fi
	rm -f "$(AGENT_PLIST)" "$(HOME)/Library/Preferences/$(AGENT_LABEL).plist"
	rm -rf "$(INSTALL_APP)" "$(HOME)/Library/Caches/$(AGENT_LABEL)" "$(HOME)/Library/Saved Application State/$(AGENT_LABEL).savedState" "$(HOME)/Library/HTTPStorages/$(AGENT_LABEL)"
	$(MAKE) clean

clean:
	rm -rf $(BUILD_DIR)
