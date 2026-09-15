// Exercise the private dashboard and controller directly, without showing windows.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import "../Sources/VBANReceiver/AppDelegate.m"
#pragma clang diagnostic pop

#include <errno.h>
#import <objc/runtime.h>

static void Assert(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

@interface VBANUDPReceiver (StatusUITesting)
- (NSSet<NSData *> *)resolvedAddressesForSourceHost:(NSString *)host error:(NSError **)error;
@end

@interface DelayedStatusReceiver : VBANUDPReceiver
@property (nonatomic, strong) dispatch_semaphore_t entered;
@property (nonatomic, strong) dispatch_semaphore_t releaseLookup;
@property (nonatomic, assign) NSTimeInterval testTimeout;
@end

@implementation DelayedStatusReceiver
- (NSSet<NSData *> *)resolvedAddressesForSourceHost:(NSString *)host error:(NSError **)error {
    dispatch_semaphore_signal(self.entered);
    Assert(dispatch_semaphore_wait(self.releaseLookup,
               dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0, "test releases DNS");
    return [super resolvedAddressesForSourceHost:@"127.0.0.1" error:error];
}
- (void)startWithPort:(uint16_t)port streamName:(NSString *)stream sourceHost:(NSString *)host
             timeout:(NSTimeInterval)timeout completion:(void (^)(BOOL, NSError *))completion {
    Assert(timeout == 5.0, "application retains five-second DNS timeout");
    [super startWithPort:0 streamName:stream sourceHost:host
                 timeout:self.testTimeout completion:completion];
}
@end

@interface OffscreenAppDelegate : AppDelegate
@property (nonatomic, assign) BOOL testVisible;
@end

@implementation OffscreenAppDelegate
- (BOOL)isPresentationVisible { return self.testVisible; }
- (void)updatePresentationActivity {}
- (void)installMainMenu {}
- (void)refreshStatusItem {}
@end

static void PumpUntil(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    Assert(condition(), "asynchronous UI transition completed");
}

static void DrainLateLookup(void) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:0.1];
    while (end.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
}


static void AssertTitle(DashboardView *dashboard, NSString *expected) {
    if (![dashboard.statusPill.title isEqualToString:expected]) {
        fprintf(stderr, "FAIL: visible pill expected '%s', got '%s'\n",
                expected.UTF8String, dashboard.statusPill.title.UTF8String);
        exit(1);
    }
}

static void TestStartupTransitions(DashboardView *dashboard) {
    OffscreenAppDelegate *app = [[OffscreenAppDelegate alloc] init];
    app.testVisible = YES;
    app.dashboard = dashboard;
    app.currentLanguage = DashboardLanguageEnglish;
    dashboard.language = DashboardLanguageEnglish;
    dashboard.sourceField.textField.stringValue = @"delayed.test";
    DelayedStatusReceiver *receiver = [[DelayedStatusReceiver alloc] init];
    receiver.entered = dispatch_semaphore_create(0);
    receiver.releaseLookup = dispatch_semaphore_create(0);
    receiver.testTimeout = 1.0;
    app.receiver = receiver;
    // No audio player is instantiated: the test never opens an audio device.
    [app startPressed:nil];
    Assert(dispatch_semaphore_wait(receiver.entered,
               dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, "slow lookup entered");
    AssertTitle(dashboard, @"Starting");
    Assert([dashboard.startButton.title isEqualToString:@"Stop Receiving"],
           "startup remains cancellable");
    [app refreshState];
    AssertTitle(dashboard, @"Starting");
    [app languagePressed:nil];
    AssertTitle(dashboard, @"正在启动");
    [app languagePressed:nil];
    AssertTitle(dashboard, @"Starting");
    app.testVisible = NO;
    [app languagePressed:nil];
    app.testVisible = YES;
    [app applyDashboardSnapshot];
    AssertTitle(dashboard, @"正在启动");
    [app languagePressed:nil];
    [app stopPressed:nil];
    AssertTitle(dashboard, @"Stopped");
    dispatch_semaphore_signal(receiver.releaseLookup);
    DrainLateLookup();
    AssertTitle(dashboard, @"Stopped");
    Assert(receiver.localPort == 0, "cancelled lookup cannot open socket");

    receiver.testTimeout = 0.05;
    [app startPressed:nil];
    Assert(dispatch_semaphore_wait(receiver.entered,
               dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, "timeout lookup entered");
    AssertTitle(dashboard, @"Starting");
    PumpUntil(^BOOL { return !app.running; });
    AssertTitle(dashboard, @"Stopped");
    Assert(app.currentErrorMessage.length > 0, "timeout leaves visible error");
    dispatch_semaphore_signal(receiver.releaseLookup);
    DrainLateLookup();
    AssertTitle(dashboard, @"Stopped");
    Assert(receiver.localPort == 0, "timed-out lookup cannot open socket");

    receiver.testTimeout = 1.0;
    [app startPressed:nil];
    Assert(dispatch_semaphore_wait(receiver.entered,
               dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, "successful lookup entered");
    AssertTitle(dashboard, @"Starting");
    dispatch_semaphore_signal(receiver.releaseLookup);
    PumpUntil(^BOOL { return [app.stateMessage isEqualToString:@"Listening"]; });
    AssertTitle(dashboard, @"Waiting");
    Assert(receiver.localPort > 0, "successful lookup starts receiving socket");
    [app languagePressed:nil];
    AssertTitle(dashboard, @"等待中");
    app.lastPacketUptime = NSProcessInfo.processInfo.systemUptime;
    [app refreshState];
    AssertTitle(dashboard, @"接收中");
    [app languagePressed:nil];
    AssertTitle(dashboard, @"Receiving");
    [app stopPressed:nil];
    AssertTitle(dashboard, @"Stopped");
}

@interface AboutTestApplication : NSApplication
@property (nonatomic, copy) NSDictionary *aboutOptions;
@end

@implementation AboutTestApplication
- (void)orderFrontStandardAboutPanelWithOptions:(NSDictionary *)options {
    self.aboutOptions = options;
}
@end

@interface AboutTestBundle : NSBundle
@property (nonatomic, copy) NSDictionary *testInfo;
@end

@implementation AboutTestBundle
- (id)objectForInfoDictionaryKey:(NSString *)key { return self.testInfo[key]; }
@end

static AboutTestBundle *aboutBundle;
static NSBundle *TestMainBundle(id object, SEL selector) { return aboutBundle; }

static void TestAboutBuildIdentity(void) {
    AboutTestApplication *application = (AboutTestApplication *)NSApp;
    AppDelegate *app = [[AppDelegate alloc] init];
    aboutBundle = [[AboutTestBundle alloc] init];
    Method method = class_getClassMethod(NSBundle.class, @selector(mainBundle));
    IMP original = method_setImplementation(method, (IMP)TestMainBundle);
    for (NSString *kind in @[@"development", @"release", @"legacy", @"missing-display"]) {
        NSString *display = [kind isEqualToString:@"development"]
            ? @"0.3.13 (17) — DEVELOPMENT arm64 abcdef123456 dirty"
            : @"0.3.13 (17) — RELEASE arm64 x86_64 abcdef123456";
        NSMutableDictionary *info = [@{@"CFBundleShortVersionString": @"0.3.13",
                                      @"CFBundleVersion": @"17"} mutableCopy];
        BOOL hasDisplay = ![kind isEqualToString:@"legacy"]
            && ![kind isEqualToString:@"missing-display"];
        if (![kind isEqualToString:@"legacy"]) {
            info[@"VBANBuildKind"] = [kind isEqualToString:@"missing-display"] ? @"development" : kind;
        }
        if (hasDisplay) {
            info[@"CFBundleGetInfoString"] = display;
        }
        aboutBundle.testInfo = info;
        [app showAboutPanel:nil];
        Assert([application.aboutOptions[NSAboutPanelOptionApplicationVersion]
                   isEqualToString:hasDisplay ? display : @"0.3.13"],
               "About displays build provenance with numeric fallback");
        Assert([application.aboutOptions[NSAboutPanelOptionVersion]
                   isEqualToString:hasDisplay ? @"" : @"17"],
               "About does not duplicate build number");
        Assert([info[@"CFBundleShortVersionString"] isEqualToString:@"0.3.13"]
                   && [info[@"CFBundleVersion"] isEqualToString:@"17"],
               "formal bundle version values remain numeric");
    }
    method_setImplementation(method, original);
    aboutBundle = nil;
}

int main(void) {
    @autoreleasepool {
        [AboutTestApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        DashboardView *dashboard = [[DashboardView alloc] initWithFrame:NSMakeRect(0, 0, 760, 600)];
        TestStartupTransitions(dashboard);
        dashboard.language = DashboardLanguageEnglish;
        [dashboard setStateText:@"Starting" kind:ReceiverStatusKindWaiting];
        AssertTitle(dashboard, @"Starting");
        [dashboard setStateText:@"Listening" kind:ReceiverStatusKindWaiting];
        AssertTitle(dashboard, @"Waiting");
        Assert([[dashboard stateTextForKind:ReceiverStatusKindWaiting fallback:@"Listening"]
                   isEqualToString:@"Listening"], "Listening detail vocabulary preserved");
        TestAboutBuildIdentity();
        puts("vban_status_ui_tests passed");
    }
    return 0;
}
