#import <AppKit/AppKit.h>

static NSImage *NotificationMask(NSSize size, CGFloat radius) {
    return [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [NSColor.whiteColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
        return YES;
    }];
}
