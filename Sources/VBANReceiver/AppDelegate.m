#import "AppDelegate.h"

#import "VBANAudioPlayer.h"
#import "VBANPacket.h"
#import "VBANUDPReceiver.h"

#import <math.h>

typedef NS_ENUM(NSInteger, ReceiverStatusKind) {
    ReceiverStatusKindStopped,
    ReceiverStatusKindWaiting,
    ReceiverStatusKindReceiving
};

typedef NS_ENUM(NSInteger, DashboardLanguage) {
    DashboardLanguageChinese = 0,
    DashboardLanguageEnglish = 1
};

static NSString *Localized(DashboardLanguage language, NSString *zh, NSString *en) {
    return language == DashboardLanguageChinese ? zh : en;
}

static NSColor *HexColor(uint32_t hex) {
    return [NSColor colorWithCalibratedRed:((hex >> 16) & 0xFF) / 255.0
                                     green:((hex >> 8) & 0xFF) / 255.0
                                      blue:(hex & 0xFF) / 255.0
                                     alpha:1.0];
}

static NSColor *HexColorAlpha(uint32_t hex, CGFloat alpha) {
    return [HexColor(hex) colorWithAlphaComponent:alpha];
}

static NSColor *AccentColor(void) {
    return HexColor(0x2F8EF7);
}

static NSColor *AccentColorAlpha(CGFloat alpha) {
    return [AccentColor() colorWithAlphaComponent:alpha];
}

static NSColor *SystemHighlightColor(void) {
    if (@available(macOS 10.14, *)) {
        return NSColor.controlAccentColor;
    }
    return AccentColor();
}

static NSColor *SystemHighlightColorAlpha(CGFloat alpha) {
    return [SystemHighlightColor() colorWithAlphaComponent:alpha];
}

static NSColor *GlassFill(CGFloat alpha) {
    return HexColorAlpha(0x1F2D37, alpha);
}

static NSColor *GlassFieldFill(CGFloat alpha) {
    return HexColorAlpha(0xFFFFFF, alpha);
}

static NSColor *PrimaryTextColor(void) {
    return HexColor(0xF4F7FA);
}

static NSColor *SecondaryTextColor(void) {
    return HexColor(0xC7D2DA);
}

static NSColor *MutedTextColor(void) {
    return HexColorAlpha(0xFFFFFF, 0.52);
}

static NSColor *MuteTextColor(void) {
    return HexColor(0xE06A72);
}

static NSColor *MuteButtonFillColor(void) {
    return HexColorAlpha(0x7A3338, 0.64);
}

static const CGFloat DashboardDefaultWidth = 600.0;
static const CGFloat DashboardDefaultHeight = 400.0;
static const CGFloat DashboardMinimumWidth = 600.0;
static const CGFloat DashboardMinimumHeight = 400.0;
static const CGFloat DashboardHeaderHeight = 54.0;
static const CGFloat DashboardMarginX = 16.0;
static const CGFloat DashboardColumnGap = 12.0;
static const CGFloat DashboardRowGap = 12.0;
static const CGFloat DashboardLeftColumnWidth = 204.0;
static const CGFloat DashboardRightColumnWidth = 352.0;
static const CGFloat DashboardTopCardY = 58.0;
static const CGFloat DashboardTopCardHeight = 202.0;
static const CGFloat DashboardBottomCardY = 270.0;
static const CGFloat DashboardBottomCardHeight = 118.0;
static const CGFloat DashboardCardPadding = 12.0;
static const CGFloat DashboardInputHeight = 30.0;
static const CGFloat DashboardDropdownHeight = 26.0;
static const CGFloat DashboardSmallButtonHeight = 30.0;
static const CGFloat DashboardPrimaryButtonHeight = 32.0;
static const CGFloat DashboardCardCornerRadius = 12.0;
static const CGFloat DashboardFieldCornerRadius = 8.0;
static const CGFloat DashboardButtonCornerRadius = 9.0;
static const CGFloat DashboardFormLabelWidth = 36.0;
static const CGFloat DashboardFormLabelGap = 8.0;
static const CGFloat DashboardEnglishFormLabelWidth = 58.0;
static const CGFloat DashboardEnglishFormLabelGap = 8.0;
static const CGFloat DashboardMetricLabelWidth = 34.0;
static const CGFloat DashboardMetricLabelGap = 6.0;
static const CGFloat DashboardEnglishMetricLabelWidth = 52.0;
static const CGFloat DashboardEnglishMetricLabelGap = 6.0;
static const CGFloat DashboardFieldTextInsetX = 10.0;

static NSString *Trimmed(NSString *value) {
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

static NSString *CompactFormatText(NSString *format) {
    NSString *text = Trimmed(format);
    if (!text.length) {
        return @"-";
    }

    NSArray<NSString *> *parts = [text componentsSeparatedByString:@" Hz"];
    if (parts.count > 1) {
        NSInteger sampleRate = parts.firstObject.integerValue;
        if (sampleRate > 0) {
            double kHz = sampleRate / 1000.0;
            NSString *rateText = fabs(kHz - round(kHz)) < 0.05
                ? [NSString stringWithFormat:@"%.0fk", kHz]
                : [NSString stringWithFormat:@"%.1fk", kHz];
            text = [rateText stringByAppendingString:[[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@" Hz"]];
        }
    }
    text = [text stringByReplacingOccurrencesOfString:@" PCM" withString:@""];
    return text;
}

static NSFont *SystemFont(CGFloat size, NSFontWeight weight) {
    return [NSFont systemFontOfSize:size weight:weight];
}

static NSFont *MonoFont(CGFloat size, NSFontWeight weight) {
    return [NSFont monospacedSystemFontOfSize:size weight:weight];
}

static NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = SystemFont(size, weight);
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

static NSFont *FittedSystemFont(NSString *text, CGFloat availableWidth, CGFloat baseSize, CGFloat minimumSize, NSFontWeight weight) {
    NSString *value = text ?: @"";
    CGFloat size = baseSize;
    while (size > minimumSize) {
        NSFont *font = SystemFont(size, weight);
        CGFloat measuredWidth = [value sizeWithAttributes:@{NSFontAttributeName: font}].width;
        if (measuredWidth <= availableWidth || availableWidth <= 1) {
            return font;
        }
        size -= 0.5;
    }
    return SystemFont(minimumSize, weight);
}

static void FitLabelToWidth(NSTextField *label, CGFloat baseSize, CGFloat minimumSize, NSFontWeight weight) {
    label.font = FittedSystemFont(label.stringValue, label.bounds.size.width, baseSize, minimumSize, weight);
    label.lineBreakMode = NSLineBreakByClipping;
    label.toolTip = label.stringValue;
}

static void FitLabelToAvailableWidth(NSTextField *label, CGFloat availableWidth, CGFloat baseSize, CGFloat minimumSize, NSFontWeight weight) {
    label.font = FittedSystemFont(label.stringValue, MAX(1, availableWidth), baseSize, minimumSize, weight);
    label.lineBreakMode = NSLineBreakByClipping;
    label.toolTip = label.stringValue;
}

static void ApplyLanguageAwareLabel(NSTextField *label,
                                    DashboardLanguage language,
                                    CGFloat chineseSize,
                                    CGFloat englishSize,
                                    CGFloat englishMinimumSize,
                                    CGFloat englishAvailableWidth,
                                    NSFontWeight weight) {
    if (language == DashboardLanguageEnglish) {
        FitLabelToAvailableWidth(label, englishAvailableWidth > 0 ? englishAvailableWidth : label.bounds.size.width, englishSize, englishMinimumSize, weight);
    } else {
        label.font = SystemFont(chineseSize, weight);
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.toolTip = label.stringValue;
    }
}

static CGFloat FormLabelWidthForLanguage(DashboardLanguage language) {
    return language == DashboardLanguageEnglish ? DashboardEnglishFormLabelWidth : DashboardFormLabelWidth;
}

static CGFloat FormLabelGapForLanguage(DashboardLanguage language) {
    return language == DashboardLanguageEnglish ? DashboardEnglishFormLabelGap : DashboardFormLabelGap;
}

static CGFloat MetricLabelWidthForLanguage(DashboardLanguage language) {
    return language == DashboardLanguageEnglish ? DashboardEnglishMetricLabelWidth : DashboardMetricLabelWidth;
}

static CGFloat MetricLabelGapForLanguage(DashboardLanguage language) {
    return language == DashboardLanguageEnglish ? DashboardEnglishMetricLabelGap : DashboardMetricLabelGap;
}

@interface GlassBackgroundView : NSVisualEffectView
@end

@implementation GlassBackgroundView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.material = NSVisualEffectMaterialHUDWindow;
        self.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        self.state = NSVisualEffectStateActive;
        self.wantsLayer = YES;
        self.layer.masksToBounds = YES;
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return YES; }
@end

@interface PanelView : NSView
@property (nonatomic, strong) NSColor *fillColor;
@property (nonatomic, strong) NSColor *borderColor;
@property (nonatomic, assign) CGFloat cornerRadius;
@end

@implementation PanelView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = YES;
        _fillColor = GlassFill(0.72);
        _borderColor = HexColorAlpha(0xFFFFFF, 0.12);
        _cornerRadius = DashboardCardCornerRadius;
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    NSRect rect = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *path = self.cornerRadius > 0
        ? [NSBezierPath bezierPathWithRoundedRect:rect xRadius:self.cornerRadius yRadius:self.cornerRadius]
        : [NSBezierPath bezierPathWithRect:rect];
    [self.fillColor setFill];
    [path fill];
    if (self.borderColor) {
        [self.borderColor setStroke];
        path.lineWidth = 1.0;
        [path stroke];
    }
}
@end

@interface StatusPillView : NSView
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSColor *dotColor;
@property (nonatomic, assign) DashboardLanguage language;
@end

@implementation StatusPillView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _title = @"Stopped";
        _dotColor = HexColor(0x89968F);
        _language = DashboardLanguageChinese;
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)setTitle:(NSString *)title {
    _title = [title copy];
    self.needsDisplay = YES;
}
- (void)setDotColor:(NSColor *)dotColor {
    _dotColor = dotColor;
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                         xRadius:self.bounds.size.height / 2.0
                                                         yRadius:self.bounds.size.height / 2.0];
    [GlassFill(0.50) setFill];
    [path fill];
    [HexColorAlpha(0xFFFFFF, 0.14) setStroke];
    path.lineWidth = 1;
    [path stroke];

    [self.dotColor setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(11, (self.bounds.size.height - 7) / 2.0, 7, 7)] fill];

    CGFloat titleWidth = self.bounds.size.width - 32;
    NSDictionary *attrs = @{
        NSFontAttributeName: self.language == DashboardLanguageEnglish
            ? FittedSystemFont(self.title, titleWidth, 14, 12.5, NSFontWeightSemibold)
            : SystemFont(14, NSFontWeightSemibold),
        NSForegroundColorAttributeName: PrimaryTextColor()
    };
    [self.title drawInRect:NSMakeRect(24, 8, titleWidth, 18) withAttributes:attrs];
}
@end

@interface LevelMeterView : NSControl
@property (nonatomic, assign) double level;
@property (nonatomic, assign) double volume;
@property (nonatomic, assign, getter=isMuted) BOOL muted;
@property (nonatomic, assign) DashboardLanguage language;
@end

