#import "VBANAudioPlayer.h"
#import "VBANActivityPolicy.h"
#import "VBANCountCoalescer.h"
#import "VBANOutputRecoveryPolicy.h"
#import "VBANPacket.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <sys/file.h>
#import <unistd.h>

static const NSUInteger VBANDiagnosticLogMaximumBytes = 10 * 1024 * 1024;
static const NSUInteger VBANDiagnosticLogBackupCount = 2;
static const NSUInteger VBANAudioIngressMaximumPendingTasks = 256;
static const NSUInteger VBANAudioIngressMaximumPendingBytes = 8 * 1024 * 1024;
static const NSTimeInterval VBANAudioQueueConfigurationMinimumInterval = 1.0;
static const void *VBANAudioQueueSpecificKey = &VBANAudioQueueSpecificKey;
static const void *VBANDiagnosticQueueSpecificKey = &VBANDiagnosticQueueSpecificKey;

static NSTimeInterval VBANMonotonicTime(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

typedef NS_ENUM(NSInteger, VBANAutomaticRepairSignal) {
    VBANAutomaticRepairSignalNone = 0,
    VBANAutomaticRepairSignalDeviceNotRunning = 1,
    VBANAutomaticRepairSignalQueueLagging = 2
};

BOOL VBANAudioIngressCanAcceptPacket(NSUInteger pendingTaskCount,
                                     NSUInteger pendingBytes,
                                     NSUInteger packetBytes,
                                     NSUInteger maximumTaskCount,
                                     NSUInteger maximumBytes) {
    if (pendingTaskCount >= maximumTaskCount || packetBytes > maximumBytes) {
        return NO;
    }
    return pendingBytes <= maximumBytes - packetBytes;
}

NSInteger VBANAudioAutomaticRepairSignal(BOOL autoRepairEnabled,
                                         BOOL queueStarted,
                                         BOOL hasFreshPackets,
                                         BOOL queueReportsRunning,
                                         BOOL hasScheduledFrames,
                                         BOOL deviceRunningKnown,
                                         BOOL deviceRunning,
                                         double queuedDuration,
                                         double maximumQueuedDuration,
                                         __unused BOOL manualRepairRecently) {
    if (!autoRepairEnabled
        || !queueStarted
        || !hasFreshPackets
        || !queueReportsRunning
        || !hasScheduledFrames) {
        return VBANAutomaticRepairSignalNone;
    }
    if (deviceRunningKnown && !deviceRunning) {
        return VBANAutomaticRepairSignalDeviceNotRunning;
    }
    if (queuedDuration > fmax(0.65, maximumQueuedDuration * 0.85)) {
        return VBANAutomaticRepairSignalQueueLagging;
    }
    return VBANAutomaticRepairSignalNone;
}

float VBANAudioSanitizedFloatSample(double value) {
    if (!isfinite(value)) {
        return 0.0f;
    }
    float sample = (float)value;
    if (!isfinite(sample)) {
        return value < 0 ? -1.0f : 1.0f;
    }
    return fminf(fmaxf(sample, -1.0f), 1.0f);
}

BOOL VBANAudioQueueConfigurationAttemptAllowed(BOOL configurationRequired,
                                                double secondsSinceLastAttempt) {
    return !configurationRequired
        || secondsSinceLastAttempt < 0
        || secondsSinceLastAttempt >= VBANAudioQueueConfigurationMinimumInterval;
}

BOOL VBANAudioPlaybackNotificationNeeded(BOOL hasAudioQueue,
                                         BOOL audioQueueStarted,
                                         NSUInteger generation,
                                         NSUInteger notifiedGeneration) {
    return hasAudioQueue
        && audioQueueStarted
        && generation != notifiedGeneration;
}

static OSStatus VBANCoreAudioOutputChanged(AudioObjectID inObjectID,
                                           UInt32 inNumberAddresses,
                                           const AudioObjectPropertyAddress inAddresses[],
                                           void *inClientData);
static void VBANAudioQueueIsRunningChanged(void *inUserData,
                                           AudioQueueRef inAQ,
                                           AudioQueuePropertyID inID);
static void VBANAudioQueueOutputCompleted(void *inUserData,
                                          AudioQueueRef inAQ,
                                          AudioQueueBufferRef inBuffer);

@class VBANOutputDeviceState;
@class VBANCoreAudioListenerContext;
@class VBANAudioQueueCallbackContext;

@interface VBANAudioPlayer ()

@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) dispatch_queue_t diagnosticQueue;
@property (nonatomic, strong) NSObject *ingressLock;
@property (nonatomic, assign) VBANPlaybackProfile configuredPlaybackProfile;
@property (nonatomic, assign) float configuredOutputVolume;
@property (nonatomic, assign) BOOL configuredLocksOutputDevice;
@property (nonatomic, assign) BOOL configuredAutoRepairsOutput;
@property (nonatomic, assign) BOOL configuredLevelReportingEnabled;
@property (nonatomic, assign) AudioQueueRef audioQueue;
@property (nonatomic, assign, nullable) void *audioQueueCallbackContext;
@property (nonatomic, assign) NSUInteger audioQueueGeneration;
@property (nonatomic, assign) NSUInteger notifiedPlaybackGeneration;
@property (nonatomic, assign) AudioStreamBasicDescription queueFormat;
@property (nonatomic, assign) NSInteger scheduledBuffers;
@property (nonatomic, assign) UInt64 scheduledFrames;
@property (nonatomic, assign) NSUInteger pendingPacketTasks;
@property (nonatomic, assign) NSUInteger pendingPacketBytes;
@property (nonatomic, strong) VBANCountCoalescer *queueDropCoalescer;
@property (nonatomic, assign) CFAbsoluteTime lastAudioQueueConfigurationAttemptAt;
@property (nonatomic, assign) NSInteger maxQueuedBuffers;
@property (nonatomic, assign) NSTimeInterval maxQueuedDuration;
@property (nonatomic, assign) NSInteger startBufferCount;
@property (nonatomic, assign) NSTimeInterval levelReportInterval;
@property (nonatomic, assign) CFAbsoluteTime lastLevelReportAt;
@property (nonatomic, assign) CFAbsoluteTime lastIntentionalEngineConfigurationAt;
@property (nonatomic, assign) CFAbsoluteTime lastOutputRecoveryAt;
@property (nonatomic, assign) CFAbsoluteTime lastAutomaticOutputRepairAt;
@property (nonatomic, assign) CFAbsoluteTime lastManualOutputReconnectAt;
@property (nonatomic, assign) CFAbsoluteTime lastPacketEnqueuedAt;
@property (nonatomic, assign) CFAbsoluteTime autoRepairSuspicionStartedAt;
@property (nonatomic, assign) AudioObjectID observedOutputDeviceID;
@property (nonatomic, assign) AudioObjectID lockedOutputDeviceID;
@property (nonatomic, copy, nullable) NSString *lockedOutputDeviceUID;
@property (nonatomic, assign) BOOL lockedOutputIdentityCaptured;
@property (nonatomic, assign) BOOL hasQueueFormat;
@property (nonatomic, assign) BOOL audioQueueStarted;
@property (nonatomic, assign) BOOL hasDefaultOutputListener;
@property (nonatomic, assign) BOOL hasDefaultSystemOutputListener;
@property (nonatomic, assign) BOOL hasDeviceListListener;
@property (nonatomic, assign) BOOL hasOutputDeviceListeners;
@property (nonatomic, assign) BOOL priorDeviceListenerRemovalFailed;
@property (nonatomic, assign, nullable) void *coreAudioListenerContext;
@property (nonatomic, assign) BOOL hasAudioQueueRunningListener;
@property (nonatomic, strong) dispatch_source_t audioQueueWatchdog;
@property (nonatomic, strong) dispatch_source_t outputChangeTimer;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *pendingOutputSelectors;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *pendingOutputObjectIDs;
@property (nonatomic, assign) VBANOutputNotificationState outputNotificationState;
@property (nonatomic, assign) NSUInteger outputChangeTimerGeneration;
@property (nonatomic, copy, nullable) NSString *activeOutputDeviceUID;
@property (nonatomic, assign) NSUInteger activeOutputChannelCount;
@property (nonatomic, assign) BOOL outputUnavailable;
@property (nonatomic, copy, nullable) NSString *outputUnavailableDeviceName;
@property (nonatomic, assign) BOOL outputRecoveryPending;
@property (nonatomic, assign) BOOL outputRecoveryPermitted;
@property (nonatomic, assign) NSUInteger outputRecoveryGeneration;
@property (nonatomic, copy) NSString *autoRepairSuspicionReason;

- (BOOL)removeCoreAudioOutputListeners;
- (BOOL)removeObservedOutputDeviceListeners;
- (void)coreAudioOutputConfigurationChangedForObjectID:(AudioObjectID)objectID
                                              selectors:(NSArray<NSNumber *> *)selectors;
- (void)recordOutputChangeOnQueueForObjectID:(AudioObjectID)objectID
                                    selectors:(NSArray<NSNumber *> *)selectors;
- (void)evaluatePendingOutputChangesOnQueue;
- (void)evaluateOutputStateOnQueueWithReason:(NSString *)reason
                           notificationCount:(NSUInteger)notificationCount
                                   selectors:(NSArray<NSNumber *> *)selectors
                                   objectIDs:(NSArray<NSNumber *> *)objectIDs;
- (VBANOutputDeviceState *)desiredOutputDeviceStateOnQueue;
- (AudioObjectID)deviceIDForUID:(nullable NSString *)deviceUID;
- (void)restartAudioQueueOnQueueForDecision:(VBANOutputRecoveryDecision)decision
                                    details:(NSDictionary<NSString *, id> *)details;
- (void)setOutputUnavailableOnQueue:(BOOL)unavailable deviceName:(nullable NSString *)deviceName;
- (void)beginOutputRestoreDeadlineOnQueue;
- (void)completeOutputRestoreIfRunningOnQueue;
- (void)notifyPlaybackStartedOnQueueIfNeeded;
- (void)reportPlaybackErrorOnQueue:(NSString *)message;
- (void)finishPendingPacketTaskWithBytes:(NSUInteger)packetBytes;
- (void)reportQueueDropCount:(NSUInteger)count;
- (BOOL)shouldAttemptAudioQueueConfigurationForPacketOnQueue:(VBANPacket *)packet;
- (BOOL)hasFreshPacketsOnQueue;
- (BOOL)hasEnoughAudioToStartOnQueue;
- (NSString *)outputPropertySelectorName:(AudioObjectPropertySelector)selector;
- (void)audioQueueRunningChangedOnQueue:(AudioQueueRef)queue generation:(NSUInteger)generation;
- (void)checkAudioQueueHealthOnQueue;
- (void)recoverStoppedAudioQueueOnQueue:(NSString *)reason;
- (void)attemptAutomaticOutputRepairOnQueue:(NSString *)reason details:(NSDictionary<NSString *, id> *)details;
- (void)resetAutoRepairSuspicionOnQueue;
- (void)appendDiagnosticLine:(NSData *)line;
- (void)rotateDiagnosticLogIfNeededForIncomingBytes:(NSUInteger)incomingBytes;
- (BOOL)copyTailOfLogAtPath:(NSString *)sourcePath toPath:(NSString *)destinationPath maxBytes:(NSUInteger)maxBytes;

@end

@interface VBANOutputDeviceState : NSObject
@property (nonatomic, assign) AudioObjectID deviceID;
@property (nonatomic, copy, nullable) NSString *deviceUID;
@property (nonatomic, copy, nullable) NSString *deviceName;
@property (nonatomic, assign) BOOL available;
@property (nonatomic, assign) NSUInteger outputChannels;
@property (nonatomic, strong, nullable) NSNumber *alive;
@property (nonatomic, strong, nullable) NSNumber *sampleRate;
@end

@implementation VBANOutputDeviceState
@end

@interface VBANCoreAudioListenerContext : NSObject
@property (nonatomic, weak, nullable) VBANAudioPlayer *player;
@end

@implementation VBANCoreAudioListenerContext
@end

@interface VBANAudioQueueCallbackContext : NSObject
@property (nonatomic, weak, nullable) VBANAudioPlayer *player;
@property (nonatomic, assign) NSUInteger generation;
@end

