#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static const NSTimeInterval VBANPacketFreshnessWindow = 2.0;

NS_INLINE BOOL VBANPacketAgeIsFresh(NSTimeInterval age) {
    return age >= 0 && age < VBANPacketFreshnessWindow;
}

NS_INLINE NSTimeInterval VBANPacketFreshnessDelay(NSTimeInterval age) {
    return MAX(0.05, VBANPacketFreshnessWindow - MAX(0, age));
}

NS_INLINE BOOL VBANShouldAnimateLevel(BOOL presentationVisible,
                                      BOOL receiverRunning,
                                      double level,
                                      double targetLevel) {
    return presentationVisible && receiverRunning && (level > 0 || targetLevel > 0);
}

NS_ASSUME_NONNULL_END