@implementation LevelMeterView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _volume = 1.0;
        _language = DashboardLanguageEnglish;
        [self updateToolTip];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder {
    self.needsDisplay = YES;
    return YES;
}
- (BOOL)resignFirstResponder {
    self.needsDisplay = YES;
    return YES;
}
- (void)setLevel:(double)level {
    _level = MIN(MAX(level, 0), 1);
    [self updateToolTip];
    self.needsDisplay = YES;
}
- (void)setVolume:(double)volume {
    _volume = MIN(MAX(volume, 0), 1);
    [self updateToolTip];
    self.needsDisplay = YES;
}
- (void)setMuted:(BOOL)muted {
    _muted = muted;
    [self updateToolTip];
    self.needsDisplay = YES;
}
- (void)setLanguage:(DashboardLanguage)language {
    _language = language;
    [self updateToolTip];
}
- (void)updateToolTip {
    double outputLevel = self.muted ? 0 : self.level * self.volume;
    NSString *prefix = self.muted
        ? Localized(self.language, @"已静音", @"Muted")
        : Localized(self.language, @"输出", @"Output");
    self.toolTip = [NSString stringWithFormat:@"%@ %ld%% · %@ %ld%%",
                    prefix,
                    (long)llround(outputLevel * 100),
                    Localized(self.language, @"音量", @"Volume"),
                    (long)llround(_volume * 100)];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect meterTrack = [self meterTrackRect];
    NSBezierPath *meterTrackPath = [NSBezierPath bezierPathWithRoundedRect:meterTrack xRadius:5 yRadius:5];
    [HexColorAlpha(0xFFFFFF, self.muted ? 0.07 : 0.10) setFill];
    [meterTrackPath fill];

    CGFloat inputWidth = [self widthForAmplitude:self.level inRect:meterTrack];
    if (self.level > 0) {
        NSRect input = NSMakeRect(meterTrack.origin.x, meterTrack.origin.y, MAX(3, inputWidth), meterTrack.size.height);
        NSBezierPath *inputPath = [NSBezierPath bezierPathWithRoundedRect:input xRadius:5 yRadius:5];
        [HexColorAlpha(0xF2F4F5, self.muted ? 0.13 : 0.20) setFill];
        [inputPath fill];
    }

    double outputLevel = self.muted ? 0 : self.level * self.volume;
    CGFloat outputWidth = [self widthForAmplitude:outputLevel inRect:meterTrack];
    if (outputLevel > 0) {
        NSRect output = NSMakeRect(meterTrack.origin.x, meterTrack.origin.y, MAX(3, outputWidth), meterTrack.size.height);
        NSBezierPath *outputPath = [NSBezierPath bezierPathWithRoundedRect:output xRadius:5 yRadius:5];
        [AccentColorAlpha(self.muted ? 0.16 : 0.84) setFill];
        [outputPath fill];
    }

    NSArray<NSNumber *> *ticks = @[@(-48), @(-42), @(-36), @(-30), @(-24), @(-18), @(-12), @(-6), @(0)];
    NSDictionary *tickAttrs = @{
        NSFontAttributeName: SystemFont(10, NSFontWeightSemibold),
            NSForegroundColorAttributeName: HexColorAlpha(0xF2F4F5, self.muted ? 0.32 : 0.50)
    };
    [HexColorAlpha(0xFFFFFF, self.muted ? 0.18 : 0.28) setStroke];
    for (NSNumber *tickNumber in ticks) {
        CGFloat x = [self xForDecibels:tickNumber.doubleValue inRect:meterTrack];
        NSBezierPath *tickPath = [NSBezierPath bezierPath];
        [tickPath moveToPoint:NSMakePoint(x, meterTrack.origin.y - 6)];
        [tickPath lineToPoint:NSMakePoint(x, NSMaxY(meterTrack) + 4)];
        tickPath.lineWidth = 1;
        [tickPath stroke];

        if (tickNumber.integerValue % 12 == 0) {
            NSString *label = tickNumber.integerValue == 0 ? @"0" : [NSString stringWithFormat:@"%ld", tickNumber.integerValue];
            NSSize labelSize = [label sizeWithAttributes:tickAttrs];
            CGFloat labelX = MIN(MAX(x - labelSize.width / 2, meterTrack.origin.x),
                                 NSMaxX(meterTrack) - labelSize.width);
            [label drawAtPoint:NSMakePoint(labelX, 54) withAttributes:tickAttrs];
        }
    }

    NSRect volumeTrack = [self volumeTrackRect];
    NSBezierPath *volumePath = [NSBezierPath bezierPathWithRoundedRect:volumeTrack xRadius:4 yRadius:4];
    [HexColorAlpha(0xF2F4F5, self.muted ? 0.11 : 0.16) setFill];
    [volumePath fill];

    CGFloat volumeWidth = volumeTrack.size.width * self.volume;
    if (volumeWidth > 0) {
        NSRect volumeFill = NSMakeRect(volumeTrack.origin.x, volumeTrack.origin.y, MAX(3, volumeWidth), volumeTrack.size.height);
        NSBezierPath *volumeFillPath = [NSBezierPath bezierPathWithRoundedRect:volumeFill xRadius:4 yRadius:4];
        [AccentColorAlpha(self.muted ? 0.18 : 0.64) setFill];
        [volumeFillPath fill];
    }

    CGFloat thumbX = volumeTrack.origin.x + volumeTrack.size.width * self.volume;
    NSRect thumb = NSMakeRect(MIN(MAX(thumbX - 2, volumeTrack.origin.x), NSMaxX(volumeTrack) - 4),
                              volumeTrack.origin.y - 5,
                              4,
                              volumeTrack.size.height + 10);
    NSBezierPath *thumbPath = [NSBezierPath bezierPathWithRoundedRect:thumb xRadius:2 yRadius:2];
    [HexColorAlpha(0xF2F4F5, self.muted ? 0.48 : 0.88) setFill];
    [thumbPath fill];
    [HexColorAlpha(0x0B0D0F, 0.28) setStroke];
    thumbPath.lineWidth = 0.5;
    [thumbPath stroke];
}
- (NSRect)levelTrackRect {
    return [self meterTrackRect];
}
- (NSRect)volumeTrackRect {
    return NSMakeRect(0, 24, MAX(1, self.bounds.size.width), 6);
}
- (NSRect)meterTrackRect {
    return NSMakeRect(0, 80, MAX(1, self.bounds.size.width), 12);
}
- (CGFloat)xForDecibels:(double)decibels inRect:(NSRect)rect {
    double clamped = MIN(0, MAX(-48.0, decibels));
    return rect.origin.x + rect.size.width * [self mixerScalePositionForDecibels:clamped];
}
- (CGFloat)mixerScalePositionForDecibels:(double)decibels {
    static const double dbs[] = { -48, -42, -36, -30, -24, -18, -12, -6, 0 };
    static const double positions[] = { 0.00, 0.08, 0.17, 0.28, 0.40, 0.54, 0.69, 0.84, 1.00 };
    NSUInteger count = sizeof(dbs) / sizeof(dbs[0]);

    if (decibels <= dbs[0]) {
        return positions[0];
    }
    if (decibels >= dbs[count - 1]) {
        return positions[count - 1];
    }

    for (NSUInteger index = 1; index < count; index++) {
        if (decibels <= dbs[index]) {
            double local = (decibels - dbs[index - 1]) / (dbs[index] - dbs[index - 1]);
            return positions[index - 1] + local * (positions[index] - positions[index - 1]);
        }
    }
    return positions[count - 1];
}
- (CGFloat)widthForAmplitude:(double)amplitude inRect:(NSRect)rect {
    if (amplitude <= 0.003981) {
        return 0;
    }
    double decibels = 20.0 * log10(amplitude);
    return [self xForDecibels:decibels inRect:rect] - rect.origin.x;
}
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    [self updateVolumeWithEvent:event];
}
- (void)mouseDragged:(NSEvent *)event {
    [self updateVolumeWithEvent:event];
}
- (void)keyDown:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers ?: @"";
    if (!characters.length) {
        [super keyDown:event];
        return;
    }

    unichar key = [characters characterAtIndex:0];
    double step = (event.modifierFlags & NSEventModifierFlagShift) ? 0.01 : 0.05;
    if (key == NSLeftArrowFunctionKey || key == NSDownArrowFunctionKey) {
        self.volume -= step;
        [self sendAction:self.action to:self.target];
        return;
    }
    if (key == NSRightArrowFunctionKey || key == NSUpArrowFunctionKey) {
        self.volume += step;
        [self sendAction:self.action to:self.target];
        return;
    }
    if (key == NSHomeFunctionKey) {
        self.volume = 0;
        [self sendAction:self.action to:self.target];
        return;
    }
    if (key == NSEndFunctionKey) {
        self.volume = 1;
        [self sendAction:self.action to:self.target];
        return;
    }

    [super keyDown:event];
}
- (void)updateVolumeWithEvent:(NSEvent *)event {
    NSRect track = [self volumeTrackRect];
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    self.volume = (point.x - track.origin.x) / track.size.width;
    [self sendAction:self.action to:self.target];
}
@end

@interface CounterTileView : NSView
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *valueLabel;
@property (nonatomic, assign) DashboardLanguage language;
- (instancetype)initWithTitle:(NSString *)title;
- (void)setValueText:(NSString *)value;
- (void)updateValueFontForText:(NSString *)text;
@end

@implementation CounterTileView
- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _language = DashboardLanguageChinese;
        _titleLabel = Label(title, 11, NSFontWeightSemibold, MutedTextColor());
        _valueLabel = Label(@"0", 18, NSFontWeightBold, PrimaryTextColor());
        _valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:18 weight:NSFontWeightBold];
        _valueLabel.lineBreakMode = NSLineBreakByClipping;
        _valueLabel.maximumNumberOfLines = 1;
        _valueLabel.allowsExpansionToolTips = YES;
        [self addSubview:_titleLabel];
        [self addSubview:_valueLabel];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout];
    self.titleLabel.frame = NSMakeRect(14, 8, self.bounds.size.width - 28, 13);
    self.valueLabel.frame = NSMakeRect(14, 20, self.bounds.size.width - 28, 18);
    ApplyLanguageAwareLabel(self.titleLabel, self.language, 11, 11, 9, self.titleLabel.bounds.size.width, NSFontWeightSemibold);
    [self updateValueFontForText:self.valueLabel.stringValue];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:8 yRadius:8];
    [GlassFill(0.36) setFill];
    [path fill];
    [HexColorAlpha(0xFFFFFF, 0.12) setStroke];
    path.lineWidth = 1;
    [path stroke];
}
- (void)setValueText:(NSString *)value {
    NSString *text = value.length ? value : @"-";
    self.valueLabel.stringValue = text;
    self.valueLabel.toolTip = text;
    [self updateValueFontForText:text];
}
- (void)updateValueFontForText:(NSString *)text {
    BOOL hasLetters = [text rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound;
    CGFloat size = hasLetters ? 17 : 18;
    if (text.length > 8) {
        size = 13.5;
    } else if (text.length > 6) {
        size = 15;
    } else if (text.length > 4) {
        size = 17;
    }

    CGFloat availableWidth = self.valueLabel.bounds.size.width > 0 ? self.valueLabel.bounds.size.width : MAX(1, self.bounds.size.width - 24);
    NSFont *font = nil;
    while (size >= 12) {
        font = hasLetters
            ? SystemFont(size, NSFontWeightSemibold)
            : [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightSemibold];
        CGFloat measuredWidth = [text sizeWithAttributes:@{NSFontAttributeName: font}].width;
        if (measuredWidth <= availableWidth || availableWidth <= 1) {
            break;
        }
        size -= 1;
    }
    self.valueLabel.font = hasLetters
        ? SystemFont(size, NSFontWeightSemibold)
        : [NSFont monospacedDigitSystemFontOfSize:size weight:NSFontWeightSemibold];
}
@end

@interface MetricPairView : NSView
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *valueLabel;
@property (nonatomic, assign) BOOL preservesFullValue;
@property (nonatomic, assign) DashboardLanguage language;
- (instancetype)initWithTitle:(NSString *)title;
- (void)setValueText:(NSString *)value;
@end

@implementation MetricPairView
- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _language = DashboardLanguageChinese;
        _titleLabel = Label(title, 13.5, NSFontWeightSemibold, SecondaryTextColor());
        _valueLabel = Label(@"—", 14, NSFontWeightSemibold, PrimaryTextColor());
        _valueLabel.font = SystemFont(14, NSFontWeightSemibold);
        _valueLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _valueLabel.maximumNumberOfLines = 1;
        _valueLabel.allowsExpansionToolTips = YES;
        [self addSubview:_titleLabel];
        [self addSubview:_valueLabel];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout];
    CGFloat labelWidth = MetricLabelWidthForLanguage(self.language);
    CGFloat labelGap = MetricLabelGapForLanguage(self.language);
    self.titleLabel.frame = NSMakeRect(0, 1, labelWidth, 16);
    self.titleLabel.alignment = self.language == DashboardLanguageEnglish ? NSTextAlignmentLeft : NSTextAlignmentRight;
    ApplyLanguageAwareLabel(self.titleLabel, self.language, 13.5, 13.5, 10.5, self.titleLabel.bounds.size.width, NSFontWeightSemibold);
    self.valueLabel.frame = NSMakeRect(labelWidth + labelGap,
                                       1,
                                       MAX(1, self.bounds.size.width - labelWidth - labelGap),
                                       16);
    [self applyValueStyle];
}
- (void)setValueText:(NSString *)value {
    NSString *text = value.length ? value : @"—";
    if ([text isEqualToString:@"-"]) {
        text = @"—";
    }
    self.valueLabel.stringValue = text;
    self.valueLabel.toolTip = text;
    [self applyValueStyle];
}
- (void)applyValueStyle {
    NSString *text = self.valueLabel.stringValue ?: @"";
    if (self.preservesFullValue) {
        BOOL noSignal = [text isEqualToString:@"No signal"] || [text isEqualToString:@"无信号"];
        self.valueLabel.lineBreakMode = NSLineBreakByClipping;
        self.valueLabel.font = noSignal
            ? SystemFont(14, NSFontWeightSemibold)
            : FittedSystemFont(text, self.valueLabel.bounds.size.width, 13.5, 8.8, NSFontWeightSemibold);
        self.valueLabel.textColor = noSignal ? MutedTextColor() : PrimaryTextColor();
    } else {
        self.valueLabel.lineBreakMode = NSLineBreakByClipping;
        self.valueLabel.font = FittedSystemFont(text, self.valueLabel.bounds.size.width, 14, 8.8, NSFontWeightSemibold);
        self.valueLabel.textColor = PrimaryTextColor();
    }
}
@end

@interface CompactInputFieldCell : NSTextFieldCell
@end