@implementation VBANAudioQueueCallbackContext
@end

static OSStatus VBANCoreAudioOutputChanged(AudioObjectID inObjectID,
                                           UInt32 inNumberAddresses,
                                           const AudioObjectPropertyAddress inAddresses[],
                                           void *inClientData) {
    VBANCoreAudioListenerContext *context = (__bridge VBANCoreAudioListenerContext *)inClientData;
    VBANAudioPlayer *player = context.player;
    if (!player) {
        return noErr;
    }
    NSMutableArray<NSNumber *> *selectors = [NSMutableArray arrayWithCapacity:inNumberAddresses];
    for (UInt32 index = 0; index < inNumberAddresses; index++) {
        [selectors addObject:@(inAddresses[index].mSelector)];
    }
    [player coreAudioOutputConfigurationChangedForObjectID:inObjectID selectors:selectors];
    return noErr;
}

static void VBANAudioQueueIsRunningChanged(void *inUserData,
                                           AudioQueueRef inAQ,
                                           AudioQueuePropertyID inID) {
    if (inID != kAudioQueueProperty_IsRunning) {
        return;
    }

    VBANAudioQueueCallbackContext *context = (__bridge VBANAudioQueueCallbackContext *)inUserData;
    VBANAudioPlayer *player = context.player;
    if (!player) {
        return;
    }
    NSUInteger generation = context.generation;
    dispatch_async(player.queue, ^{
        [player audioQueueRunningChangedOnQueue:inAQ generation:generation];
    });
}

static void VBANAudioQueueOutputCompleted(void *inUserData,
                                          AudioQueueRef inAQ,
                                          AudioQueueBufferRef inBuffer) {
    UInt64 frameCount = (UInt64)(uintptr_t)inBuffer->mUserData;
    VBANAudioQueueCallbackContext *context = (__bridge VBANAudioQueueCallbackContext *)inUserData;
    VBANAudioPlayer *player = context.player;
    if (player) {
        @synchronized (player) {
            if (player.audioQueue == inAQ
                && player.audioQueueGeneration == context.generation
                && player.scheduledBuffers > 0) {
                player.scheduledBuffers = MAX(0, player.scheduledBuffers - 1);
                player.scheduledFrames = player.scheduledFrames > frameCount ? player.scheduledFrames - frameCount : 0;
            }
        }
    }
    AudioQueueFreeBuffer(inAQ, inBuffer);
}

@implementation VBANAudioPlayer

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("local.codex.vban.audio", DISPATCH_QUEUE_SERIAL);
        _diagnosticQueue = dispatch_queue_create("local.codex.vban.diagnostics", DISPATCH_QUEUE_SERIAL);
        _ingressLock = [[NSObject alloc] init];
        dispatch_queue_set_specific(_queue,
                                    VBANAudioQueueSpecificKey,
                                    (__bridge void *)self,
                                    NULL);
        dispatch_queue_set_specific(_diagnosticQueue,
                                    VBANDiagnosticQueueSpecificKey,
                                    (__bridge void *)self,
                                    NULL);
        _configuredOutputVolume = 1.0f;
        _lockedOutputDeviceID = kAudioObjectUnknown;
        _observedOutputDeviceID = kAudioObjectUnknown;
        _pendingOutputSelectors = [NSMutableSet set];
        _pendingOutputObjectIDs = [NSMutableSet set];
        _queueDropCoalescer = [[VBANCountCoalescer alloc] init];
        VBANCoreAudioListenerContext *listenerContext = [[VBANCoreAudioListenerContext alloc] init];
        listenerContext.player = self;
        _coreAudioListenerContext = (__bridge_retained void *)listenerContext;
        _configuredPlaybackProfile = VBANPlaybackProfileOptimal;
        [self applyPlaybackProfile:VBANPlaybackProfileOptimal];
        [self installCoreAudioOutputListeners];
        dispatch_async(_queue, ^{
            [self writeDiagnosticEventOnQueue:@"audio-player-init" details:@{} includeSnapshot:YES];
        });
    }
    return self;
}

- (void)dealloc {
    __unsafe_unretained VBANAudioPlayer *unsafeSelf = self;
    __block BOOL removedAllListeners = YES;
    void (^cleanup)(void) = ^{
        VBANCoreAudioListenerContext *listenerContext = unsafeSelf.coreAudioListenerContext
            ? (__bridge VBANCoreAudioListenerContext *)unsafeSelf.coreAudioListenerContext
            : nil;
        listenerContext.player = nil;
        removedAllListeners = [unsafeSelf removeCoreAudioOutputListeners];
        if (unsafeSelf.outputChangeTimer) {
            dispatch_source_cancel(unsafeSelf.outputChangeTimer);
            unsafeSelf.outputChangeTimer = nil;
        }
        [unsafeSelf teardownAudioQueueOnQueue];
        if (unsafeSelf.coreAudioListenerContext) {
            if (VBANCoreAudioListenerContextCanRelease(
                    removedAllListeners,
                    unsafeSelf.priorDeviceListenerRemovalFailed)) {
                CFRelease(unsafeSelf.coreAudioListenerContext);
            }
            // A failed CoreAudio unregister keeps this tiny nil-target context alive.
            unsafeSelf.coreAudioListenerContext = NULL;
        }
    };
    if (dispatch_get_specific(VBANAudioQueueSpecificKey) == (__bridge void *)self) {
        cleanup();
    } else {
        dispatch_sync(self.queue, cleanup);
    }
}

- (void)installCoreAudioOutputListeners {
    void *listenerContext = self.coreAudioListenerContext;
    AudioObjectPropertyAddress defaultOutputAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectAddPropertyListener(kAudioObjectSystemObject,
                                       &defaultOutputAddress,
                                       VBANCoreAudioOutputChanged,
                                       listenerContext) == noErr) {
        self.hasDefaultOutputListener = YES;
    }

    AudioObjectPropertyAddress defaultSystemOutputAddress = {
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectAddPropertyListener(kAudioObjectSystemObject,
                                       &defaultSystemOutputAddress,
                                       VBANCoreAudioOutputChanged,
                                       listenerContext) == noErr) {
        self.hasDefaultSystemOutputListener = YES;
    }

    AudioObjectPropertyAddress deviceListAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectAddPropertyListener(kAudioObjectSystemObject,
                                       &deviceListAddress,
                                       VBANCoreAudioOutputChanged,
                                       listenerContext) == noErr) {
        self.hasDeviceListListener = YES;
    }

    [self refreshObservedOutputDevice];
}

- (BOOL)removeCoreAudioOutputListeners {
    void *listenerContext = self.coreAudioListenerContext;
    BOOL removedAll = YES;
    AudioObjectPropertyAddress defaultOutputAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (self.hasDefaultOutputListener) {
        removedAll = AudioObjectRemovePropertyListener(kAudioObjectSystemObject,
                                                       &defaultOutputAddress,
                                                       VBANCoreAudioOutputChanged,
                                                       listenerContext) == noErr && removedAll;
        self.hasDefaultOutputListener = NO;
    }

    AudioObjectPropertyAddress defaultSystemOutputAddress = {
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (self.hasDefaultSystemOutputListener) {
        removedAll = AudioObjectRemovePropertyListener(kAudioObjectSystemObject,
                                                       &defaultSystemOutputAddress,
                                                       VBANCoreAudioOutputChanged,
                                                       listenerContext) == noErr && removedAll;
        self.hasDefaultSystemOutputListener = NO;
    }

    AudioObjectPropertyAddress deviceListAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (self.hasDeviceListListener) {
        removedAll = AudioObjectRemovePropertyListener(kAudioObjectSystemObject,
                                                       &deviceListAddress,
                                                       VBANCoreAudioOutputChanged,
                                                       listenerContext) == noErr && removedAll;
        self.hasDeviceListListener = NO;
    }

    return [self removeObservedOutputDeviceListeners] && removedAll;
}

- (void)refreshObservedOutputDevice {
    AudioObjectID deviceID = [self desiredOutputDeviceIDOnQueue];
    if (deviceID == self.observedOutputDeviceID) {
        return;
    }

    [self removeObservedOutputDeviceListeners];
    if (deviceID == kAudioObjectUnknown) {
        return;
    }
    self.observedOutputDeviceID = deviceID;
    [self addObservedOutputDeviceListeners];
    [self writeDiagnosticEventOnQueue:@"observed-output-device-changed"
                              details:@{@"observedDevice": [self dictionaryForDeviceID:deviceID]}
                      includeSnapshot:YES];
}

- (void)addObservedOutputDeviceListeners {
    if (self.observedOutputDeviceID == kAudioObjectUnknown) {
        return;
    }

    AudioObjectPropertyAddress addresses[] = {
        { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
    };

    BOOL addedAny = NO;
    for (NSUInteger index = 0; index < sizeof(addresses) / sizeof(addresses[0]); index++) {
        if (AudioObjectAddPropertyListener(self.observedOutputDeviceID,
                                           &addresses[index],
                                           VBANCoreAudioOutputChanged,
                                           self.coreAudioListenerContext) == noErr) {
            addedAny = YES;
        }
    }
    self.hasOutputDeviceListeners = addedAny;
}

- (BOOL)removeObservedOutputDeviceListeners {
    if (!self.hasOutputDeviceListeners || self.observedOutputDeviceID == kAudioObjectUnknown) {
        self.observedOutputDeviceID = kAudioObjectUnknown;
        self.hasOutputDeviceListeners = NO;
        return YES;
    }

    AudioObjectPropertyAddress addresses[] = {
        { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
    };

    BOOL removedAll = YES;
    for (NSUInteger index = 0; index < sizeof(addresses) / sizeof(addresses[0]); index++) {
        removedAll = AudioObjectRemovePropertyListener(self.observedOutputDeviceID,
                                                       &addresses[index],
                                                       VBANCoreAudioOutputChanged,
                                                       self.coreAudioListenerContext) == noErr && removedAll;
    }
    self.priorDeviceListenerRemovalFailed =
        VBANCoreAudioListenerRemovalFailureRecorded(self.priorDeviceListenerRemovalFailed,
                                                    removedAll);
    self.observedOutputDeviceID = kAudioObjectUnknown;
    self.hasOutputDeviceListeners = NO;
    return removedAll;
}

- (AudioObjectID)currentDefaultOutputDeviceID {
    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &size,
                                                 &deviceID);
    return status == noErr ? deviceID : kAudioObjectUnknown;
}

- (AudioObjectID)currentDefaultSystemOutputDeviceID {
    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &size,
                                                 &deviceID);
    return status == noErr ? deviceID : kAudioObjectUnknown;
}

- (AudioObjectID)desiredOutputDeviceIDOnQueue {
    if (self.locksOutputDevice) {
        if (!self.lockedOutputIdentityCaptured || !self.lockedOutputDeviceUID.length) {
            return kAudioObjectUnknown;
        }
        self.lockedOutputDeviceID = [self deviceIDForUID:self.lockedOutputDeviceUID];
        return self.lockedOutputDeviceID;
    }
    return [self currentDefaultOutputDeviceID];
}

- (AudioObjectID)deviceIDForUID:(NSString *)deviceUID {
    if (!deviceUID.length) {
        return kAudioObjectUnknown;
    }
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,
                                       &address,
                                       0,
                                       NULL,
                                       &size) != noErr || size == 0) {
        return kAudioObjectUnknown;
    }
    NSUInteger count = size / sizeof(AudioObjectID);
    AudioObjectID *deviceIDs = calloc(count, sizeof(AudioObjectID));
    if (!deviceIDs) {
        return kAudioObjectUnknown;
    }
    AudioObjectID match = kAudioObjectUnknown;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                   &address,
                                   0,
                                   NULL,
                                   &size,
                                   deviceIDs) == noErr) {
        for (NSUInteger index = 0; index < count; index++) {
            if ([[self deviceUIDForDeviceID:deviceIDs[index]] isEqualToString:deviceUID]) {
                match = deviceIDs[index];
                break;
            }
        }
    }
    free(deviceIDs);
    return match;
}

- (NSString *)desiredOutputDeviceUIDOnQueue {
    AudioObjectID deviceID = [self desiredOutputDeviceIDOnQueue];
    return [self deviceUIDForDeviceID:deviceID];
}

