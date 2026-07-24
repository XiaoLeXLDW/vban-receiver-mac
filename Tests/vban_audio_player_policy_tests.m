#import <Foundation/Foundation.h>
#import <float.h>
#import <math.h>

#import "VBANCountCoalescer.h"
#import "VBANOutputRecoveryPolicy.h"

extern BOOL VBANAudioIngressCanAcceptPacket(NSUInteger pendingTaskCount,
                                            NSUInteger pendingBytes,
                                            NSUInteger packetBytes,
                                            NSUInteger maximumTaskCount,
                                            NSUInteger maximumBytes);
extern NSInteger VBANAudioAutomaticRepairSignal(BOOL autoRepairEnabled,
                                                BOOL queueStarted,
                                                BOOL hasFreshPackets,
                                                BOOL queueReportsRunning,
                                                BOOL hasScheduledFrames,
                                                BOOL deviceRunningKnown,
                                                BOOL deviceRunning,
                                                double queuedDuration,
                                                double maximumQueuedDuration,
                                                BOOL manualRepairRecently);
extern float VBANAudioSanitizedFloatSample(double value);
extern BOOL VBANAudioQueueConfigurationAttemptAllowed(BOOL configurationRequired,
                                                       double secondsSinceLastAttempt);
extern BOOL VBANAudioPlaybackNotificationNeeded(BOOL hasAudioQueue,
                                                BOOL audioQueueStarted,
                                                NSUInteger generation,
                                                NSUInteger notifiedGeneration);

static const NSInteger VBANAutomaticRepairSignalNoneForTest = 0;
static const NSInteger VBANAutomaticRepairSignalDeviceNotRunningForTest = 1;
static const NSInteger VBANAutomaticRepairSignalQueueLaggingForTest = 2;

