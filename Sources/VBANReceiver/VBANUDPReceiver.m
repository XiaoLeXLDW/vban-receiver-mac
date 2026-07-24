#import "VBANUDPReceiver.h"
#import "VBANPacket.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static void *VBANUDPReceiverQueueKey = &VBANUDPReceiverQueueKey;
// Bound each source callback so lifecycle work queued by stop can always run.
static const NSUInteger VBANUDPDrainPacketLimit = 64;
static const uint64_t VBANUDPDrainTimeBudgetNanoseconds = 2 * NSEC_PER_MSEC;

static uint64_t VBANUDPMonotonicNanoseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return ((uint64_t)now.tv_sec * NSEC_PER_SEC) + (uint64_t)now.tv_nsec;
}

@interface VBANUDPReceiver ()

@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) dispatch_source_t source;
@property (nonatomic) dispatch_group_t sourceCancellationGroup;
@property (nonatomic, copy, nullable) NSString *streamName;
@property (nonatomic, copy, nullable) NSSet<NSData *> *sourceAddresses;
@property (nonatomic, assign) int socketFD;
@property (atomic, assign, readwrite) uint16_t localPort;
@property (atomic, assign) BOOL stopRequested;

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
    if (dispatch_get_specific(VBANUDPReceiverQueueKey) == (__bridge void *)self) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:EDEADLK
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"Cannot restart the UDP receiver from its own callback"}];
        }
        return NO;
    }
    [self stop];

    NSString *normalizedSourceHost =
        [sourceHost stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSSet<NSData *> *sourceAddresses = nil;
    if (normalizedSourceHost.length) {
        sourceAddresses = [self resolvedAddressesForSourceHost:normalizedSourceHost error:error];
        if (!sourceAddresses) {
            return NO;
        }
    }

    int fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        if (error) {
            *error = [self posixError:@"Cannot create UDP socket"];
        }
        return NO;
    }

    int receiveBufferSize = 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBufferSize, sizeof(receiveBufferSize));

    int no = 0;
    if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof(no)) < 0) {
        NSError *dualStackError = [self posixError:@"Cannot enable IPv4/IPv6 UDP reception"];
        close(fd);
        if (error) {
            *error = dualStackError;
        }
        return NO;
    }

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        NSError *flagsError = [self posixError:@"Cannot read UDP socket flags"];
        close(fd);
        if (error) {
            *error = flagsError;
        }
        return NO;
    }
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        NSError *nonblockingError = [self posixError:@"Cannot make UDP socket nonblocking"];
        close(fd);
        if (error) {
            *error = nonblockingError;
        }
        return NO;
    }

    uint16_t bindPort = port;
    if (bindPort == 0) {
        // On macOS, binding an IPv6 dual-stack socket directly to port zero
        // can select an ephemeral port already owned by an IPv4 socket that
        // opted into address reuse. Select through IPv4 first, then bind the
        // chosen explicit port below so a conflict is reported instead of
        // entering a false Listening state.
        int selectorFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (selectorFD < 0) {
            NSError *selectorError = [self posixError:@"Cannot select an available UDP port"];
            close(fd);
            if (error) {
                *error = selectorError;
            }
            return NO;
        }

        struct sockaddr_in selectorAddress;
        memset(&selectorAddress, 0, sizeof(selectorAddress));
        selectorAddress.sin_len = sizeof(selectorAddress);
        selectorAddress.sin_family = AF_INET;
        selectorAddress.sin_addr.s_addr = htonl(INADDR_ANY);
        selectorAddress.sin_port = 0;
        if (bind(selectorFD,
                 (struct sockaddr *)&selectorAddress,
                 sizeof(selectorAddress)) < 0) {
            NSError *selectorError = [self posixError:@"Cannot select an available UDP port"];
            close(selectorFD);
            close(fd);
            if (error) {
                *error = selectorError;
            }
            return NO;
        }

        socklen_t selectorLength = sizeof(selectorAddress);
        if (getsockname(selectorFD,
                        (struct sockaddr *)&selectorAddress,
                        &selectorLength) < 0) {
            NSError *selectorError = [self posixError:@"Cannot read the selected UDP port"];
            close(selectorFD);
            close(fd);
            if (error) {
                *error = selectorError;
            }
            return NO;
        }
        bindPort = ntohs(selectorAddress.sin_port);
        if (bindPort == 0) {
            close(selectorFD);
            close(fd);
            if (error) {
                *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:EADDRNOTAVAIL
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        @"Cannot select a nonzero UDP port"}];
            }
            return NO;
        }
        close(selectorFD);
    }

    struct sockaddr_in6 address;
    memset(&address, 0, sizeof(address));
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
    address.sin6_addr = in6addr_any;
    address.sin6_port = htons(bindPort);

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
    uint16_t localPort = bindPort;
    if (getsockname(fd, (struct sockaddr *)&boundAddress, &boundLength) == 0) {
        localPort = ntohs(boundAddress.sin6_port);
    }

    dispatch_source_t source =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, self.queue);
    if (!source) {
        close(fd);
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                         code:ENOMEM
                                     userInfo:@{NSLocalizedDescriptionKey: @"Cannot create UDP dispatch source"}];
        }
        return NO;
    }

    dispatch_group_t cancellationGroup = dispatch_group_create();
    dispatch_group_enter(cancellationGroup);
    int sourceFD = fd;
    dispatch_queue_t receiverQueue = self.queue;
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_cancel_handler(source, ^{
        close(sourceFD);
        // Leave from the next receiver-queue turn, after the cancel handler
        // itself has returned and libdispatch has finished retiring the old
        // source. A waiter may otherwise rebind the same port in the tiny
        // interval between group_leave() and cancel-handler return.
        dispatch_async(receiverQueue, ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (self
                && self.sourceCancellationGroup == cancellationGroup
                && !self.source) {
                self.sourceCancellationGroup = nil;
            }
            dispatch_group_leave(cancellationGroup);
        });
    });
    dispatch_source_set_event_handler(source, ^{
        [weakSelf drainSocket];
    });
    dispatch_sync(self.queue, ^{
        self.socketFD = fd;
        self.localPort = localPort;
        self.streamName = streamName.length ? streamName : nil;
        self.sourceAddresses = sourceAddresses;
        self.sourceCancellationGroup = cancellationGroup;
        self.source = source;
        self.stopRequested = NO;
        dispatch_resume(source);
    });

    void (^stateHandler)(NSString *) = self.stateHandler;
    if (stateHandler) {
        stateHandler(@"Listening");
    }
    return YES;
}

