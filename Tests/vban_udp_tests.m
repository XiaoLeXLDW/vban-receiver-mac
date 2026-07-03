#import "VBANPacket.h"
#import "VBANUDPReceiver.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

static void AssertTrue(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static NSData *MakePacket(NSString *streamName) {
    NSMutableData *data = [NSMutableData data];
    const uint8_t magic[] = {'V', 'B', 'A', 'N'};
    [data appendBytes:magic length:4];
    uint8_t header[] = {
        16,
        1,
        1,
        VBANDataTypeInt16
    };
    [data appendBytes:header length:4];

    uint8_t stream[16] = {0};
    NSData *streamData = [(streamName.length ? streamName : @"Stream1") dataUsingEncoding:NSASCIIStringEncoding];
    memcpy(stream, streamData.bytes, MIN((NSUInteger)16, streamData.length));
    [data appendBytes:stream length:16];

    uint32_t frameCounter = 7;
    uint8_t frame[] = {
        (uint8_t)(frameCounter & 0xFF),
        (uint8_t)((frameCounter >> 8) & 0xFF),
        (uint8_t)((frameCounter >> 16) & 0xFF),
        (uint8_t)((frameCounter >> 24) & 0xFF)
    };
    [data appendBytes:frame length:4];

    uint8_t payload[] = {
        0x00, 0x00, 0x00, 0x00,
        0xFF, 0x7F, 0x00, 0x80
    };
    [data appendBytes:payload length:sizeof(payload)];
    return data;
}

static void SendPacket(NSData *packet, uint16_t port) {
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    AssertTrue(fd >= 0, "create sender socket");

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);

    ssize_t sent = sendto(fd,
                          packet.bytes,
                          packet.length,
                          0,
                          (struct sockaddr *)&address,
                          sizeof(address));
    close(fd);
    AssertTrue(sent == (ssize_t)packet.length, "send udp packet");
}

static BOOL WaitForSignal(dispatch_semaphore_t semaphore) {
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
}

int main(void) {
    @autoreleasepool {
        __block dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        __block VBANPacket *receivedPacket = nil;
        __block NSError *receivedError = nil;

        VBANUDPReceiver *receiver = [[VBANUDPReceiver alloc] init];
        receiver.packetHandler = ^(VBANPacket *packet) {
            receivedPacket = packet;
            dispatch_semaphore_signal(semaphore);
        };
        receiver.parseErrorHandler = ^(NSError *error) {
            receivedError = error;
            dispatch_semaphore_signal(semaphore);
        };

        NSError *error = nil;
        BOOL started = [receiver startWithPort:0 streamName:@"Stream1" sourceHost:nil error:&error];
        AssertTrue(started, "start receiver");
        uint16_t port = receiver.localPort;
        AssertTrue(port > 0, "receiver exposes local port");

        SendPacket(MakePacket(@"Stream1"), port);
        BOOL signaled = WaitForSignal(semaphore);
        [receiver stop];

        AssertTrue(receiver.localPort == 0, "receiver clears local port after stop");
        AssertTrue(signaled, "receive udp packet");
        AssertTrue(receivedError == nil, "no parse error");
        AssertTrue(receivedPacket != nil, "packet callback");
        AssertTrue([receivedPacket.streamName isEqualToString:@"Stream1"], "stream filter");
        AssertTrue(receivedPacket.frameCounter == 7, "frame counter");

        semaphore = dispatch_semaphore_create(0);
        receivedPacket = nil;
        receivedError = nil;
        started = [receiver startWithPort:port streamName:@"Stream1" sourceHost:@"127.0.0.1" error:&error];
        AssertTrue(started, "restart receiver on previous port");
        AssertTrue(receiver.localPort == port, "receiver reuses requested port");

        SendPacket(MakePacket(@"Stream1"), port);
        signaled = WaitForSignal(semaphore);
        [receiver stop];
        AssertTrue(signaled, "receive source-matched udp packet");
        AssertTrue(receivedError == nil, "no source-matched parse error");
        AssertTrue(receivedPacket != nil, "source-matched packet callback");

        semaphore = dispatch_semaphore_create(0);
        __block NSUInteger filteredCount = 0;
        receivedPacket = nil;
        receiver.packetHandler = ^(VBANPacket *packet) {
            receivedPacket = packet;
            dispatch_semaphore_signal(semaphore);
        };
        receiver.filteredPacketHandler = ^{
            filteredCount++;
            dispatch_semaphore_signal(semaphore);
        };
        started = [receiver startWithPort:0 streamName:@"Other" sourceHost:nil error:&error];
        AssertTrue(started, "start stream-mismatch receiver");
        port = receiver.localPort;
        AssertTrue(port > 0, "stream-mismatch receiver exposes local port");

        SendPacket(MakePacket(@"Stream1"), port);
        signaled = WaitForSignal(semaphore);
        [receiver stop];
        AssertTrue(signaled, "stream mismatch reports filtered packet");
        AssertTrue(filteredCount == 1, "stream mismatch filtered count");
        AssertTrue(receivedPacket == nil, "stream mismatch suppresses packet callback");

        semaphore = dispatch_semaphore_create(0);
        filteredCount = 0;
        receivedPacket = nil;
        started = [receiver startWithPort:0 streamName:@"Stream1" sourceHost:@"192.0.2.1" error:&error];
        AssertTrue(started, "start source-mismatch receiver");
        port = receiver.localPort;
        AssertTrue(port > 0, "source-mismatch receiver exposes local port");

        SendPacket(MakePacket(@"Stream1"), port);
        signaled = WaitForSignal(semaphore);
        [receiver stop];
        AssertTrue(signaled, "source mismatch reports filtered packet");
        AssertTrue(filteredCount == 1, "source mismatch filtered count");
        AssertTrue(receivedPacket == nil, "source mismatch suppresses packet callback");
        puts("vban_udp_tests passed");
    }
    return 0;
}
