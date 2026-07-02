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

static NSData *MakePacket(void) {
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
    memcpy(stream, "Stream1", 7);
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

int main(void) {
    @autoreleasepool {
        uint16_t port = 46980;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
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
        BOOL started = [receiver startWithPort:port streamName:@"Stream1" sourceHost:nil error:&error];
        AssertTrue(started, "start receiver");

        SendPacket(MakePacket(), port);
        long result = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        [receiver stop];

        AssertTrue(result == 0, "receive udp packet");
        AssertTrue(receivedError == nil, "no parse error");
        AssertTrue(receivedPacket != nil, "packet callback");
        AssertTrue([receivedPacket.streamName isEqualToString:@"Stream1"], "stream filter");
        AssertTrue(receivedPacket.frameCounter == 7, "frame counter");
        puts("vban_udp_tests passed");
    }
    return 0;
}
