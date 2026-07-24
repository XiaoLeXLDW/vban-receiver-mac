#import "VBANPacket.h"
#import "VBANUDPReceiver.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

@interface VBANUDPReceiver (AddressKeyTesting)
- (NSData *)addressKeyFromSockaddr:(const struct sockaddr *)address length:(socklen_t)length;
@end

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

static int VBANTestIPv4SenderFD = -1;

static void SendPacket(NSData *packet, uint16_t port) {
    if (VBANTestIPv4SenderFD < 0) {
        VBANTestIPv4SenderFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    }
    AssertTrue(VBANTestIPv4SenderFD >= 0, "create sender socket");

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);

    ssize_t sent = sendto(VBANTestIPv4SenderFD,
                          packet.bytes,
                          packet.length,
                          0,
                          (struct sockaddr *)&address,
                          sizeof(address));
    AssertTrue(sent == (ssize_t)packet.length, "send udp packet");
}

static void SendPacketIPv6(NSData *packet, uint16_t port) {
    int fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
    AssertTrue(fd >= 0, "create ipv6 sender socket");

    struct sockaddr_in6 address;
    memset(&address, 0, sizeof(address));
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
    address.sin6_port = htons(port);
    address.sin6_addr = in6addr_loopback;

    ssize_t sent = sendto(fd,
                          packet.bytes,
                          packet.length,
                          0,
                          (struct sockaddr *)&address,
                          sizeof(address));
    close(fd);
    AssertTrue(sent == (ssize_t)packet.length, "send ipv6 udp packet");
}

static void SendPacketBurst(NSData *packet, uint16_t port, NSUInteger count) {
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    AssertTrue(fd >= 0, "create burst sender socket");

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);

    for (NSUInteger index = 0; index < count; index++) {
        ssize_t sent = sendto(fd,
                              packet.bytes,
                              packet.length,
                              0,
                              (struct sockaddr *)&address,
                              sizeof(address));
        AssertTrue(sent == (ssize_t)packet.length, "send udp packet burst");
    }
    close(fd);
}

static double MonotonicSeconds(void) {
    struct timespec now;
    AssertTrue(clock_gettime(CLOCK_MONOTONIC, &now) == 0, "read monotonic clock");
    return (double)now.tv_sec + ((double)now.tv_nsec / 1000000000.0);
}

static BOOL WaitForSignal(dispatch_semaphore_t semaphore) {
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
}

static BOOL WaitForSignalMilliseconds(dispatch_semaphore_t semaphore, int64_t milliseconds) {
    return dispatch_semaphore_wait(
               semaphore,
               dispatch_time(DISPATCH_TIME_NOW, milliseconds * NSEC_PER_MSEC)) == 0;
}

static void TestIPv6AddressScopeKeys(void) {
    VBANUDPReceiver *receiver = [[VBANUDPReceiver alloc] init];
    struct sockaddr_in6 first = {0};
    first.sin6_len = sizeof(first);
    first.sin6_family = AF_INET6;
    first.sin6_scope_id = 4;
    AssertTrue(inet_pton(AF_INET6, "fe80::1234", &first.sin6_addr) == 1,
               "parse link-local ipv6 fixture");
    struct sockaddr_in6 second = first;
    second.sin6_scope_id = 9;

    NSData *firstKey = [receiver addressKeyFromSockaddr:(const struct sockaddr *)&first
                                                length:sizeof(first)];
    NSData *secondKey = [receiver addressKeyFromSockaddr:(const struct sockaddr *)&second
                                                 length:sizeof(second)];
    AssertTrue(![firstKey isEqualToData:secondKey],
               "link-local ipv6 source keys include their interface scope");

    AssertTrue(inet_pton(AF_INET6, "2001:db8::1234", &first.sin6_addr) == 1,
               "parse global ipv6 fixture");
    second.sin6_addr = first.sin6_addr;
    firstKey = [receiver addressKeyFromSockaddr:(const struct sockaddr *)&first
                                        length:sizeof(first)];
    secondKey = [receiver addressKeyFromSockaddr:(const struct sockaddr *)&second
                                         length:sizeof(second)];
    AssertTrue([firstKey isEqualToData:secondKey],
               "global ipv6 source keys ignore irrelevant interface scopes");
}

