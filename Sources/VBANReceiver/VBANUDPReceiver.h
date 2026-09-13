#import <Foundation/Foundation.h>

@class VBANPacket;

NS_ASSUME_NONNULL_BEGIN

@interface VBANUDPReceiver : NSObject

@property (atomic, copy, nullable) void (^packetHandler)(VBANPacket *packet);
@property (atomic, copy, nullable) void (^parseErrorHandler)(NSError *error);
@property (atomic, copy, nullable) void (^filteredPacketHandler)(void);
@property (atomic, copy, nullable) void (^stateHandler)(NSString *state);
@property (atomic, assign, readonly) uint16_t localPort;

- (BOOL)startWithPort:(uint16_t)port
           streamName:(nullable NSString *)streamName
           sourceHost:(nullable NSString *)sourceHost
                error:(NSError **)error;
// Call on the main thread. Completion is delivered there; stop cancels pending
// startup without calling completion. A timed-out DNS result cannot open a socket.
- (void)startWithPort:(uint16_t)port
          streamName:(nullable NSString *)streamName
          sourceHost:(nullable NSString *)sourceHost
             timeout:(NSTimeInterval)timeout
          completion:(void (^)(BOOL started, NSError * _Nullable error))completion;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