- (void)stop {
    self.stopRequested = YES;

    __block dispatch_group_t cancellationGroup = nil;
    __block int descriptorWithoutSource = -1;
    void (^stopBlock)(void) = ^{
        dispatch_source_t source = self.source;
        int fd = self.socketFD;
        cancellationGroup = self.sourceCancellationGroup;
        self.source = nil;
        self.socketFD = -1;
        self.localPort = 0;
        self.streamName = nil;
        self.sourceAddresses = nil;

        if (source) {
            dispatch_source_cancel(source);
        } else {
            descriptorWithoutSource = fd;
        }
    };

    BOOL calledFromReceiverQueue =
        dispatch_get_specific(VBANUDPReceiverQueueKey) == (__bridge void *)self;
    if (calledFromReceiverQueue) {
        stopBlock();
    } else {
        dispatch_sync(self.queue, stopBlock);
    }

    if (descriptorWithoutSource >= 0) {
        close(descriptorWithoutSource);
    }
    if (cancellationGroup && !calledFromReceiverQueue) {
        dispatch_group_wait(cancellationGroup, DISPATCH_TIME_FOREVER);
    }

    void (^stateHandler)(NSString *) = self.stateHandler;
    if (stateHandler) {
        stateHandler(@"Stopped");
    }
}

- (void)drainSocket {
    if (self.socketFD < 0 || self.stopRequested) {
        return;
    }

    NSUInteger drainedPacketCount = 0;
    uint64_t drainStartedAt = VBANUDPMonotonicNanoseconds();
    while (!self.stopRequested && drainedPacketCount < VBANUDPDrainPacketLimit) {
        if (drainedPacketCount > 0 && drainStartedAt > 0) {
            uint64_t now = VBANUDPMonotonicNanoseconds();
            if (now > drainStartedAt &&
                now - drainStartedAt >= VBANUDPDrainTimeBudgetNanoseconds) {
                return;
            }
        }

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
            void (^parseErrorHandler)(NSError *) = self.parseErrorHandler;
            if (parseErrorHandler) {
                parseErrorHandler([self posixError:@"UDP receive failed"]);
            }
            return;
        }
        drainedPacketCount++;

        if (self.stopRequested) {
            return;
        }

        NSData *data = [NSData dataWithBytes:buffer length:(NSUInteger)byteCount];
        NSString *sender = [self senderStringFromAddress:&senderAddress length:senderLength host:NULL];

        NSData *sourceAddress = [self addressKeyFromSockaddr:(struct sockaddr *)&senderAddress
                                                     length:senderLength];
        if (self.sourceAddresses.count &&
            (!sourceAddress || ![self.sourceAddresses containsObject:sourceAddress])) {
            void (^filteredPacketHandler)(void) = self.filteredPacketHandler;
            if (filteredPacketHandler) {
                filteredPacketHandler();
            }
            continue;
        }

        NSError *error = nil;
        VBANPacket *packet = [VBANPacket packetWithData:data sender:sender error:&error];
        if (!packet) {
            void (^parseErrorHandler)(NSError *) = self.parseErrorHandler;
            if (parseErrorHandler) {
                parseErrorHandler(error);
            }
            continue;
        }

        if (self.streamName.length && ![self.streamName isEqualToString:packet.streamName]) {
            void (^filteredPacketHandler)(void) = self.filteredPacketHandler;
            if (filteredPacketHandler) {
                filteredPacketHandler();
            }
            continue;
        }

        void (^packetHandler)(VBANPacket *) = self.packetHandler;
        if (packetHandler) {
            packetHandler(packet);
        }
    }
}

