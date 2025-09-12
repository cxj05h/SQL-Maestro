.PHONY: debug run release dist clean

DERIVED=./build
APPDBG=$(DERIVED)/Build/Products/Debug/SQLMaestro.app
APPREL=$(DERIVED)/Build/Products/Release/SQLMaestro.app
SCHEME=SQLMaestro
ARCH=arm64
VERSION?=v0.1.0-unsigned

debug:
	@echo "Building Debug to $(DERIVED)..."
	xcodebuild -scheme $(SCHEME) -configuration Debug \
	  -destination 'platform=macOS,arch=$(ARCH)' \
	  -derivedDataPath $(DERIVED) \
	  build

run: debug
	@echo "Opening $(APPDBG)..."
	open "$(APPDBG)"

release:
	@echo "Building Release to $(DERIVED)..."
	xcodebuild -scheme $(SCHEME) -configuration Release \
	  -destination 'platform=macOS,arch=$(ARCH)' \
	  -derivedDataPath $(DERIVED) \
	  build

dist: release
	@echo "Zipping to dist/SQLMaestro-$(VERSION).zip..."
	mkdir -p dist
	cd $(DERIVED)/Build/Products/Release && zip -r ../../../../dist/SQLMaestro-$(VERSION).zip SQLMaestro.app

clean:
	@echo "Removing $(DERIVED)..."
	rm -rf $(DERIVED)
