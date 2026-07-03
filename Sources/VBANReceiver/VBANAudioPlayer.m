#import "VBANAudioPlayer.h"
#import "VBANPacket.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <math.h>

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

@interface VBANAudioPlayer ()

@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) dispatch_queue_t diagnosticQueue;
@property (nonatomic, assign) AudioQueueRef audioQueue;
@property (nonatomic, assign) AudioStreamBasicDescription queueFormat;
@property (nonatomic, assign) NSInteger scheduledBuffers;
@property (nonatomic, assign) UInt64 scheduledFrames;
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
@property (nonatomic, assign) BOOL hasQueueFormat;
@property (nonatomic, assign) BOOL audioQueueStarted;
@property (nonatomic, assign) BOOL hasDefaultOutputListener;
@property (nonatomic, assign) BOOL hasDefaultSystemOutputListener;
@property (nonatomic, assign) BOOL hasOutputDeviceListeners;
@property (nonatomic, assign) BOOL hasAudioQueueRunningListener;
@property (nonatomic, strong) dispatch_source_t audioQueueWatchdog;
@property (nonatomic, copy) NSString *autoRepairSuspicionReason;

- (void)coreAudioOutputConfigurationChanged;
- (void)audioQueueRunningChangedOnQueue:(AudioQueueRef)queue;
- (void)checkAudioQueueHealthOnQueue;
- (void)recoverStoppedAudioQueueOnQueue:(NSString *)reason;
- (void)attemptAutomaticOutputRepairOnQueue:(NSString *)reason details:(NSDictionary<NSString *, id> *)details;
- (void)resetAutoRepairSuspicionOnQueue;
- (void)appendDiagnosticLine:(NSData *)line;

@end

static OSStatus VBANCoreAudioOutputChanged(__unused AudioObjectID inObjectID,
                                           __unused UInt32 inNumberAddresses,
                                           __unused const AudioObjectPropertyAddress inAddresses[],
                                           void *inClientData) {
    VBANAudioPlayer *player = (__bridge VBANAudioPlayer *)inClientData;
    [player coreAudioOutputConfigurationChanged];
    return noErr;
}

static void VBANAudioQueueIsRunningChanged(void *inUserData,
                                           AudioQueueRef inAQ,
                                           AudioQueuePropertyID inID) {
    if (inID != kAudioQueueProperty_IsRunning) {
        return;
    }

    VBANAudioPlayer *player = (__bridge VBANAudioPlayer *)inUserData;
    dispatch_async(player.queue, ^{
        [player audioQueueRunningChangedOnQueue:inAQ];
    });
}

static void VBANAudioQueueOutputCompleted(void *inUserData,
                                          AudioQueueRef inAQ,
                                          AudioQueueBufferRef inBuffer) {
    UInt64 frameCount = (UInt64)(uintptr_t)inBuffer->mUserData;
    VBANAudioPlayer *player = (__bridge VBANAudioPlayer *)inUserData;
    @synchronized (player) {
        if (player.audioQueue == inAQ && player.scheduledBuffers > 0) {
            player.scheduledBuffers = MAX(0, player.scheduledBuffers - 1);
            player.scheduledFrames = player.scheduledFrames > frameCount ? player.scheduledFrames - frameCount : 0;
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
        _outputVolume = 1.0f;
        _lockedOutputDeviceID = kAudioObjectUnknown;
        _observedOutputDeviceID = kAudioObjectUnknown;
        _playbackProfile = VBANPlaybackProfileOptimal;
        [self applyPlaybackProfile:VBANPlaybackProfileOptimal];
        [self installCoreAudioOutputListeners];
        dispatch_async(_queue, ^{
            [self writeDiagnosticEventOnQueue:@"audio-player-init" details:@{} includeSnapshot:YES];
        });
    }
    return self;
}

- (void)dealloc {
    [self removeCoreAudioOutputListeners];
    [self teardownAudioQueueOnQueue];
}

- (void)installCoreAudioOutputListeners {
    AudioObjectPropertyAddress defaultOutputAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectAddPropertyListener(kAudioObjectSystemObject,
                                       &defaultOutputAddress,
                                       VBANCoreAudioOutputChanged,
                                       (__bridge void *)self) == noErr) {
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
                                       (__bridge void *)self) == noErr) {
        self.hasDefaultSystemOutputListener = YES;
    }

    [self refreshObservedOutputDevice];
}

