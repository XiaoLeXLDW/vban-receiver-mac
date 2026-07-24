#import "VBANCountCoalescer.h"

@interface VBANCountCoalescer ()

@property (nonatomic, assign) NSUInteger storedPendingCount;
@property (nonatomic, assign) BOOL drainScheduled;

@end

@interface VBANLatestValueCoalescer ()

@property (nonatomic, strong, nullable) id storedPendingValue;
@property (nonatomic, assign) BOOL drainScheduled;

@end

@implementation VBANCountCoalescer

- (NSUInteger)pendingCount {
    @synchronized (self) {
        return self.storedPendingCount;
    }
}

- (BOOL)recordCount:(NSUInteger)count {
    if (count == 0) {
        return NO;
    }

    @synchronized (self) {
        self.storedPendingCount = count > NSUIntegerMax - self.storedPendingCount
            ? NSUIntegerMax
            : self.storedPendingCount + count;
        if (self.drainScheduled) {
            return NO;
        }
        self.drainScheduled = YES;
        return YES;
    }
}

- (NSUInteger)drainCount {
    @synchronized (self) {
        NSUInteger count = self.storedPendingCount;
        self.storedPendingCount = 0;
        self.drainScheduled = NO;
        return count;
    }
}

@end

@implementation VBANLatestValueCoalescer

- (id)pendingValue {
    @synchronized (self) {
        return self.storedPendingValue;
    }
}

- (BOOL)recordValue:(id)value {
    if (!value) {
        return NO;
    }

    @synchronized (self) {
        self.storedPendingValue = value;
        if (self.drainScheduled) {
            return NO;
        }
        self.drainScheduled = YES;
        return YES;
    }
}

- (id)drainValue {
    @synchronized (self) {
        id value = self.storedPendingValue;
        self.storedPendingValue = nil;
        self.drainScheduled = NO;
        return value;
    }
}

@end
