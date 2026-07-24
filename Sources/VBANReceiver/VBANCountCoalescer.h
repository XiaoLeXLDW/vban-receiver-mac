#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thread-safe count aggregation with at most one outstanding drain request.
@interface VBANCountCoalescer : NSObject

@property (nonatomic, assign, readonly) NSUInteger pendingCount;

/// Returns YES only when the caller must schedule a drain.
- (BOOL)recordCount:(NSUInteger)count;
- (NSUInteger)drainCount;

@end

/// Thread-safe latest-value aggregation with at most one outstanding drain request.
@interface VBANLatestValueCoalescer<ObjectType> : NSObject

@property (nonatomic, strong, nullable, readonly) ObjectType pendingValue;

/// Returns YES only when the caller must schedule a drain.
- (BOOL)recordValue:(ObjectType)value;
- (nullable ObjectType)drainValue;

@end

NS_ASSUME_NONNULL_END