- (NSString *)deviceUIDForDeviceID:(AudioObjectID)deviceID {
    if (deviceID == kAudioObjectUnknown) {
        return nil;
    }

    CFStringRef deviceUID = NULL;
    UInt32 size = sizeof(deviceUID);
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus status = AudioObjectGetPropertyData(deviceID,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &size,
                                                 &deviceUID);
    if (status != noErr || !deviceUID) {
        return nil;
    }
    return CFBridgingRelease(deviceUID);
}

- (BOOL)applyOutputDevicePolicyOnQueue {
    if (!self.audioQueue) {
        return NO;
    }

    NSString *deviceUID = [self desiredOutputDeviceUIDOnQueue];
    if (!deviceUID.length) {
        return NO;
    }

    CFStringRef uid = (__bridge CFStringRef)deviceUID;
    OSStatus status = AudioQueueSetProperty(self.audioQueue,
                                            kAudioQueueProperty_CurrentDevice,
                                            &uid,
                                            sizeof(uid));
    if (status == noErr) {
        VBANOutputDeviceState *state = [self desiredOutputDeviceStateOnQueue];
        self.activeOutputDeviceUID = deviceUID;
        self.activeOutputChannelCount = state.outputChannels;
    }
    [self writeDiagnosticEventOnQueue:@"audio-queue-set-current-device"
                              details:@{
        @"deviceUID": deviceUID,
        @"status": @(status),
        @"device": [self dictionaryForDeviceID:[self desiredOutputDeviceIDOnQueue]]
    }
                      includeSnapshot:NO];
    return status == noErr;
}

- (void)startAudioQueueWatchdogOnQueue {
    if (self.audioQueueWatchdog) {
        return;
    }

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    if (!timer) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                              (uint64_t)(1.0 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf checkAudioQueueHealthOnQueue];
    });
    self.audioQueueWatchdog = timer;
    dispatch_resume(timer);
}

- (void)stopAudioQueueWatchdogOnQueue {
    if (!self.audioQueueWatchdog) {
        return;
    }

    dispatch_source_cancel(self.audioQueueWatchdog);
    self.audioQueueWatchdog = nil;
}

- (void)audioQueueRunningChangedOnQueue:(AudioQueueRef)queue generation:(NSUInteger)generation {
    if (!self.audioQueue
        || self.audioQueue != queue
        || self.audioQueueGeneration != generation) {
        return;
    }

    NSInteger scheduledBuffers = 0;
    UInt64 scheduledFrames = 0;
    @synchronized (self) {
        scheduledBuffers = self.scheduledBuffers;
        scheduledFrames = self.scheduledFrames;
    }

    id reportedRunning = [self audioQueueReportedRunningOnQueue];
    BOOL stopped = [reportedRunning isKindOfClass:NSNumber.class] && ![(NSNumber *)reportedRunning boolValue];
    [self writeDiagnosticEventOnQueue:@"audio-queue-running-changed"
                              details:@{
        @"reportedRunning": reportedRunning,
        @"scheduledBuffers": @(scheduledBuffers),
        @"scheduledFrames": @(scheduledFrames),
        @"currentDeviceUID": [self audioQueueCurrentDeviceUIDOnQueue],
        @"desiredDeviceUID": [self jsonString:[self desiredOutputDeviceUIDOnQueue]]
    }
                      includeSnapshot:stopped];

    if (stopped) {
        [self recoverStoppedAudioQueueOnQueue:@"is-running-property"];
    } else {
        [self completeOutputRestoreIfRunningOnQueue];
    }
}

- (void)checkAudioQueueHealthOnQueue {
    if (!self.audioQueue) {
        [self resetAutoRepairSuspicionOnQueue];
        return;
    }

    CFAbsoluteTime now = VBANMonotonicTime();
    NSString *desiredDeviceUID = [self desiredOutputDeviceUIDOnQueue];
    id currentDeviceUID = [self audioQueueCurrentDeviceUIDOnQueue];
    if (desiredDeviceUID.length
        && ((self.activeOutputDeviceUID.length
             && ![self.activeOutputDeviceUID isEqualToString:desiredDeviceUID])
            || ([currentDeviceUID isKindOfClass:NSString.class]
                && ![(NSString *)currentDeviceUID isEqualToString:desiredDeviceUID]))) {
        [self writeDiagnosticEventOnQueue:@"audio-queue-device-drift"
                                  details:@{
            @"currentDeviceUID": currentDeviceUID,
            @"desiredDeviceUID": desiredDeviceUID
        }
                          includeSnapshot:YES];
        [self resetAutoRepairSuspicionOnQueue];
        [self recordOutputChangeOnQueueForObjectID:kAudioObjectSystemObject
                                         selectors:@[@(kAudioHardwarePropertyDefaultOutputDevice)]];
        return;
    }

    id reportedRunning = [self audioQueueReportedRunningOnQueue];
    if ([reportedRunning isKindOfClass:NSNumber.class] && ![(NSNumber *)reportedRunning boolValue]) {
        [self recoverStoppedAudioQueueOnQueue:@"watchdog"];
        return;
    }

    NSInteger scheduledBuffers = 0;
    UInt64 scheduledFrames = 0;
    @synchronized (self) {
        scheduledBuffers = self.scheduledBuffers;
        scheduledFrames = self.scheduledFrames;
    }

    BOOL freshPackets = [self hasFreshPacketsOnQueue];
    BOOL queuePretendsRunning = [reportedRunning isKindOfClass:NSNumber.class] && [(NSNumber *)reportedRunning boolValue];
    double sampleRate = self.queueFormat.mSampleRate > 0 ? self.queueFormat.mSampleRate : 0;
    double queuedDuration = sampleRate > 0 ? (double)scheduledFrames / sampleRate : 0;
    BOOL manualRepairRecently = self.lastManualOutputReconnectAt > 0
        && now - self.lastManualOutputReconnectAt < 180.0;
    double manualRepairAge = self.lastManualOutputReconnectAt > 0 ? now - self.lastManualOutputReconnectAt : -1.0;

    NSString *suspicionReason = nil;
    NSMutableDictionary<NSString *, id> *details = [@{
        @"reportedRunning": reportedRunning,
        @"scheduledBuffers": @(scheduledBuffers),
        @"scheduledFrames": @(scheduledFrames),
        @"queuedMilliseconds": @(llround(queuedDuration * 1000.0)),
        @"currentDeviceUID": currentDeviceUID,
        @"desiredDeviceUID": [self jsonString:desiredDeviceUID],
        @"freshPackets": @(freshPackets),
        @"manualRepairRecently": @(manualRepairRecently),
        @"manualRepairAgeSeconds": @(manualRepairAge)
    } mutableCopy];

    AudioObjectID desiredDevice = [self desiredOutputDeviceIDOnQueue];
    NSNumber *deviceRunning = [self uint32Property:kAudioDevicePropertyDeviceIsRunningSomewhere
                                         deviceID:desiredDevice
                                            scope:kAudioObjectPropertyScopeGlobal];
    if (deviceRunning) {
        details[@"deviceRunningSomewhere"] = deviceRunning;
    }

    VBANAutomaticRepairSignal repairSignal = VBANAudioAutomaticRepairSignal(
        self.autoRepairsOutput,
        self.audioQueueStarted,
        freshPackets,
        queuePretendsRunning,
        scheduledFrames > 0,
        deviceRunning != nil,
        deviceRunning.boolValue,
        queuedDuration,
        self.maxQueuedDuration,
        manualRepairRecently);
    switch (repairSignal) {
        case VBANAutomaticRepairSignalDeviceNotRunning:
            suspicionReason = @"device-not-running";
            break;
        case VBANAutomaticRepairSignalQueueLagging:
            suspicionReason = @"queue-lagging";
            break;
        case VBANAutomaticRepairSignalNone:
            break;
    }

    if (!suspicionReason) {
        [self resetAutoRepairSuspicionOnQueue];
        return;
    }

    if (![self.autoRepairSuspicionReason isEqualToString:suspicionReason]) {
        self.autoRepairSuspicionReason = suspicionReason;
        self.autoRepairSuspicionStartedAt = now;
        [self writeDiagnosticEventOnQueue:@"auto-output-repair-watch"
                                  details:@{
            @"reason": suspicionReason,
            @"details": details
        }
                          includeSnapshot:NO];
        return;
    }

    if (now - self.autoRepairSuspicionStartedAt >= 1.5) {
        [self attemptAutomaticOutputRepairOnQueue:suspicionReason details:details];
    }
}

- (void)attemptAutomaticOutputRepairOnQueue:(NSString *)reason details:(NSDictionary<NSString *, id> *)details {
    if (!self.autoRepairsOutput || !self.audioQueue) {
        return;
    }

    CFAbsoluteTime now = VBANMonotonicTime();
    if (now - self.lastIntentionalEngineConfigurationAt < 0.8 || now - self.lastAutomaticOutputRepairAt < 12.0) {
        return;
    }

    self.lastAutomaticOutputRepairAt = now;
    self.lastOutputRecoveryAt = now;
    self.lastIntentionalEngineConfigurationAt = now;
    [self writeDiagnosticEventOnQueue:@"auto-output-repair"
                              details:@{
        @"reason": reason ?: @"unknown",
        @"manualRepairRecently": @(self.lastManualOutputReconnectAt > 0 && now - self.lastManualOutputReconnectAt < 180.0),
        @"cooldownSeconds": @12,
        @"details": details ?: @{}
    }
                      includeSnapshot:YES];
    [self resetAutoRepairSuspicionOnQueue];
    self.outputRecoveryPending = YES;
    self.lastAudioQueueConfigurationAttemptAt = 0;
    [self teardownAudioQueueOnQueue];
    self.lastLevelReportAt = 0;
    [self reportQueueDropCount:1];
    [self beginOutputRestoreDeadlineOnQueue];
}

- (void)resetAutoRepairSuspicionOnQueue {
    self.autoRepairSuspicionStartedAt = 0;
    self.autoRepairSuspicionReason = nil;
}

- (void)recoverStoppedAudioQueueOnQueue:(NSString *)reason {
    if (!self.audioQueue || !self.audioQueueStarted) {
        return;
    }

    NSInteger scheduledBuffers = 0;
    UInt64 scheduledFrames = 0;
    @synchronized (self) {
        scheduledBuffers = self.scheduledBuffers;
        scheduledFrames = self.scheduledFrames;
    }
    id reportedRunning = [self audioQueueReportedRunningOnQueue];
    VBANOutputRecoveryFacts facts = {
        .hasAudioQueue = self.audioQueue != NULL,
        .outputAvailable = YES,
        .routeChanged = NO,
        .outputFormatCompatible = YES,
        .queueStarted = self.audioQueueStarted,
        .queueRunningKnown = [reportedRunning isKindOfClass:NSNumber.class],
        .queueRunning = [reportedRunning isKindOfClass:NSNumber.class]
            && [(NSNumber *)reportedRunning boolValue],
        .hasPendingAudio = scheduledFrames > 0,
        .hasFreshInput = [self hasFreshPacketsOnQueue]
    };
    if (VBANOutputRecoveryDecisionForFacts(facts) != VBANOutputRecoveryDecisionRestartForPlaybackStall) {
        return;
    }

    CFAbsoluteTime now = VBANMonotonicTime();
    if (now - self.lastIntentionalEngineConfigurationAt < 0.35 || now - self.lastOutputRecoveryAt < 0.75) {
        return;
    }

    [self restartAudioQueueOnQueueForDecision:VBANOutputRecoveryDecisionRestartForPlaybackStall
                                      details:@{
        @"reason": reason ?: @"unknown",
        @"scheduledBuffers": @(scheduledBuffers),
        @"scheduledFrames": @(scheduledFrames),
        @"queuedMilliseconds": self.queueFormat.mSampleRate > 0 ? @(llround(((double)scheduledFrames / self.queueFormat.mSampleRate) * 1000.0)) : (id)[NSNull null],
        @"reportedRunning": reportedRunning,
        @"currentDeviceUID": [self audioQueueCurrentDeviceUIDOnQueue],
        @"desiredDeviceUID": [self jsonString:[self desiredOutputDeviceUIDOnQueue]]
    }];
}

