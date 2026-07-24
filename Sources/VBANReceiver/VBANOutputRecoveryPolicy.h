#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static const NSTimeInterval VBANOutputNotificationQuietInterval = 0.20;
static const NSTimeInterval VBANOutputNotificationMaximumInterval = 1.00;
static const NSTimeInterval VBANOutputRestoreDeadline = 0.50;

typedef NS_ENUM(NSInteger, VBANOutputRecoveryDecision) {
    VBANOutputRecoveryDecisionNone = 0,
    VBANOutputRecoveryDecisionMarkUnavailable,
    VBANOutputRecoveryDecisionRestartForRouteChange,
    VBANOutputRecoveryDecisionRestartForFormatChange,
    VBANOutputRecoveryDecisionRestartForPlaybackStall
};

typedef struct {
    BOOL hasAudioQueue;
    BOOL outputAvailable;
    BOOL routeChanged;
    BOOL outputFormatCompatible;
    BOOL queueStarted;
    BOOL queueRunningKnown;
    BOOL queueRunning;
    BOOL hasPendingAudio;
    BOOL hasFreshInput;
} VBANOutputRecoveryFacts;

typedef struct {
    NSTimeInterval burstStartedAt;
    NSTimeInterval lastNotificationAt;
    NSUInteger notificationCount;
    NSUInteger generation;
} VBANOutputNotificationState;

typedef NS_ENUM(NSInteger, VBANOutputNotificationTimerAction) {
    VBANOutputNotificationTimerActionIgnore = 0,
    VBANOutputNotificationTimerActionRearm,
    VBANOutputNotificationTimerActionEvaluate
};

NS_INLINE NSTimeInterval VBANOutputNotificationDeadline(NSTimeInterval burstStartedAt,
                                                         NSTimeInterval lastNotificationAt) {
    NSTimeInterval quietDeadline = lastNotificationAt + VBANOutputNotificationQuietInterval;
    NSTimeInterval maximumDeadline = burstStartedAt + VBANOutputNotificationMaximumInterval;
    return MIN(quietDeadline, maximumDeadline);
}

NS_INLINE NSTimeInterval VBANOutputNotificationDelay(NSTimeInterval burstStartedAt,
                                                      NSTimeInterval lastNotificationAt,
                                                      NSTimeInterval now) {
    return MAX(0, VBANOutputNotificationDeadline(burstStartedAt, lastNotificationAt) - now);
}

NS_INLINE VBANOutputNotificationState VBANOutputNotificationNotice(VBANOutputNotificationState state,
                                                                    NSTimeInterval now) {
    if (state.notificationCount == 0) {
        state.burstStartedAt = now;
    }
    state.lastNotificationAt = now;
    state.notificationCount++;
    state.generation++;
    return state;
}

NS_INLINE VBANOutputNotificationTimerAction VBANOutputNotificationTimerDecision(
    VBANOutputNotificationState state,
    NSTimeInterval now,
    NSUInteger timerGeneration) {
    if (state.notificationCount == 0 || timerGeneration != state.generation) {
        return VBANOutputNotificationTimerActionIgnore;
    }
    return now + 0.0005 < VBANOutputNotificationDeadline(state.burstStartedAt,
                                                          state.lastNotificationAt)
        ? VBANOutputNotificationTimerActionRearm
        : VBANOutputNotificationTimerActionEvaluate;
}

NS_INLINE VBANOutputNotificationState VBANOutputNotificationCleared(VBANOutputNotificationState state) {
    state.burstStartedAt = 0;
    state.lastNotificationAt = 0;
    state.notificationCount = 0;
    return state;
}

NS_INLINE VBANOutputRecoveryDecision VBANOutputRecoveryDecisionForFacts(VBANOutputRecoveryFacts facts) {
    if (!facts.outputAvailable) {
        return VBANOutputRecoveryDecisionMarkUnavailable;
    }
    if (!facts.hasAudioQueue) {
        return VBANOutputRecoveryDecisionNone;
    }
    if (facts.routeChanged) {
        return VBANOutputRecoveryDecisionRestartForRouteChange;
    }
    if (!facts.outputFormatCompatible) {
        return VBANOutputRecoveryDecisionRestartForFormatChange;
    }
    if (facts.queueStarted
        && facts.queueRunningKnown
        && !facts.queueRunning
        && facts.hasPendingAudio
        && facts.hasFreshInput) {
        return VBANOutputRecoveryDecisionRestartForPlaybackStall;
    }
    return VBANOutputRecoveryDecisionNone;
}

NS_INLINE BOOL VBANOutputRecoveryDecisionRequiresRestart(VBANOutputRecoveryDecision decision) {
    return decision == VBANOutputRecoveryDecisionRestartForRouteChange
        || decision == VBANOutputRecoveryDecisionRestartForFormatChange
        || decision == VBANOutputRecoveryDecisionRestartForPlaybackStall;
}

NS_INLINE BOOL VBANOutputShouldClearAvailabilityAlert(BOOL hasAudioQueue,
                                                       BOOL queueRunningKnown,
                                                       BOOL queueRunning,
                                                       BOOL outputAvailable,
                                                       BOOL routeMatches,
                                                       BOOL queueGenerationCurrent) {
    return hasAudioQueue
        && queueRunningKnown
        && queueRunning
        && outputAvailable
        && routeMatches
        && queueGenerationCurrent;
}

NS_INLINE BOOL VBANCoreAudioListenerContextCanRelease(BOOL removedAllListeners,
                                                       BOOL priorDeviceListenerRemovalFailed) {
    return removedAllListeners && !priorDeviceListenerRemovalFailed;
}

NS_INLINE BOOL VBANCoreAudioListenerRemovalFailureRecorded(BOOL priorFailure,
                                                            BOOL removedAllListeners) {
    return priorFailure || !removedAllListeners;
}

NS_INLINE BOOL VBANOutputRestoreFailurePermitsPacketRetry(BOOL outputAvailable) {
    return outputAvailable;
}

NS_INLINE NSString *VBANOutputRecoveryDecisionName(VBANOutputRecoveryDecision decision) {
    switch (decision) {
        case VBANOutputRecoveryDecisionMarkUnavailable:
            return @"output-unavailable";
        case VBANOutputRecoveryDecisionRestartForRouteChange:
            return @"restart-route-change";
        case VBANOutputRecoveryDecisionRestartForFormatChange:
            return @"restart-format-change";
        case VBANOutputRecoveryDecisionRestartForPlaybackStall:
            return @"restart-playback-stall";
        case VBANOutputRecoveryDecisionNone:
        default:
            return @"none";
    }
}

NS_ASSUME_NONNULL_END