static void AssertTrue(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static void TestBoundedIngressPolicy(void) {
    AssertTrue(VBANAudioIngressCanAcceptPacket(0, 0, 1024, 256, 8 * 1024 * 1024),
               "empty ingress accepts a normal packet");
    AssertTrue(!VBANAudioIngressCanAcceptPacket(256, 0, 1024, 256, 8 * 1024 * 1024),
               "ingress rejects at the pending task limit");
    AssertTrue(!VBANAudioIngressCanAcceptPacket(1,
                                                8 * 1024 * 1024 - 512,
                                                1024,
                                                256,
                                                8 * 1024 * 1024),
               "ingress rejects packets that exceed the byte budget");
    AssertTrue(VBANAudioIngressCanAcceptPacket(1,
                                               8 * 1024 * 1024 - 512,
                                               512,
                                               256,
                                               8 * 1024 * 1024),
               "ingress accepts a packet exactly at the byte budget");
    AssertTrue(!VBANAudioIngressCanAcceptPacket(1, NSUIntegerMax - 8, 16, 256, NSUIntegerMax),
               "ingress byte arithmetic does not overflow");
}

static void TestDropNotificationCoalescing(void) {
    VBANCountCoalescer *coalescer = [[VBANCountCoalescer alloc] init];
    AssertTrue([coalescer recordCount:1], "first drop schedules one notification");
    for (NSUInteger index = 0; index < 1000; index++) {
        AssertTrue(![coalescer recordCount:1], "later drops merge into the pending notification");
    }
    AssertTrue(coalescer.pendingCount == 1001, "all coalesced drops remain observable");
    AssertTrue([coalescer drainCount] == 1001, "one drain reports the complete drop count");
    AssertTrue([coalescer recordCount:NSUIntegerMax], "new drops schedule after a drain");
    AssertTrue(![coalescer recordCount:1], "overflowing drop count stays on the existing notification");
    AssertTrue([coalescer drainCount] == NSUIntegerMax, "drop count saturates instead of wrapping");

    VBANLatestValueCoalescer<NSString *> *messages = [[VBANLatestValueCoalescer alloc] init];
    AssertTrue([messages recordValue:@"first"], "first error schedules one notification");
    AssertTrue(![messages recordValue:@"latest"], "later errors merge into the pending notification");
    AssertTrue([messages.pendingValue isEqualToString:@"latest"], "coalesced error keeps the latest value");
    AssertTrue([[messages drainValue] isEqualToString:@"latest"], "one drain reports the latest error");
    AssertTrue([messages recordValue:@""], "an empty success value can schedule error clearing");
}

static void TestAutomaticRepairEvidence(void) {
    NSInteger healthyAfterManualRepair = VBANAudioAutomaticRepairSignal(
        YES, YES, YES, YES, YES, YES, YES, 0.10, 0.60, YES);
    AssertTrue(healthyAfterManualRepair == VBANAutomaticRepairSignalNoneForTest,
               "recent manual repair is context, not standalone failure evidence");

    NSInteger deviceStopped = VBANAudioAutomaticRepairSignal(
        YES, YES, YES, YES, YES, YES, NO, 0.10, 0.60, YES);
    AssertTrue(deviceStopped == VBANAutomaticRepairSignalDeviceNotRunningForTest,
               "an observed stopped device remains actionable evidence");

    NSInteger queueLagging = VBANAudioAutomaticRepairSignal(
        YES, YES, YES, YES, YES, YES, YES, 0.70, 0.60, NO);
    AssertTrue(queueLagging == VBANAutomaticRepairSignalQueueLaggingForTest,
               "excess queued duration remains actionable evidence");

    NSInteger disabled = VBANAudioAutomaticRepairSignal(
        NO, YES, YES, YES, YES, YES, NO, 1.0, 0.60, NO);
    AssertTrue(disabled == VBANAutomaticRepairSignalNoneForTest,
               "disabled automatic repair ignores health signals");
}

static void TestSafeFloatingPointSamples(void) {
    AssertTrue(VBANAudioSanitizedFloatSample(NAN) == 0.0f,
               "NaN becomes silence");
    AssertTrue(VBANAudioSanitizedFloatSample(INFINITY) == 0.0f,
               "infinity becomes silence");
    AssertTrue(VBANAudioSanitizedFloatSample(DBL_MAX) == 1.0f,
               "finite positive Float64 overflow is safely clipped");
    AssertTrue(VBANAudioSanitizedFloatSample(-DBL_MAX) == -1.0f,
               "finite negative Float64 overflow is safely clipped");
    AssertTrue(VBANAudioSanitizedFloatSample(2.0) == 1.0f,
               "positive floating-point PCM is clipped to full scale");
    AssertTrue(VBANAudioSanitizedFloatSample(-2.0) == -1.0f,
               "negative floating-point PCM is clipped to full scale");
    AssertTrue(fabsf(VBANAudioSanitizedFloatSample(0.25) - 0.25f) < 0.000001f,
               "in-range floating-point PCM is preserved");
}

static void TestAudioQueueConfigurationRateLimit(void) {
    AssertTrue(VBANAudioQueueConfigurationAttemptAllowed(NO, 0),
               "packets matching the current format are never throttled");
    AssertTrue(VBANAudioQueueConfigurationAttemptAllowed(YES, -1),
               "the first queue configuration is allowed");
    AssertTrue(!VBANAudioQueueConfigurationAttemptAllowed(YES, 0.999),
               "rapid format changes are rejected inside the minimum interval");
    AssertTrue(VBANAudioQueueConfigurationAttemptAllowed(YES, 1.0),
               "a stable stream can change format after the minimum interval");

    NSUInteger attempts = 0;
    double lastAttempt = -1;
    for (NSUInteger index = 0; index < 100; index++) {
        double now = index * 0.05;
        double age = lastAttempt < 0 ? -1 : now - lastAttempt;
        if (VBANAudioQueueConfigurationAttemptAllowed(YES, age)) {
            attempts++;
            lastAttempt = now;
        }
    }
    AssertTrue(attempts == 5, "alternating formats are bounded to one configuration attempt per second");
}

static void TestPlaybackSuccessNotificationPolicy(void) {
    AssertTrue(!VBANAudioPlaybackNotificationNeeded(NO, YES, 4, 0),
               "a missing queue cannot report playback success");
    AssertTrue(!VBANAudioPlaybackNotificationNeeded(YES, NO, 4, 0),
               "a stopped queue cannot report playback success");
    AssertTrue(!VBANAudioPlaybackNotificationNeeded(YES, YES, 4, 4),
               "one queue generation reports ordinary success only once");
    AssertTrue(VBANAudioPlaybackNotificationNeeded(YES, YES, 4, 0),
               "resetting the marker after an error permits success clearing");
}

static void TestCoreAudioListenerContextReleasePolicy(void) {
    AssertTrue(VBANCoreAudioListenerContextCanRelease(YES, NO),
               "the callback context can be released after every listener is removed");
    AssertTrue(!VBANCoreAudioListenerContextCanRelease(NO, NO),
               "a current listener removal failure keeps the callback context alive");
    AssertTrue(!VBANCoreAudioListenerContextCanRelease(YES, YES),
               "a prior device listener removal failure keeps the shared callback context alive");
    AssertTrue(!VBANCoreAudioListenerContextCanRelease(NO, YES),
               "current and prior removal failures keep the callback context alive");

    BOOL removalFailed = VBANCoreAudioListenerRemovalFailureRecorded(NO, NO);
    AssertTrue(removalFailed, "a device listener removal failure is recorded");
    removalFailed = VBANCoreAudioListenerRemovalFailureRecorded(removalFailed, YES);
    AssertTrue(removalFailed, "a later successful removal does not erase the prior failure");
}

static void TestOutputRestorePacketRetryPolicy(void) {
    AssertTrue(VBANOutputRestoreFailurePermitsPacketRetry(YES),
               "an available output permits packet-driven retry after a failed restore");
    AssertTrue(!VBANOutputRestoreFailurePermitsPacketRetry(NO),
               "an unavailable output still waits for an availability notification");
}

int main(void) {
    @autoreleasepool {
        TestBoundedIngressPolicy();
        TestDropNotificationCoalescing();
        TestAutomaticRepairEvidence();
        TestSafeFloatingPointSamples();
        TestAudioQueueConfigurationRateLimit();
        TestPlaybackSuccessNotificationPolicy();
        TestCoreAudioListenerContextReleasePolicy();
        TestOutputRestorePacketRetryPolicy();
        puts("vban_audio_player_policy_tests passed");
    }
    return 0;
}
