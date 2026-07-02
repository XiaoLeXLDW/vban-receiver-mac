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

@property (nonatomic, copy, nullable) void (^levelHandler)(double level);
@property (nonatomic, copy, nullable) void (^errorHandler)(NSString *message);
@property (nonatomic, copy, nullable) void (^queueDropHandler)(void);
@property (nonatomic, assign) VBANPlaybackProfile playbackProfile;
@property (nonatomic, assign) float outputVolume;
@property (nonatomic, assign) BOOL locksOutputDevice;
@property (nonatomic, assign) BOOL autoRepairsOutput;
@property (nonatomic, copy, readonly) NSString *diagnosticLogPath;

- (void)enqueuePacket:(VBANPacket *)packet;
- (void)writeDiagnosticSnapshot:(NSString *)reason;
- (void)reconnectOutput;
- (void)reset;

@end

NS_ASSUME_NONNULL_END
