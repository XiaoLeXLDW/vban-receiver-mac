APP_NAME := VBAN Receiver
BINARY_NAME := VBANReceiver
BUILD_DIR := .build
DIST_DIR := dist
APP_PATH ?= $(DIST_DIR)/$(APP_NAME).app
ARCH ?= arm64
VERSION ?= 0.3.13
BUILD_NUMBER ?= 17
EXPECTED_VERSION ?=
EXPECTED_BUILD_NUMBER ?=
# Validation metadata is opt-in: EXPECTED_* always wins, while VERSION and
# BUILD_NUMBER are treated as expectations only when supplied outside this
# Makefile (for example, on the command line or by CI).
VALIDATION_EXPECTED_VERSION = $(if $(strip $(EXPECTED_VERSION)),$(EXPECTED_VERSION),$(if $(filter-out file undefined,$(origin VERSION)),$(VERSION)))
VALIDATION_EXPECTED_BUILD_NUMBER = $(if $(strip $(EXPECTED_BUILD_NUMBER)),$(EXPECTED_BUILD_NUMBER),$(if $(filter-out file undefined,$(origin BUILD_NUMBER)),$(BUILD_NUMBER)))
SOURCES := $(shell find Sources/VBANReceiver -name '*.m' -type f | sort)
PACKET_TEST_SOURCES := Sources/VBANReceiver/VBANPacket.m Tests/vban_packet_tests.m
UDP_TEST_SOURCES := Sources/VBANReceiver/VBANPacket.m Sources/VBANReceiver/VBANUDPReceiver.m Tests/vban_udp_tests.m
ACTIVITY_POLICY_TEST_SOURCES := Tests/vban_activity_policy_tests.m
OUTPUT_RECOVERY_POLICY_TEST_SOURCES := Tests/vban_output_recovery_policy_tests.m
RECEIVER_STATS_TEST_SOURCES := Sources/VBANReceiver/VBANPacket.m Sources/VBANReceiver/VBANReceiverStatsAccumulator.m Tests/vban_receiver_stats_tests.m
AUDIO_PLAYER_POLICY_TEST_SOURCES := Sources/VBANReceiver/VBANPacket.m Sources/VBANReceiver/VBANCountCoalescer.m Sources/VBANReceiver/VBANAudioPlayer.m Tests/vban_audio_player_policy_tests.m
ARCH_FLAGS := $(foreach arch,$(ARCH),-arch $(arch))
CFLAGS := $(ARCH_FLAGS) -fobjc-arc -O2 -mmacosx-version-min=13.0 -I Sources/VBANReceiver
APP_FRAMEWORKS := -framework Cocoa -framework AudioToolbox -framework CoreAudio
TEST_FRAMEWORKS := -framework Foundation

.PHONY: build app test perf-idle validate-app validate-release validate-release-tree clean

build:
	mkdir -p "$(BUILD_DIR)"
	clang $(CFLAGS) $(SOURCES) $(APP_FRAMEWORKS) -o "$(BUILD_DIR)/$(BINARY_NAME)"

test:
	mkdir -p "$(BUILD_DIR)"
	clang $(CFLAGS) -DVBAN_PACKET_TEST $(PACKET_TEST_SOURCES) $(TEST_FRAMEWORKS) -o "$(BUILD_DIR)/vban_packet_tests"
	"$(BUILD_DIR)/vban_packet_tests"
	clang $(CFLAGS) -DVBAN_UDP_TEST $(UDP_TEST_SOURCES) $(TEST_FRAMEWORKS) -o "$(BUILD_DIR)/vban_udp_tests"
	"$(BUILD_DIR)/vban_udp_tests"
	clang $(CFLAGS) $(ACTIVITY_POLICY_TEST_SOURCES) $(TEST_FRAMEWORKS) -o "$(BUILD_DIR)/vban_activity_policy_tests"
	"$(BUILD_DIR)/vban_activity_policy_tests"
	clang $(CFLAGS) $(OUTPUT_RECOVERY_POLICY_TEST_SOURCES) $(TEST_FRAMEWORKS) -o "$(BUILD_DIR)/vban_output_recovery_policy_tests"
	"$(BUILD_DIR)/vban_output_recovery_policy_tests"
	clang $(CFLAGS) $(RECEIVER_STATS_TEST_SOURCES) $(TEST_FRAMEWORKS) -o "$(BUILD_DIR)/vban_receiver_stats_tests"
	"$(BUILD_DIR)/vban_receiver_stats_tests"
	clang $(CFLAGS) $(AUDIO_PLAYER_POLICY_TEST_SOURCES) $(TEST_FRAMEWORKS) -framework AudioToolbox -framework CoreAudio -o "$(BUILD_DIR)/vban_audio_player_policy_tests"
	"$(BUILD_DIR)/vban_audio_player_policy_tests"

app: build
	SKIP_BUILD=1 VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" ARCH="$(ARCH)" ./Scripts/package-app.sh

perf-idle: app
	bash ./Scripts/measure-idle-cpu.sh "$(APP_PATH)"

# Read-only validation of an app that has already been packaged. This target
# deliberately does not depend on `app`, so it can never replace the artifact
# (or its embedded version) while validating it.
validate-app:
	APP_NAME="$(APP_NAME)" BINARY_NAME="$(BINARY_NAME)" ARCH="$(ARCH)" \
		EXPECTED_VERSION="$(VALIDATION_EXPECTED_VERSION)" EXPECTED_BUILD_NUMBER="$(VALIDATION_EXPECTED_BUILD_NUMBER)" \
		STRICT_RELEASE=0 bash ./Scripts/validate-app.sh "$(APP_PATH)"

# Public distribution gate. This is also read-only and requires explicit
# expected metadata plus a Developer ID signature, Gatekeeper acceptance, and
# a stapled notarization ticket.
validate-release:
	APP_NAME="$(APP_NAME)" BINARY_NAME="$(BINARY_NAME)" ARCH="$(ARCH)" \
		EXPECTED_VERSION="$(VALIDATION_EXPECTED_VERSION)" EXPECTED_BUILD_NUMBER="$(VALIDATION_EXPECTED_BUILD_NUMBER)" \
		STRICT_RELEASE=1 bash ./Scripts/validate-app.sh "$(APP_PATH)"

# Repository integrity gate for a release commit. Kept separate from artifact
# validation so local/ad-hoc app checks do not require a clean or staged tree.
validate-release-tree:
	bash ./Scripts/validate-release-tree.sh

clean:
	rm -rf "$(BUILD_DIR)" "$(DIST_DIR)"
