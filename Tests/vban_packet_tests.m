#import "VBANPacket.h"

static void AssertTrue(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static NSData *MakePacket(uint8_t sampleRateIndex,
                          uint8_t sampleCount,
                          uint8_t channelCount,
                          VBANDataType dataType,
                          uint32_t frameCounter,
                          uint8_t codecNibble,
                          NSArray<NSNumber *> *payload) {
    NSMutableData *data = [NSMutableData data];
    const uint8_t magic[] = {'V', 'B', 'A', 'N'};
    [data appendBytes:magic length:4];
    uint8_t header[] = {
        sampleRateIndex,
        (uint8_t)(sampleCount - 1),
        (uint8_t)(channelCount - 1),
        (uint8_t)(codecNibble | dataType)
    };
    [data appendBytes:header length:4];

    uint8_t stream[16] = {0};
    memcpy(stream, "Stream1", 7);
    [data appendBytes:stream length:16];

    uint8_t frame[] = {
        (uint8_t)(frameCounter & 0xFF),
        (uint8_t)((frameCounter >> 8) & 0xFF),
        (uint8_t)((frameCounter >> 16) & 0xFF),
        (uint8_t)((frameCounter >> 24) & 0xFF)
    };
    [data appendBytes:frame length:4];

    for (NSNumber *byte in payload) {
        uint8_t value = byte.unsignedCharValue;
        [data appendBytes:&value length:1];
    }
    return data;
}

int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        NSData *packetData = MakePacket(16, 2, 2, VBANDataTypeInt16, 42, 0, @[
            @0x00, @0x00, @0xFF, @0x7F,
            @0x00, @0x80, @0x01, @0x00
        ]);
        VBANPacket *packet = [VBANPacket packetWithData:packetData sender:@"192.168.1.2:6980" error:&error];
        AssertTrue(packet != nil, "expected packet to parse");
        AssertTrue([packet.streamName isEqualToString:@"Stream1"], "stream name");
        AssertTrue(packet.sampleRate == 44100, "sample rate");
        AssertTrue(packet.sampleCount == 2, "sample count");
        AssertTrue(packet.channelCount == 2, "channel count");
        AssertTrue(packet.dataType == VBANDataTypeInt16, "data type");
        AssertTrue(packet.frameCounter == 42, "frame counter");
        AssertTrue([packet.sender isEqualToString:@"192.168.1.2:6980"], "sender");
        AssertTrue([packet.formatDescription isEqualToString:@"44100 Hz / 2ch / 16-bit PCM"], "format description");

        NSData *shortData = [NSData dataWithBytes:"VBAN" length:4];
        error = nil;
        packet = [VBANPacket packetWithData:shortData sender:@"" error:&error];
        AssertTrue(packet == nil, "short packet rejects");
        AssertTrue(error.code == 1, "short packet error code");

        NSData *codecData = MakePacket(16, 1, 1, VBANDataTypeInt16, 1, 0x10, @[@0x00, @0x00]);
        error = nil;
        packet = [VBANPacket packetWithData:codecData sender:@"" error:&error];
        AssertTrue(packet == nil, "unsupported codec rejects");
        AssertTrue(error.code == 4, "unsupported codec error code");

        NSMutableData *trailingData = [MakePacket(16, 1, 1, VBANDataTypeInt16, 1, 0, @[@0x00, @0x00]) mutableCopy];
        uint8_t extraByte = 0xAA;
        [trailingData appendBytes:&extraByte length:1];
        error = nil;
        packet = [VBANPacket packetWithData:trailingData sender:@"" error:&error];
        AssertTrue(packet == nil, "trailing payload rejects");
        AssertTrue(error.code == 7, "trailing payload error code");

        NSData *reservedBitData = MakePacket(16, 1, 1, VBANDataTypeInt16, 1, 0x08, @[@0x00, @0x00]);
        error = nil;
        packet = [VBANPacket packetWithData:reservedBitData sender:@"" error:&error];
        AssertTrue(packet == nil, "reserved format bit rejects");
        AssertTrue(error != nil, "reserved format bit error");

        puts("vban_packet_tests passed");
    }
    return 0;
}