- (void)setPlaybackProfile:(VBANPlaybackProfile)playbackProfile {
    dispatch_async(self.queue, ^{
        self->_configuredPlaybackProfile = playbackProfile;
        [self applyPlaybackProfile:playbackProfile];
    });
}

- (VBANPlaybackProfile)playbackProfile {
    __block VBANPlaybackProfile profile = VBANPlaybackProfileOptimal;
    void (^readBlock)(void) = ^{
        profile = self->_configuredPlaybackProfile;
    };
    if (dispatch_get_specific(VBANAudioQueueSpecificKey) == (__bridge void *)self) {
        readBlock();
    } else {
        dispatch_sync(self.queue, readBlock);
    }
    return profile;
}

- (void)applyPlaybackProfile:(VBANPlaybackProfile)profile {
    switch (profile) {
        case VBANPlaybackProfileFast:
            self.maxQueuedBuffers = 192;
            self.maxQueuedDuration = 0.30;
            self.startBufferCount = 2;
            self.levelReportInterval = 1.0 / 20.0;
            break;
        case VBANPlaybackProfileOptimal:
            self.maxQueuedBuffers = 384;
            self.maxQueuedDuration = 0.60;
            self.startBufferCount = 2;
            self.levelReportInterval = 1.0 / 20.0;
            break;
        case VBANPlaybackProfileMedium:
            self.maxQueuedBuffers = 512;
            self.maxQueuedDuration = 0.90;
            self.startBufferCount = 2;
            self.levelReportInterval = 1.0 / 20.0;
            break;
        case VBANPlaybackProfileSlow:
            self.maxQueuedBuffers = 1024;
            self.maxQueuedDuration = 1.80;
            self.startBufferCount = 4;
            self.levelReportInterval = 1.0 / 15.0;
            break;
        case VBANPlaybackProfileVerySlow:
            self.maxQueuedBuffers = 2048;
            self.maxQueuedDuration = 3.00;
            self.startBufferCount = 6;
            self.levelReportInterval = 1.0 / 12.0;
            break;
    }
}

- (void)setOutputVolume:(float)outputVolume {
    float clamped = isfinite(outputVolume)
        ? fminf(fmaxf(outputVolume, 0.0f), 1.0f)
        : 0.0f;
    dispatch_async(self.queue, ^{
        self->_configuredOutputVolume = clamped;
        if (self.audioQueue) {
            AudioQueueSetParameter(self.audioQueue, kAudioQueueParam_Volume, clamped);
        }
    });
}

- (float)outputVolume {
    __block float volume = 0.0f;
    void (^readBlock)(void) = ^{
        volume = self->_configuredOutputVolume;
    };
    if (dispatch_get_specific(VBANAudioQueueSpecificKey) == (__bridge void *)self) {
        readBlock();
    } else {
        dispatch_sync(self.queue, readBlock);
    }
    return volume;
}

- (void)setLocksOutputDevice:(BOOL)locksOutputDevice {
    dispatch_async(self.queue, ^{
        self->_configuredLocksOutputDevice = locksOutputDevice;
        self.lockedOutputDeviceID = locksOutputDevice ? [self currentDefaultOutputDeviceID] : kAudioObjectUnknown;
        self.lockedOutputDeviceUID = locksOutputDevice
            ? [self deviceUIDForDeviceID:self.lockedOutputDeviceID]
            : nil;
        self.lockedOutputIdentityCaptured = locksOutputDevice;
        [self writeDiagnosticEventOnQueue:@"output-lock-changed"
                                  details:@{
            @"enabled": @(locksOutputDevice),
            @"lockedDevice": [self dictionaryForDeviceID:self.lockedOutputDeviceID]
        }
                          includeSnapshot:YES];
        [self recordOutputChangeOnQueueForObjectID:kAudioObjectSystemObject
                                         selectors:@[@(kAudioHardwarePropertyDefaultOutputDevice)]];
    });
}

- (BOOL)locksOutputDevice {
    __block BOOL locksOutputDevice = NO;
    void (^readBlock)(void) = ^{
        locksOutputDevice = self->_configuredLocksOutputDevice;
    };
    if (dispatch_get_specific(VBANAudioQueueSpecificKey) == (__bridge void *)self) {
        readBlock();
    } else {
        dispatch_sync(self.queue, readBlock);
    }
    return locksOutputDevice;
}

- (void)setAutoRepairsOutput:(BOOL)autoRepairsOutput {
    dispatch_async(self.queue, ^{
        self->_configuredAutoRepairsOutput = autoRepairsOutput;
        [self resetAutoRepairSuspicionOnQueue];
        [self writeDiagnosticEventOnQueue:@"auto-output-repair-changed"
                                  details:@{@"enabled": @(autoRepairsOutput)}
                          includeSnapshot:YES];
    });
}

- (BOOL)autoRepairsOutput {
    __block BOOL autoRepairsOutput = NO;
    void (^readBlock)(void) = ^{
        autoRepairsOutput = self->_configuredAutoRepairsOutput;
    };
    if (dispatch_get_specific(VBANAudioQueueSpecificKey) == (__bridge void *)self) {
        readBlock();
    } else {
        dispatch_sync(self.queue, readBlock);
    }
    return autoRepairsOutput;
}

- (void)setLevelReportingEnabled:(BOOL)levelReportingEnabled {
    dispatch_async(self.queue, ^{
        if (self->_configuredLevelReportingEnabled == levelReportingEnabled) {
            return;
        }
        self->_configuredLevelReportingEnabled = levelReportingEnabled;
        if (levelReportingEnabled) {
            self.lastLevelReportAt = 0;
        }
    });
}

- (BOOL)levelReportingEnabled {
    __block BOOL levelReportingEnabled = NO;
    void (^readBlock)(void) = ^{
        levelReportingEnabled = self->_configuredLevelReportingEnabled;
    };
    if (dispatch_get_specific(VBANAudioQueueSpecificKey) == (__bridge void *)self) {
        readBlock();
    } else {
        dispatch_sync(self.queue, readBlock);
    }
    return levelReportingEnabled;
}

- (void)coreAudioOutputConfigurationChangedForObjectID:(AudioObjectID)objectID
                                              selectors:(NSArray<NSNumber *> *)selectors {
    dispatch_async(self.queue, ^{
        [self recordOutputChangeOnQueueForObjectID:objectID selectors:selectors];
    });
}

- (void)recordOutputChangeOnQueueForObjectID:(AudioObjectID)objectID
                                    selectors:(NSArray<NSNumber *> *)selectors {
    CFAbsoluteTime now = VBANMonotonicTime();
    self.outputNotificationState = VBANOutputNotificationNotice(self.outputNotificationState, now);
    self.outputChangeTimerGeneration = self.outputNotificationState.generation;
    [self.pendingOutputObjectIDs addObject:@(objectID)];
    [self.pendingOutputSelectors addObjectsFromArray:selectors];

    if (!self.outputChangeTimer) {
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
        if (!timer) {
            VBANOutputNotificationState state = self.outputNotificationState;
            state.burstStartedAt = now - VBANOutputNotificationMaximumInterval;
            state.lastNotificationAt = now - VBANOutputNotificationQuietInterval;
            self.outputNotificationState = state;
            [self evaluatePendingOutputChangesOnQueue];
            return;
        }
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{
            [weakSelf evaluatePendingOutputChangesOnQueue];
        });
        self.outputChangeTimer = timer;
        dispatch_resume(timer);
    }

    NSTimeInterval delay = VBANOutputNotificationDelay(self.outputNotificationState.burstStartedAt,
                                                        self.outputNotificationState.lastNotificationAt,
                                                        now);
    dispatch_source_set_timer(self.outputChangeTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(0.02 * NSEC_PER_SEC));
}

- (void)evaluatePendingOutputChangesOnQueue {
    VBANOutputNotificationTimerAction action = VBANOutputNotificationTimerDecision(
        self.outputNotificationState,
        VBANMonotonicTime(),
        self.outputChangeTimerGeneration);
    if (action == VBANOutputNotificationTimerActionIgnore) {
        return;
    }
    if (action == VBANOutputNotificationTimerActionRearm) {
        NSTimeInterval delay = VBANOutputNotificationDelay(
            self.outputNotificationState.burstStartedAt,
            self.outputNotificationState.lastNotificationAt,
            VBANMonotonicTime());
        dispatch_source_set_timer(self.outputChangeTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                                  DISPATCH_TIME_FOREVER,
                                  (uint64_t)(0.02 * NSEC_PER_SEC));
        return;
    }

    NSUInteger notificationCount = self.outputNotificationState.notificationCount;
    NSArray<NSNumber *> *selectors = [[self.pendingOutputSelectors allObjects]
        sortedArrayUsingSelector:@selector(compare:)];
    NSArray<NSNumber *> *objectIDs = [[self.pendingOutputObjectIDs allObjects]
        sortedArrayUsingSelector:@selector(compare:)];
    [self.pendingOutputSelectors removeAllObjects];
    [self.pendingOutputObjectIDs removeAllObjects];
    self.outputNotificationState = VBANOutputNotificationCleared(self.outputNotificationState);
    if (self.outputChangeTimer) {
        dispatch_source_set_timer(self.outputChangeTimer,
                                  DISPATCH_TIME_FOREVER,
                                  DISPATCH_TIME_FOREVER,
                                  0);
    }

    [self evaluateOutputStateOnQueueWithReason:@"coreaudio-notifications"
                             notificationCount:notificationCount
                                     selectors:selectors
                                     objectIDs:objectIDs];
}

- (void)evaluateOutputStateOnQueueWithReason:(NSString *)reason
                           notificationCount:(NSUInteger)notificationCount
                                   selectors:(NSArray<NSNumber *> *)selectors
                                   objectIDs:(NSArray<NSNumber *> *)objectIDs {
    [self refreshObservedOutputDevice];
    VBANOutputDeviceState *desiredState = [self desiredOutputDeviceStateOnQueue];

    NSInteger scheduledBuffers = 0;
    UInt64 scheduledFrames = 0;
    @synchronized (self) {
        scheduledBuffers = self.scheduledBuffers;
        scheduledFrames = self.scheduledFrames;
    }

    id reportedRunning = [self audioQueueReportedRunningOnQueue];
    BOOL queueRunningKnown = [reportedRunning isKindOfClass:NSNumber.class];
    BOOL queueRunning = queueRunningKnown && [(NSNumber *)reportedRunning boolValue];
    id queueCurrentDeviceValue = [self audioQueueCurrentDeviceUIDOnQueue];
    NSString *queueCurrentDeviceUID = [queueCurrentDeviceValue isKindOfClass:NSString.class]
        ? queueCurrentDeviceValue
        : nil;
    NSString *currentDeviceUID = self.activeOutputDeviceUID ?: queueCurrentDeviceUID;
    BOOL routeChanged = self.audioQueue
        && desiredState.deviceUID.length
        && ((self.activeOutputDeviceUID.length
             && ![desiredState.deviceUID isEqualToString:self.activeOutputDeviceUID])
            || (queueCurrentDeviceUID.length
                && ![desiredState.deviceUID isEqualToString:queueCurrentDeviceUID]));
    BOOL outputFormatCompatible = desiredState.outputChannels > 0
        && (self.activeOutputChannelCount == 0
            || desiredState.outputChannels == self.activeOutputChannelCount);

    VBANOutputRecoveryFacts facts = {
        .hasAudioQueue = self.audioQueue != NULL,
        .outputAvailable = desiredState.available,
        .routeChanged = routeChanged,
        .outputFormatCompatible = outputFormatCompatible,
        .queueStarted = self.audioQueueStarted,
        .queueRunningKnown = queueRunningKnown,
        .queueRunning = queueRunning,
        .hasPendingAudio = scheduledFrames > 0,
        .hasFreshInput = [self hasFreshPacketsOnQueue]
    };
    VBANOutputRecoveryDecision decision = VBANOutputRecoveryDecisionForFacts(facts);

    NSMutableArray<NSString *> *selectorNames = [NSMutableArray arrayWithCapacity:selectors.count];
    for (NSNumber *selector in selectors) {
        [selectorNames addObject:[self outputPropertySelectorName:selector.unsignedIntValue]];
    }
    NSDictionary<NSString *, id> *details = @{
        @"reason": reason ?: @"unknown",
        @"decision": VBANOutputRecoveryDecisionName(decision),
        @"notificationCount": @(notificationCount),
        @"selectors": selectorNames,
        @"objectIDs": objectIDs ?: @[],
        @"desiredDevice": [self dictionaryForDeviceID:desiredState.deviceID],
        @"currentDeviceUID": [self jsonString:currentDeviceUID],
        @"queueCurrentDeviceUID": [self jsonString:queueCurrentDeviceUID],
        @"activeOutputChannels": @(self.activeOutputChannelCount),
        @"queueStarted": @(self.audioQueueStarted),
        @"queueRunning": reportedRunning,
        @"scheduledBuffers": @(scheduledBuffers),
        @"scheduledFrames": @(scheduledFrames),
        @"freshInput": @(facts.hasFreshInput)
    };
    [self writeDiagnosticEventOnQueue:@"output-change-evaluated"
                              details:details
                      includeSnapshot:decision != VBANOutputRecoveryDecisionNone];

    if (decision == VBANOutputRecoveryDecisionMarkUnavailable) {
        BOOL hadAudioQueue = self.audioQueue != NULL;
        self.outputRecoveryPending = YES;
        self.outputRecoveryGeneration++;
        if (hadAudioQueue) {
            self.lastIntentionalEngineConfigurationAt = VBANMonotonicTime();
            self.lastAudioQueueConfigurationAttemptAt = 0;
            [self teardownAudioQueueOnQueue];
            [self reportQueueDropCount:1];
        }
        [self setOutputUnavailableOnQueue:YES deviceName:desiredState.deviceName];
        return;
    }

    if (VBANOutputRecoveryDecisionRequiresRestart(decision)) {
        [self restartAudioQueueOnQueueForDecision:decision details:details];
        return;
    }

    if (self.outputUnavailable && desiredState.available && !self.audioQueue) {
        if (!self.outputRecoveryPermitted) {
            self.outputRecoveryPending = YES;
            self.outputRecoveryPermitted = YES;
            [self writeDiagnosticEventOnQueue:@"output-restore-stabilized"
                                      details:@{ @"desiredDevice": [self dictionaryForDeviceID:desiredState.deviceID] }
                              includeSnapshot:NO];
            [self beginOutputRestoreDeadlineOnQueue];
        }
        return;
    }

    [self completeOutputRestoreIfRunningOnQueue];
}