@implementation CompactInputFieldCell
- (NSRect)centeredTextRectForBounds:(NSRect)rect {
    NSFont *font = self.font ?: SystemFont(13.5, NSFontWeightSemibold);
    CGFloat textHeight = ceil(font.ascender - font.descender);
    CGFloat y = floor(rect.origin.y + (rect.size.height - textHeight) * 0.5) - 1;
    return NSMakeRect(rect.origin.x + DashboardFieldTextInsetX,
                      y,
                      MAX(1, rect.size.width - DashboardFieldTextInsetX * 2),
                      textHeight + 2);
}
- (NSRect)drawingRectForBounds:(NSRect)rect {
    return [self centeredTextRectForBounds:rect];
}
- (void)editWithFrame:(NSRect)rect
               inView:(NSView *)controlView
               editor:(NSText *)textObj
             delegate:(id)delegate
                event:(NSEvent *)event {
    [super editWithFrame:[self centeredTextRectForBounds:rect]
                  inView:controlView
                  editor:textObj
                delegate:delegate
                   event:event];
}
- (void)selectWithFrame:(NSRect)rect
                 inView:(NSView *)controlView
                 editor:(NSText *)textObj
               delegate:(id)delegate
                  start:(NSInteger)selectionStart
                 length:(NSInteger)selectionLength {
    [super selectWithFrame:[self centeredTextRectForBounds:rect]
                    inView:controlView
                    editor:textObj
                  delegate:delegate
                     start:selectionStart
                    length:selectionLength];
}
@end

@interface CompactInputField : NSTextField
@property (nonatomic, copy) NSString *placeholder;
@property (nonatomic, assign) BOOL hovered;
@end

@implementation CompactInputField
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _placeholder = @"";
        self.cell = [[CompactInputFieldCell alloc] initTextCell:@""];
        self.bezeled = NO;
        self.bordered = NO;
        self.drawsBackground = NO;
        self.focusRingType = NSFocusRingTypeNone;
        self.editable = YES;
        self.selectable = YES;
        self.enabled = YES;
        self.usesSingleLineMode = YES;
        self.lineBreakMode = NSLineBreakByClipping;
        self.allowsExpansionToolTips = YES;
        self.font = SystemFont(13.5, NSFontWeightSemibold);
        self.textColor = PrimaryTextColor();
        self.maximumNumberOfLines = 1;
        [[self cell] setScrollable:YES];
        [[self cell] setWraps:NO];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)accessibilityPerformPress {
    if (!self.enabled || !self.editable) {
        return NO;
    }
    [self.window makeFirstResponder:self];
    return YES;
}
- (BOOL)isFocused {
    return self.currentEditor != nil || self.window.firstResponder == self;
}
- (void)mouseDown:(NSEvent *)event {
    if (self.enabled && self.editable) {
        [self.window makeFirstResponder:self];
    }
    [super mouseDown:event];
}
- (void)setStringValue:(NSString *)stringValue {
    [super setStringValue:stringValue ?: @""];
    [self updateFittedFont];
    self.needsDisplay = YES;
}
- (void)setPlaceholder:(NSString *)placeholder {
    _placeholder = [placeholder copy] ?: @"";
    NSDictionary *attrs = @{
        NSFontAttributeName: self.font ?: SystemFont(13.5, NSFontWeightSemibold),
        NSForegroundColorAttributeName: MutedTextColor()
    };
    self.placeholderAttributedString = [[NSAttributedString alloc] initWithString:_placeholder attributes:attrs];
    [self updateFittedFont];
    self.needsDisplay = YES;
}
- (void)setEditable:(BOOL)editable {
    [super setEditable:editable];
    self.selectable = editable;
    if (!editable && self.currentEditor) {
        [self.window makeFirstResponder:nil];
    }
    self.needsDisplay = YES;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect;
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:options owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)event {
    self.hovered = YES;
    self.needsDisplay = YES;
}
- (void)mouseExited:(NSEvent *)event {
    self.hovered = NO;
    self.needsDisplay = YES;
}
- (void)textDidBeginEditing:(NSNotification *)notification {
    [super textDidBeginEditing:notification];
    self.needsDisplay = YES;
}
- (void)textDidChange:(NSNotification *)notification {
    [super textDidChange:notification];
    [self updateFittedFont];
    [self sendAction:self.action to:self.target];
    self.needsDisplay = YES;
}
- (void)textDidEndEditing:(NSNotification *)notification {
    [super textDidEndEditing:notification];
    [self updateFittedFont];
    self.needsDisplay = YES;
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.needsDisplay = YES;
}
- (void)updateFittedFont {
    NSString *text = self.stringValue.length ? self.stringValue : self.placeholder;
    CGFloat width = self.bounds.size.width > 0 ? self.bounds.size.width : 132;
    self.font = FittedSystemFont(text ?: @"", width - DashboardFieldTextInsetX * 2, 13.5, 11.0, NSFontWeightSemibold);
    self.textColor = PrimaryTextColor();
    if (self.placeholder.length) {
        self.placeholderAttributedString = [[NSAttributedString alloc] initWithString:self.placeholder
                                                                           attributes:@{
            NSFontAttributeName: self.font ?: SystemFont(13.5, NSFontWeightSemibold),
            NSForegroundColorAttributeName: MutedTextColor()
        }];
    }
}
- (void)setFrame:(NSRect)frameRect {
    [super setFrame:frameRect];
    [self updateFittedFont];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect rect = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect
                                                         xRadius:DashboardFieldCornerRadius
                                                         yRadius:DashboardFieldCornerRadius];
    CGFloat fillAlpha = self.isFocused ? 0.14 : (self.hovered ? 0.105 : 0.08);
    [GlassFieldFill(fillAlpha) setFill];
    [path fill];
    [(self.isFocused ? AccentColorAlpha(0.78) : HexColorAlpha(0xFFFFFF, self.hovered ? 0.18 : 0.13)) setStroke];
    path.lineWidth = self.isFocused ? 1.6 : 1.0;
    [path stroke];
    [super drawRect:dirtyRect];
}
@end

@interface LabeledTextFieldView : NSView
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) CompactInputField *textField;
@property (nonatomic, assign, getter=isFocused) BOOL focused;
@property (nonatomic, assign) DashboardLanguage language;
- (instancetype)initWithTitle:(NSString *)title placeholder:(NSString *)placeholder value:(NSString *)value;
- (void)setTitleText:(NSString *)title placeholder:(NSString *)placeholder;
@end

@implementation LabeledTextFieldView
- (instancetype)initWithTitle:(NSString *)title placeholder:(NSString *)placeholder value:(NSString *)value {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _language = DashboardLanguageChinese;
        _titleLabel = Label(title, 13.5, NSFontWeightSemibold, SecondaryTextColor());
        _textField = [[CompactInputField alloc] initWithFrame:NSZeroRect];
        _textField.stringValue = value ?: @"";
        _textField.placeholder = placeholder ?: @"";
        [self addSubview:_titleLabel];
        [self addSubview:_textField];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (NSView *)hitTest:(NSPoint)point {
    if (!self.hidden && NSPointInRect(point, self.textField.frame)) {
        return self.textField;
    }
    return [super hitTest:point];
}
- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(point, self.textField.frame)) {
        [self.window makeFirstResponder:self.textField];
        return;
    }
    [super mouseDown:event];
}
- (NSRect)fieldFrame {
    CGFloat labelWidth = FormLabelWidthForLanguage(self.language);
    CGFloat labelGap = FormLabelGapForLanguage(self.language);
    return NSMakeRect(labelWidth + labelGap,
                      0,
                      MAX(1, self.bounds.size.width - labelWidth - labelGap),
                      DashboardInputHeight);
}
- (NSRect)textFrame {
    return [self fieldFrame];
}
- (void)layout {
    [super layout];
    CGFloat labelWidth = FormLabelWidthForLanguage(self.language);
    self.titleLabel.frame = NSMakeRect(0, 6, labelWidth, 18);
    self.titleLabel.alignment = self.language == DashboardLanguageEnglish ? NSTextAlignmentLeft : NSTextAlignmentRight;
    ApplyLanguageAwareLabel(self.titleLabel, self.language, 13.5, 13.5, 11.5, self.titleLabel.bounds.size.width, NSFontWeightSemibold);
    self.textField.frame = [self textFrame];
}
- (void)setTitleText:(NSString *)title placeholder:(NSString *)placeholder {
    self.titleLabel.stringValue = title ?: @"";
    self.textField.placeholder = placeholder ?: @"";
    [self.textField setAccessibilityLabel:title ?: @""];
}
@end

@interface CompactDropdownButton : NSControl
@property (nonatomic, strong) NSMutableArray<NSString *> *items;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, readonly) NSInteger indexOfSelectedItem;
@property (nonatomic, readonly) NSInteger numberOfItems;
- (void)addItemsWithTitles:(NSArray<NSString *> *)titles;
- (void)removeAllItems;
- (void)selectItemAtIndex:(NSInteger)index;
@end

@implementation CompactDropdownButton
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _items = [NSMutableArray array];
        _selectedIndex = -1;
        self.toolTip = @"Latency";
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityPopUpButtonRole; }
- (NSString *)accessibilityLabel { return self.toolTip ?: @"Latency"; }
- (NSString *)accessibilityValue { return self.selectedTitle ?: @""; }
- (NSRect)accessibilityFrame {
    return [self.window convertRectToScreen:[self convertRect:self.bounds toView:nil]];
}
- (BOOL)accessibilityPerformPress {
    [self showMenu];
    return YES;
}
- (NSInteger)indexOfSelectedItem { return self.selectedIndex; }
- (NSInteger)numberOfItems { return (NSInteger)self.items.count; }
- (void)addItemsWithTitles:(NSArray<NSString *> *)titles {
    [self.items addObjectsFromArray:titles ?: @[]];
    if (self.selectedIndex < 0 && self.items.count > 0) {
        self.selectedIndex = 0;
    }
    self.needsDisplay = YES;
}
- (void)removeAllItems {
    [self.items removeAllObjects];
    self.selectedIndex = -1;
    self.needsDisplay = YES;
}
- (void)selectItemAtIndex:(NSInteger)index {
    if (self.items.count == 0) {
        self.selectedIndex = -1;
    } else {
        self.selectedIndex = MAX(0, MIN(index, (NSInteger)self.items.count - 1));
    }
    self.needsDisplay = YES;
    NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification);
}
- (NSString *)selectedTitle {
    if (self.selectedIndex < 0 || self.selectedIndex >= (NSInteger)self.items.count) {
        return @"";
    }
    return self.items[(NSUInteger)self.selectedIndex];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect rect = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect
                                                         xRadius:DashboardButtonCornerRadius
                                                         yRadius:DashboardButtonCornerRadius];
    [GlassFieldFill(0.18) setFill];
    [path fill];
    [HexColorAlpha(0xFFFFFF, 0.16) setStroke];
    path.lineWidth = 1;
    [path stroke];

    NSString *title = self.selectedTitle ?: @"";
    CGFloat titleLeftPadding = 8;
    CGFloat chevronSpace = 18;
    CGFloat titleWidth = MAX(1, self.bounds.size.width - titleLeftPadding - chevronSpace);
    NSFont *titleFont = FittedSystemFont(title, titleWidth, 13, 10.5, NSFontWeightSemibold);
    NSDictionary *attrs = @{
        NSFontAttributeName: titleFont,
        NSForegroundColorAttributeName: PrimaryTextColor()
    };
    CGFloat textHeight = ceil(titleFont.ascender - titleFont.descender);
    NSRect titleRect = NSMakeRect(titleLeftPadding,
                                  floor((self.bounds.size.height - textHeight) * 0.5) - 1,
                                  titleWidth,
                                  textHeight + 2);
    [title drawInRect:titleRect withAttributes:attrs];

    [SecondaryTextColor() setStroke];
    NSBezierPath *chevron = [NSBezierPath bezierPath];
    CGFloat x = self.bounds.size.width - 15;
    CGFloat y = floor(self.bounds.size.height * 0.5) - 2;
    [chevron moveToPoint:NSMakePoint(x, y)];
    [chevron lineToPoint:NSMakePoint(x + 4, y + 4)];
    [chevron lineToPoint:NSMakePoint(x + 8, y)];
    chevron.lineWidth = 1.4;
    [chevron stroke];
}
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    [self showMenu];
}
- (void)keyDown:(NSEvent *)event {
    NSString *characters = event.charactersIgnoringModifiers ?: @"";
    if (!characters.length) {
        [super keyDown:event];
        return;
    }
    unichar key = [characters characterAtIndex:0];
    if (key == NSCarriageReturnCharacter || key == NSEnterCharacter || key == ' ') {
        [self showMenu];
        return;
    }
    if (key == NSUpArrowFunctionKey && self.selectedIndex > 0) {
        [self selectItemAtIndex:self.selectedIndex - 1];
        [self sendAction:self.action to:self.target];
        return;
    }
    if (key == NSDownArrowFunctionKey && self.selectedIndex + 1 < (NSInteger)self.items.count) {
        [self selectItemAtIndex:self.selectedIndex + 1];
        [self sendAction:self.action to:self.target];
        return;
    }
    [super keyDown:event];
}
- (void)showMenu {
    if (self.items.count == 0) {
        return;
    }
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    for (NSUInteger index = 0; index < self.items.count; index++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:self.items[index]
                                                      action:@selector(menuItemSelected:)
                                               keyEquivalent:@""];
        item.target = self;
        item.representedObject = @(index);
        item.state = (NSInteger)index == self.selectedIndex ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, self.bounds.size.height + 2) inView:self];
}
- (void)menuItemSelected:(NSMenuItem *)item {
    [self selectItemAtIndex:[item.representedObject integerValue]];
    [self sendAction:self.action to:self.target];
}
@end