- (void)removeCoreAudioOutputListeners {
    AudioObjectPropertyAddress defaultOutputAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (self.hasDefaultOutputListener) {
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject,
                                          &defaultOutputAddress,
                                          VBANCoreAudioOutputChanged,
                                          (__bridge void *)self);
        self.hasDefaultOutputListener = NO;
    }

    AudioObjectPropertyAddress defaultSystemOutputAddress = {
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (self.hasDefaultSystemOutputListener) {
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject,
                                          &defaultSystemOutputAddress,
                                          VBANCoreAudioOutputChanged,
                                          (__bridge void *)self);
        self.hasDefaultSystemOutputListener = NO;
    }

    [self removeObservedOutputDeviceListeners];
}

- (void)refreshObservedOutputDevice {
    AudioObjectID deviceID = [self desiredOutputDeviceIDOnQueue];
    if (deviceID == kAudioObjectUnknown || deviceID == self.observedOutputDeviceID) {
        return;
    }

    [self removeObservedOutputDeviceListeners];
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
                                           (__bridge void *)self) == noErr) {
            addedAny = YES;
        }
    }
    self.hasOutputDeviceListeners = addedAny;
}

- (void)removeObservedOutputDeviceListeners {
    if (!self.hasOutputDeviceListeners || self.observedOutputDeviceID == kAudioObjectUnknown) {
        self.observedOutputDeviceID = kAudioObjectUnknown;
        self.hasOutputDeviceListeners = NO;
        return;
    }

    AudioObjectPropertyAddress addresses[] = {
        { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
    };

    for (NSUInteger index = 0; index < sizeof(addresses) / sizeof(addresses[0]); index++) {
        AudioObjectRemovePropertyListener(self.observedOutputDeviceID,
                                          &addresses[index],
                                          VBANCoreAudioOutputChanged,
                                          (__bridge void *)self);
    }
    self.observedOutputDeviceID = kAudioObjectUnknown;
    self.hasOutputDeviceListeners = NO;
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
        if (self.lockedOutputDeviceID == kAudioObjectUnknown) {
            self.lockedOutputDeviceID = [self currentDefaultOutputDeviceID];
        }
        return self.lockedOutputDeviceID;
    }
    return [self currentDefaultOutputDeviceID];
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

- (void)applyOutputDevicePolicyOnQueue {
    if (!self.audioQueue) {
        return;
    }

    NSString *deviceUID = [self desiredOutputDeviceUIDOnQueue];
    if (!deviceUID.length) {
        return;
    }

    CFStringRef uid = (__bridge CFStringRef)deviceUID;
    OSStatus status = AudioQueueSetProperty(self.audioQueue,
                                            kAudioQueueProperty_CurrentDevice,
                                            &uid,
                                            sizeof(uid));
    [self writeDiagnosticEventOnQueue:@"audio-queue-set-current-device"
                              details:@{
        @"deviceUID": deviceUID,
        @"status": @(status),
        @"device": [self dictionaryForDeviceID:[self desiredOutputDeviceIDOnQueue]]
    }
                      includeSnapshot:NO];
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

- (void)audioQueueRunningChangedOnQueue:(AudioQueueRef)queue {
    if (!self.audioQueue || self.audioQueue != queue) {
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
    }
}

- (void)checkAudioQueueHealthOnQueue {
    if (!self.audioQueue) {
        [self resetAutoRepairSuspicionOnQueue];
        return;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSString *desiredDeviceUID = [self desiredOutputDeviceUIDOnQueue];
    id currentDeviceUID = [self audioQueueCurrentDeviceUIDOnQueue];
    if (desiredDeviceUID.length
        && [currentDeviceUID isKindOfClass:NSString.class]
        && ![(NSString *)currentDeviceUID isEqualToString:desiredDeviceUID]) {
        [self writeDiagnosticEventOnQueue:@"audio-queue-device-drift"
                                  details:@{
            @"currentDeviceUID": currentDeviceUID,
            @"desiredDeviceUID": desiredDeviceUID
        }
                          includeSnapshot:YES];
        [self applyOutputDevicePolicyOnQueue];
        [self attemptAutomaticOutputRepairOnQueue:@"device-drift"
                                          details:@{
            @"currentDeviceUID": currentDeviceUID,
            @"desiredDeviceUID": desiredDeviceUID
        }];
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

    BOOL freshPackets = self.lastPacketEnqueuedAt > 0 && now - self.lastPacketEnqueuedAt < 2.5;
    BOOL queuePretendsRunning = [reportedRunning isKindOfClass:NSNumber.class] && [(NSNumber *)reportedRunning boolValue];
    double sampleRate = self.queueFormat.mSampleRate > 0 ? self.queueFormat.mSampleRate : 0;
    double queuedDuration = sampleRate > 0 ? (double)scheduledFrames / sampleRate : 0;
    BOOL manualRepairPattern = self.lastManualOutputReconnectAt > 0 && now - self.lastManualOutputReconnectAt < 600.0;
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
        @"manualRepairPattern": @(manualRepairPattern),
        @"manualRepairAgeSeconds": @(manualRepairAge)
    } mutableCopy];

    AudioObjectID desiredDevice = [self desiredOutputDeviceIDOnQueue];
    NSNumber *deviceRunning = [self uint32Property:kAudioDevicePropertyDeviceIsRunningSomewhere
                                         deviceID:desiredDevice
                                            scope:kAudioObjectPropertyScopeGlobal];
    if (deviceRunning) {
        details[@"deviceRunningSomewhere"] = deviceRunning;
    }

    if (self.autoRepairsOutput && self.audioQueueStarted && freshPackets && queuePretendsRunning && scheduledFrames > 0) {
        if (deviceRunning && !deviceRunning.boolValue) {
            suspicionReason = @"device-not-running";
        } else if (queuedDuration > fmax(0.65, self.maxQueuedDuration * 0.85)) {
            suspicionReason = @"queue-lagging";
        } else if (manualRepairPattern) {
            suspicionReason = @"manual-repair-pattern";
        }
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

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
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
    [self teardownAudioQueueOnQueue];
    self.lastLevelReportAt = 0;
    if (self.queueDropHandler) {
        self.queueDropHandler();
    }
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
    if (scheduledFrames == 0) {
        return;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - self.lastIntentionalEngineConfigurationAt < 0.35 || now - self.lastOutputRecoveryAt < 0.75) {
        return;
    }

    self.lastOutputRecoveryAt = now;
    self.lastIntentionalEngineConfigurationAt = now;
    [self writeDiagnosticEventOnQueue:@"audio-queue-stopped-recovery"
                              details:@{
        @"reason": reason ?: @"unknown",
        @"scheduledBuffers": @(scheduledBuffers),
        @"scheduledFrames": @(scheduledFrames),
        @"queuedMilliseconds": self.queueFormat.mSampleRate > 0 ? @(llround(((double)scheduledFrames / self.queueFormat.mSampleRate) * 1000.0)) : (id)[NSNull null],
        @"reportedRunning": [self audioQueueReportedRunningOnQueue],
        @"currentDeviceUID": [self audioQueueCurrentDeviceUIDOnQueue],
        @"desiredDeviceUID": [self jsonString:[self desiredOutputDeviceUIDOnQueue]]
    }
                      includeSnapshot:YES];
    [self teardownAudioQueueOnQueue];
    self.lastLevelReportAt = 0;
    if (self.queueDropHandler) {
        self.queueDropHandler();
    }
}

- (void)setPlaybackProfile:(VBANPlaybackProfile)playbackProfile {
    _playbackProfile = playbackProfile;
    dispatch_async(self.queue, ^{
        [self applyPlaybackProfile:playbackProfile];
    });
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
    float clamped = fminf(fmaxf(outputVolume, 0.0f), 1.0f);
    _outputVolume = clamped;
    dispatch_async(self.queue, ^{
        if (self.audioQueue) {
            AudioQueueSetParameter(self.audioQueue, kAudioQueueParam_Volume, clamped);
        }
    });
}

- (void)setLocksOutputDevice:(BOOL)locksOutputDevice {
    _locksOutputDevice = locksOutputDevice;
    dispatch_async(self.queue, ^{
        self.lockedOutputDeviceID = locksOutputDevice ? [self currentDefaultOutputDeviceID] : kAudioObjectUnknown;
        [self writeDiagnosticEventOnQueue:@"output-lock-changed"
                                  details:@{
            @"enabled": @(locksOutputDevice),
            @"lockedDevice": [self dictionaryForDeviceID:self.lockedOutputDeviceID]
        }
                          includeSnapshot:YES];
        [self refreshObservedOutputDevice];
        [self recoverFromOutputConfigurationChangeOnQueue];
    });
}

- (void)setAutoRepairsOutput:(BOOL)autoRepairsOutput {
    _autoRepairsOutput = autoRepairsOutput;
    dispatch_async(self.queue, ^{
        [self resetAutoRepairSuspicionOnQueue];
        [self writeDiagnosticEventOnQueue:@"auto-output-repair-changed"
                                  details:@{@"enabled": @(autoRepairsOutput)}
                          includeSnapshot:YES];
    });
}

- (void)coreAudioOutputConfigurationChanged {
    dispatch_async(self.queue, ^{
        [self writeDiagnosticEventOnQueue:@"coreaudio-output-configuration-changed"
                                  details:@{}
                          includeSnapshot:YES];
        [self refreshObservedOutputDevice];
        [self attemptAutomaticOutputRepairOnQueue:@"coreaudio-output-configuration-changed" details:@{}];
        [self recoverFromOutputConfigurationChangeOnQueue];
    });
}

- (void)reset {
    dispatch_sync(self.queue, ^{
        [self writeDiagnosticEventOnQueue:@"audio-reset" details:@{} includeSnapshot:YES];
        self.lastIntentionalEngineConfigurationAt = CFAbsoluteTimeGetCurrent();
        [self teardownAudioQueueOnQueue];
        self.lastLevelReportAt = 0;
    });
}

- (void)reconnectOutput {
    dispatch_async(self.queue, ^{
        [self writeDiagnosticEventOnQueue:@"manual-output-reconnect"
                                  details:@{@"hadAudioQueue": @(self.audioQueue != NULL)}
                          includeSnapshot:YES];
        self.lastManualOutputReconnectAt = CFAbsoluteTimeGetCurrent();
        self.lastIntentionalEngineConfigurationAt = CFAbsoluteTimeGetCurrent();
        [self resetAutoRepairSuspicionOnQueue];
        [self teardownAudioQueueOnQueue];
        self.lastLevelReportAt = 0;
    });
}

- (void)recoverFromOutputConfigurationChangeOnQueue {
    if (!self.audioQueue) {
        return;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - self.lastIntentionalEngineConfigurationAt < 0.35 || now - self.lastOutputRecoveryAt < 0.50) {
        return;
    }

    self.lastOutputRecoveryAt = now;
    self.lastIntentionalEngineConfigurationAt = CFAbsoluteTimeGetCurrent();
    [self writeDiagnosticEventOnQueue:@"audio-output-recovery"
                              details:@{}
                      includeSnapshot:YES];
    [self teardownAudioQueueOnQueue];
    self.lastLevelReportAt = 0;
}

- (void)enqueuePacket:(VBANPacket *)packet {
    dispatch_async(self.queue, ^{
        self.lastPacketEnqueuedAt = CFAbsoluteTimeGetCurrent();
        NSError *error = nil;
        double peak = 0;
        NSData *audioData = [self audioDataFromPacket:packet peak:&peak error:&error];
        if (!audioData) {
            if (self.errorHandler) {
                self.errorHandler(error.localizedDescription ?: @"Cannot decode audio packet");
            }
            return;
        }

        if (![self ensureAudioQueueForPacket:packet error:&error]) {
            if (self.errorHandler) {
                self.errorHandler(error.localizedDescription ?: @"Cannot start audio output");
            }
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
            [self resetAudioQueueBuffersOnQueue];
            if (self.queueDropHandler) {
                self.queueDropHandler();
            }
        }

        AudioQueueBufferRef queueBuffer = NULL;
        OSStatus allocateStatus = AudioQueueAllocateBuffer(self.audioQueue,
                                                          (UInt32)audioData.length,
                                                          &queueBuffer);
        if (allocateStatus != noErr || !queueBuffer) {
            if (self.errorHandler) {
                self.errorHandler([self messageForAudioStatus:allocateStatus fallback:@"Cannot allocate audio output buffer"]);
            }
            [self writeDiagnosticEventOnQueue:@"audio-queue-allocate-error"
                                      details:@{@"status": @(allocateStatus)}
                              includeSnapshot:YES];
            return;
        }

        memcpy(queueBuffer->mAudioData, audioData.bytes, audioData.length);
        queueBuffer->mAudioDataByteSize = (UInt32)audioData.length;
        queueBuffer->mUserData = (void *)(uintptr_t)packet.sampleCount;

        OSStatus enqueueStatus = AudioQueueEnqueueBuffer(self.audioQueue, queueBuffer, 0, NULL);
        if (enqueueStatus != noErr) {
            AudioQueueFreeBuffer(self.audioQueue, queueBuffer);
            if (self.errorHandler) {
                self.errorHandler([self messageForAudioStatus:enqueueStatus fallback:@"Cannot enqueue audio output buffer"]);
            }
            [self writeDiagnosticEventOnQueue:@"audio-queue-enqueue-error"
                                      details:@{@"status": @(enqueueStatus)}
                              includeSnapshot:YES];
            return;
        }

        @synchronized (self) {
            self.scheduledBuffers++;
            self.scheduledFrames += packet.sampleCount;
            queuedBuffers = self.scheduledBuffers;
        }
        if (!self.audioQueueStarted && queuedBuffers >= self.startBufferCount) {
            OSStatus startStatus = AudioQueueStart(self.audioQueue, NULL);
            if (startStatus == noErr) {
                self.audioQueueStarted = YES;
                [self writeDiagnosticEventOnQueue:@"audio-queue-started"
                                          details:@{@"scheduledBuffers": @(queuedBuffers)}
                                  includeSnapshot:NO];
            } else if (self.errorHandler) {
                self.errorHandler([self messageForAudioStatus:startStatus fallback:@"Cannot start audio output"]);
                [self writeDiagnosticEventOnQueue:@"audio-queue-start-error"
                                          details:@{@"status": @(startStatus)}
                                  includeSnapshot:YES];
            }
        }

        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (self.levelHandler && now - self.lastLevelReportAt >= self.levelReportInterval) {
            self.lastLevelReportAt = now;
            self.levelHandler(MIN(peak, 1.0));
        }
    });
}

- (BOOL)ensureAudioQueueForPacket:(VBANPacket *)packet error:(NSError **)error {
    BOOL formatChanged = !self.hasQueueFormat
        || self.queueFormat.mSampleRate != packet.sampleRate
        || self.queueFormat.mChannelsPerFrame != packet.channelCount;

    if (formatChanged) {
        self.lastIntentionalEngineConfigurationAt = CFAbsoluteTimeGetCurrent();
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
        OSStatus status = AudioQueueNewOutput(&format,
                                              VBANAudioQueueOutputCompleted,
                                              (__bridge void *)self,
                                              NULL,
                                              NULL,
                                              0,
                                              &outputQueue);
        if (status != noErr || !outputQueue) {
            if (error) {
                *error = [self errorForAudioStatus:status fallback:@"Cannot create audio output queue"];
            }
            [self writeDiagnosticEventOnQueue:@"audio-queue-create-error"
                                      details:@{@"status": @(status)}
                              includeSnapshot:YES];
            return NO;
        }

        self.audioQueue = outputQueue;
        self.queueFormat = format;
        self.hasQueueFormat = YES;
        self.audioQueueStarted = NO;
        OSStatus runningListenerStatus = AudioQueueAddPropertyListener(self.audioQueue,
                                                                       kAudioQueueProperty_IsRunning,
                                                                       VBANAudioQueueIsRunningChanged,
                                                                       (__bridge void *)self);
        self.hasAudioQueueRunningListener = runningListenerStatus == noErr;
        @synchronized (self) {
            self.scheduledBuffers = 0;
            self.scheduledFrames = 0;
        }

        [self applyOutputDevicePolicyOnQueue];
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
            maxPeak = fmaxf(maxPeak, fabsf(sample));
        }
    }

    if (peak) {
        *peak = maxPeak;
    }
    return data;
}

- (void)resetAudioQueueBuffersOnQueue {
    if (!self.audioQueue) {
        @synchronized (self) {
            self.scheduledBuffers = 0;
            self.scheduledFrames = 0;
        }
        self.audioQueueStarted = NO;
        return;
    }

    self.lastIntentionalEngineConfigurationAt = CFAbsoluteTimeGetCurrent();
    AudioQueueStop(self.audioQueue, true);
    AudioQueueReset(self.audioQueue);
    @synchronized (self) {
        self.scheduledBuffers = 0;
        self.scheduledFrames = 0;
    }
    self.audioQueueStarted = NO;
    AudioQueueSetParameter(self.audioQueue, kAudioQueueParam_Volume, self.outputVolume);
    [self applyOutputDevicePolicyOnQueue];
}

- (void)teardownAudioQueueOnQueue {
    [self stopAudioQueueWatchdogOnQueue];
    if (self.audioQueue) {
        if (self.hasAudioQueueRunningListener) {
            AudioQueueRemovePropertyListener(self.audioQueue,
                                             kAudioQueueProperty_IsRunning,
                                             VBANAudioQueueIsRunningChanged,
                                             (__bridge void *)self);
            self.hasAudioQueueRunningListener = NO;
        }
        AudioQueueStop(self.audioQueue, true);
        AudioQueueDispose(self.audioQueue, true);
        self.audioQueue = NULL;
    }
    self.hasAudioQueueRunningListener = NO;

    self.hasQueueFormat = NO;
    self.audioQueueStarted = NO;
    @synchronized (self) {
        self.scheduledBuffers = 0;
        self.scheduledFrames = 0;
    }
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
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [line writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:line];
    [handle closeFile];
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
    @synchronized (self) {
        scheduledBuffers = self.scheduledBuffers;
        scheduledFrames = self.scheduledFrames;
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
            return isfinite(value) ? value : 0;
        }
        case VBANDataTypeFloat64: {
            uint64_t raw = 0;
            for (NSUInteger index = 0; index < 8; index++) {
                raw |= (uint64_t)bytes[offset + index] << (index * 8);
            }
            double value = 0;
            memcpy(&value, &raw, sizeof(value));
            return isfinite(value) ? (float)value : 0;
        }
    }
}

@end
