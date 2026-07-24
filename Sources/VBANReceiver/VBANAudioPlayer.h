#import <Foundation/Foundation.h>

@class VBANPacket;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VBANPlaybackProfile) {
    VBANPlaybackProfileOptimal = 0,
    VBANPlaybackProfileFast = 1,
    VBANPlaybackProfileMedium = 2,
    VBANPlaybackProfileSlow = 3,
    VBANPlaybackProfileVerySlow = 4
};

@interface VBANAudioPlayer : NSObject

@property (atomic, copy, nullable) void (^levelHandler)(double level);
@property (atomic, copy, nullable) void (^errorHandler)(NSString *message);
@property (atomic, copy, nullable) void (^queueDropHandler)(NSUInteger count);
@property (atomic, copy, nullable) void (^outputAvailabilityHandler)(BOOL available, NSString * _Nullable deviceName);
@property (atomic, copy, nullable) void (^playbackStartedHandler)(void);
@property (atomic, assign) VBANPlaybackProfile playbackProfile;
@property (atomic, assign) float outputVolume;
@property (atomic, assign) BOOL locksOutputDevice;
@property (atomic, assign) BOOL autoRepairsOutput;
@property (atomic, assign) BOOL levelReportingEnabled;
@property (atomic, copy, readonly) NSString *diagnosticLogPath;

- (void)enqueuePacket:(VBANPacket *)packet;
- (void)writeDiagnosticSnapshot:(NSString *)reason;
- (void)reconnectOutput;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