typedef NS_ENUM(NSInteger, CompactButtonStyle) {
    CompactButtonStyleDefault,
    CompactButtonStylePrimary,
    CompactButtonStyleDanger,
    CompactButtonStyleSystemAccent,
    CompactButtonStyleMuteRed
};

typedef NS_ENUM(NSInteger, CompactButtonGlyph) {
    CompactButtonGlyphNone,
    CompactButtonGlyphPlay,
    CompactButtonGlyphStop
};

@interface CompactButton : NSButton
@property (nonatomic, assign) CompactButtonStyle compactStyle;
@property (nonatomic, assign) CompactButtonGlyph glyph;
@property (nonatomic, assign) DashboardLanguage language;
@end

@implementation CompactButton
- (BOOL)isFlipped { return YES; }
- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _compactStyle = CompactButtonStyleDefault;
        _glyph = CompactButtonGlyphNone;
        _language = DashboardLanguageChinese;
        self.bordered = NO;
        self.imagePosition = NSNoImage;
        self.font = SystemFont(13, NSFontWeightSemibold);
        [self setButtonType:NSButtonTypeMomentaryPushIn];
    }
    return self;
}
- (void)setTitle:(NSString *)title {
    [super setTitle:title ?: @""];
    self.needsDisplay = YES;
}
- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.needsDisplay = YES;
}
- (void)setState:(NSControlStateValue)state {
    [super setState:state];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    BOOL highlighted = [self.cell isHighlighted];
    BOOL active = self.state == NSControlStateValueOn;
    NSColor *fill = nil;
    NSColor *border = nil;
    NSColor *foreground = self.enabled ? PrimaryTextColor() : MutedTextColor();

    if (self.compactStyle == CompactButtonStylePrimary) {
        fill = self.enabled ? AccentColorAlpha(highlighted ? 0.58 : 0.48) : GlassFieldFill(0.10);
        border = self.enabled ? AccentColorAlpha(0.40) : HexColorAlpha(0xFFFFFF, 0.10);
    } else if (self.compactStyle == CompactButtonStyleDanger) {
        fill = self.enabled ? HexColorAlpha(0xF04438, highlighted ? 0.34 : 0.24) : GlassFieldFill(0.10);
        border = self.enabled ? HexColorAlpha(0xF04438, 0.34) : HexColorAlpha(0xFFFFFF, 0.10);
    } else if (self.compactStyle == CompactButtonStyleSystemAccent) {
        fill = self.enabled ? SystemHighlightColorAlpha(highlighted ? 0.62 : 0.52) : GlassFieldFill(0.10);
        border = self.enabled ? SystemHighlightColorAlpha(0.68) : HexColorAlpha(0xFFFFFF, 0.10);
    } else if (self.compactStyle == CompactButtonStyleMuteRed) {
        fill = self.enabled ? HexColorAlpha(0xF04438, highlighted ? 0.54 : 0.42) : GlassFieldFill(0.10);
        border = self.enabled ? HexColorAlpha(0xF04438, 0.60) : HexColorAlpha(0xFFFFFF, 0.10);
    } else {
        CGFloat fillAlpha = active ? 0.24 : 0.18;
        fill = GlassFieldFill(self.enabled ? (highlighted ? fillAlpha + 0.06 : fillAlpha) : 0.10);
        border = HexColorAlpha(0xFFFFFF, self.enabled ? (active ? 0.22 : 0.16) : 0.10);
    }

    NSRect rect = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect
                                                         xRadius:DashboardButtonCornerRadius
                                                         yRadius:DashboardButtonCornerRadius];
    [fill setFill];
    [path fill];
    [border setStroke];
    path.lineWidth = 1;
    [path stroke];

    NSString *title = self.title ?: @"";
    CGFloat iconWidth = self.glyph == CompactButtonGlyphNone ? 0 : 12;
    CGFloat spacing = iconWidth > 0 && title.length ? 6 : 0;
    CGFloat titleMaxWidth = MAX(1, self.bounds.size.width - iconWidth - spacing - 12);
    CGFloat baseSize = (self.font ?: SystemFont(13, NSFontWeightSemibold)).pointSize;
    NSFont *font = self.language == DashboardLanguageEnglish
        ? FittedSystemFont(title, titleMaxWidth, baseSize, 11.5, NSFontWeightSemibold)
        : SystemFont(baseSize, NSFontWeightSemibold);
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: foreground
    };
    NSSize titleSize = [title sizeWithAttributes:attrs];
    CGFloat totalWidth = iconWidth + spacing + titleSize.width;
    CGFloat x = floor((self.bounds.size.width - totalWidth) * 0.5);
    CGFloat centerY = self.bounds.size.height * 0.5;

    if (self.glyph == CompactButtonGlyphPlay) {
        NSBezierPath *triangle = [NSBezierPath bezierPath];
        [triangle moveToPoint:NSMakePoint(x + 1, centerY - 6)];
        [triangle lineToPoint:NSMakePoint(x + 1, centerY + 6)];
        [triangle lineToPoint:NSMakePoint(x + 11, centerY)];
        [triangle closePath];
        [foreground setFill];
        [triangle fill];
        x += iconWidth + spacing;
    } else if (self.glyph == CompactButtonGlyphStop) {
        NSBezierPath *square = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x + 1, centerY - 5, 10, 10)
                                                               xRadius:2
                                                               yRadius:2];
        [foreground setFill];
        [square fill];
        x += iconWidth + spacing;
    }

    NSRect textRect = NSMakeRect(x, floor((self.bounds.size.height - 18) * 0.5), MAX(1, titleSize.width + 2), 18);
    [title drawInRect:textRect withAttributes:attrs];
}
@end

@interface SparkleRepairButton : NSButton
@end

@implementation SparkleRepairButton
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)performClick:(id)sender {
    if (!self.enabled) {
        return;
    }
    [self sendAction:self.action to:self.target];
}
- (BOOL)accessibilityPerformPress {
    if (!self.enabled) {
        return NO;
    }
    [self performClick:self];
    return YES;
}
- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) {
        return;
    }

    self.highlighted = YES;
    self.needsDisplay = YES;
    BOOL shouldFire = NO;
    while (YES) {
        NSEvent *nextEvent = [self.window nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)];
        if (!nextEvent || nextEvent.type == NSEventTypeLeftMouseUp) {
            NSPoint point = [self convertPoint:(nextEvent ? nextEvent.locationInWindow : event.locationInWindow) fromView:nil];
            shouldFire = NSPointInRect(point, self.bounds);
            break;
        }
    }
    self.highlighted = NO;
    self.needsDisplay = YES;
    if (shouldFire) {
        [self sendAction:self.action to:self.target];
    }
}
- (void)drawRect:(NSRect)dirtyRect {
    BOOL highlighted = self.highlighted || [self.cell isHighlighted];
    CGFloat fillAlpha = self.enabled ? (highlighted ? 0.24 : 0.14) : 0.10;
    CGFloat borderAlpha = self.enabled ? (highlighted ? 0.24 : 0.16) : 0.10;
    NSRect rect = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect
                                                         xRadius:DashboardButtonCornerRadius
                                                         yRadius:DashboardButtonCornerRadius];
    [GlassFieldFill(fillAlpha) setFill];
    [path fill];
    [HexColorAlpha(0xFFFFFF, borderAlpha) setStroke];
    path.lineWidth = 1;
    [path stroke];

    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    NSFont *font = [NSFont fontWithName:@"Apple Color Emoji" size:12] ?: SystemFont(12, NSFontWeightSemibold);
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [PrimaryTextColor() colorWithAlphaComponent:self.enabled ? 0.95 : 0.58],
        NSParagraphStyleAttributeName: paragraph
    };
    [NSGraphicsContext saveGraphicsState];
    CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, self.enabled ? 0.92 : 0.56);
    [@"✨" drawInRect:NSMakeRect(0, 6, self.bounds.size.width, 16) withAttributes:attrs];
    [NSGraphicsContext restoreGraphicsState];
}
@end

@interface ErrorBannerView : NSView
@property (nonatomic, strong) NSTextField *label;
- (void)setMessage:(NSString *)message;
@end

@implementation ErrorBannerView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _label = Label(@"", 12, NSFontWeightRegular, PrimaryTextColor());
        _label.lineBreakMode = NSLineBreakByWordWrapping;
        [self addSubview:_label];
        self.hidden = YES;
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout];
    self.label.frame = NSInsetRect(self.bounds, 8, 3);
}
- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:8 yRadius:8];
    [HexColorAlpha(0xF4C45D, 0.12) setFill];
    [path fill];
    [HexColorAlpha(0xF4C45D, 0.38) setStroke];
    path.lineWidth = 1;
    [path stroke];
}
- (void)setMessage:(NSString *)message {
    self.label.stringValue = message ?: @"";
    self.hidden = message.length == 0;
}
@end

@interface DashboardView : NSView
@property (nonatomic, strong) GlassBackgroundView *glassBackground;
@property (nonatomic, strong) PanelView *header;
@property (nonatomic, strong) PanelView *inputCard;
@property (nonatomic, strong) PanelView *streamCard;
@property (nonatomic, strong) PanelView *audioCard;
@property (nonatomic, strong) PanelView *networkCard;
@property (nonatomic, strong) NSImageView *headerIcon;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *stateLabel;
@property (nonatomic, strong) StatusPillView *statusPill;
@property (nonatomic, strong) NSButton *languageButton;
@property (nonatomic, strong) NSTextField *inputTitleLabel;
@property (nonatomic, strong) LabeledTextFieldView *portField;
@property (nonatomic, strong) LabeledTextFieldView *streamField;
@property (nonatomic, strong) LabeledTextFieldView *sourceField;
@property (nonatomic, strong) NSButton *startButton;
@property (nonatomic, strong) NSButton *stopButton;
@property (nonatomic, strong) NSTextField *streamTitleLabel;
@property (nonatomic, strong) MetricPairView *streamMetric;
@property (nonatomic, strong) MetricPairView *senderMetric;
@property (nonatomic, strong) MetricPairView *formatMetric;
@property (nonatomic, strong) ErrorBannerView *errorBanner;
@property (nonatomic, strong) NSTextField *audioTitleLabel;
@property (nonatomic, strong) NSTextField *levelTitle;
@property (nonatomic, strong) NSTextField *levelValue;
@property (nonatomic, strong) NSTextField *meterLabel;
@property (nonatomic, strong) NSTextField *volumeValue;
@property (nonatomic, strong) NSButton *muteButton;
@property (nonatomic, strong) NSImageView *waveIcon;
@property (nonatomic, strong) LevelMeterView *levelMeter;
@property (nonatomic, strong) NSTextField *optionsTitle;
@property (nonatomic, strong) NSTextField *latencyLabel;
@property (nonatomic, strong) CompactDropdownButton *latencyPopup;
@property (nonatomic, strong) NSButton *autoRepairButton;
@property (nonatomic, strong) NSButton *manualRepairButton;
@property (nonatomic, strong) NSTextField *outputResetLabel;
@property (nonatomic, strong) NSTextField *networkTitleLabel;
@property (nonatomic, strong) CounterTileView *packetTile;
@property (nonatomic, strong) CounterTileView *missingTile;
@property (nonatomic, strong) CounterTileView *filteredTile;
@property (nonatomic, strong) CounterTileView *badTile;
@property (nonatomic, strong) CounterTileView *queueTile;
@property (nonatomic, strong) CounterTileView *stateTile;
@property (nonatomic, strong) NSTextField *networkQueueLabel;
@property (nonatomic, strong) NSTextField *networkQualityLabel;
@property (nonatomic, assign, getter=isMuted) BOOL muted;
@property (nonatomic, assign, getter=isRunning) BOOL running;
@property (nonatomic, assign) DashboardLanguage language;
- (VBANPlaybackProfile)playbackProfileValue;
- (double)volumeValueNumber;
- (void)setVolume:(double)volume;
- (void)setMuted:(BOOL)muted;
- (BOOL)autoRepairEnabled;
- (void)setAutoRepairEnabled:(BOOL)enabled;
- (void)configureKeyViewLoop;
- (void)toggleLanguage;
- (void)applyLanguage;
- (NSString *)localizedNoSignalText;
@end

