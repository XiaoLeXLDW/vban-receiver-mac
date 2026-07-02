#import <Foundation/Foundation.h>

@class VBANPacket;

NS_ASSUME_NONNULL_BEGIN

@interface VBANUDPReceiver : NSObject

@property (nonatomic, copy, nullable) void (^packetHandler)(VBANPacket *packet);
@property (nonatomic, copy, nullable) void (^parseErrorHandler)(NSError *error);
@property (nonatomic, copy, nullable) void (^filteredPacketHandler)(void);
@property (nonatomic, copy, nullable) void (^stateHandler)(NSString *state);

- (BOOL)startWithPort:(uint16_t)port
           streamName:(nullable NSString *)streamName
           sourceHost:(nullable NSString *)sourceHost
                error:(NSError **)error;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
