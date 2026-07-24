#import "VBANOutputRecoveryPolicy.h"

static void AssertTrue(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static VBANOutputRecoveryFacts HealthyFacts(void) {
    return (VBANOutputRecoveryFacts) {
        .hasAudioQueue = YES,
        .outputAvailable = YES,
        .routeChanged = NO,
        .outputFormatCompatible = YES,
        .queueStarted = YES,
        .queueRunningKnown = YES,
        .queueRunning = YES,
        .hasPendingAudio = YES,
        .hasFreshInput = YES
    };
}

static void TestNotificationCoalescing(void) {
    VBANOutputNotificationState state = {0};
    state = VBANOutputNotificationNotice(state, 0.00);
    NSUInteger firstGeneration = state.generation;
    AssertTrue(fabs(VBANOutputNotificationDeadline(state.burstStartedAt,
                                                    state.lastNotificationAt) - 0.20) < 0.0001,
               "first notification is due after the quiet interval");

    state = VBANOutputNotificationNotice(state, 0.15);
    AssertTrue(fabs(VBANOutputNotificationDeadline(state.burstStartedAt,
                                                    state.lastNotificationAt) - 0.35) < 0.0001,
               "new notification moves the quiet deadline");
    AssertTrue(VBANOutputNotificationTimerDecision(state, 0.20, firstGeneration)
                   == VBANOutputNotificationTimerActionIgnore,
               "stale timer generation is ignored");
    AssertTrue(VBANOutputNotificationTimerDecision(state, 0.20, state.generation)
                   == VBANOutputNotificationTimerActionRearm,
               "early timer is rearmed instead of evaluating");
    AssertTrue(VBANOutputNotificationTimerDecision(state, 0.35, state.generation)
                   == VBANOutputNotificationTimerActionEvaluate,
               "quiet deadline evaluates once");

    state = VBANOutputNotificationCleared(state);
    AssertTrue(VBANOutputNotificationTimerDecision(state, 0.35, state.generation)
                   == VBANOutputNotificationTimerActionIgnore,
               "cleared burst ignores duplicate timer delivery");

    for (NSUInteger index = 0; index < 34; index++) {
        state = VBANOutputNotificationNotice(state, index * 0.03);
        AssertTrue(VBANOutputRecoveryDecisionForFacts(HealthyFacts()) == VBANOutputRecoveryDecisionNone,
                   "incidental notification never restarts a healthy queue");
    }
    AssertTrue(fabs(VBANOutputNotificationDeadline(state.burstStartedAt,
                                                    state.lastNotificationAt) - 1.00) < 0.0001,
               "notification storm is capped at one second");
    AssertTrue(VBANOutputNotificationTimerDecision(state, 1.00, state.generation)
                   == VBANOutputNotificationTimerActionEvaluate,
               "one-second cap forces evaluation");
}

static void TestRecoveryDecisions(void) {
    VBANOutputRecoveryFacts facts = HealthyFacts();
    facts.routeChanged = YES;
    AssertTrue(VBANOutputRecoveryDecisionForFacts(facts) == VBANOutputRecoveryDecisionRestartForRouteChange,
               "validated route change restarts once evaluated");
    facts.routeChanged = NO;
    AssertTrue(VBANOutputRecoveryDecisionForFacts(facts) == VBANOutputRecoveryDecisionNone,
               "adopting the new route prevents a duplicate restart");

    facts = HealthyFacts();
    facts.outputFormatCompatible = NO;
    AssertTrue(VBANOutputRecoveryDecisionForFacts(facts) == VBANOutputRecoveryDecisionRestartForFormatChange,
               "incompatible output format restarts");
    facts.outputFormatCompatible = YES;
    AssertTrue(VBANOutputRecoveryDecisionForFacts(facts) == VBANOutputRecoveryDecisionNone,
               "adopting the new output format prevents a duplicate restart");

    facts = HealthyFacts();
    facts.outputAvailable = NO;
    AssertTrue(VBANOutputRecoveryDecisionForFacts(facts) == VBANOutputRecoveryDecisionMarkUnavailable,
               "missing output is marked unavailable");

    facts = HealthyFacts();
    facts.queueRunning = NO;
    AssertTrue(VBANOutputRecoveryDecisionForFacts(facts) == VBANOutputRecoveryDecisionRestartForPlaybackStall,
               "stopped queue with pending audio and fresh input restarts");

    facts.hasFreshInput = NO;
    AssertTrue(VBANOutputRecoveryDecisionForFacts(facts) == VBANOutputRecoveryDecisionNone,
               "stopped queue without fresh input does not restart");

    facts = HealthyFacts();
    facts.hasPendingAudio = NO;
    facts.queueRunning = NO;
    AssertTrue(VBANOutputRecoveryDecisionForFacts(facts) == VBANOutputRecoveryDecisionNone,
               "naturally drained queue is not a playback stall");

    facts = HealthyFacts();
    facts.queueRunning = NO;
    facts.queueStarted = NO;
    AssertTrue(VBANOutputRecoveryDecisionForFacts(facts) == VBANOutputRecoveryDecisionNone,
               "unstarted queue is not a playback stall");
    facts.queueStarted = YES;
    facts.queueRunningKnown = NO;
    AssertTrue(VBANOutputRecoveryDecisionForFacts(facts) == VBANOutputRecoveryDecisionNone,
               "unknown running state is not a playback stall");
}

static void TestAvailabilityAlert(void) {
    AssertTrue(!VBANOutputShouldClearAvailabilityAlert(NO, NO, NO, YES, YES, YES),
               "device discovery alone does not clear output alert");
    AssertTrue(!VBANOutputShouldClearAvailabilityAlert(YES, YES, NO, YES, YES, YES),
               "created but stopped queue does not clear output alert");
    AssertTrue(!VBANOutputShouldClearAvailabilityAlert(YES, YES, YES, NO, YES, YES),
               "unavailable target does not clear output alert");
    AssertTrue(!VBANOutputShouldClearAvailabilityAlert(YES, YES, YES, YES, NO, YES),
               "wrong route does not clear output alert");
    AssertTrue(!VBANOutputShouldClearAvailabilityAlert(YES, YES, YES, YES, YES, NO),
               "stale queue generation does not clear output alert");
    AssertTrue(VBANOutputShouldClearAvailabilityAlert(YES, YES, YES, YES, YES, YES),
               "running queue clears output alert");
}

static void TestCapturedTrace(void) {
    NSString *path = @"Tests/fixtures/output_recovery_trace.json";
    NSData *data = [NSData dataWithContentsOfFile:path];
    AssertTrue(data != nil, "captured output recovery trace is readable");

    NSError *error = nil;
    NSArray<NSDictionary *> *events = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    AssertTrue(events != nil && error == nil, "captured output recovery trace is valid JSON");
    AssertTrue(events.count > 0, "captured output recovery trace is not empty");

    for (NSDictionary *event in events) {
        VBANOutputRecoveryFacts facts = {
            .hasAudioQueue = [event[@"hasAudioQueue"] boolValue],
            .outputAvailable = [event[@"outputAvailable"] boolValue],
            .routeChanged = [event[@"routeChanged"] boolValue],
            .outputFormatCompatible = [event[@"outputFormatCompatible"] boolValue],
            .queueStarted = [event[@"queueStarted"] boolValue],
            .queueRunningKnown = [event[@"queueRunningKnown"] boolValue],
            .queueRunning = [event[@"queueRunning"] boolValue],
            .hasPendingAudio = [event[@"hasPendingAudio"] boolValue],
            .hasFreshInput = [event[@"hasFreshInput"] boolValue]
        };
        NSString *decision = VBANOutputRecoveryDecisionName(VBANOutputRecoveryDecisionForFacts(facts));
        AssertTrue([decision isEqualToString:event[@"expectedDecision"]],
                   "captured healthy queue notification is ignored");
    }
}

int main(void) {
    @autoreleasepool {
        TestNotificationCoalescing();
        TestRecoveryDecisions();
        TestAvailabilityAlert();
        TestCapturedTrace();
        puts("vban_output_recovery_policy_tests passed");
    }
    return 0;
}