@implementation DashboardView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _language = DashboardLanguageChinese;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.clearColor.CGColor;

        _glassBackground = [[GlassBackgroundView alloc] initWithFrame:NSZeroRect];
        _header = [[PanelView alloc] initWithFrame:NSZeroRect];
        _header.fillColor = NSColor.clearColor;
        _header.borderColor = nil;
        _header.cornerRadius = 0;
        _inputCard = [[PanelView alloc] initWithFrame:NSZeroRect];
        _streamCard = [[PanelView alloc] initWithFrame:NSZeroRect];
        _audioCard = [[PanelView alloc] initWithFrame:NSZeroRect];
        _networkCard = [[PanelView alloc] initWithFrame:NSZeroRect];

        [self addSubview:_glassBackground];
        [self addSubview:_header];
        [self addSubview:_inputCard];
        [self addSubview:_streamCard];
        [self addSubview:_audioCard];
        [self addSubview:_networkCard];

        _headerIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _headerIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
        _headerIcon.hidden = NO;
        if (@available(macOS 11.0, *)) {
            _headerIcon.image = [NSImage imageWithSystemSymbolName:@"dot.radiowaves.left.and.right" accessibilityDescription:@"VBAN"];
            _headerIcon.contentTintColor = AccentColorAlpha(0.82);
        }
        _titleLabel = Label(@"VBAN Receiver", 18, NSFontWeightSemibold, PrimaryTextColor());
        _stateLabel = Label(@"Stopped", 12, NSFontWeightMedium, SecondaryTextColor());
        _stateLabel.hidden = YES;
        _statusPill = [[StatusPillView alloc] initWithFrame:NSZeroRect];
        _languageButton = [[CompactButton alloc] initWithFrame:NSZeroRect];
        _languageButton.title = @"EN";
        _languageButton.bordered = NO;
        _languageButton.font = SystemFont(13, NSFontWeightSemibold);
        _languageButton.toolTip = @"Switch to English";
        [_header addSubview:_headerIcon];
        [_header addSubview:_titleLabel];
        [_header addSubview:_stateLabel];
        [_header addSubview:_languageButton];
        [_header addSubview:_statusPill];

        _inputTitleLabel = Label(@"Input", 16, NSFontWeightSemibold, PrimaryTextColor());
        _portField = [[LabeledTextFieldView alloc] initWithTitle:@"UDP port" placeholder:@"6980" value:@"6980"];
        _streamField = [[LabeledTextFieldView alloc] initWithTitle:@"Stream" placeholder:@"Any" value:@""];
        _sourceField = [[LabeledTextFieldView alloc] initWithTitle:@"Source host" placeholder:@"Any" value:@""];
        _startButton = [[CompactButton alloc] initWithFrame:NSZeroRect];
        _startButton.title = @"Start";
        _startButton.font = SystemFont(14, NSFontWeightSemibold);
        ((CompactButton *)_startButton).compactStyle = CompactButtonStylePrimary;
        ((CompactButton *)_startButton).glyph = CompactButtonGlyphPlay;
        _stopButton = [[CompactButton alloc] initWithFrame:NSZeroRect];
        _stopButton.hidden = YES;
        _stopButton.enabled = NO;

        _streamTitleLabel = Label(@"Current Stream", 16, NSFontWeightSemibold, PrimaryTextColor());
        _streamMetric = [[MetricPairView alloc] initWithTitle:@"Stream"];
        _senderMetric = [[MetricPairView alloc] initWithTitle:@"Sender"];
        _formatMetric = [[MetricPairView alloc] initWithTitle:@"Format"];
        _formatMetric.preservesFullValue = YES;
        [_formatMetric setValueText:@"No signal"];
        _errorBanner = [[ErrorBannerView alloc] initWithFrame:NSZeroRect];

        NSArray *inputViews = @[_inputTitleLabel, _portField, _streamField, _sourceField, _startButton];
        for (NSView *view in inputViews) {
            [_inputCard addSubview:view];
        }
        NSArray *streamViews = @[_streamTitleLabel, _streamMetric, _senderMetric, _formatMetric];
        for (NSView *view in streamViews) {
            [_streamCard addSubview:view];
        }

        _audioTitleLabel = Label(@"Audio Output", 16, NSFontWeightSemibold, PrimaryTextColor());
        _levelTitle = Label(@"Volume", 16, NSFontWeightSemibold, SecondaryTextColor());
        _levelValue = Label(@"100%", 24, NSFontWeightBold, PrimaryTextColor());
        _levelValue.font = SystemFont(24, NSFontWeightBold);
        _levelValue.lineBreakMode = NSLineBreakByClipping;
        _meterLabel = Label(@"Level", 16, NSFontWeightSemibold, SecondaryTextColor());
        _muteButton = [[CompactButton alloc] initWithFrame:NSZeroRect];
        _muteButton.bezelStyle = NSBezelStyleRegularSquare;
        _muteButton.bordered = NO;
        _muteButton.imagePosition = NSNoImage;
        _muteButton.font = SystemFont(13, NSFontWeightSemibold);
        [_muteButton setButtonType:NSButtonTypePushOnPushOff];
        _muteButton.toolTip = @"Mute";
        [_muteButton setAccessibilityLabel:@"Mute"];
        _waveIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
        _waveIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
        if (@available(macOS 11.0, *)) {
            _waveIcon.image = [NSImage imageWithSystemSymbolName:@"waveform.path" accessibilityDescription:@"Level"];
            _waveIcon.contentTintColor = HexColorAlpha(0xD6E2E8, 0.58);
        }
        _levelMeter = [[LevelMeterView alloc] initWithFrame:NSZeroRect];
        _optionsTitle = Label(@"OPTIONS", 11, NSFontWeightBold, MutedTextColor());
        _optionsTitle.hidden = YES;
        _latencyLabel = Label(@"Latency", 16, NSFontWeightSemibold, SecondaryTextColor());
        _latencyPopup = [[CompactDropdownButton alloc] initWithFrame:NSZeroRect];
        [_latencyPopup addItemsWithTitles:@[@"Optimal", @"Fast", @"Medium", @"Slow", @"Very Slow"]];
        [_latencyPopup selectItemAtIndex:VBANPlaybackProfileOptimal];
        _autoRepairButton = [[CompactButton alloc] initWithFrame:NSZeroRect];
        _autoRepairButton.title = @"Auto";
        _autoRepairButton.bezelStyle = NSBezelStyleRegularSquare;
        _autoRepairButton.bordered = NO;
        _autoRepairButton.imagePosition = NSNoImage;
        _autoRepairButton.font = SystemFont(13, NSFontWeightSemibold);
        [_autoRepairButton setButtonType:NSButtonTypePushOnPushOff];
        if (@available(macOS 11.0, *)) {
            _autoRepairButton.image = nil;
        }
        _manualRepairButton = [[SparkleRepairButton alloc] initWithFrame:NSZeroRect];
        _manualRepairButton.title = @"✨";
        _manualRepairButton.bezelStyle = NSBezelStyleRegularSquare;
        _manualRepairButton.bordered = NO;
        _manualRepairButton.imagePosition = NSNoImage;
        _manualRepairButton.font = [NSFont fontWithName:@"Apple Color Emoji" size:13.5] ?: SystemFont(13.5, NSFontWeightSemibold);
        [_manualRepairButton setButtonType:NSButtonTypeMomentaryPushIn];
        if (@available(macOS 11.0, *)) {
            _manualRepairButton.image = nil;
        }
        _outputResetLabel = Label(@"Reset: 0", 13, NSFontWeightSemibold, SecondaryTextColor());
        _outputResetLabel.alignment = NSTextAlignmentRight;

        _networkTitleLabel = Label(@"Network", 16, NSFontWeightSemibold, PrimaryTextColor());
        _packetTile = [[CounterTileView alloc] initWithTitle:@"Packets"];
        _missingTile = [[CounterTileView alloc] initWithTitle:@"Missing"];
        _filteredTile = [[CounterTileView alloc] initWithTitle:@"Filtered"];
        _badTile = [[CounterTileView alloc] initWithTitle:@"Errors"];
        _queueTile = [[CounterTileView alloc] initWithTitle:@"Queue resets"];
        _queueTile.hidden = YES;
        _networkQueueLabel = Label(@"Queue: 0", 13, NSFontWeightSemibold, SecondaryTextColor());
        _networkQualityLabel = Label(@"Normal", 13, NSFontWeightSemibold, SecondaryTextColor());
        _networkQualityLabel.alignment = NSTextAlignmentRight;

        [self updateMuteButton];

        NSArray *audioViews = @[
            _audioTitleLabel, _autoRepairButton, _manualRepairButton, _muteButton,
            _levelTitle, _levelValue, _meterLabel, _waveIcon, _levelMeter,
            _latencyLabel, _latencyPopup, _outputResetLabel
        ];
        for (NSView *view in audioViews) {
            [_audioCard addSubview:view];
        }
        NSArray *networkViews = @[
            _networkTitleLabel, _packetTile, _missingTile, _filteredTile, _badTile,
            _networkQueueLabel, _networkQualityLabel, _errorBanner
        ];
        for (NSView *view in networkViews) {
            [_networkCard addSubview:view];
        }
        [self applyLanguage];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:HexColor(0x303A40)
                                                         endingColor:HexColor(0x283038)];
    [gradient drawInRect:self.bounds angle:270.0];
    [HexColorAlpha(0xFFFFFF, 0.10) setStroke];
    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(0, DashboardHeaderHeight)];
    [path lineToPoint:NSMakePoint(self.bounds.size.width, DashboardHeaderHeight)];
    path.lineWidth = 1;
    [path stroke];
}

- (void)layout {
    [super layout];
    CGFloat width = self.bounds.size.width;

    self.glassBackground.frame = self.bounds;
    self.header.frame = NSMakeRect(0, 0, width, DashboardHeaderHeight);

    CGFloat leftX = DashboardMarginX;
    CGFloat rightX = leftX + DashboardLeftColumnWidth + DashboardColumnGap;
    self.inputCard.frame = NSMakeRect(leftX, DashboardTopCardY, DashboardLeftColumnWidth, DashboardTopCardHeight);
    self.streamCard.frame = NSMakeRect(leftX, DashboardBottomCardY, DashboardLeftColumnWidth, DashboardBottomCardHeight);
    self.audioCard.frame = NSMakeRect(rightX, DashboardTopCardY, DashboardRightColumnWidth, DashboardTopCardHeight);
    self.networkCard.frame = NSMakeRect(rightX, DashboardBottomCardY, DashboardRightColumnWidth, DashboardBottomCardHeight);

    self.headerIcon.frame = NSMakeRect(86, 17, 22, 22);
    self.titleLabel.frame = NSMakeRect(116, 17, 190, 24);
    self.stateLabel.frame = NSZeroRect;
    self.languageButton.frame = NSMakeRect(436, 12, 42, 32);
    self.statusPill.frame = NSMakeRect(486, 12, 98, 32);

    CGFloat inset = DashboardCardPadding;
    CGFloat inputWidth = self.inputCard.bounds.size.width - inset * 2;
    self.inputTitleLabel.frame = NSMakeRect(inset, 12, inputWidth, 22);
    self.portField.frame = NSMakeRect(inset, 46, inputWidth, DashboardInputHeight);
    self.streamField.frame = NSMakeRect(inset, 84, inputWidth, DashboardInputHeight);
    self.sourceField.frame = NSMakeRect(inset, 122, inputWidth, DashboardInputHeight);
    self.startButton.frame = NSMakeRect(inset, 164, inputWidth, DashboardPrimaryButtonHeight);
    self.stopButton.frame = NSZeroRect;

    CGFloat streamWidth = self.streamCard.bounds.size.width - inset * 2;
    self.streamTitleLabel.frame = NSMakeRect(inset, 12, streamWidth, 20);
    self.streamMetric.frame = NSMakeRect(inset, 40, streamWidth, 18);
    self.senderMetric.frame = NSMakeRect(inset, 63, streamWidth, 18);
    self.formatMetric.frame = NSMakeRect(inset, 86, streamWidth, 18);

    CGFloat audioWidth = self.audioCard.bounds.size.width;
    CGFloat audioInnerWidth = audioWidth - inset * 2;
    self.audioTitleLabel.frame = NSMakeRect(inset, 17, 100, 20);
    ApplyLanguageAwareLabel(self.audioTitleLabel, self.language, 16, 16, 12, self.audioTitleLabel.bounds.size.width, NSFontWeightSemibold);
    CGFloat controlHeight = DashboardSmallButtonHeight;
    CGFloat buttonGroupWidth = 72 + 6 + 34 + 6 + 52;
    CGFloat buttonX = inset + audioInnerWidth - buttonGroupWidth;
    self.autoRepairButton.frame = NSMakeRect(buttonX, 12, 72, controlHeight);
    self.manualRepairButton.frame = NSMakeRect(buttonX + 72 + 6, 12, 34, controlHeight);
    self.muteButton.frame = NSMakeRect(buttonX + 72 + 6 + 34 + 6, 12, 52, controlHeight);

    CGFloat audioLabelWidth = 62;
    CGFloat audioControlX = inset + audioLabelWidth + 8;
    CGFloat meterX = 160;
    CGFloat meterWidth = audioInnerWidth - (meterX - inset);
    self.levelTitle.frame = NSMakeRect(inset, 63, audioLabelWidth, 22);
    ApplyLanguageAwareLabel(self.levelTitle, self.language, 16, 16, 12.5, self.levelTitle.bounds.size.width, NSFontWeightSemibold);
    self.levelValue.frame = NSMakeRect(audioControlX, 58, 68, 30);
    self.levelValue.font = FittedSystemFont(self.levelValue.stringValue, self.levelValue.bounds.size.width, 24, 20, NSFontWeightBold);
    self.levelMeter.frame = NSMakeRect(meterX, 45, meterWidth, 106);
    self.meterLabel.frame = NSMakeRect(inset, 120, audioLabelWidth, 22);
    ApplyLanguageAwareLabel(self.meterLabel, self.language, 16, 16, 12.5, self.meterLabel.bounds.size.width, NSFontWeightSemibold);
    self.waveIcon.frame = NSMakeRect(audioControlX, 119, 24, 24);
    self.latencyLabel.frame = NSMakeRect(inset, 166, audioLabelWidth, 22);
    ApplyLanguageAwareLabel(self.latencyLabel, self.language, 16, 16, 11.5, self.latencyLabel.bounds.size.width, NSFontWeightSemibold);
    CGFloat latencyPopupWidth = self.language == DashboardLanguageEnglish ? 96 : 76;
    self.latencyPopup.frame = NSMakeRect(audioControlX, 164, latencyPopupWidth, DashboardDropdownHeight);
    self.outputResetLabel.frame = NSMakeRect(audioWidth - inset - 58, 170, 58, 18);
    ApplyLanguageAwareLabel(self.outputResetLabel, self.language, 13, 13, 10, self.outputResetLabel.bounds.size.width, NSFontWeightSemibold);

    CGFloat networkWidth = self.networkCard.bounds.size.width;
    CGFloat networkContentWidth = networkWidth - inset * 2;
    self.networkTitleLabel.frame = NSMakeRect(inset, 10, networkContentWidth, 20);
    CGFloat statGap = 8;
    CGFloat tileWidth = floor((networkContentWidth - statGap * 3) / 4.0);
    CGFloat tileY = 38;
    NSArray *topTiles = @[self.packetTile, self.missingTile, self.filteredTile, self.badTile];
    for (NSInteger index = 0; index < topTiles.count; index++) {
        NSView *tile = topTiles[index];
        tile.frame = NSMakeRect(inset + index * (tileWidth + statGap), tileY, tileWidth, 44);
    }
    self.networkQueueLabel.frame = NSMakeRect(inset, 92, 120, 18);
    CGFloat qualityWidth = self.language == DashboardLanguageEnglish ? 64 : 46;
    self.networkQualityLabel.frame = NSMakeRect(networkWidth - inset - qualityWidth, 92, qualityWidth, 18);
    ApplyLanguageAwareLabel(self.networkQualityLabel, self.language, 13, 13, 7.5, self.networkQualityLabel.bounds.size.width, NSFontWeightSemibold);
    self.errorBanner.frame = NSMakeRect(inset, 80, networkContentWidth, 24);
    self.queueTile.frame = NSZeroRect;
}