- (VBANOutputDeviceState *)desiredOutputDeviceStateOnQueue {
    VBANOutputDeviceState *state = [[VBANOutputDeviceState alloc] init];
    state.deviceID = [self desiredOutputDeviceIDOnQueue];
    NSDictionary<NSString *, id> *device = [self dictionaryForDeviceID:state.deviceID];
    id uid = device[@"uid"];
    id name = device[@"name"];
    id alive = device[@"alive"];
    id sampleRate = device[@"sampleRate"];
    state.deviceUID = [uid isKindOfClass:NSString.class] ? uid : nil;
    state.deviceName = [name isKindOfClass:NSString.class] ? name : nil;
    state.outputChannels = [device[@"outputChannels"] unsignedIntegerValue];
    state.alive = [alive isKindOfClass:NSNumber.class] ? alive : nil;
    state.sampleRate = [sampleRate isKindOfClass:NSNumber.class] ? sampleRate : nil;
    state.available = state.deviceID != kAudioObjectUnknown
        && state.outputChannels > 0
        && (!state.alive || state.alive.boolValue);
    return state;
}

- (void)restartAudioQueueOnQueueForDecision:(VBANOutputRecoveryDecision)decision
                                    details:(NSDictionary<NSString *, id> *)details {
    if (!self.audioQueue) {
        return;
    }

    self.lastOutputRecoveryAt = VBANMonotonicTime();
    self.lastIntentionalEngineConfigurationAt = self.lastOutputRecoveryAt;
    self.outputRecoveryPending = YES;
    [self writeDiagnosticEventOnQueue:@"controlled-output-restart"
                              details:@{
        @"decision": VBANOutputRecoveryDecisionName(decision),
        @"evaluation": details ?: @{}
    }
                      includeSnapshot:YES];
    self.lastAudioQueueConfigurationAttemptAt = 0;
    [self teardownAudioQueueOnQueue];
    self.lastLevelReportAt = 0;
    [self reportQueueDropCount:1];
    [self beginOutputRestoreDeadlineOnQueue];
}

- (void)setOutputUnavailableOnQueue:(BOOL)unavailable deviceName:(NSString *)deviceName {
    NSString *normalizedName = deviceName.length ? deviceName : @"Default Output";
    BOOL changed = self.outputUnavailable != unavailable
        || (unavailable && ![self.outputUnavailableDeviceName isEqualToString:normalizedName]);
    self.outputUnavailable = unavailable;
    self.outputUnavailableDeviceName = unavailable ? normalizedName : nil;
    self.outputRecoveryPermitted = NO;
    void (^handler)(BOOL, NSString *) = self.outputAvailabilityHandler;
    if (changed && handler) {
        handler(!unavailable, unavailable ? normalizedName : nil);
    }
}

- (void)beginOutputRestoreDeadlineOnQueue {
    self.outputRecoveryGeneration++;
    NSUInteger generation = self.outputRecoveryGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(VBANOutputRestoreDeadline * NSEC_PER_SEC)),
                   self.queue, ^{
        if (generation != self.outputRecoveryGeneration || !self.outputRecoveryPending) {
            return;
        }
        [self completeOutputRestoreIfRunningOnQueue];
        if (!self.outputRecoveryPending || ![self hasFreshPacketsOnQueue]) {
            return;
        }
        if (!self.audioQueue || ![self hasEnoughAudioToStartOnQueue]) {
            return;
        }
        self.lastAudioQueueConfigurationAttemptAt = 0;
        [self teardownAudioQueueOnQueue];
        VBANOutputDeviceState *state = [self desiredOutputDeviceStateOnQueue];
        [self setOutputUnavailableOnQueue:YES deviceName:state.deviceName];
        self.outputRecoveryPermitted =
            VBANOutputRestoreFailurePermitsPacketRetry(state.available);
    });
}

- (void)completeOutputRestoreIfRunningOnQueue {
    id reportedRunning = [self audioQueueReportedRunningOnQueue];
    VBANOutputDeviceState *desiredState = [self desiredOutputDeviceStateOnQueue];
    id currentDeviceValue = [self audioQueueCurrentDeviceUIDOnQueue];
    NSString *currentDeviceUID = [currentDeviceValue isKindOfClass:NSString.class]
        ? currentDeviceValue
        : nil;
    BOOL routeMatches = desiredState.deviceUID.length
        && [self.activeOutputDeviceUID isEqualToString:desiredState.deviceUID]
        && [currentDeviceUID isEqualToString:desiredState.deviceUID]
        && (self.activeOutputChannelCount == 0
            || self.activeOutputChannelCount == desiredState.outputChannels);
    VBANAudioQueueCallbackContext *context = self.audioQueueCallbackContext
        ? (__bridge VBANAudioQueueCallbackContext *)self.audioQueueCallbackContext
        : nil;
    BOOL queueGenerationCurrent = context
        && context.generation == self.audioQueueGeneration;
    BOOL running = VBANOutputShouldClearAvailabilityAlert(self.audioQueue != NULL,
                                                           [reportedRunning isKindOfClass:NSNumber.class],
                                                           [reportedRunning isKindOfClass:NSNumber.class]
                                                               && [(NSNumber *)reportedRunning boolValue],
                                                           desiredState.available,
                                                           routeMatches,
                                                           queueGenerationCurrent);
    if (!running) {
        return;
    }
    self.outputRecoveryPending = NO;
    self.outputRecoveryGeneration++;
    [self setOutputUnavailableOnQueue:NO deviceName:nil];
    [self notifyPlaybackStartedOnQueueIfNeeded];
}

- (void)notifyPlaybackStartedOnQueueIfNeeded {
    NSUInteger generation = self.audioQueueGeneration;
    if (!VBANAudioPlaybackNotificationNeeded(self.audioQueue != NULL,
                                             self.audioQueueStarted,
                                             generation,
                                             self.notifiedPlaybackGeneration)) {
        return;
    }
    void (^handler)(void) = self.playbackStartedHandler;
    if (!handler) {
        return;
    }
    self.notifiedPlaybackGeneration = generation;
    handler();
}

- (void)reportPlaybackErrorOnQueue:(NSString *)message {
    self.notifiedPlaybackGeneration = 0;
    void (^handler)(NSString *) = self.errorHandler;
    if (handler) {
        handler(message ?: @"Audio output error");
    }
}

- (BOOL)hasFreshPacketsOnQueue {
    return self.lastPacketEnqueuedAt > 0
        && VBANPacketAgeIsFresh(VBANMonotonicTime() - self.lastPacketEnqueuedAt);
}

- (BOOL)hasEnoughAudioToStartOnQueue {
    NSInteger scheduledBuffers = 0;
    UInt64 scheduledFrames = 0;
    @synchronized (self) {
        scheduledBuffers = self.scheduledBuffers;
        scheduledFrames = self.scheduledFrames;
    }
    return scheduledFrames > 0
        && (self.audioQueueStarted || scheduledBuffers >= self.startBufferCount);
}

- (NSString *)outputPropertySelectorName:(AudioObjectPropertySelector)selector {
    switch (selector) {
        case kAudioHardwarePropertyDefaultOutputDevice:
            return @"default-output-device";
        case kAudioHardwarePropertyDefaultSystemOutputDevice:
            return @"default-system-output-device";
        case kAudioHardwarePropertyDevices:
            return @"audio-device-list";
        case kAudioDevicePropertyNominalSampleRate:
            return @"nominal-sample-rate";
        case kAudioDevicePropertyStreamConfiguration:
            return @"stream-configuration";
        case kAudioDevicePropertyDeviceIsAlive:
            return @"device-is-alive";
        case kAudioDevicePropertyDeviceIsRunningSomewhere:
            return @"device-is-running-somewhere";
        case kAudioDevicePropertyHogMode:
            return @"hog-mode";
        default:
            return [NSString stringWithFormat:@"0x%08x", (unsigned int)selector];
    }
}

- (void)reset {
    void (^resetBlock)(void) = ^{
        [self writeDiagnosticEventOnQueue:@"audio-reset" details:@{} includeSnapshot:YES];
        self.lastIntentionalEngineConfigurationAt = VBANMonotonicTime();
        self.outputRecoveryPending = NO;
        self.outputRecoveryGeneration++;
        self.lastAudioQueueConfigurationAttemptAt = 0;
        [self setOutputUnavailableOnQueue:NO deviceName:nil];
        [self teardownAudioQueueOnQueue];
        self.lastLevelReportAt = 0;
    };
    if (dispatch_get_specific(VBANAudioQueueSpecificKey) == (__bridge void *)self) {
        resetBlock();
    } else {
        dispatch_sync(self.queue, resetBlock);
    }
    if (dispatch_get_specific(VBANDiagnosticQueueSpecificKey) != (__bridge void *)self) {
        dispatch_sync(self.diagnosticQueue, ^{});
    }
}

- (void)reconnectOutput {
    dispatch_async(self.queue, ^{
        [self writeDiagnosticEventOnQueue:@"manual-output-reconnect"
                                  details:@{@"hadAudioQueue": @(self.audioQueue != NULL)}
                          includeSnapshot:YES];
        self.lastManualOutputReconnectAt = VBANMonotonicTime();
        self.lastIntentionalEngineConfigurationAt = VBANMonotonicTime();
        [self resetAutoRepairSuspicionOnQueue];
        self.outputRecoveryPending = YES;
        self.outputRecoveryPermitted = YES;
        self.lastAudioQueueConfigurationAttemptAt = 0;
        [self teardownAudioQueueOnQueue];
        self.lastLevelReportAt = 0;
        [self beginOutputRestoreDeadlineOnQueue];
    });
}

