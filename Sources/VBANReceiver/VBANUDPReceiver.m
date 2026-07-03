#import "VBANUDPReceiver.h"
#import "VBANPacket.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

static void *VBANUDPReceiverQueueKey = &VBANUDPReceiverQueueKey;

@interface VBANUDPReceiver ()

@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) dispatch_source_t source;
@property (nonatomic, copy, nullable) NSString *streamName;
@property (nonatomic, copy, nullable) NSString *sourceHost;
@property (nonatomic, assign) int socketFD;
@property (nonatomic, assign, readwrite) uint16_t localPort;

@end

@implementation VBANUDPReceiver

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("local.codex.vban.udp", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_queue, VBANUDPReceiverQueueKey, (__bridge void *)self, NULL);
        _socketFD = -1;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)startWithPort:(uint16_t)port
           streamName:(NSString *)streamName
           sourceHost:(NSString *)sourceHost
                error:(NSError **)error {
    [self stop];

    int fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        if (error) {
            *error = [self posixError:@"Cannot create UDP socket"];
        }
        return NO;
    }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    int receiveBufferSize = 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBufferSize, sizeof(receiveBufferSize));

    int no = 0;
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no));

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }

    struct sockaddr_in6 address;
    memset(&address, 0, sizeof(address));
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
    address.sin6_addr = in6addr_any;
    address.sin6_port = htons(port);

    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        NSError *bindError = [self posixError:@"Cannot bind UDP port"];
        close(fd);
        if (error) {
            *error = bindError;
        }
        return NO;
    }

    struct sockaddr_in6 boundAddress;
    memset(&boundAddress, 0, sizeof(boundAddress));
    socklen_t boundLength = sizeof(boundAddress);
    uint16_t localPort = port;
    if (getsockname(fd, (struct sockaddr *)&boundAddress, &boundLength) == 0) {
        localPort = ntohs(boundAddress.sin6_port);
    }

    self.socketFD = fd;
    self.localPort = localPort;
    self.streamName = streamName.length ? streamName : nil;
    self.sourceHost = sourceHost.length ? sourceHost : nil;
    self.source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, self.queue);
    if (!self.source) {
        close(fd);
        self.socketFD = -1;
        self.localPort = 0;
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:ENOMEM
                                     userInfo:@{NSLocalizedDescriptionKey: @"Cannot create UDP dispatch source"}];
        }
        return NO;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.source, ^{
        [weakSelf drainSocket];
    });
    dispatch_resume(self.source);

    if (self.stateHandler) {
        self.stateHandler(@"Listening");
    }
    return YES;
}

- (void)stop {
    void (^stopBlock)(void) = ^{
        dispatch_source_t source = self.source;
        int fd = self.socketFD;
        self.source = nil;
        self.socketFD = -1;
        self.localPort = 0;

        if (source) {
            dispatch_source_cancel(source);
        }
        if (fd >= 0) {
            close(fd);
        }
    };

    if (dispatch_get_specific(VBANUDPReceiverQueueKey) == (__bridge void *)self) {
        stopBlock();
    } else {
        dispatch_sync(self.queue, stopBlock);
    }

    if (self.stateHandler) {
        self.stateHandler(@"Stopped");
    }
}

- (void)drainSocket {
    if (self.socketFD < 0) {
        return;
    }

    while (YES) {
        uint8_t buffer[65535];
        struct sockaddr_storage senderAddress;
        socklen_t senderLength = sizeof(senderAddress);
        int fd = self.socketFD;
        if (fd < 0) {
            return;
        }

        ssize_t byteCount = recvfrom(fd,
                                     buffer,
                                     sizeof(buffer),
                                     0,
                                     (struct sockaddr *)&senderAddress,
                                     &senderLength);

        if (byteCount < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                return;
            }
            if (self.parseErrorHandler) {
                self.parseErrorHandler([self posixError:@"UDP receive failed"]);
            }
            return;
        }

        NSData *data = [NSData dataWithBytes:buffer length:(NSUInteger)byteCount];
        NSString *host = nil;
        NSString *sender = [self senderStringFromAddress:&senderAddress length:senderLength host:&host];

        if (self.sourceHost.length && ![self.sourceHost isEqualToString:host]) {
            if (self.filteredPacketHandler) {
                self.filteredPacketHandler();
            }
            continue;
        }

        NSError *error = nil;
        VBANPacket *packet = [VBANPacket packetWithData:data sender:sender error:&error];
        if (!packet) {
            if (self.parseErrorHandler) {
                self.parseErrorHandler(error);
            }
            continue;
        }

        if (self.streamName.length && ![self.streamName isEqualToString:packet.streamName]) {
            if (self.filteredPacketHandler) {
                self.filteredPacketHandler();
            }
            continue;
        }

        if (self.packetHandler) {
            self.packetHandler(packet);
        }
    }
}

- (NSString *)senderStringFromAddress:(struct sockaddr_storage *)address
                               length:(socklen_t)length
                                 host:(NSString **)hostOut {
    char host[NI_MAXHOST];
    char service[NI_MAXSERV];
    int result = getnameinfo((struct sockaddr *)address,
                             length,
                             host,
                             sizeof(host),
                             service,
                             sizeof(service),
                             NI_NUMERICHOST | NI_NUMERICSERV);
    if (result != 0) {
        if (hostOut) {
            *hostOut = @"unknown";
        }
        return @"unknown";
    }

    NSString *hostString = [NSString stringWithUTF8String:host] ?: @"unknown";
    if ([hostString hasPrefix:@"::ffff:"]) {
        hostString = [hostString substringFromIndex:7];
    }
    NSString *serviceString = [NSString stringWithUTF8String:service] ?: @"";
    if (hostOut) {
        *hostOut = hostString;
    }
    return serviceString.length ? [NSString stringWithFormat:@"%@:%@", hostString, serviceString] : hostString;
}

- (NSError *)posixError:(NSString *)prefix {
    NSString *message = [NSString stringWithFormat:@"%@: %s", prefix, strerror(errno)];
    return [NSError errorWithDomain:NSPOSIXErrorDomain
                               code:errno
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
