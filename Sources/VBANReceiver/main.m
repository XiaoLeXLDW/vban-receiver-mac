#import <Cocoa/Cocoa.h>

#import "AppDelegate.h"

int main(__unused int argc, __unused const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application activateIgnoringOtherApps:YES];
        [application run];
        return 0;
    }
}