- (void)enqueuePacket:(VBANPacket *)packet {
    NSUInteger packetBytes = packet.payload.length;
    BOOL accepted = NO;
    @synchronized (self.ingressLock) {
        accepted = VBANAudioIngressCanAcceptPacket(self.pendingPacketTasks,
                                                   self.pendingPacketBytes,
                                                   packetBytes,
                                                   VBANAudioIngressMaximumPendingTasks,
                                                   VBANAudioIngressMaximumPendingBytes);
        if (accepted) {
            self.pendingPacketTasks++;
            self.pendingPacketBytes += packetBytes;
        }
    }
    if (!accepted) {
        [self reportQueueDropCount:1];
        return;
    }

    dispatch_async(self.queue, ^{
        @try {
            self.lastPacketEnqueuedAt = VBANMonotonicTime();
            if (self.outputUnavailable && !self.outputRecoveryPermitted) {
                return;
            }
            if (![self shouldAttemptAudioQueueConfigurationForPacketOnQueue:packet]) {
                [self reportQueueDropCount:1];
                return;
            }
            NSError *error = nil;
            void (^levelHandler)(double) = self.levelHandler;
            BOOL shouldReportLevel = self->_configuredLevelReportingEnabled && levelHandler != nil;
            double peak = 0;
            NSData *audioData = [self audioDataFromPacket:packet
                                                    peak:shouldReportLevel ? &peak : NULL
                                                   error:&error];
            if (!audioData) {
                [self reportPlaybackErrorOnQueue:
                    error.localizedDescription ?: @"Cannot decode audio packet"];
                return;
            }

            if (![self ensureAudioQueueForPacket:packet error:&error]) {
                [self reportPlaybackErrorOnQueue:
                    error.localizedDescription ?: @"Cannot start audio output"];
                return;
            }

            NSInteger queuedBuffers = 0;
            UInt64 queuedFrames = 0;
            @synchronized (self) {
                queuedBuffers = self.scheduledBuffers;
                queuedFrames = self.scheduledFrames;
            }

            double sampleRate = self.queueFormat.mSampleRate > 0 ? self.queueFormat.mSampleRate : packet.sampleRate;
            double queuedDuration = sampleRate > 0 ? (double)queuedFrames / sampleRate : 0;
            BOOL exceedsDuration = self.maxQueuedDuration > 0 && queuedDuration >= self.maxQueuedDuration;
            BOOL exceedsBuffers = self.maxQueuedBuffers > 0 && queuedBuffers >= self.maxQueuedBuffers;
            if (exceedsDuration || exceedsBuffers) {
                [self writeDiagnosticEventOnQueue:@"audio-queue-buffer-pressure"
                                          details:@{
                    @"scheduledBuffers": @(queuedBuffers),
                    @"maxQueuedBuffers": @(self.maxQueuedBuffers),
                    @"scheduledFrames": @(queuedFrames),
                    @"queuedMilliseconds": @(llround(queuedDuration * 1000.0)),
                    @"maxQueuedMilliseconds": @(llround(self.maxQueuedDuration * 1000.0)),
                    @"packetFrames": @(packet.sampleCount),
                    @"packetMilliseconds": @(llround((packet.sampleRate > 0 ? packet.sampleCount / packet.sampleRate : 0) * 1000.0)),
                    @"reportedRunning": [self audioQueueReportedRunningOnQueue],
                    @"currentDeviceUID": [self audioQueueCurrentDeviceUIDOnQueue],
                    @"reason": exceedsDuration ? @"duration" : @"buffer-count"
                }
                                  includeSnapshot:YES];
                if (![self resetAudioQueueBuffersOnQueue]) {
                    return;
                }
                [self reportQueueDropCount:1];
            }

            AudioQueueBufferRef queueBuffer = NULL;
            OSStatus allocateStatus = AudioQueueAllocateBuffer(self.audioQueue,
                                                              (UInt32)audioData.length,
                                                              &queueBuffer);
            if (allocateStatus != noErr || !queueBuffer) {
                [self reportPlaybackErrorOnQueue:
                    [self messageForAudioStatus:allocateStatus
                                      fallback:@"Cannot allocate audio output buffer"]];
                [self writeDiagnosticEventOnQueue:@"audio-queue-allocate-error"
                                          details:@{@"status": @(allocateStatus)}
                                  includeSnapshot:YES];
                return;
            }

            memcpy(queueBuffer->mAudioData, audioData.bytes, audioData.length);
            queueBuffer->mAudioDataByteSize = (UInt32)audioData.length;
            queueBuffer->mUserData = (void *)(uintptr_t)packet.sampleCount;

            AudioQueueRef enqueueQueue = self.audioQueue;
            NSUInteger enqueueGeneration = self.audioQueueGeneration;
            @synchronized (self) {
                self.scheduledBuffers++;
                self.scheduledFrames += packet.sampleCount;
            }

            OSStatus enqueueStatus = AudioQueueEnqueueBuffer(enqueueQueue, queueBuffer, 0, NULL);
            if (enqueueStatus != noErr) {
                @synchronized (self) {
                    if (self.audioQueue == enqueueQueue
                        && self.audioQueueGeneration == enqueueGeneration) {
                        self.scheduledBuffers = MAX(0, self.scheduledBuffers - 1);
                        self.scheduledFrames = self.scheduledFrames > packet.sampleCount
                            ? self.scheduledFrames - packet.sampleCount
                            : 0;
                    }
                }
                AudioQueueFreeBuffer(enqueueQueue, queueBuffer);
                [self reportPlaybackErrorOnQueue:
                    [self messageForAudioStatus:enqueueStatus
                                      fallback:@"Cannot enqueue audio output buffer"]];
                [self writeDiagnosticEventOnQueue:@"audio-queue-enqueue-error"
                                          details:@{@"status": @(enqueueStatus)}
                                  includeSnapshot:YES];
                return;
            }

            @synchronized (self) {
                queuedBuffers = self.scheduledBuffers;
            }
            if (!self.audioQueueStarted && queuedBuffers >= self.startBufferCount) {
                if (self.outputRecoveryPending) {
                    [self beginOutputRestoreDeadlineOnQueue];
                }
                OSStatus startStatus = AudioQueueStart(self.audioQueue, NULL);
                if (startStatus == noErr) {
                    self.audioQueueStarted = YES;
                    [self writeDiagnosticEventOnQueue:@"audio-queue-started"
                                              details:@{@"scheduledBuffers": @(queuedBuffers)}
                                      includeSnapshot:NO];
                } else {
                    [self reportPlaybackErrorOnQueue:
                        [self messageForAudioStatus:startStatus
                                          fallback:@"Cannot start audio output"]];
                    [self writeDiagnosticEventOnQueue:@"audio-queue-start-error"
                                              details:@{@"status": @(startStatus)}
                                      includeSnapshot:YES];
                }
            }

            // Usually a no-op after the first successful start. A playback
            // error resets the marker, so the next successful enqueue clears
            // the stale UI error without rebuilding the queue.
            [self notifyPlaybackStartedOnQueueIfNeeded];

            CFAbsoluteTime now = VBANMonotonicTime();
            if (shouldReportLevel
                && now - self.lastLevelReportAt >= self.levelReportInterval) {
                self.lastLevelReportAt = now;
                levelHandler(MIN(peak, 1.0));
            }
        } @finally {
            [self finishPendingPacketTaskWithBytes:packetBytes];
        }
    });
}

- (BOOL)shouldAttemptAudioQueueConfigurationForPacketOnQueue:(VBANPacket *)packet {
    BOOL configurationRequired = !self.audioQueue
        || !self.hasQueueFormat
        || self.queueFormat.mSampleRate != packet.sampleRate
        || self.queueFormat.mChannelsPerFrame != packet.channelCount;
    if (!configurationRequired) {
        return YES;
    }

    CFAbsoluteTime now = VBANMonotonicTime();
    double secondsSinceLastAttempt = self.lastAudioQueueConfigurationAttemptAt > 0
        ? now - self.lastAudioQueueConfigurationAttemptAt
        : -1.0;
    if (!VBANAudioQueueConfigurationAttemptAllowed(YES, secondsSinceLastAttempt)) {
        return NO;
    }
    self.lastAudioQueueConfigurationAttemptAt = now;
    return YES;
}

- (void)finishPendingPacketTaskWithBytes:(NSUInteger)packetBytes {
    @synchronized (self.ingressLock) {
        self.pendingPacketTasks = self.pendingPacketTasks > 0
            ? self.pendingPacketTasks - 1
            : 0;
        self.pendingPacketBytes = self.pendingPacketBytes > packetBytes
            ? self.pendingPacketBytes - packetBytes
            : 0;
    }
}

- (void)reportQueueDropCount:(NSUInteger)count {
    VBANCountCoalescer *coalescer = self.queueDropCoalescer;
    if (![coalescer recordCount:count]) {
        return;
    }

    dispatch_async(self.queue, ^{
        NSUInteger coalescedCount = [coalescer drainCount];
        void (^handler)(NSUInteger) = self.queueDropHandler;
        if (coalescedCount > 0 && handler) {
            handler(coalescedCount);
        }
    });
}

- (BOOL)ensureAudioQueueForPacket:(VBANPacket *)packet error:(NSError **)error {
    BOOL formatChanged = !self.hasQueueFormat
        || self.queueFormat.mSampleRate != packet.sampleRate
        || self.queueFormat.mChannelsPerFrame != packet.channelCount;

    if (formatChanged) {
        VBANOutputDeviceState *desiredState = [self desiredOutputDeviceStateOnQueue];
        if (!desiredState.available) {
            self.outputRecoveryPending = YES;
            [self setOutputUnavailableOnQueue:YES deviceName:desiredState.deviceName];
            if (error) {
                *error = [NSError errorWithDomain:@"local.codex.vban.audio"
                                             code:3
                                         userInfo:@{NSLocalizedDescriptionKey: @"Output device is unavailable"}];
            }
            return NO;
        }
        self.lastIntentionalEngineConfigurationAt = VBANMonotonicTime();
        [self teardownAudioQueueOnQueue];

        AudioStreamBasicDescription format = {0};
        format.mSampleRate = packet.sampleRate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        format.mBytesPerPacket = (UInt32)(sizeof(float) * packet.channelCount);
        format.mFramesPerPacket = 1;
        format.mBytesPerFrame = (UInt32)(sizeof(float) * packet.channelCount);
        format.mChannelsPerFrame = (UInt32)packet.channelCount;
        format.mBitsPerChannel = 32;

        AudioQueueRef outputQueue = NULL;
        NSUInteger queueGeneration = 0;
        @synchronized (self) {
            queueGeneration = ++self.audioQueueGeneration;
        }
        VBANAudioQueueCallbackContext *callbackContext = [[VBANAudioQueueCallbackContext alloc] init];
        callbackContext.player = self;
        callbackContext.generation = queueGeneration;
        void *retainedCallbackContext = (__bridge_retained void *)callbackContext;
        OSStatus status = AudioQueueNewOutput(&format,
                                              VBANAudioQueueOutputCompleted,
                                              retainedCallbackContext,
                                              NULL,
                                              NULL,
                                              0,
                                              &outputQueue);
        if (status != noErr || !outputQueue) {
            if (outputQueue) {
                AudioQueueDispose(outputQueue, true);
            }
            CFRelease(retainedCallbackContext);
            if (error) {
                *error = [self errorForAudioStatus:status fallback:@"Cannot create audio output queue"];
            }
            [self writeDiagnosticEventOnQueue:@"audio-queue-create-error"
                                      details:@{@"status": @(status)}
                              includeSnapshot:YES];
            return NO;
        }

        @synchronized (self) {
            self.audioQueue = outputQueue;
            self.audioQueueCallbackContext = retainedCallbackContext;
        }
        self.queueFormat = format;
        self.hasQueueFormat = YES;
        self.audioQueueStarted = NO;
        self.notifiedPlaybackGeneration = 0;
        OSStatus runningListenerStatus = AudioQueueAddPropertyListener(self.audioQueue,
                                                                       kAudioQueueProperty_IsRunning,
                                                                       VBANAudioQueueIsRunningChanged,
                                                                       retainedCallbackContext);
        self.hasAudioQueueRunningListener = runningListenerStatus == noErr;
        @synchronized (self) {
            self.scheduledBuffers = 0;
            self.scheduledFrames = 0;
        }

        if (![self applyOutputDevicePolicyOnQueue]) {
            [self teardownAudioQueueOnQueue];
            VBANOutputDeviceState *retryState = [self desiredOutputDeviceStateOnQueue];
            self.outputRecoveryPending = YES;
            [self setOutputUnavailableOnQueue:YES deviceName:retryState.deviceName];
            self.outputRecoveryPermitted =
                VBANOutputRestoreFailurePermitsPacketRetry(retryState.available);
            if (error) {
                *error = [NSError errorWithDomain:@"local.codex.vban.audio"
                                             code:4
                                         userInfo:@{NSLocalizedDescriptionKey: @"Cannot select the output device"}];
            }
            return NO;
        }
        [self startAudioQueueWatchdogOnQueue];
        AudioQueueSetParameter(self.audioQueue, kAudioQueueParam_Volume, self.outputVolume);
        [self writeDiagnosticEventOnQueue:@"audio-queue-created"
                                  details:@{
            @"sampleRate": @(packet.sampleRate),
            @"channels": @(packet.channelCount),
            @"volume": @(self.outputVolume),
            @"locksOutputDevice": @(self.locksOutputDevice),
            @"runningListenerStatus": @(runningListenerStatus)
        }
                          includeSnapshot:YES];
    }

    return YES;
}

