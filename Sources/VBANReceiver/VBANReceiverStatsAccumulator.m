#import "VBANReceiverStatsAccumulator.h"

#import "VBANPacket.h"

#include <float.h>

static const NSUInteger VBANDefaultMaximumTrackedIdentities = 256;
static const NSUInteger VBANDefaultReorderWindow = 64;

@interface VBANSequenceState : NSObject

@property (nonatomic, assign) uint32_t highWatermark;
@property (nonatomic, assign) NSTimeInterval lastSeenUptime;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *pendingMissingCounters;

@end

@implementation VBANSequenceState
@end

@interface VBANReceiverStatsSnapshot ()

@property (nonatomic, assign, readwrite) NSUInteger packetDelta;
@property (nonatomic, assign, readwrite) NSUInteger badPacketDelta;
@property (nonatomic, assign, readwrite) NSUInteger filteredPacketDelta;
@property (nonatomic, assign, readwrite) NSInteger missingPacketDelta;
@property (nonatomic, strong, nullable, readwrite) VBANPacket *latestPacket;
@property (nonatomic, assign, readwrite) NSTimeInterval latestPacketUptime;
@property (nonatomic, assign, readwrite) BOOL hasNetworkErrorUpdate;
@property (nonatomic, copy, readwrite) NSString *networkErrorMessage;

@end

@implementation VBANReceiverStatsSnapshot
@end

@interface VBANReceiverStatsAccumulator ()

@property (nonatomic, assign) NSUInteger maximumTrackedIdentities;
@property (nonatomic, assign) NSUInteger reorderWindow;
@property (nonatomic, strong) NSMutableDictionary<NSString *, VBANSequenceState *> *sequenceStates;
@property (nonatomic, assign) BOOL refreshScheduled;
@property (nonatomic, assign) NSUInteger pendingPacketDelta;
@property (nonatomic, assign) NSUInteger pendingBadPacketDelta;
@property (nonatomic, assign) NSUInteger pendingFilteredPacketDelta;
@property (nonatomic, assign) NSInteger pendingMissingPacketDelta;
@property (nonatomic, strong, nullable) VBANPacket *pendingLatestPacket;
@property (nonatomic, assign) NSTimeInterval pendingLatestPacketUptime;
@property (nonatomic, assign) BOOL pendingNetworkErrorUpdate;
@property (nonatomic, copy) NSString *pendingNetworkErrorMessage;

@end

@implementation VBANReceiverStatsAccumulator

- (instancetype)init {
    return [self initWithMaximumTrackedIdentities:VBANDefaultMaximumTrackedIdentities
                                   reorderWindow:VBANDefaultReorderWindow];
}

- (instancetype)initWithMaximumTrackedIdentities:(NSUInteger)maximumTrackedIdentities
                                   reorderWindow:(NSUInteger)reorderWindow {
    self = [super init];
    if (self) {
        _maximumTrackedIdentities = MAX(maximumTrackedIdentities, 1);
        _reorderWindow = MIN(MAX(reorderWindow, 1), 4096);
        _sequenceStates = [NSMutableDictionary dictionary];
        _pendingNetworkErrorMessage = @"";
    }
    return self;
}

- (NSUInteger)trackedIdentityCount {
    @synchronized (self) {
        return self.sequenceStates.count;
    }
}

- (NSUInteger)pendingReorderCounterCount {
    @synchronized (self) {
        NSUInteger count = 0;
        for (VBANSequenceState *state in self.sequenceStates.allValues) {
            if (state.pendingMissingCounters.count > NSUIntegerMax - count) {
                return NSUIntegerMax;
            }
            count += state.pendingMissingCounters.count;
        }
        return count;
    }
}

- (BOOL)recordPacket:(VBANPacket *)packet uptime:(NSTimeInterval)uptime {
    if (!packet) {
        return NO;
    }

    @synchronized (self) {
        self.pendingPacketDelta++;
        self.pendingLatestPacket = packet;
        self.pendingLatestPacketUptime = uptime;
        self.pendingNetworkErrorUpdate = YES;
        self.pendingNetworkErrorMessage = @"";
        self.pendingMissingPacketDelta += [self missingDeltaForPacketOnLock:packet uptime:uptime];
        return [self markRefreshScheduledOnLock];
    }
}

- (BOOL)recordBadPacketError:(NSError *)error fallbackMessage:(NSString *)fallbackMessage {
    @synchronized (self) {
        self.pendingBadPacketDelta++;
        self.pendingNetworkErrorUpdate = YES;
        self.pendingNetworkErrorMessage = error.localizedDescription.length
            ? error.localizedDescription
            : (fallbackMessage ?: @"");
        return [self markRefreshScheduledOnLock];
    }
}

- (BOOL)recordFilteredPacket {
    @synchronized (self) {
        self.pendingFilteredPacketDelta++;
        return [self markRefreshScheduledOnLock];
    }
}