- (NSSet<NSData *> *)resolvedAddressesForSourceHost:(NSString *)sourceHost error:(NSError **)error {
    NSString *host = sourceHost;
    if ([host hasPrefix:@"["] && [host hasSuffix:@"]"] && host.length > 2) {
        host = [host substringWithRange:NSMakeRange(1, host.length - 2)];
    }

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_protocol = IPPROTO_UDP;

    struct addrinfo *results = NULL;
    int result = getaddrinfo(host.UTF8String, NULL, &hints, &results);
    if (result != 0) {
        if (error) {
            const char *reasonCString = gai_strerror(result);
            NSString *reason = reasonCString ? [NSString stringWithUTF8String:reasonCString] : nil;
            NSString *message = [NSString stringWithFormat:@"Cannot resolve source host '%@': %@",
                                                           sourceHost,
                                                           reason ?: @"unknown address error"];
            *error = [NSError errorWithDomain:@"VBANUDPReceiverAddressErrorDomain"
                                         code:result
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
        }
        return nil;
    }

    NSMutableSet<NSData *> *addresses = [NSMutableSet set];
    for (struct addrinfo *entry = results; entry; entry = entry->ai_next) {
        NSData *address = [self addressKeyFromSockaddr:entry->ai_addr length:(socklen_t)entry->ai_addrlen];
        if (address) {
            [addresses addObject:address];
        }
    }
    freeaddrinfo(results);

    if (!addresses.count) {
        if (error) {
            *error = [NSError errorWithDomain:@"VBANUDPReceiverAddressErrorDomain"
                                         code:EADDRNOTAVAIL
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:
                                                                  @"Source host '%@' has no usable IPv4 or IPv6 address",
                                                                  sourceHost]}];
        }
        return nil;
    }

    return [addresses copy];
}

- (NSData *)addressKeyFromSockaddr:(const struct sockaddr *)address length:(socklen_t)length {
    if (!address) {
        return nil;
    }

    NSMutableData *key = [NSMutableData dataWithCapacity:21];
    if (address->sa_family == AF_INET && length >= sizeof(struct sockaddr_in)) {
        struct sockaddr_in ipv4;
        memcpy(&ipv4, address, sizeof(ipv4));
        const uint8_t family = 4;
        [key appendBytes:&family length:sizeof(family)];
        [key appendBytes:&ipv4.sin_addr length:sizeof(ipv4.sin_addr)];
        return key;
    }

    if (address->sa_family == AF_INET6 && length >= sizeof(struct sockaddr_in6)) {
        struct sockaddr_in6 ipv6;
        memcpy(&ipv6, address, sizeof(ipv6));
        if (IN6_IS_ADDR_V4MAPPED(&ipv6.sin6_addr)) {
            const uint8_t family = 4;
            [key appendBytes:&family length:sizeof(family)];
            [key appendBytes:&ipv6.sin6_addr.s6_addr[12] length:sizeof(struct in_addr)];
        } else {
            const uint8_t family = 6;
            [key appendBytes:&family length:sizeof(family)];
            [key appendBytes:&ipv6.sin6_addr length:sizeof(ipv6.sin6_addr)];
            if (IN6_IS_ADDR_LINKLOCAL(&ipv6.sin6_addr)
                || IN6_IS_ADDR_MC_LINKLOCAL(&ipv6.sin6_addr)) {
                uint32_t scope = htonl(ipv6.sin6_scope_id);
                [key appendBytes:&scope length:sizeof(scope)];
            }
        }
        return key;
    }

    return nil;
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
    int errorCode = errno;
    NSString *message = [NSString stringWithFormat:@"%@: %s", prefix, strerror(errorCode)];
    return [NSError errorWithDomain:NSPOSIXErrorDomain
                               code:errorCode
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@end
