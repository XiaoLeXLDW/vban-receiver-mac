APP_NAME := VBAN Receiver
BINARY_NAME := VBANReceiver
BUILD_DIR := .build
DIST_DIR := dist
ARCH ?= arm64
VERSION ?= 0.3.12
BUILD_NUMBER ?= 16
SOURCES := $(shell find Sources/VBANReceiver -name '*.m' -type f | sort)
PACKET_TEST_SOURCES := Sources/VBANReceiver/VBANPacket.m Tests/vban_packet_tests.m
UDP_TEST_SOURCES := Sources/VBANReceiver/VBANPacket.m Sources/VBANReceiver/VBANUDPReceiver.m Tests/vban_udp_tests.m
ARCH_FLAGS := $(foreach arch,$(ARCH),-arch $(arch))
CFLAGS := $(ARCH_FLAGS) -fobjc-arc -O2 -mmacosx-version-min=13.0 -I Sources/VBANReceiver
APP_FRAMEWORKS := -framework Cocoa -framework AudioToolbox -framework CoreAudio
TEST_FRAMEWORKS := -framework Foundation

.PHONY: build app test validate-app clean

build:
	mkdir -p "$(BUILD_DIR)"
	clang $(CFLAGS) $(SOURCES) $(APP_FRAMEWORKS) -o "$(BUILD_DIR)/$(BINARY_NAME)"

test:
	mkdir -p "$(BUILD_DIR)"
	clang $(CFLAGS) -DVBAN_PACKET_TEST $(PACKET_TEST_SOURCES) $(TEST_FRAMEWORKS) -o "$(BUILD_DIR)/vban_packet_tests"
	"$(BUILD_DIR)/vban_packet_tests"
	clang $(CFLAGS) -DVBAN_UDP_TEST $(UDP_TEST_SOURCES) $(TEST_FRAMEWORKS) -o "$(BUILD_DIR)/vban_udp_tests"
	"$(BUILD_DIR)/vban_udp_tests"

app: build
	SKIP_BUILD=1 VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" ARCH="$(ARCH)" ./Scripts/package-app.sh

validate-app: app
	plutil -lint "$(DIST_DIR)/$(APP_NAME).app/Contents/Info.plist"
	test -x "$(DIST_DIR)/$(APP_NAME).app/Contents/MacOS/$(BINARY_NAME)"
	codesign --verify --deep --strict --verbose=2 "$(DIST_DIR)/$(APP_NAME).app"
	lipo "$(DIST_DIR)/$(APP_NAME).app/Contents/MacOS/$(BINARY_NAME)" -verify_arch $(ARCH)

clean:
	rm -rf "$(BUILD_DIR)" "$(DIST_DIR)"