- (NSString *)portValue { return Trimmed(self.portField.textField.stringValue); }
- (NSString *)streamValue { return Trimmed(self.streamField.textField.stringValue); }
- (NSString *)sourceValue { return Trimmed(self.sourceField.textField.stringValue); }
- (VBANPlaybackProfile)playbackProfileValue { return (VBANPlaybackProfile)self.latencyPopup.indexOfSelectedItem; }
- (double)volumeValueNumber { return self.levelMeter.volume; }

- (void)toggleLanguage {
    self.language = self.language == DashboardLanguageChinese ? DashboardLanguageEnglish : DashboardLanguageChinese;
    [self applyLanguage];
}

- (void)applyLanguage {
    self.titleLabel.stringValue = Localized(self.language, @"VBAN 接收器", @"VBAN Receiver");
    self.languageButton.title = self.language == DashboardLanguageChinese ? @"EN" : @"中";
    self.languageButton.toolTip = Localized(self.language, @"切换到 English", @"Switch to Chinese");
    [self.languageButton setAccessibilityLabel:self.languageButton.toolTip];

    for (LabeledTextFieldView *field in @[self.portField, self.streamField, self.sourceField]) {
        field.language = self.language;
        field.needsLayout = YES;
    }
    for (MetricPairView *metric in @[self.streamMetric, self.senderMetric, self.formatMetric]) {
        metric.language = self.language;
        metric.needsLayout = YES;
    }
    for (CounterTileView *tile in @[self.packetTile, self.missingTile, self.filteredTile, self.badTile]) {
        tile.language = self.language;
        tile.needsLayout = YES;
    }
    self.statusPill.language = self.language;
    for (NSButton *button in @[self.languageButton, self.startButton, self.autoRepairButton, self.muteButton]) {
        if ([button isKindOfClass:CompactButton.class]) {
            ((CompactButton *)button).language = self.language;
            button.needsDisplay = YES;
        }
    }

    self.inputTitleLabel.stringValue = Localized(self.language, @"输入源", @"Input");
    [self.portField setTitleText:@"UDP" placeholder:@"6980"];
    [self.streamField setTitleText:Localized(self.language, @"流", @"Stream") placeholder:Localized(self.language, @"任意", @"Any")];
    [self.sourceField setTitleText:Localized(self.language, @"来源", @"Source") placeholder:Localized(self.language, @"任意", @"Any")];

    [self setRunning:self.running];
    self.streamTitleLabel.stringValue = Localized(self.language, @"当前流", @"Current Stream");
    self.streamMetric.titleLabel.stringValue = Localized(self.language, @"流", @"Stream");
    self.senderMetric.titleLabel.stringValue = Localized(self.language, @"源", @"Source");
    self.formatMetric.titleLabel.stringValue = Localized(self.language, @"格式", @"Format");
    NSString *formatValue = self.formatMetric.valueLabel.stringValue ?: @"";
    if ([formatValue isEqualToString:@"No signal"] || [formatValue isEqualToString:@"无信号"]) {
        [self.formatMetric setValueText:[self localizedNoSignalText]];
    }

    self.audioTitleLabel.stringValue = Localized(self.language, @"音频输出", @"Audio Output");
    self.levelTitle.stringValue = Localized(self.language, @"音量", @"Volume");
    self.meterLabel.stringValue = Localized(self.language, @"电平", @"Level");
    self.levelMeter.language = self.language;
    [self updateVolumeReadout];
    [self updateMuteButton];
    [self updateAutoRepairButton];

    self.optionsTitle.stringValue = Localized(self.language, @"选项", @"OPTIONS");
    self.latencyLabel.stringValue = Localized(self.language, @"延迟", @"Latency");
    self.latencyPopup.toolTip = self.latencyLabel.stringValue;
    NSInteger selectedIndex = self.latencyPopup.indexOfSelectedItem;
    [self.latencyPopup removeAllItems];
    [self.latencyPopup addItemsWithTitles:@[
        Localized(self.language, @"最佳", @"Optimal"),
        Localized(self.language, @"快速", @"Fast"),
        Localized(self.language, @"中等", @"Medium"),
        Localized(self.language, @"慢速", @"Slow"),
        Localized(self.language, @"非常慢", @"Very Slow")
    ]];
    [self.latencyPopup selectItemAtIndex:MAX(0, MIN(selectedIndex, (NSInteger)self.latencyPopup.numberOfItems - 1))];
    [self updateManualRepairButton];

    self.networkTitleLabel.stringValue = Localized(self.language, @"网络状态", @"Network Status");
    self.packetTile.titleLabel.stringValue = Localized(self.language, @"数据", @"Data");
    self.missingTile.titleLabel.stringValue = Localized(self.language, @"丢包", @"Missing");
    self.filteredTile.titleLabel.stringValue = Localized(self.language, @"过滤", @"Filtered");
    self.badTile.titleLabel.stringValue = Localized(self.language, @"错误", @"Errors");
    self.queueTile.titleLabel.stringValue = Localized(self.language, @"队列重置", @"Queue resets");
    self.networkQueueLabel.stringValue = Localized(self.language, @"队列：0", @"Queue: 0");
    if ([self.networkQualityLabel.stringValue isEqualToString:@"Quality: Normal"] ||
        [self.networkQualityLabel.stringValue isEqualToString:@"连接质量：正常"] ||
        [self.networkQualityLabel.stringValue isEqualToString:@"质量：正常"]) {
        self.networkQualityLabel.stringValue = Localized(self.language, @"正常", @"Normal");
    }

    if ([self.statusPill.title isEqualToString:@"Stopped"] ||
        [self.statusPill.title isEqualToString:@"已停止"] ||
        [self.statusPill.title isEqualToString:@"未接收"]) {
        [self setStateText:nil kind:ReceiverStatusKindStopped];
    }
    self.needsLayout = YES;
}

- (NSString *)localizedNoSignalText {
    return Localized(self.language, @"无信号", @"No signal");
}

- (void)setVolume:(double)volume {
    self.levelMeter.volume = volume;
    [self updateVolumeReadout];
    [self updateMuteButton];
}

- (void)setMuted:(BOOL)muted {
    _muted = muted;
    self.levelMeter.muted = muted;
    self.muteButton.state = muted ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateVolumeReadout];
    [self updateMuteButton];
}

- (BOOL)autoRepairEnabled {
    return self.autoRepairButton.state == NSControlStateValueOn;
}

- (void)setAutoRepairEnabled:(BOOL)enabled {
    self.autoRepairButton.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateAutoRepairButton];
}

- (void)updateVolumeReadout {
    long percent = (long)llround(self.levelMeter.volume * 100);
    self.levelValue.stringValue = [NSString stringWithFormat:@"%ld%%", percent];
    if (self.levelValue.bounds.size.width > 0) {
        self.levelValue.font = FittedSystemFont(self.levelValue.stringValue, self.levelValue.bounds.size.width, 24, 20, NSFontWeightBold);
    }
    self.levelValue.textColor = self.muted ? MuteTextColor() : PrimaryTextColor();
}

- (void)updateMuteButton {
    BOOL muted = self.muted;
    self.muteButton.title = Localized(self.language, @"静音", @"Mute");
    self.muteButton.imagePosition = NSNoImage;
    self.muteButton.toolTip = muted
        ? Localized(self.language, @"已静音", @"Muted")
        : Localized(self.language, @"静音输出", @"Mute output");
    [self.muteButton setAccessibilityLabel:self.muteButton.toolTip];
    self.muteButton.image = nil;
    if ([self.muteButton isKindOfClass:CompactButton.class]) {
        ((CompactButton *)self.muteButton).compactStyle = muted ? CompactButtonStyleMuteRed : CompactButtonStyleDefault;
    }
    self.muteButton.needsDisplay = YES;
}

- (void)updateAutoRepairButton {
    BOOL enabled = self.autoRepairEnabled;
    self.autoRepairButton.title = Localized(self.language, @"自动修复", @"Auto");
    self.autoRepairButton.toolTip = enabled
        ? Localized(self.language, @"自动修复已开启：检测到输出异常时重连", @"Auto repair is on: reconnect when output looks stuck")
        : Localized(self.language, @"开启自动修复输出", @"Enable automatic output repair");
    [self.autoRepairButton setAccessibilityLabel:self.autoRepairButton.toolTip];
    self.autoRepairButton.image = nil;
    if ([self.autoRepairButton isKindOfClass:CompactButton.class]) {
        ((CompactButton *)self.autoRepairButton).compactStyle = enabled ? CompactButtonStyleSystemAccent : CompactButtonStyleDefault;
    }
    self.autoRepairButton.needsDisplay = YES;
}

- (void)updateManualRepairButton {
    self.manualRepairButton.state = NSControlStateValueOff;
    self.manualRepairButton.toolTip = Localized(self.language, @"手动修复输出", @"Manually repair output");
    [self.manualRepairButton setAccessibilityLabel:Localized(self.language, @"手动修复输出", @"Manually repair output")];
    [self.manualRepairButton setAccessibilityHelp:Localized(self.language, @"重置音频输出和缓冲队列", @"Reset audio output and buffer queue")];
    self.manualRepairButton.title = @"✨";
    self.manualRepairButton.image = nil;
    self.manualRepairButton.bezelColor = GlassFieldFill(0.08);
}

- (void)configureKeyViewLoop {
    self.portField.textField.nextKeyView = self.streamField.textField;
    self.streamField.textField.nextKeyView = self.sourceField.textField;
    self.sourceField.textField.nextKeyView = self.startButton;
    self.startButton.nextKeyView = self.latencyPopup;
    self.latencyPopup.nextKeyView = self.autoRepairButton;
    self.autoRepairButton.nextKeyView = self.manualRepairButton;
    self.manualRepairButton.nextKeyView = self.levelMeter;
    self.levelMeter.nextKeyView = self.muteButton;
    self.muteButton.nextKeyView = self.languageButton;
    self.languageButton.nextKeyView = self.portField.textField;
}

