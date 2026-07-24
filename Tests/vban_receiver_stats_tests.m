#import "VBANPacket.h"
#import "VBANReceiverStatsAccumulator.h"

static void AssertTrue(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static VBANPacket *MakePacket(NSString *sender, NSString *streamName, uint32_t frameCounter) {
    NSMutableData *data = [NSMutableData data];
    const uint8_t magic[] = {'V', 'B', 'A', 'N'};
    [data appendBytes:magic length:sizeof(magic)];
    uint8_t format[] = {16, 0, 0, VBANDataTypeInt16};
    [data appendBytes:format length:sizeof(format)];

    uint8_t stream[16] = {0};
    NSData *streamData = [streamName dataUsingEncoding:NSASCIIStringEncoding];
    memcpy(stream, streamData.bytes, MIN(sizeof(stream), streamData.length));
    [data appendBytes:stream length:sizeof(stream)];

    uint8_t frame[] = {
        (uint8_t)(frameCounter & 0xFF),
        (uint8_t)((frameCounter >> 8) & 0xFF),
        (uint8_t)((frameCounter >> 16) & 0xFF),
        (uint8_t)((frameCounter >> 24) & 0xFF)
    };
    [data appendBytes:frame length:sizeof(frame)];
    uint8_t payload[] = {0, 0};
    [data appendBytes:payload length:sizeof(payload)];

    NSError *error = nil;
    VBANPacket *packet = [VBANPacket packetWithData:data sender:sender error:&error];
    AssertTrue(packet != nil && error == nil, "build packet fixture");
    return packet;
}

static void TestRefreshCoalescing(void) {
    VBANReceiverStatsAccumulator *stats = [[VBANReceiverStatsAccumulator alloc] init];
    AssertTrue([stats recordPacket:MakePacket(@"127.0.0.1:1", @"Stream", 1) uptime:1],
               "first event schedules refresh");
    AssertTrue(![stats recordPacket:MakePacket(@"127.0.0.1:1", @"Stream", 2) uptime:2],
               "second event coalesces into pending refresh");

    VBANReceiverStatsSnapshot *snapshot = [stats drainSnapshot];
    AssertTrue(snapshot.packetDelta == 2, "coalesced packet count is preserved");
    AssertTrue(snapshot.latestPacket.frameCounter == 2, "coalesced refresh keeps latest packet");
    AssertTrue([stats recordFilteredPacket], "drain permits one new refresh");
}

static void TestLatePacketRepairsGapWithoutRegressingWatermark(void) {
    VBANReceiverStatsAccumulator *stats = [[VBANReceiverStatsAccumulator alloc] init];
    [stats recordPacket:MakePacket(@"127.0.0.1:1", @"Stream", 100) uptime:1];
    [stats recordPacket:MakePacket(@"127.0.0.1:1", @"Stream", 102) uptime:2];
    [stats recordPacket:MakePacket(@"127.0.0.1:1", @"Stream", 101) uptime:3];
    [stats recordPacket:MakePacket(@"127.0.0.1:1", @"Stream", 103) uptime:4];

    VBANReceiverStatsSnapshot *snapshot = [stats drainSnapshot];
    AssertTrue(snapshot.packetDelta == 4, "all reordered packets are counted");
    AssertTrue(snapshot.missingPacketDelta == 0, "late packet repairs temporary gap");
}

static void TestLatePacketRepairsGapAcrossRefreshDrains(void) {
    VBANReceiverStatsAccumulator *stats = [[VBANReceiverStatsAccumulator alloc] init];
    [stats recordPacket:MakePacket(@"127.0.0.1:1", @"Stream", 100) uptime:1];
    [stats recordPacket:MakePacket(@"127.0.0.1:1", @"Stream", 102) uptime:2];
    VBANReceiverStatsSnapshot *snapshot = [stats drainSnapshot];
    AssertTrue(snapshot.missingPacketDelta == 1, "a temporary gap is visible after a refresh drain");

    [stats recordPacket:MakePacket(@"127.0.0.1:1", @"Stream", 101) uptime:3];
    snapshot = [stats drainSnapshot];
    AssertTrue(snapshot.missingPacketDelta == -1, "a late packet repairs a gap across refresh drains");

    [stats recordPacket:MakePacket(@"127.0.0.1:1", @"Stream", 103) uptime:4];
    snapshot = [stats drainSnapshot];
    AssertTrue(snapshot.missingPacketDelta == 0, "the repaired watermark remains contiguous");
}

static void TestWraparoundAndIdentityBound(void) {
    VBANReceiverStatsAccumulator *stats =
        [[VBANReceiverStatsAccumulator alloc] initWithMaximumTrackedIdentities:2
                                                                reorderWindow:8];
    [stats recordPacket:MakePacket(@"127.0.0.1:1", @"A", UINT32_MAX) uptime:1];
    [stats recordPacket:MakePacket(@"127.0.0.1:1", @"A", 0) uptime:2];
    [stats recordPacket:MakePacket(@"127.0.0.1:2", @"B", 1) uptime:3];
    [stats recordPacket:MakePacket(@"127.0.0.1:3", @"C", 1) uptime:4];

    VBANReceiverStatsSnapshot *snapshot = [stats drainSnapshot];
    AssertTrue(snapshot.missingPacketDelta == 0, "frame counter wraparound is contiguous");
    AssertTrue(stats.trackedIdentityCount == 2, "attacker-controlled identities remain bounded");
}

static void TestReorderStorageRemainsBoundedWithinOneIdentity(void) {
    const NSUInteger reorderWindow = 64;
    VBANReceiverStatsAccumulator *stats =
        [[VBANReceiverStatsAccumulator alloc] initWithMaximumTrackedIdentities:1
                                                                reorderWindow:reorderWindow];
    uint32_t frameCounter = 0;
    [stats recordPacket:MakePacket(@"127.0.0.1:1", @"A", frameCounter) uptime:0];
    for (NSUInteger index = 1; index <= 1000; index++) {
        frameCounter += (uint32_t)reorderWindow + 1;
        [stats recordPacket:MakePacket(@"127.0.0.1:1", @"A", frameCounter) uptime:index];
        AssertTrue(stats.pendingReorderCounterCount <= reorderWindow,
                   "one identity cannot accumulate gaps outside the reorder window");
    }
    AssertTrue(stats.trackedIdentityCount == 1, "bounded gap test uses one identity");
}

static void TestLatestNetworkErrorWinsWithinBatch(void) {
    VBANReceiverStatsAccumulator *stats = [[VBANReceiverStatsAccumulator alloc] init];
    NSError *error = [NSError errorWithDomain:@"test"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"bad packet"}];
    [stats recordBadPacketError:error fallbackMessage:@"fallback"];
    [stats recordPacket:MakePacket(@"127.0.0.1:1", @"A", 1) uptime:1];
    VBANReceiverStatsSnapshot *snapshot = [stats drainSnapshot];
    AssertTrue(snapshot.badPacketDelta == 1, "bad packet count is preserved");
    AssertTrue(snapshot.hasNetworkErrorUpdate, "network error state has an update");
    AssertTrue(snapshot.networkErrorMessage.length == 0, "later valid packet clears network error");
}

int main(void) {
    @autoreleasepool {
        TestRefreshCoalescing();
        TestLatePacketRepairsGapWithoutRegressingWatermark();
        TestLatePacketRepairsGapAcrossRefreshDrains();
        TestWraparoundAndIdentityBound();
        TestReorderStorageRemainsBoundedWithinOneIdentity();
        TestLatestNetworkErrorWinsWithinBatch();
        puts("vban_receiver_stats_tests passed");
    }
    return 0;
}
