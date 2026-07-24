#import "VBANActivityPolicy.h"

static void AssertTrue(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        AssertTrue(VBANPacketAgeIsFresh(0), "new packet is fresh");
        AssertTrue(VBANPacketAgeIsFresh(1.999), "packet remains fresh inside window");
        AssertTrue(!VBANPacketAgeIsFresh(2.0), "packet expires at freshness boundary");
        AssertTrue(VBANPacketFreshnessDelay(0) == 2.0, "new packet schedules full freshness window");
        AssertTrue(VBANPacketFreshnessDelay(1.5) == 0.5, "freshness timer schedules remaining window");

        AssertTrue(!VBANShouldAnimateLevel(YES, NO, 0.5, 0.5), "stopped receiver does not animate");
        AssertTrue(!VBANShouldAnimateLevel(YES, YES, 0, 0), "waiting receiver does not animate");
        AssertTrue(VBANShouldAnimateLevel(YES, YES, 0, 0.5), "visible target level animates");
        AssertTrue(VBANShouldAnimateLevel(YES, YES, 0.5, 0), "visible fading level animates");
        AssertTrue(!VBANShouldAnimateLevel(NO, YES, 0.5, 0.5), "hidden presentation does not animate");

        puts("vban_activity_policy_tests passed");
    }
    return 0;
}
