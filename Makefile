# Override with SIM=<simulator name or UDID> when several runtimes are installed.
SIM ?= iPhone 16 Pro

# Signing / connected-device install. Override TEAM or DEVICE as needed.
TEAM ?= QML5B57EMH
DEVICE ?= 00008101-001971222298001E

.PHONY: build app run server test thunderbird-import ios-project ios-build ios-run device-build device-install docs docs-build clean

# Pass CLI arguments with ARGS, for example: make thunderbird-import ARGS="list"
ARGS ?=

build:
	swift build

app:
	./Scripts/build-app.sh

run: app
	open build/Mailr.app

server:
	swift run MailrServer

test:
	swift test

thunderbird-import:
	swift run mailr-import $(ARGS)

ios-project:
	xcodegen generate

ios-build:
	xcodebuild -project Mailr.xcodeproj -scheme Mailr \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath build/DerivedData build

ios-run: ios-build
	xcrun simctl boot "$(SIM)" 2>/dev/null || true
	open -a Simulator 2>/dev/null || true
	xcrun simctl bootstatus "$(SIM)" -b
	xcrun simctl install "$(SIM)" build/DerivedData/Build/Products/Debug-iphonesimulator/Mailr.app
	@if [ -f .env ]; then \
		DATA_DIR=$$(xcrun simctl get_app_container "$(SIM)" app.mailr.Mailr data); \
		mkdir -p "$$DATA_DIR/Library/Application Support/Mailr"; \
		cp .env "$$DATA_DIR/Library/Application Support/Mailr/.env"; \
	fi
	xcrun simctl launch --terminate-running-process "$(SIM)" app.mailr.Mailr

device-build:
	xcodebuild -project Mailr.xcodeproj -scheme Mailr -configuration Debug \
		-destination 'platform=iOS,id=$(DEVICE)' \
		-derivedDataPath build/DeviceDerivedData \
		-allowProvisioningUpdates DEVELOPMENT_TEAM=$(TEAM) build

device-install: device-build
	xcrun devicectl device install app --device "$(DEVICE)" \
		build/DeviceDerivedData/Build/Products/Debug-iphoneos/Mailr.app
	xcrun devicectl device process launch --device "$(DEVICE)" \
		--terminate-existing app.mailr.Mailr

docs:
	cd website && npm start

docs-build:
	cd website && npm run build

clean:
	rm -rf .build build website/build website/.docusaurus
