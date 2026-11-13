#import <AppKit/AppKit.h>

static NSImage *NotificationStatusIcon(BOOL running) {
    NSImage *image = [NSImage imageWithSize:NSMakeSize(22, 18) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSGraphicsContext.currentContext.shouldAntialias = NO;
        [NSColor.blackColor setFill];
        const char *rows[] = {
            "000010000", "000111000", "001111100", "001111100", "001111100",
            "011111110", "111111111", "000111000", "000010000"
        };
        for (NSUInteger y = 0; y < 9; y++) {
            for (NSUInteger x = 0; x < 9; x++) {
                if (rows[y][x] == '1') NSRectFill(NSMakeRect(x * 2, 16 - y * 2, 1.5, 1.5));
            }
        }
        if (running) {
            NSRectFill(NSMakeRect(15, 13, 1.5, 1.5));
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
