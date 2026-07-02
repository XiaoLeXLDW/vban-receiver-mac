APP_NAME := VBAN Receiver
BINARY_NAME := VBANReceiver
BUILD_DIR := .build
DIST_DIR := dist
SOURCES := $(shell find Sources/VBANReceiver -name '*.m' -type f | sort)
PACKET_TEST_SOURCES := Sources/VBANReceiver/VBANPacket.m Tests/vban_packet_tests.m
UDP_TEST_SOURCES := Sources/VBANReceiver/VBANPacket.m Sources/VBANReceiver/VBANUDPReceiver.m Tests/vban_udp_tests.m
CFLAGS := -fobjc-arc -O2 -mmacosx-version-min=13.0 -I Sources/VBANReceiver
APP_FRAMEWORKS := -framework Cocoa -framework AudioToolbox -framework CoreAudio
TEST_FRAMEWORKS := -framework Foundation

.PHONY: build app test clean

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
	./Scripts/package-app.sh

clean:
	rm -rf "$(BUILD_DIR)" "$(DIST_DIR)"
