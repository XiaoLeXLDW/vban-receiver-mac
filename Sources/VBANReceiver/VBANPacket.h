#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint8_t, VBANDataType) {
    VBANDataTypeUInt8 = 0,
    VBANDataTypeInt16 = 1,
    VBANDataTypeInt24 = 2,
    VBANDataTypeInt32 = 3,
    VBANDataTypeFloat32 = 4,
    VBANDataTypeFloat64 = 5
};

extern NSErrorDomain const VBANPacketErrorDomain;

NSString *VBANDataTypeDisplayName(VBANDataType dataType);
NSUInteger VBANBytesPerSample(VBANDataType dataType);

@interface VBANPacket : NSObject

@property (nonatomic, copy, readonly) NSString *streamName;
@property (nonatomic, copy, readonly) NSString *sender;
@property (nonatomic, assign, readonly) double sampleRate;
@property (nonatomic, assign, readonly) uint8_t sampleRateIndex;
@property (nonatomic, assign, readonly) NSUInteger sampleCount;
@property (nonatomic, assign, readonly) NSUInteger channelCount;
@property (nonatomic, assign, readonly) VBANDataType dataType;
@property (nonatomic, assign, readonly) uint32_t frameCounter;
@property (nonatomic, copy, readonly) NSData *payload;

+ (nullable instancetype)packetWithData:(NSData *)data sender:(NSString *)sender error:(NSError **)error;
- (NSString *)formatDescription;

@end

NS_ASSUME_NONNULL_END