- (void)setRunning:(BOOL)running {
    _running = running;
    self.startButton.enabled = YES;
    self.stopButton.enabled = NO;
    self.stopButton.hidden = YES;
    self.startButton.title = running
        ? Localized(self.language, @"停止接收", @"Stop Receiving")
        : Localized(self.language, @"开始接收", @"Start Receiving");
    self.startButton.toolTip = self.startButton.title;
    [self.startButton setAccessibilityLabel:self.startButton.title];
    if ([self.startButton isKindOfClass:CompactButton.class]) {
        CompactButton *button = (CompactButton *)self.startButton;
        button.compactStyle = running ? CompactButtonStyleDanger : CompactButtonStylePrimary;
        button.glyph = running ? CompactButtonGlyphStop : CompactButtonGlyphPlay;
        button.needsDisplay = YES;
    }
    self.portField.textField.editable = !running;
    self.streamField.textField.editable = !running;
    self.sourceField.textField.editable = !running;
    self.manualRepairButton.enabled = running;
    self.manualRepairButton.alphaValue = 1.0;
    self.manualRepairButton.needsDisplay = YES;
}

- (void)setStateText:(NSString *)state kind:(ReceiverStatusKind)kind {
    self.statusPill.title = [self statusTitleForKind:kind];
    self.statusPill.dotColor = [self statusColorForKind:kind];
    if (@available(macOS 11.0, *)) {
        self.waveIcon.image = [NSImage imageWithSystemSymbolName:(kind == ReceiverStatusKindReceiving ? @"waveform" : @"waveform.path")
                                        accessibilityDescription:@"Level"];
        self.waveIcon.contentTintColor = kind == ReceiverStatusKindReceiving
            ? AccentColorAlpha(0.88)
            : HexColorAlpha(0xD6E2E8, 0.58);
    }
}

- (NSString *)statusTitleForKind:(ReceiverStatusKind)kind {
    switch (kind) {
        case ReceiverStatusKindStopped:
            return Localized(self.language, @"未接收", @"Stopped");
        case ReceiverStatusKindWaiting:
            return Localized(self.language, @"等待中", @"Waiting");
        case ReceiverStatusKindReceiving:
            return Localized(self.language, @"接收中", @"Receiving");
    }
}

- (NSString *)stateTextForKind:(ReceiverStatusKind)kind fallback:(NSString *)state {
    switch (kind) {
        case ReceiverStatusKindStopped:
            return Localized(self.language, @"未接收", @"Stopped");
        case ReceiverStatusKindWaiting:
            return Localized(self.language, @"监听中", @"Listening");
        case ReceiverStatusKindReceiving:
            return Localized(self.language, @"接收中", @"Receiving");
    }
}

- (NSColor *)statusColorForKind:(ReceiverStatusKind)kind {
    switch (kind) {
        case ReceiverStatusKindStopped:
            return HexColor(0x89968F);
        case ReceiverStatusKindWaiting:
            return HexColor(0xF4C45D);
        case ReceiverStatusKindReceiving:
            return HexColor(0x31D07E);
    }
}

- (void)setLevel:(double)level {
    self.levelMeter.level = level;
}

- (void)setStream:(NSString *)stream sender:(NSString *)sender format:(NSString *)format {
    [self.streamMetric setValueText:stream];
    [self.senderMetric setValueText:sender];
    [self.formatMetric setValueText:CompactFormatText(format)];
}

- (void)setCountersPackets:(NSUInteger)packets
                   missing:(NSUInteger)missing
                  filtered:(NSUInteger)filtered
                       bad:(NSUInteger)bad
                queueDrops:(NSUInteger)queueDrops {
    [self.packetTile setValueText:[self compactCount:packets]];
    [self.missingTile setValueText:[self compactCount:missing]];
    [self.filteredTile setValueText:[self compactCount:filtered]];
    [self.badTile setValueText:[self compactCount:bad]];
    self.outputResetLabel.stringValue = Localized(
        self.language,
        [NSString stringWithFormat:@"重置：%@", [self compactCount:queueDrops]],
        [NSString stringWithFormat:@"Reset: %@", [self compactCount:queueDrops]]
    );
    self.outputResetLabel.toolTip = Localized(self.language, @"输出重置次数", @"Output reset count");
    self.networkQueueLabel.stringValue = Localized(self.language, @"队列：0", @"Queue: 0");
    BOOL clean = missing == 0 && bad == 0;
    self.networkQualityLabel.stringValue = clean
        ? Localized(self.language, @"正常", @"Normal")
        : Localized(self.language, @"需留意", @"Check");
    self.missingTile.valueLabel.textColor = missing > 0 ? HexColor(0xF5B942) : PrimaryTextColor();
    self.badTile.valueLabel.textColor = bad > 0 ? HexColor(0xF04438) : PrimaryTextColor();
}

- (void)setErrorMessage:(NSString *)message {
    [self.errorBanner setMessage:message];
    BOOL hasMessage = message.length > 0;
    self.networkQueueLabel.hidden = hasMessage;
    self.networkQualityLabel.hidden = hasMessage;
}

- (NSString *)compactCount:(NSUInteger)value {
    if (value < 10000) {
        NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        return [formatter stringFromNumber:@(value)];
    }

    double count = (double)value;
    if (value < 1000000) {
        return value < 100000
            ? [NSString stringWithFormat:@"%.1fk", count / 1000.0]
            : [NSString stringWithFormat:@"%.0fk", count / 1000.0];
    }
    if (value < 1000000000) {
        return value < 10000000
            ? [NSString stringWithFormat:@"%.1fM", count / 1000000.0]
            : [NSString stringWithFormat:@"%.0fM", count / 1000000.0];
    }
    return value < 10000000000ULL
        ? [NSString stringWithFormat:@"%.1fB", count / 1000000000.0]
        : [NSString stringWithFormat:@"%.0fB", count / 1000000000.0];
}

@end

@interface AppDelegate ()

@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) DashboardView *dashboard;
@property (nonatomic, strong) VBANUDPReceiver *receiver;
@property (nonatomic, strong) VBANAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) id keyMonitor;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong, nullable) NSDate *lastPacketAt;
@property (nonatomic, assign) BOOL hasLastFrameCounter;
@property (nonatomic, assign) uint32_t lastFrameCounter;
@property (nonatomic, assign) NSUInteger packetCount;
@property (nonatomic, assign) NSUInteger badPacketCount;
@property (nonatomic, assign) NSUInteger filteredPacketCount;
@property (nonatomic, assign) NSUInteger missingPacketCount;
@property (nonatomic, assign) NSUInteger queueDropCount;
@property (nonatomic, assign) double level;
@property (nonatomic, assign) double targetLevel;
@property (nonatomic, assign, getter=isMuted) BOOL muted;
@property (nonatomic, copy) NSString *stateMessage;
@property (nonatomic, assign) DashboardLanguage currentLanguage;

- (void)installApplicationIcon;
- (void)installKeyboardMonitor;
- (BOOL)isToggleReceiveKeyEvent:(NSEvent *)event;
- (void)toggleReceiving:(id)sender;

@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.currentLanguage = DashboardLanguageEnglish;
    [self installMainMenu];
    [self installApplicationIcon];

    self.receiver = [[VBANUDPReceiver alloc] init];
    self.audioPlayer = [[VBANAudioPlayer alloc] init];
    self.stateMessage = @"Stopped";

    self.dashboard = [[DashboardView alloc] initWithFrame:NSMakeRect(0, 0, DashboardDefaultWidth, DashboardDefaultHeight)];
    self.dashboard.language = self.currentLanguage;
    [self.dashboard applyLanguage];
    self.dashboard.startButton.target = self;
    self.dashboard.startButton.action = @selector(toggleReceiving:);
    self.dashboard.stopButton.target = self;
    self.dashboard.stopButton.action = @selector(stopPressed:);
    self.dashboard.latencyPopup.target = self;
    self.dashboard.latencyPopup.action = @selector(latencyChanged:);
    self.dashboard.levelMeter.target = self;
    self.dashboard.levelMeter.action = @selector(volumeChanged:);
    self.dashboard.muteButton.target = self;
    self.dashboard.muteButton.action = @selector(mutePressed:);
    self.dashboard.autoRepairButton.target = self;
    self.dashboard.autoRepairButton.action = @selector(autoRepairPressed:);
    self.dashboard.languageButton.target = self;
    self.dashboard.languageButton.action = @selector(languagePressed:);
    self.dashboard.manualRepairButton.target = self;
    self.dashboard.manualRepairButton.action = @selector(manualRepairPressed:);
    [self.dashboard setVolume:1.0];
    [self.dashboard setMuted:NO];
    [self.dashboard setAutoRepairEnabled:NO];
    self.audioPlayer.playbackProfile = self.dashboard.playbackProfileValue;
    self.audioPlayer.outputVolume = [self effectiveOutputVolume];
    self.audioPlayer.autoRepairsOutput = self.dashboard.autoRepairEnabled;

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, DashboardDefaultWidth, DashboardDefaultHeight)
                                               styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView)
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    self.window.title = Localized(self.currentLanguage, @"VBAN 接收器", @"VBAN Receiver");
    NSSize fixedContentSize = NSMakeSize(DashboardDefaultWidth, DashboardDefaultHeight);
    self.window.contentMinSize = fixedContentSize;
    self.window.contentMaxSize = fixedContentSize;
    self.window.minSize = [self.window frameRectForContentRect:NSMakeRect(0, 0, DashboardMinimumWidth, DashboardMinimumHeight)].size;
    self.window.maxSize = self.window.minSize;
    [self.window setContentSize:fixedContentSize];
    self.window.styleMask = self.window.styleMask & ~NSWindowStyleMaskResizable;
    self.window.opaque = NO;
    self.window.backgroundColor = NSColor.clearColor;
    self.window.titlebarAppearsTransparent = YES;
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.movableByWindowBackground = YES;
    self.window.contentView = self.dashboard;
    self.window.autorecalculatesKeyViewLoop = NO;
    self.window.initialFirstResponder = nil;
    [[self.window standardWindowButton:NSWindowZoomButton] setEnabled:NO];
    [self.dashboard configureKeyViewLoop];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:nil];
    [self installKeyboardMonitor];

    __weak typeof(self) weakSelf = self;
    self.audioPlayer.levelHandler = ^(double level) {
        dispatch_async(dispatch_get_main_queue(), ^{
            double normalized = MIN(MAX(level, 0), 1);
            weakSelf.targetLevel = MAX(weakSelf.targetLevel * 0.92, normalized);
        });
    };
    self.audioPlayer.errorHandler = ^(NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.dashboard setErrorMessage:message];
        });
    };
    self.audioPlayer.queueDropHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.queueDropCount++;
            [weakSelf refreshCounters];
        });
    };

    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0
                                                  target:self
                                                selector:@selector(timerFired:)
                                                userInfo:nil
                                                 repeats:YES];

    [self resetStats];
    [self refreshState];
}

- (void)installApplicationIcon {
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
    if (!iconPath.length) {
        return;
    }

    NSImage *icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
    if (!icon) {
        return;
    }

    [NSApp setApplicationIconImage:icon];
}

- (void)installKeyboardMonitor {
    __weak typeof(self) weakSelf = self;
    self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                            handler:^NSEvent *(NSEvent *event) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || event.window != self.window || ![self isToggleReceiveKeyEvent:event]) {
            return event;
        }
        [self toggleReceiving:event];
        return nil;
    }];
}

- (BOOL)isToggleReceiveKeyEvent:(NSEvent *)event {
    NSEventModifierFlags blockedModifiers = NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption;
    if ((event.modifierFlags & blockedModifiers) != 0) {
        return NO;
    }

    NSString *characters = event.charactersIgnoringModifiers ?: @"";
    if (!characters.length) {
        return NO;
    }

    unichar key = [characters characterAtIndex:0];
    return key == NSCarriageReturnCharacter || key == NSEnterCharacter || key == '\r' || key == 0x03;
}

- (void)toggleReceiving:(id)sender {
    if (self.running) {
        [self stopPressed:sender];
    } else {
        [self startPressed:sender];
    }
}

