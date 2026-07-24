#import <Foundation/Foundation.h>

@class VBANPacket;

NS_ASSUME_NONNULL_BEGIN

@interface VBANReceiverStatsSnapshot : NSObject

@property (nonatomic, assign, readonly) NSUInteger packetDelta;
@property (nonatomic, assign, readonly) NSUInteger badPacketDelta;
@property (nonatomic, assign, readonly) NSUInteger filteredPacketDelta;
@property (nonatomic, assign, readonly) NSInteger missingPacketDelta;
@property (nonatomic, strong, nullable, readonly) VBANPacket *latestPacket;
@property (nonatomic, assign, readonly) NSTimeInterval latestPacketUptime;
@property (nonatomic, assign, readonly) BOOL hasNetworkErrorUpdate;
@property (nonatomic, copy, readonly) NSString *networkErrorMessage;

@end

@interface VBANReceiverStatsAccumulator : NSObject

@property (nonatomic, assign, readonly) NSUInteger trackedIdentityCount;
@property (nonatomic, assign, readonly) NSUInteger pendingReorderCounterCount;

- (instancetype)init;
- (instancetype)initWithMaximumTrackedIdentities:(NSUInteger)maximumTrackedIdentities
                                   reorderWindow:(NSUInteger)reorderWindow NS_DESIGNATED_INITIALIZER;

/// Returns YES when the caller must schedule a main-thread drain.
- (BOOL)recordPacket:(VBANPacket *)packet uptime:(NSTimeInterval)uptime;
- (BOOL)recordBadPacketError:(nullable NSError *)error fallbackMessage:(NSString *)fallbackMessage;
- (BOOL)recordFilteredPacket;

/// Drains all pending deltas and permits the next producer to schedule one refresh.
- (VBANReceiverStatsSnapshot *)drainSnapshot;

@end

NS_ASSUME_NONNULL_END