- (NSData *)audioDataFromPacket:(VBANPacket *)packet peak:(double *)peak error:(NSError **)error {
    NSUInteger sampleBytes = sizeof(float);
    NSUInteger byteCount = packet.sampleCount * packet.channelCount * sampleBytes;
    NSMutableData *data = [NSMutableData dataWithLength:byteCount];
    if (!data.mutableBytes) {
        if (error) {
            *error = [NSError errorWithDomain:@"local.codex.vban.audio"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Cannot allocate audio buffer"}];
        }
        return nil;
    }

    float *output = data.mutableBytes;
    const uint8_t *bytes = packet.payload.bytes;
    NSUInteger frameStride = packet.channelCount * VBANBytesPerSample(packet.dataType);
    float maxPeak = 0;

    for (NSUInteger frame = 0; frame < packet.sampleCount; frame++) {
        NSUInteger frameOffset = frame * frameStride;
        for (NSUInteger channel = 0; channel < packet.channelCount; channel++) {
            NSUInteger sampleOffset = frameOffset + channel * VBANBytesPerSample(packet.dataType);
            float sample = [self decodeSample:bytes offset:sampleOffset type:packet.dataType];
            output[frame * packet.channelCount + channel] = sample;
            if (peak) {
                maxPeak = fmaxf(maxPeak, fabsf(sample));
            }
        }
    }

    if (peak) {
        *peak = maxPeak;
    }
    return data;
}

- (BOOL)resetAudioQueueBuffersOnQueue {
    if (!self.audioQueue) {
        @synchronized (self) {
            self.scheduledBuffers = 0;
            self.scheduledFrames = 0;
        }
        self.audioQueueStarted = NO;
        return NO;
    }

    self.lastIntentionalEngineConfigurationAt = VBANMonotonicTime();
    AudioQueueStop(self.audioQueue, true);
    AudioQueueReset(self.audioQueue);
    @synchronized (self) {
        self.scheduledBuffers = 0;
        self.scheduledFrames = 0;
    }
    self.audioQueueStarted = NO;
    self.notifiedPlaybackGeneration = 0;
    AudioQueueSetParameter(self.audioQueue, kAudioQueueParam_Volume, self.outputVolume);
    if (![self applyOutputDevicePolicyOnQueue]) {
        [self teardownAudioQueueOnQueue];
        VBANOutputDeviceState *state = [self desiredOutputDeviceStateOnQueue];
        self.outputRecoveryPending = YES;
        [self setOutputUnavailableOnQueue:YES deviceName:state.deviceName];
        self.outputRecoveryPermitted =
            VBANOutputRestoreFailurePermitsPacketRetry(state.available);
        return NO;
    }
    return YES;
}

- (void)teardownAudioQueueOnQueue {
    [self stopAudioQueueWatchdogOnQueue];
    AudioQueueRef queue = NULL;
    void *callbackContext = NULL;
    BOOL hadRunningListener = NO;
    @synchronized (self) {
        queue = self.audioQueue;
        callbackContext = self.audioQueueCallbackContext;
        hadRunningListener = self.hasAudioQueueRunningListener;
        self.audioQueue = NULL;
        self.audioQueueCallbackContext = NULL;
        self.hasAudioQueueRunningListener = NO;
        self.audioQueueGeneration++;
        self.scheduledBuffers = 0;
        self.scheduledFrames = 0;
    }
    if (queue) {
        if (hadRunningListener) {
            AudioQueueRemovePropertyListener(queue,
                                             kAudioQueueProperty_IsRunning,
                                             VBANAudioQueueIsRunningChanged,
                                             callbackContext);
        }
        AudioQueueStop(queue, true);
        AudioQueueDispose(queue, true);
    }
    if (callbackContext) {
        CFRelease(callbackContext);
    }

    self.hasQueueFormat = NO;
    self.audioQueueStarted = NO;
    self.notifiedPlaybackGeneration = 0;
    memset(&_queueFormat, 0, sizeof(_queueFormat));
}

- (NSError *)errorForAudioStatus:(OSStatus)status fallback:(NSString *)fallback {
    return [NSError errorWithDomain:@"local.codex.vban.audio"
                               code:status
                           userInfo:@{NSLocalizedDescriptionKey: [self messageForAudioStatus:status fallback:fallback]}];
}

- (NSString *)messageForAudioStatus:(OSStatus)status fallback:(NSString *)fallback {
    if (status == noErr) {
        return fallback;
    }
    return [NSString stringWithFormat:@"%@ (%d)", fallback, (int)status];
}

- (NSString *)diagnosticLogPath {
    NSString *overridePath = NSProcessInfo.processInfo.environment[@"VBAN_DIAGNOSTIC_LOG_PATH"];
    if (overridePath.length) {
        return overridePath.stringByExpandingTildeInPath;
    }
    NSArray<NSString *> *libraryPaths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
                                                                            NSUserDomainMask,
                                                                            YES);
    NSString *libraryPath = libraryPaths.firstObject ?: NSHomeDirectory();
    return [[libraryPath stringByAppendingPathComponent:@"Logs/VBAN Receiver"] stringByAppendingPathComponent:@"diagnostics.jsonl"];
}

- (void)writeDiagnosticSnapshot:(NSString *)reason {
    dispatch_async(self.queue, ^{
        [self writeDiagnosticEventOnQueue:@"manual-diagnostic-snapshot"
                                  details:@{@"reason": reason ?: @""}
                          includeSnapshot:YES];
    });
}

- (void)writeDiagnosticEventOnQueue:(NSString *)event
                            details:(NSDictionary<NSString *, id> *)details
                    includeSnapshot:(BOOL)includeSnapshot {
    NSMutableDictionary<NSString *, id> *entry = [NSMutableDictionary dictionary];
    entry[@"time"] = [self diagnosticTimestamp];
    entry[@"event"] = event ?: @"unknown";
    if (details.count) {
        entry[@"details"] = details;
    }
    if (includeSnapshot) {
        entry[@"snapshot"] = [self diagnosticSnapshotOnQueue];
    }

    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:entry options:0 error:&jsonError];
    if (!jsonData) {
        return;
    }

    NSMutableData *line = [jsonData mutableCopy];
    const char newline = '\n';
    [line appendBytes:&newline length:1];

    dispatch_async(self.diagnosticQueue, ^{
        [self appendDiagnosticLine:line];
    });
}

- (void)appendDiagnosticLine:(NSData *)line {
    NSString *path = self.diagnosticLogPath;
    NSString *directory = path.stringByDeletingLastPathComponent;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *lockPath = [path stringByAppendingString:@".lock"];
    int lockFD = open(lockPath.fileSystemRepresentation, O_CREAT | O_RDWR, 0644);
    if (lockFD < 0) {
        return;
    }
    BOOL acquiredLock = NO;
    for (NSUInteger attempt = 0; attempt < 20; attempt++) {
        if (flock(lockFD, LOCK_EX | LOCK_NB) == 0) {
            acquiredLock = YES;
            break;
        }
        if (errno != EWOULDBLOCK && errno != EAGAIN) {
            break;
        }
        usleep(5000);
    }
    if (!acquiredLock) {
        close(lockFD);
        return;
    }
    [self rotateDiagnosticLogIfNeededForIncomingBytes:line.length];
    int logFD = open(path.fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (logFD >= 0) {
        const uint8_t *bytes = line.bytes;
        NSUInteger remaining = line.length;
        while (remaining > 0) {
            ssize_t written = write(logFD, bytes, remaining);
            if (written > 0) {
                bytes += written;
                remaining -= (NSUInteger)written;
            } else if (errno != EINTR) {
                break;
            }
        }
        close(logFD);
    }
    flock(lockFD, LOCK_UN);
    close(lockFD);
}

- (void)rotateDiagnosticLogIfNeededForIncomingBytes:(NSUInteger)incomingBytes {
    NSString *path = self.diagnosticLogPath;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSNumber *fileSize = [[fileManager attributesOfItemAtPath:path error:nil]
        objectForKey:NSFileSize];
    if (!fileSize || fileSize.unsignedLongLongValue + incomingBytes <= VBANDiagnosticLogMaximumBytes) {
        return;
    }

    NSString *oldestBackup = [path stringByAppendingFormat:@".%lu",
        (unsigned long)VBANDiagnosticLogBackupCount];
    if ([fileManager fileExistsAtPath:oldestBackup]
        && ![fileManager removeItemAtPath:oldestBackup error:nil]) {
        return;
    }
    for (NSUInteger index = VBANDiagnosticLogBackupCount; index > 1; index--) {
        NSString *source = [path stringByAppendingFormat:@".%lu", (unsigned long)(index - 1)];
        NSString *destination = [path stringByAppendingFormat:@".%lu", (unsigned long)index];
        if ([fileManager fileExistsAtPath:source]
            && ![fileManager moveItemAtPath:source toPath:destination error:nil]) {
            return;
        }
    }

    NSString *newestBackup = [path stringByAppendingString:@".1"];
    if (fileSize.unsignedLongLongValue <= VBANDiagnosticLogMaximumBytes) {
        [fileManager moveItemAtPath:path toPath:newestBackup error:nil];
    } else {
        BOOL copied = [self copyTailOfLogAtPath:path
                                         toPath:newestBackup
                                       maxBytes:VBANDiagnosticLogMaximumBytes];
        if (copied) {
            [fileManager removeItemAtPath:path error:nil];
        }
    }
}

- (BOOL)copyTailOfLogAtPath:(NSString *)sourcePath
                     toPath:(NSString *)destinationPath
                   maxBytes:(NSUInteger)maxBytes {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSNumber *fileSize = [[fileManager attributesOfItemAtPath:sourcePath error:nil]
        objectForKey:NSFileSize];
    if (!fileSize) {
        return NO;
    }

    unsigned long long size = fileSize.unsignedLongLongValue;
    unsigned long long offset = size > maxBytes ? size - maxBytes : 0;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:sourcePath];
    if (!handle) {
        return NO;
    }
    [handle seekToFileOffset:offset];
    NSData *tail = [handle readDataToEndOfFile];
    [handle closeFile];

    if (offset > 0 && tail.length > 0) {
        const uint8_t newline = '\n';
        NSRange firstNewline = [tail rangeOfData:[NSData dataWithBytes:&newline length:1]
                                         options:0
                                           range:NSMakeRange(0, tail.length)];
        if (firstNewline.location == NSNotFound || NSMaxRange(firstNewline) >= tail.length) {
            return NO;
        }
        tail = [tail subdataWithRange:NSMakeRange(NSMaxRange(firstNewline),
                                                  tail.length - NSMaxRange(firstNewline))];
    }
    return [tail writeToFile:destinationPath atomically:YES];
}

- (NSString *)diagnosticTimestamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ";
    return [formatter stringFromDate:[NSDate date]];
}