static void TestOccupiedIPv4PortRejected(void) {
    int occupyingFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    AssertTrue(occupyingFD >= 0, "create occupying ipv4 socket");

    struct sockaddr_in occupiedAddress;
    memset(&occupiedAddress, 0, sizeof(occupiedAddress));
    occupiedAddress.sin_len = sizeof(occupiedAddress);
    occupiedAddress.sin_family = AF_INET;
    occupiedAddress.sin_port = 0;
    occupiedAddress.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    AssertTrue(bind(occupyingFD,
                    (struct sockaddr *)&occupiedAddress,
                    sizeof(occupiedAddress)) == 0,
               "bind occupying ipv4 socket");

    socklen_t occupiedLength = sizeof(occupiedAddress);
    AssertTrue(getsockname(occupyingFD,
                           (struct sockaddr *)&occupiedAddress,
                           &occupiedLength) == 0,
               "read occupying ipv4 port");
    uint16_t occupiedPort = ntohs(occupiedAddress.sin_port);
    AssertTrue(occupiedPort > 0, "occupying ipv4 socket exposes a port");

    VBANUDPReceiver *receiver = [[VBANUDPReceiver alloc] init];
    NSError *error = nil;
    BOOL started = [receiver startWithPort:occupiedPort
                                streamName:@"Stream1"
                                sourceHost:nil
                                     error:&error];
    AssertTrue(!started, "receiver rejects a port already occupied by ipv4");
    AssertTrue(error.code == EADDRINUSE, "occupied port reports EADDRINUSE");
    AssertTrue(receiver.localPort == 0, "failed bind does not report listening");
    close(occupyingFD);
}

