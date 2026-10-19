APP      := C1Tune
BUNDLE   := build/$(APP).app
BINARY   := $(BUNDLE)/Contents/MacOS/$(APP)
SOURCES  := $(wildcard Sources/*.swift)
VERSION  := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
COMMIT   := $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
GENERATED := build/Version.swift

all: $(BINARY)

$(GENERATED): FORCE
	@mkdir -p build
	@printf 'let appVersion = "%s"\nlet appCommit = "%s"\n' "$(VERSION)" "$(COMMIT)" > $(GENERATED)

FORCE:

$(BINARY): $(SOURCES) $(GENERATED) Info.plist
	mkdir -p $(BUNDLE)/Contents/MacOS
	swiftc -O -swift-version 6 $(SOURCES) $(GENERATED) -o $(BINARY)
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)

run: all
	$(BINARY)

install: all
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/$(APP).app
	@echo "Installed to /Applications/$(APP).app — launch it with: open /Applications/$(APP).app"

# Update flow: rebuild from the current checkout, swap the installed app,
# and relaunch. Settings and login-item registration are preserved.
reinstall: all
	-pkill -x $(APP)
	$(MAKE) install
	open /Applications/$(APP).app
	@echo "Reinstalled and relaunched $(APP)."

uninstall:
	-/Applications/$(APP).app/Contents/MacOS/$(APP) --unregister-login-item
	-pkill -x $(APP)
	rm -rf /Applications/$(APP).app
	-defaults delete com.ryankirkman.c1tune
	@echo "Uninstalled $(APP) (app, login item, and preferences removed)."

# Offline protocol tests: encoders vs reference bytes, and firmware extraction from Opal.
test:
	@mkdir -p build
	swiftc -swift-version 6 Sources/DepthAI.swift Tests/main.swift -o build/tests
	build/tests Tests/fixtures

# Switch Opal Composer's login items, agents and helpers off (or back on). Opal stays installed.
disable-opal:
	scripts/disable-opal.sh

enable-opal:
	scripts/disable-opal.sh --undo

clean:
	rm -rf build

.PHONY: all run install reinstall uninstall test disable-opal enable-opal clean
