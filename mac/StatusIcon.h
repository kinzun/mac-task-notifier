#import <AppKit/AppKit.h>

static NSImage *NotificationStatusIcon(BOOL running) {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(22, 18) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightRegular];
        configuration = [configuration configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.blackColor]]];
        NSImage *bell = [[NSImage imageWithSystemSymbolName:@"bell" accessibilityDescription:nil] imageWithSymbolConfiguration:configuration];
        [bell drawInRect:NSMakeRect(1, 1, 14, 16)];
        NSGraphicsContext.currentContext.shouldAntialias = NO;
        [NSColor.blackColor setFill];
        if (running) {
            NSRectFill(NSMakeRect(16, 12, 1.5, 1.5));
            NSRectFill(NSMakeRect(18, 16, 1.5, 1.5));
        } else {
            NSRectFill(NSMakeRect(20, 8, 1.5, 6));
            NSRectFill(NSMakeRect(20, 4, 1.5, 1.5));
        }
        return YES;
    }];
    image.template = YES;
    image.accessibilityDescription = running ? @"任务通知：服务运行中" : @"任务通知：服务未连接";
    return image;
}
