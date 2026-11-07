# Antigravity Code — build entry points
#   make build        debug build for the host architecture
#   make test         run unit tests
#   make universal    release arm64 + x86_64 binaries merged with lipo (.build/universal)
#   make app          dist/Antigravity Code.app (Universal 2, ad-hoc or Developer ID signed)
#   make dmg          dist/AntigravityCode-<ver>-universal.dmg (notarized if NOTARY_PROFILE is set)
#   make install-cli  symlink the bundled agcode into /usr/local/bin
#   make run          launch the GUI from the build tree

.PHONY: build test universal app dmg install-cli run clean

build:
	swift build

test:
	swift test

universal:
	./scripts/build-universal.sh universal

app:
	./scripts/build-universal.sh app

dmg:
	./scripts/build-universal.sh dmg

install-cli: app
	sudo mkdir -p /usr/local/bin
	sudo ln -sf "$(CURDIR)/dist/Antigravity Code.app/Contents/Helpers/agcode" /usr/local/bin/agcode
	@echo "agcode installed → /usr/local/bin/agcode"

run:
	swift run AntigravityCodeApp

clean:
	rm -rf .build dist