- (void)installMainMenu {
    NSString *appName = Localized(self.currentLanguage, @"VBAN 接收器", @"VBAN Receiver");
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];

    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:appName
                                                        action:nil
                                                 keyEquivalent:@""];
    [mainMenu addItem:appMenuItem];

    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:appName];
    [appMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"关于 VBAN 接收器", @"About VBAN Receiver")
                                      action:@selector(showAboutPanel:)
                               keyEquivalent:@""]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"写入诊断快照", @"Write Diagnostic Snapshot")
                                      action:@selector(captureDiagnosticSnapshot:)
                               keyEquivalent:@""]];
    [appMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"打开诊断日志", @"Open Diagnostic Log")
                                      action:@selector(openDiagnosticLog:)
                               keyEquivalent:@""]];
    [appMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"修复输出", @"Repair Output")
                                      action:@selector(repairOutput:)
                               keyEquivalent:@"r"]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *servicesItem = [[NSMenuItem alloc] initWithTitle:Localized(self.currentLanguage, @"服务", @"Services")
                                                          action:nil
                                                   keyEquivalent:@""];
    NSMenu *servicesMenu = [[NSMenu alloc] initWithTitle:servicesItem.title];
    servicesItem.submenu = servicesMenu;
    [appMenu addItem:servicesItem];
    NSApp.servicesMenu = servicesMenu;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"隐藏 VBAN 接收器", @"Hide VBAN Receiver")
                                      action:@selector(hide:)
                               keyEquivalent:@"h"]];

    NSMenuItem *hideOthersItem = [self menuItemWithTitle:Localized(self.currentLanguage, @"隐藏其他", @"Hide Others")
                                                  action:@selector(hideOtherApplications:)
                                           keyEquivalent:@"h"];
    hideOthersItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItem:hideOthersItem];
    [appMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"全部显示", @"Show All")
                                      action:@selector(unhideAllApplications:)
                               keyEquivalent:@""]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"退出 VBAN 接收器", @"Quit VBAN Receiver")
                                      action:@selector(terminate:)
                               keyEquivalent:@"q"]];
    appMenuItem.submenu = appMenu;

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:Localized(self.currentLanguage, @"编辑", @"Edit")
                                                         action:nil
                                                  keyEquivalent:@""];
    [mainMenu addItem:editMenuItem];

    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:editMenuItem.title];
    [editMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"撤销", @"Undo")
                                       action:@selector(undo:)
                                keyEquivalent:@"z"]];

    NSMenuItem *redoItem = [self menuItemWithTitle:Localized(self.currentLanguage, @"重做", @"Redo")
                                            action:@selector(redo:)
                                     keyEquivalent:@"Z"];
    redoItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItem:redoItem];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"剪切", @"Cut")
                                       action:@selector(cut:)
                                keyEquivalent:@"x"]];
    [editMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"复制", @"Copy")
                                       action:@selector(copy:)
                                keyEquivalent:@"c"]];
    [editMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"粘贴", @"Paste")
                                       action:@selector(paste:)
                                keyEquivalent:@"v"]];
    [editMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"删除", @"Delete")
                                       action:@selector(delete:)
                                keyEquivalent:@""]];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"全选", @"Select All")
                                       action:@selector(selectAll:)
                                keyEquivalent:@"a"]];
    editMenuItem.submenu = editMenu;

    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle:Localized(self.currentLanguage, @"窗口", @"Window")
                                                           action:nil
                                                    keyEquivalent:@""];
    [mainMenu addItem:windowMenuItem];

    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:windowMenuItem.title];
    [windowMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"关闭窗口", @"Close Window")
                                         action:@selector(performClose:)
                                  keyEquivalent:@"w"]];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItem:[self menuItemWithTitle:Localized(self.currentLanguage, @"最小化", @"Minimize")
                                         action:@selector(performMiniaturize:)
                                  keyEquivalent:@"m"]];
    NSMenuItem *zoomItem = [self menuItemWithTitle:Localized(self.currentLanguage, @"缩放", @"Zoom")
                                            action:@selector(performZoom:)
                                     keyEquivalent:@""];
    zoomItem.enabled = NO;
    [windowMenu addItem:zoomItem];
    windowMenuItem.submenu = windowMenu;
    NSApp.windowsMenu = windowMenu;

    NSApp.mainMenu = mainMenu;
}

- (NSMenuItem *)menuItemWithTitle:(NSString *)title
                           action:(SEL)action
                    keyEquivalent:(NSString *)keyEquivalent {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:action
                                           keyEquivalent:keyEquivalent];
    item.keyEquivalentModifierMask = keyEquivalent.length ? NSEventModifierFlagCommand : 0;
    item.target = nil;
    return item;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (NSMenu *)applicationDockMenu:(NSApplication *)sender {
    NSMenu *dockMenu = [[NSMenu alloc] initWithTitle:@""];
    NSString *toggleTitle = self.running
        ? Localized(self.currentLanguage, @"停止接收", @"Stop Receiving")
        : Localized(self.currentLanguage, @"开始接收", @"Start Receiving");
    NSMenuItem *toggleItem = [[NSMenuItem alloc] initWithTitle:toggleTitle
                                                        action:@selector(toggleReceiving:)
                                                 keyEquivalent:@""];
    toggleItem.target = self;
    [dockMenu addItem:toggleItem];
    [dockMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *repairItem = [[NSMenuItem alloc] initWithTitle:Localized(self.currentLanguage, @"修复输出", @"Repair Output")
                                                        action:@selector(repairOutput:)
                                                 keyEquivalent:@""];
    repairItem.target = self;
    [dockMenu addItem:repairItem];
    return dockMenu;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.keyMonitor) {
        [NSEvent removeMonitor:self.keyMonitor];
        self.keyMonitor = nil;
    }
    [self.audioPlayer writeDiagnosticSnapshot:@"app-will-terminate"];
    [self.receiver stop];
    [self.audioPlayer reset];
}

- (void)showAboutPanel:(id)sender {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"";
    NSString *creditsText = @"Made by XiaoLeXLDW";
    NSAttributedString *credits = [[NSAttributedString alloc] initWithString:creditsText
                                                                  attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor
    }];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationName: Localized(self.currentLanguage, @"VBAN 接收器", @"VBAN Receiver"),
        NSAboutPanelOptionApplicationVersion: version,
        NSAboutPanelOptionVersion: build,
        NSAboutPanelOptionCredits: credits
    }];
}

- (void)captureDiagnosticSnapshot:(id)sender {
    [self.audioPlayer writeDiagnosticSnapshot:@"manual-menu-snapshot"];
}

- (void)openDiagnosticLog:(id)sender {
    [self.audioPlayer writeDiagnosticSnapshot:@"open-diagnostic-log"];
    NSString *path = self.audioPlayer.diagnosticLogPath;
    NSString *directory = path.stringByDeletingLastPathComponent;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:path]]];
}

- (void)repairOutput:(id)sender {
    [self performManualOutputRepair];
}

- (void)performManualOutputRepair {
    self.audioPlayer.locksOutputDevice = YES;
    [self.audioPlayer reconnectOutput];
    [self.audioPlayer writeDiagnosticSnapshot:@"manual-output-repair"];
    self.queueDropCount++;
    [self refreshCounters];
    self.dashboard.manualRepairButton.state = NSControlStateValueOff;
}

- (void)startPressed:(id)sender {
    NSInteger portValue = self.dashboard.portValue.integerValue;
    if (portValue <= 0 || portValue > 65535) {
        [self.dashboard setErrorMessage:Localized(self.currentLanguage, @"端口必须是 1-65535", @"Port must be 1-65535")];
        return;
    }

    [self resetStats];
    self.audioPlayer.playbackProfile = self.dashboard.playbackProfileValue;

    __weak typeof(self) weakSelf = self;
    self.receiver.packetHandler = ^(VBANPacket *packet) {
        [weakSelf.audioPlayer enqueuePacket:packet];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf recordPacket:packet];
        });
    };
    self.receiver.parseErrorHandler = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.badPacketCount++;
            [weakSelf.dashboard setErrorMessage:error.localizedDescription ?: Localized(weakSelf.currentLanguage, @"VBAN 数据包无效", @"Bad VBAN packet")];
            [weakSelf refreshCounters];
        });
    };
    self.receiver.filteredPacketHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.filteredPacketCount++;
            [weakSelf refreshCounters];
        });
    };
    self.receiver.stateHandler = ^(NSString *state) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.stateMessage = state ?: @"";
            [weakSelf refreshState];
        });
    };

    NSError *error = nil;
    BOOL started = [self.receiver startWithPort:(uint16_t)portValue
                                     streamName:self.dashboard.streamValue
                                     sourceHost:self.dashboard.sourceValue
                                          error:&error];
    if (!started) {
        [self.dashboard setErrorMessage:error.localizedDescription ?: Localized(self.currentLanguage, @"无法启动接收器", @"Cannot start receiver")];
        self.running = NO;
        self.stateMessage = @"Stopped";
        [self refreshState];
        return;
    }

    self.running = YES;
    self.stateMessage = @"Listening";
    [self.audioPlayer writeDiagnosticSnapshot:@"receiver-started"];
    [self refreshState];
}

- (void)latencyChanged:(id)sender {
    self.audioPlayer.playbackProfile = self.dashboard.playbackProfileValue;
    [self.audioPlayer writeDiagnosticSnapshot:@"latency-profile-changed"];
}

- (void)volumeChanged:(id)sender {
    [self.dashboard setVolume:self.dashboard.volumeValueNumber];
    self.audioPlayer.outputVolume = [self effectiveOutputVolume];
}

- (void)mutePressed:(id)sender {
    self.muted = self.dashboard.muteButton.state == NSControlStateValueOn;
    [self.dashboard setMuted:self.muted];
    self.audioPlayer.outputVolume = [self effectiveOutputVolume];
    [self.audioPlayer writeDiagnosticSnapshot:self.muted ? @"muted" : @"unmuted"];
}

- (void)autoRepairPressed:(id)sender {
    BOOL enabled = self.dashboard.autoRepairEnabled;
    [self.dashboard setAutoRepairEnabled:enabled];
    self.audioPlayer.autoRepairsOutput = enabled;
    [self.audioPlayer writeDiagnosticSnapshot:enabled ? @"auto-output-repair-enabled" : @"auto-output-repair-disabled"];
}

- (void)languagePressed:(id)sender {
    [self.dashboard toggleLanguage];
    self.currentLanguage = self.dashboard.language;
    self.window.title = Localized(self.currentLanguage, @"VBAN 接收器", @"VBAN Receiver");
    [self installMainMenu];
    [self refreshCounters];
    [self refreshState];
}

- (void)manualRepairPressed:(id)sender {
    [self repairOutput:sender];
}

- (float)effectiveOutputVolume {
    return self.muted ? 0.0f : (float)self.dashboard.volumeValueNumber;
}

- (void)stopPressed:(id)sender {
    [self.receiver stop];
    [self.audioPlayer writeDiagnosticSnapshot:@"receiver-stop-requested"];
    [self.audioPlayer reset];
    self.running = NO;
    self.level = 0;
    self.targetLevel = 0;
    self.stateMessage = @"Stopped";
    [self.dashboard setLevel:0];
    [self refreshState];
}

- (void)recordPacket:(VBANPacket *)packet {
    self.packetCount++;
    self.lastPacketAt = [NSDate date];
    [self.dashboard setErrorMessage:@""];

    if (self.hasLastFrameCounter) {
        uint32_t expected = self.lastFrameCounter + 1;
        if (packet.frameCounter != expected) {
            uint32_t delta = packet.frameCounter - expected;
            self.missingPacketCount += (delta > 0 && delta < 10000) ? delta : 1;
        }
    }
    self.hasLastFrameCounter = YES;
    self.lastFrameCounter = packet.frameCounter;

    NSString *stream = packet.streamName.length ? packet.streamName : Localized(self.currentLanguage, @"（未命名）", @"(unnamed)");
    [self.dashboard setStream:stream sender:packet.sender format:packet.formatDescription];
    [self refreshCounters];
    [self refreshState];
}

- (void)timerFired:(NSTimer *)timer {
    double rate = self.targetLevel > self.level ? 0.18 : 0.055;
    self.level += (self.targetLevel - self.level) * rate;
    self.targetLevel *= 0.91;

    if (self.level < 0.003 && self.targetLevel < 0.003) {
        self.level = 0;
        self.targetLevel = 0;
    }

    [self.dashboard setLevel:self.level];
    [self refreshState];
}

- (void)resetStats {
    self.packetCount = 0;
    self.badPacketCount = 0;
    self.filteredPacketCount = 0;
    self.missingPacketCount = 0;
    self.queueDropCount = 0;
    self.hasLastFrameCounter = NO;
    self.lastFrameCounter = 0;
    self.lastPacketAt = nil;
    self.level = 0;
    self.targetLevel = 0;
    [self.dashboard setLevel:0];
    [self.dashboard setStream:@"-" sender:@"-" format:[self.dashboard localizedNoSignalText]];
    [self.dashboard setErrorMessage:@""];
    [self refreshCounters];
}

- (void)refreshCounters {
    [self.dashboard setCountersPackets:self.packetCount
                               missing:self.missingPacketCount
                              filtered:self.filteredPacketCount
                                   bad:self.badPacketCount
                            queueDrops:self.queueDropCount];
}

- (void)refreshState {
    ReceiverStatusKind kind = ReceiverStatusKindStopped;
    if (self.running) {
        BOOL freshPacket = self.lastPacketAt && [[NSDate date] timeIntervalSinceDate:self.lastPacketAt] < 2.0;
        kind = freshPacket ? ReceiverStatusKindReceiving : ReceiverStatusKindWaiting;
    }
    [self.dashboard setRunning:self.running];
    [self.dashboard setStateText:self.stateMessage kind:kind];
}

@end
