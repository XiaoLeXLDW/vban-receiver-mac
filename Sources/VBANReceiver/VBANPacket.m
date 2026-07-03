#import "VBANPacket.h"

NSErrorDomain const VBANPacketErrorDomain = @"local.codex.vban.packet";

typedef NS_ENUM(NSInteger, VBANPacketErrorCode) {
    VBANPacketErrorTooSmall = 1,
    VBANPacketErrorInvalidMagic,
    VBANPacketErrorUnsupportedProtocol,
    VBANPacketErrorUnsupportedCodec,
    VBANPacketErrorUnsupportedSampleRate,
    VBANPacketErrorUnsupportedDataType,
    VBANPacketErrorCorruptPayload,
    VBANPacketErrorInvalidFormat
};

static const NSUInteger VBANHeaderSize = 28;

static NSError *VBANError(VBANPacketErrorCode code, NSString *message) {
    return [NSError errorWithDomain:VBANPacketErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSNumber *VBANSampleRateForIndex(uint8_t index) {
    static NSDictionary<NSNumber *, NSNumber *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = @{
            @0: @6000,
            @1: @12000,
            @2: @24000,
            @3: @48000,
            @4: @96000,
            @5: @192000,
            @6: @384000,
            @7: @8000,
            @8: @16000,
            @9: @32000,
            @10: @64000,
            @11: @128000,
            @12: @256000,
            @13: @512000,
            @14: @11025,
            @15: @22050,
            @16: @44100,
            @17: @88200,
            @18: @176400,
            @19: @352800,
            @20: @705600
        };
    });
    return table[@(index)];
}

NSString *VBANDataTypeDisplayName(VBANDataType dataType) {
    switch (dataType) {
        case VBANDataTypeUInt8:
            return @"8-bit PCM";
        case VBANDataTypeInt16:
            return @"16-bit PCM";
        case VBANDataTypeInt24:
            return @"24-bit PCM";
        case VBANDataTypeInt32:
            return @"32-bit PCM";
        case VBANDataTypeFloat32:
            return @"32-bit float";
        case VBANDataTypeFloat64:
            return @"64-bit float";
    }
}

NSUInteger VBANBytesPerSample(VBANDataType dataType) {
    switch (dataType) {
        case VBANDataTypeUInt8:
            return 1;
        case VBANDataTypeInt16:
            return 2;
        case VBANDataTypeInt24:
            return 3;
        case VBANDataTypeInt32:
        case VBANDataTypeFloat32:
            return 4;
        case VBANDataTypeFloat64:
            return 8;
    }
}

@interface VBANPacket ()

@property (nonatomic, copy) NSString *streamName;
@property (nonatomic, copy) NSString *sender;
@property (nonatomic, assign) double sampleRate;
@property (nonatomic, assign) uint8_t sampleRateIndex;
@property (nonatomic, assign) NSUInteger sampleCount;
@property (nonatomic, assign) NSUInteger channelCount;
@property (nonatomic, assign) VBANDataType dataType;
@property (nonatomic, assign) uint32_t frameCounter;
@property (nonatomic, copy) NSData *payload;

@end

@implementation VBANPacket

+ (instancetype)packetWithData:(NSData *)data sender:(NSString *)sender error:(NSError **)error {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;

    if (length < VBANHeaderSize) {
        if (error) {
            *error = VBANError(VBANPacketErrorTooSmall, [NSString stringWithFormat:@"Packet too small: %lu bytes", (unsigned long)length]);
        }
        return nil;
    }

    if (bytes[0] != 'V' || bytes[1] != 'B' || bytes[2] != 'A' || bytes[3] != 'N') {
        if (error) {
            *error = VBANError(VBANPacketErrorInvalidMagic, @"Missing VBAN header");
        }
        return nil;
    }

    uint8_t protocolValue = bytes[4] & 0xE0;
    if (protocolValue != 0x00) {
        if (error) {
            *error = VBANError(VBANPacketErrorUnsupportedProtocol, [NSString stringWithFormat:@"Unsupported VBAN protocol: %u", protocolValue >> 5]);
        }
        return nil;
    }

    uint8_t sampleRateIndex = bytes[4] & 0x1F;
    NSNumber *sampleRate = VBANSampleRateForIndex(sampleRateIndex);
    if (!sampleRate) {
        if (error) {
            *error = VBANError(VBANPacketErrorUnsupportedSampleRate, [NSString stringWithFormat:@"Unsupported sample-rate index: %u", sampleRateIndex]);
        }
        return nil;
    }

    uint8_t codec = bytes[7] & 0xF0;
    if (codec != 0x00) {
        if (error) {
            *error = VBANError(VBANPacketErrorUnsupportedCodec, [NSString stringWithFormat:@"Unsupported VBAN codec: %u", codec >> 4]);
        }
        return nil;
    }

    if ((bytes[7] & 0x08) != 0) {
        if (error) {
            *error = VBANError(VBANPacketErrorInvalidFormat, @"Reserved VBAN format bit is set");
        }
        return nil;
    }

    uint8_t dataTypeRaw = bytes[7] & 0x07;
    if (dataTypeRaw > VBANDataTypeFloat64) {
        if (error) {
            *error = VBANError(VBANPacketErrorUnsupportedDataType, [NSString stringWithFormat:@"Unsupported sample type: %u", dataTypeRaw]);
        }
        return nil;
    }

    NSUInteger sampleCount = (NSUInteger)bytes[5] + 1;
    NSUInteger channelCount = (NSUInteger)bytes[6] + 1;
    VBANDataType dataType = (VBANDataType)dataTypeRaw;
    NSUInteger expectedPayloadSize = sampleCount * channelCount * VBANBytesPerSample(dataType);
    NSUInteger actualPayloadSize = length - VBANHeaderSize;

    if (actualPayloadSize != expectedPayloadSize) {
        if (error) {
            *error = VBANError(VBANPacketErrorCorruptPayload, [NSString stringWithFormat:@"Payload size mismatch: expected %lu, got %lu", (unsigned long)expectedPayloadSize, (unsigned long)actualPayloadSize]);
        }
        return nil;
    }

    VBANPacket *packet = [[VBANPacket alloc] init];
    packet.streamName = [self streamNameFromBytes:&bytes[8]];
    packet.sender = sender ?: @"";
    packet.sampleRate = sampleRate.doubleValue;
    packet.sampleRateIndex = sampleRateIndex;
    packet.sampleCount = sampleCount;
    packet.channelCount = channelCount;
    packet.dataType = dataType;
    packet.frameCounter = (uint32_t)bytes[24]
        | ((uint32_t)bytes[25] << 8)
        | ((uint32_t)bytes[26] << 16)
        | ((uint32_t)bytes[27] << 24);
    packet.payload = [data subdataWithRange:NSMakeRange(VBANHeaderSize, expectedPayloadSize)];
    return packet;
}

+ (NSString *)streamNameFromBytes:(const uint8_t *)bytes {
    NSUInteger length = 0;
    while (length < 16 && bytes[length] != 0) {
        length++;
    }

    NSString *name = [[NSString alloc] initWithBytes:bytes length:length encoding:NSASCIIStringEncoding];
    return [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

- (NSString *)formatDescription {
    return [NSString stringWithFormat:@"%.0f Hz / %luch / %@",
            self.sampleRate,
            (unsigned long)self.channelCount,
            VBANDataTypeDisplayName(self.dataType)];
}

@end