- (VBANReceiverStatsSnapshot *)drainSnapshot {
    @synchronized (self) {
        VBANReceiverStatsSnapshot *snapshot = [[VBANReceiverStatsSnapshot alloc] init];
        snapshot.packetDelta = self.pendingPacketDelta;
        snapshot.badPacketDelta = self.pendingBadPacketDelta;
        snapshot.filteredPacketDelta = self.pendingFilteredPacketDelta;
        snapshot.missingPacketDelta = self.pendingMissingPacketDelta;
        snapshot.latestPacket = self.pendingLatestPacket;
        snapshot.latestPacketUptime = self.pendingLatestPacketUptime;
        snapshot.hasNetworkErrorUpdate = self.pendingNetworkErrorUpdate;
        snapshot.networkErrorMessage = self.pendingNetworkErrorMessage ?: @"";

        self.pendingPacketDelta = 0;
        self.pendingBadPacketDelta = 0;
        self.pendingFilteredPacketDelta = 0;
        self.pendingMissingPacketDelta = 0;
        self.pendingLatestPacket = nil;
        self.pendingLatestPacketUptime = 0;
        self.pendingNetworkErrorUpdate = NO;
        self.pendingNetworkErrorMessage = @"";
        self.refreshScheduled = NO;
        return snapshot;
    }
}

- (BOOL)markRefreshScheduledOnLock {
    if (self.refreshScheduled) {
        return NO;
    }
    self.refreshScheduled = YES;
    return YES;
}

- (NSInteger)missingDeltaForPacketOnLock:(VBANPacket *)packet
                                  uptime:(NSTimeInterval)uptime {
    NSString *identity = [NSString stringWithFormat:@"%@|%@|%.0f|%lu|%u",
                          packet.sender ?: @"",
                          packet.streamName ?: @"",
                          packet.sampleRate,
                          (unsigned long)packet.channelCount,
                          packet.dataType];
    VBANSequenceState *state = self.sequenceStates[identity];
    if (!state) {
        [self evictOldestIdentityIfNeededOnLock];
        state = [[VBANSequenceState alloc] init];
        state.highWatermark = packet.frameCounter;
        state.lastSeenUptime = uptime;
        state.pendingMissingCounters = [NSMutableSet set];
        self.sequenceStates[identity] = state;
        return 0;
    }

    state.lastSeenUptime = uptime;
    uint32_t forwardDistance = packet.frameCounter - state.highWatermark;
    if (forwardDistance == 0) {
        return 0;
    }

    if (forwardDistance < UINT32_C(0x80000000)) {
        NSInteger missingDelta = 0;
        if (forwardDistance <= self.reorderWindow + 1) {
            for (uint32_t offset = 1; offset < forwardDistance; offset++) {
                NSNumber *missingCounter = @(state.highWatermark + offset);
                if (![state.pendingMissingCounters containsObject:missingCounter]) {
                    [state.pendingMissingCounters addObject:missingCounter];
                    missingDelta++;
                }
            }
        } else {
            // Preserve the prior large-discontinuity behavior without allocating
            // attacker-controlled numbers of pending counters.
            missingDelta = 1;
            [state.pendingMissingCounters removeAllObjects];
        }
        state.highWatermark = packet.frameCounter;
        [self prunePendingCountersOutsideWindowOnLockForState:state];
        return missingDelta;
    }

    NSNumber *lateCounter = @(packet.frameCounter);
    if ([state.pendingMissingCounters containsObject:lateCounter]) {
        [state.pendingMissingCounters removeObject:lateCounter];
        return -1;
    }
    return 0;
}

- (void)prunePendingCountersOutsideWindowOnLockForState:(VBANSequenceState *)state {
    NSMutableArray<NSNumber *> *expiredCounters = [NSMutableArray array];
    for (NSNumber *counterValue in state.pendingMissingCounters) {
        uint32_t counter = counterValue.unsignedIntValue;
        uint32_t backwardDistance = state.highWatermark - counter;
        if (backwardDistance == 0
            || backwardDistance > self.reorderWindow
            || backwardDistance >= UINT32_C(0x80000000)) {
            [expiredCounters addObject:counterValue];
        }
    }
    [state.pendingMissingCounters minusSet:[NSSet setWithArray:expiredCounters]];
}

- (void)evictOldestIdentityIfNeededOnLock {
    if (self.sequenceStates.count < self.maximumTrackedIdentities) {
        return;
    }

    __block NSString *oldestIdentity = nil;
    __block NSTimeInterval oldestUptime = DBL_MAX;
    [self.sequenceStates enumerateKeysAndObjectsUsingBlock:
        ^(NSString *identity, VBANSequenceState *state, __unused BOOL *stop) {
            if (state.lastSeenUptime < oldestUptime) {
                oldestUptime = state.lastSeenUptime;
                oldestIdentity = identity;
            }
        }];
    if (oldestIdentity) {
        [self.sequenceStates removeObjectForKey:oldestIdentity];
    }
}

@end