- (NSDictionary<NSString *, id> *)diagnosticSnapshotOnQueue {
    AudioObjectID defaultOutput = [self currentDefaultOutputDeviceID];
    AudioObjectID defaultSystemOutput = [self currentDefaultSystemOutputDeviceID];
    NSInteger scheduledBuffers = 0;
    UInt64 scheduledFrames = 0;
    NSUInteger pendingPacketTasks = 0;
    NSUInteger pendingPacketBytes = 0;
    @synchronized (self) {
        scheduledBuffers = self.scheduledBuffers;
        scheduledFrames = self.scheduledFrames;
    }
    @synchronized (self.ingressLock) {
        pendingPacketTasks = self.pendingPacketTasks;
        pendingPacketBytes = self.pendingPacketBytes;
    }
    double sampleRate = self.hasQueueFormat ? self.queueFormat.mSampleRate : 0;
    id queuedMilliseconds = sampleRate > 0
        ? @(llround(((double)scheduledFrames / sampleRate) * 1000.0))
        : (id)[NSNull null];
    return @{
        @"outputVolume": @(self.outputVolume),
        @"locksOutputDevice": @(self.locksOutputDevice),
        @"autoRepairsOutput": @(self.autoRepairsOutput),
        @"audioQueue": @{
            @"exists": @(self.audioQueue != NULL),
            @"started": @(self.audioQueueStarted),
            @"reportedRunning": [self audioQueueReportedRunningOnQueue],
            @"currentDeviceUID": [self audioQueueCurrentDeviceUIDOnQueue],
            @"scheduledBuffers": @(scheduledBuffers),
            @"scheduledFrames": @(scheduledFrames),
            @"queuedMilliseconds": queuedMilliseconds,
            @"maxQueuedBuffers": @(self.maxQueuedBuffers),
            @"maxQueuedMilliseconds": @(llround(self.maxQueuedDuration * 1000.0)),
            @"hasFormat": @(self.hasQueueFormat),
            @"sampleRate": self.hasQueueFormat ? @(self.queueFormat.mSampleRate) : [NSNull null],
            @"channels": self.hasQueueFormat ? @(self.queueFormat.mChannelsPerFrame) : [NSNull null]
        },
        @"ingress": @{
            @"pendingTasks": @(pendingPacketTasks),
            @"pendingBytes": @(pendingPacketBytes),
            @"maximumPendingTasks": @(VBANAudioIngressMaximumPendingTasks),
            @"maximumPendingBytes": @(VBANAudioIngressMaximumPendingBytes)
        },
        @"defaultOutput": [self dictionaryForDeviceID:defaultOutput],
        @"defaultSystemOutput": [self dictionaryForDeviceID:defaultSystemOutput],
        @"lockedOutput": [self dictionaryForDeviceID:self.lockedOutputDeviceID],
        @"observedOutput": [self dictionaryForDeviceID:self.observedOutputDeviceID],
        @"outputDevices": [self outputDevicesSnapshotWithDefaultOutput:defaultOutput
                                                    defaultSystemOutput:defaultSystemOutput]
    };
}

- (id)audioQueueReportedRunningOnQueue {
    if (!self.audioQueue) {
        return [NSNull null];
    }

    UInt32 isRunning = 0;
    UInt32 size = sizeof(isRunning);
    OSStatus status = AudioQueueGetProperty(self.audioQueue,
                                            kAudioQueueProperty_IsRunning,
                                            &isRunning,
                                            &size);
    return status == noErr ? @(isRunning) : (id)[NSNull null];
}

- (id)audioQueueCurrentDeviceUIDOnQueue {
    if (!self.audioQueue) {
        return [NSNull null];
    }

    CFStringRef deviceUID = NULL;
    UInt32 size = sizeof(deviceUID);
    OSStatus status = AudioQueueGetProperty(self.audioQueue,
                                            kAudioQueueProperty_CurrentDevice,
                                            &deviceUID,
                                            &size);
    if (status != noErr || !deviceUID) {
        return [NSNull null];
    }
    return CFBridgingRelease(deviceUID);
}

- (NSArray<NSDictionary<NSString *, id> *> *)outputDevicesSnapshotWithDefaultOutput:(AudioObjectID)defaultOutput
                                                                defaultSystemOutput:(AudioObjectID)defaultSystemOutput {
    NSArray<NSNumber *> *deviceIDs = [self audioDeviceIDs];
    NSMutableArray<NSDictionary<NSString *, id> *> *devices = [NSMutableArray array];
    for (NSNumber *number in deviceIDs) {
        AudioObjectID deviceID = number.unsignedIntValue;
        NSUInteger outputChannels = [self outputChannelCountForDeviceID:deviceID];
        if (outputChannels == 0) {
            continue;
        }

        NSMutableDictionary<NSString *, id> *device = [[self dictionaryForDeviceID:deviceID] mutableCopy];
        device[@"isDefaultOutput"] = @(deviceID == defaultOutput);
        device[@"isDefaultSystemOutput"] = @(deviceID == defaultSystemOutput);
        device[@"isLockedOutput"] = @(deviceID == self.lockedOutputDeviceID);
        device[@"isObservedOutput"] = @(deviceID == self.observedOutputDeviceID);
        [devices addObject:device];
    }
    return devices;
}

- (NSArray<NSNumber *> *)audioDeviceIDs {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus sizeStatus = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,
                                                         &address,
                                                         0,
                                                         NULL,
                                                         &size);
    if (sizeStatus != noErr || size == 0) {
        return @[];
    }

    NSUInteger count = size / sizeof(AudioObjectID);
    NSMutableData *data = [NSMutableData dataWithLength:size];
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &size,
                                                 data.mutableBytes);
    if (status != noErr) {
        return @[];
    }

    AudioObjectID *deviceIDs = data.mutableBytes;
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [result addObject:@(deviceIDs[index])];
    }
    return result;
}

- (NSDictionary<NSString *, id> *)dictionaryForDeviceID:(AudioObjectID)deviceID {
    if (deviceID == kAudioObjectUnknown) {
        return @{
            @"id": @(kAudioObjectUnknown),
            @"name": [NSNull null],
            @"uid": [NSNull null],
            @"sampleRate": [NSNull null],
            @"outputChannels": @(0),
            @"alive": [NSNull null],
            @"runningSomewhere": [NSNull null],
            @"hogMode": [NSNull null]
        };
    }

    return @{
        @"id": @(deviceID),
        @"name": [self jsonString:[self stringProperty:kAudioObjectPropertyName
                                              deviceID:deviceID
                                                 scope:kAudioObjectPropertyScopeGlobal]],
        @"uid": [self jsonString:[self deviceUIDForDeviceID:deviceID]],
        @"sampleRate": [self jsonNumber:[self doubleProperty:kAudioDevicePropertyNominalSampleRate
                                                    deviceID:deviceID
                                                       scope:kAudioObjectPropertyScopeGlobal]],
        @"outputChannels": @([self outputChannelCountForDeviceID:deviceID]),
        @"alive": [self jsonNumber:[self uint32Property:kAudioDevicePropertyDeviceIsAlive
                                               deviceID:deviceID
                                                  scope:kAudioObjectPropertyScopeGlobal]],
        @"runningSomewhere": [self jsonNumber:[self uint32Property:kAudioDevicePropertyDeviceIsRunningSomewhere
                                                          deviceID:deviceID
                                                             scope:kAudioObjectPropertyScopeGlobal]],
        @"hogMode": [self jsonNumber:[self int32Property:kAudioDevicePropertyHogMode
                                                deviceID:deviceID
                                                   scope:kAudioObjectPropertyScopeGlobal]]
    };
}

- (id)jsonString:(NSString *)value {
    return value.length ? value : (id)[NSNull null];
}

- (id)jsonNumber:(NSNumber *)value {
    return value ?: (id)[NSNull null];
}

- (NSString *)stringProperty:(AudioObjectPropertySelector)selector
                    deviceID:(AudioObjectID)deviceID
                       scope:(AudioObjectPropertyScope)scope {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = {
        selector,
        scope,
        kAudioObjectPropertyElementMain
    };
    OSStatus status = AudioObjectGetPropertyData(deviceID,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &size,
                                                 &value);
    if (status != noErr || !value) {
        return nil;
    }
    return CFBridgingRelease(value);
}

- (NSNumber *)uint32Property:(AudioObjectPropertySelector)selector
                    deviceID:(AudioObjectID)deviceID
                       scope:(AudioObjectPropertyScope)scope {
    UInt32 value = 0;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = {
        selector,
        scope,
        kAudioObjectPropertyElementMain
    };
    OSStatus status = AudioObjectGetPropertyData(deviceID,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &size,
                                                 &value);
    return status == noErr ? @(value) : nil;
}

- (NSNumber *)int32Property:(AudioObjectPropertySelector)selector
                   deviceID:(AudioObjectID)deviceID
                      scope:(AudioObjectPropertyScope)scope {
    SInt32 value = 0;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = {
        selector,
        scope,
        kAudioObjectPropertyElementMain
    };
    OSStatus status = AudioObjectGetPropertyData(deviceID,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &size,
                                                 &value);
    return status == noErr ? @(value) : nil;
}

- (NSNumber *)doubleProperty:(AudioObjectPropertySelector)selector
                    deviceID:(AudioObjectID)deviceID
                       scope:(AudioObjectPropertyScope)scope {
    Float64 value = 0;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = {
        selector,
        scope,
        kAudioObjectPropertyElementMain
    };
    OSStatus status = AudioObjectGetPropertyData(deviceID,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &size,
                                                 &value);
    return status == noErr ? @(value) : nil;
}

- (NSUInteger)outputChannelCountForDeviceID:(AudioObjectID)deviceID {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus sizeStatus = AudioObjectGetPropertyDataSize(deviceID,
                                                         &address,
                                                         0,
                                                         NULL,
                                                         &size);
    if (sizeStatus != noErr || size == 0) {
        return 0;
    }

    AudioBufferList *bufferList = malloc(size);
    if (!bufferList) {
        return 0;
    }

    OSStatus status = AudioObjectGetPropertyData(deviceID,
                                                 &address,
                                                 0,
                                                 NULL,
                                                 &size,
                                                 bufferList);
    NSUInteger channels = 0;
    if (status == noErr) {
        for (UInt32 index = 0; index < bufferList->mNumberBuffers; index++) {
            channels += bufferList->mBuffers[index].mNumberChannels;
        }
    }
    free(bufferList);
    return channels;
}

- (float)decodeSample:(const uint8_t *)bytes offset:(NSUInteger)offset type:(VBANDataType)dataType {
    switch (dataType) {
        case VBANDataTypeUInt8:
            return ((float)bytes[offset] - 128.0f) / 128.0f;
        case VBANDataTypeInt16: {
            uint16_t raw = (uint16_t)bytes[offset] | ((uint16_t)bytes[offset + 1] << 8);
            return (float)(int16_t)raw / 32768.0f;
        }
        case VBANDataTypeInt24: {
            uint32_t raw = (uint32_t)bytes[offset]
                | ((uint32_t)bytes[offset + 1] << 8)
                | ((uint32_t)bytes[offset + 2] << 16);
            int32_t signedValue = (raw & 0x800000) ? (int32_t)(raw | 0xFF000000) : (int32_t)raw;
            return (float)signedValue / 8388608.0f;
        }
        case VBANDataTypeInt32: {
            uint32_t raw = (uint32_t)bytes[offset]
                | ((uint32_t)bytes[offset + 1] << 8)
                | ((uint32_t)bytes[offset + 2] << 16)
                | ((uint32_t)bytes[offset + 3] << 24);
            return (float)(int32_t)raw / 2147483648.0f;
        }
        case VBANDataTypeFloat32: {
            uint32_t raw = (uint32_t)bytes[offset]
                | ((uint32_t)bytes[offset + 1] << 8)
                | ((uint32_t)bytes[offset + 2] << 16)
                | ((uint32_t)bytes[offset + 3] << 24);
            float value = 0;
            memcpy(&value, &raw, sizeof(value));
            return VBANAudioSanitizedFloatSample(value);
        }
        case VBANDataTypeFloat64: {
            uint64_t raw = 0;
            for (NSUInteger index = 0; index < 8; index++) {
                raw |= (uint64_t)bytes[offset + index] << (index * 8);
            }
            double value = 0;
            memcpy(&value, &raw, sizeof(value));
            return VBANAudioSanitizedFloatSample(value);
        }
    }
}

@end