int main(void) {
    @autoreleasepool {
        TestIPv6AddressScopeKeys();
        TestOccupiedIPv4PortRejected();
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
        receivedPacket = nil;
        receivedError = nil;
        started = [receiver startWithPort:0 streamName:@"Stream1" sourceHost:@"localhost" error:&error];
        AssertTrue(started, "start hostname-matched receiver");
        port = receiver.localPort;
        AssertTrue(port > 0, "hostname-matched receiver exposes local port");

        SendPacket(MakePacket(@"Stream1"), port);
        signaled = WaitForSignal(semaphore);
        [receiver stop];
        if (!signaled) {
            fprintf(stderr, "hostname receiver port: %u\n", port);
        }
        AssertTrue(signaled, "receive hostname-matched udp packet");
        AssertTrue(receivedError == nil, "no hostname-matched parse error");
        AssertTrue(receivedPacket != nil, "hostname-matched packet callback");

        semaphore = dispatch_semaphore_create(0);
        receivedPacket = nil;
        receivedError = nil;
        started = [receiver startWithPort:0 streamName:@"Stream1" sourceHost:@"[::1]" error:&error];
        AssertTrue(started, "start ipv6-source receiver");
        port = receiver.localPort;
        AssertTrue(port > 0, "ipv6-source receiver exposes local port");

        SendPacketIPv6(MakePacket(@"Stream1"), port);
        signaled = WaitForSignal(semaphore);
        [receiver stop];
        AssertTrue(signaled, "receive ipv6 source-matched udp packet");
        AssertTrue(receivedError == nil, "no ipv6 source-matched parse error");
        AssertTrue(receivedPacket != nil, "ipv6 source-matched packet callback");

        dispatch_semaphore_t beyondFirstDrain = dispatch_semaphore_create(0);
        __block NSUInteger receivedBatchCount = 0;
        receivedError = nil;
        receiver.packetHandler = ^(VBANPacket *packet) {
            (void)packet;
            receivedBatchCount++;
            if (receivedBatchCount == 65) {
                dispatch_semaphore_signal(beyondFirstDrain);
            }
        };
        started = [receiver startWithPort:0 streamName:@"Stream1" sourceHost:nil error:&error];
        AssertTrue(started, "start multi-batch receiver");
        port = receiver.localPort;
        AssertTrue(port > 0, "multi-batch receiver exposes local port");

        // UDP itself is allowed to drop datagrams. Send enough traffic to
        // prove processing continues beyond the receiver's 64-packet drain
        // limit without asserting lossless delivery of an exact burst.
        SendPacketBurst(MakePacket(@"Stream1"), port, 256);
        signaled = WaitForSignal(beyondFirstDrain);
        [receiver stop];
        AssertTrue(signaled, "dispatch source continues after a bounded drain");
        AssertTrue(receivedBatchCount >= 65, "more than one bounded drain is delivered");
        AssertTrue(receivedError == nil, "no multi-batch parse error");

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

        dispatch_semaphore_t firstSlowPacket = dispatch_semaphore_create(0);
        __block NSUInteger slowPacketCount = 0;
        receiver.filteredPacketHandler = nil;
        receiver.packetHandler = ^(VBANPacket *packet) {
            (void)packet;
            slowPacketCount++;
            if (slowPacketCount == 1) {
                dispatch_semaphore_signal(firstSlowPacket);
            }
            usleep(5000);
        };
        started = [receiver startWithPort:0 streamName:@"Stream1" sourceHost:nil error:&error];
        AssertTrue(started, "start bounded-drain receiver");
        port = receiver.localPort;
        AssertTrue(port > 0, "bounded-drain receiver exposes local port");

        SendPacketBurst(MakePacket(@"Stream1"), port, 600);
        AssertTrue(WaitForSignal(firstSlowPacket), "bounded-drain receiver begins processing");
        double stopStart = MonotonicSeconds();
        [receiver stop];
        double stopDuration = MonotonicSeconds() - stopStart;

        AssertTrue(stopDuration < 0.25, "stop yields promptly while udp packets remain queued");

        VBANUDPReceiver *rapidReceiver = [[VBANUDPReceiver alloc] init];
        uint16_t rapidPort = 0;
        for (NSUInteger iteration = 0; iteration < 128; iteration++) {
            dispatch_semaphore_t rapidSignal = dispatch_semaphore_create(0);
            rapidReceiver.packetHandler = ^(VBANPacket *packet) {
                (void)packet;
                dispatch_semaphore_signal(rapidSignal);
            };
            started = [rapidReceiver startWithPort:rapidPort
                                        streamName:@"Stream1"
                                        sourceHost:@"127.0.0.1"
                                             error:&error];
            AssertTrue(started, "rapid restart receiver binds after prior source cancellation");
            if (rapidPort == 0) {
                rapidPort = rapidReceiver.localPort;
            }
            SendPacket(MakePacket(@"Stream1"), rapidPort);
            BOOL rapidDelivered = WaitForSignalMilliseconds(rapidSignal, 250);
            if (!rapidDelivered) {
                // A UDP datagram is not a delivery guarantee; one retry keeps
                // this lifecycle test focused on source/fd reuse.
                SendPacket(MakePacket(@"Stream1"), rapidPort);
                rapidDelivered = WaitForSignalMilliseconds(rapidSignal, 500);
            }
            AssertTrue(rapidDelivered,
                       "rapid restart receiver accepts packets after source cancellation");
            [rapidReceiver stop];
            AssertTrue(rapidReceiver.localPort == 0,
                       "rapid restart receiver fully stops before descriptor reuse");
        }

        VBANUDPReceiver *callbackStopReceiver = [[VBANUDPReceiver alloc] init];
        __weak VBANUDPReceiver *weakCallbackStopReceiver = callbackStopReceiver;
        for (NSUInteger iteration = 0; iteration < 64; iteration++) {
            dispatch_semaphore_t callbackStopped = dispatch_semaphore_create(0);
            callbackStopReceiver.packetHandler = ^(VBANPacket *packet) {
                (void)packet;
                [weakCallbackStopReceiver stop];
                dispatch_semaphore_signal(callbackStopped);
            };
            started = [callbackStopReceiver startWithPort:0
                                               streamName:@"Stream1"
                                               sourceHost:@"127.0.0.1"
                                                    error:&error];
            AssertTrue(started, "callback-stop receiver starts");
            uint16_t callbackStopPort = callbackStopReceiver.localPort;
            AssertTrue(callbackStopPort > 0, "callback-stop receiver exposes local port");
            SendPacket(MakePacket(@"Stream1"), callbackStopPort);
            BOOL callbackDidStop =
                WaitForSignalMilliseconds(callbackStopped, 250);
            if (!callbackDidStop) {
                SendPacket(MakePacket(@"Stream1"), callbackStopPort);
                callbackDidStop = WaitForSignalMilliseconds(callbackStopped, 500);
            }
            if (!callbackDidStop) {
                fprintf(stderr, "callback-stop receiver port: %u\n", callbackStopPort);
            }
            AssertTrue(callbackDidStop, "receiver can stop from its packet callback");

            dispatch_semaphore_t restartedSignal = dispatch_semaphore_create(0);
            callbackStopReceiver.packetHandler = ^(VBANPacket *packet) {
                (void)packet;
                dispatch_semaphore_signal(restartedSignal);
            };
            started = [callbackStopReceiver startWithPort:callbackStopPort
                                               streamName:@"Stream1"
                                               sourceHost:@"127.0.0.1"
                                                    error:&error];
            AssertTrue(started,
                       "external restart waits for callback-initiated cancellation");
            SendPacket(MakePacket(@"Stream1"), callbackStopPort);
            BOOL restartedDelivered =
                WaitForSignalMilliseconds(restartedSignal, 250);
            if (!restartedDelivered) {
                SendPacket(MakePacket(@"Stream1"), callbackStopPort);
                restartedDelivered = WaitForSignalMilliseconds(restartedSignal, 500);
            }
            if (!restartedDelivered) {
                fprintf(stderr, "restarted receiver port: %u\n", callbackStopPort);
            }
            AssertTrue(restartedDelivered,
                       "callback-stopped receiver accepts packets after external restart");
            [callbackStopReceiver stop];
        }
        if (VBANTestIPv4SenderFD >= 0) {
            close(VBANTestIPv4SenderFD);
            VBANTestIPv4SenderFD = -1;
        }
        puts("vban_udp_tests passed");
    }
    return 0;
}
