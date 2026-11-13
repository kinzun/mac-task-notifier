#import <AppKit/AppKit.h>
#import "../mac/NotificationMask.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        NSImage *mask = NotificationMask(NSMakeSize(404, 104), 44);
        NSBitmapImageRep *pixels = [NSBitmapImageRep imageRepWithData:mask.TIFFRepresentation];
        NSInteger width = pixels.pixelsWide, height = pixels.pixelsHigh;
        assert([pixels colorAtX:0 y:0].alphaComponent == 0);
        assert([pixels colorAtX:width - 1 y:0].alphaComponent == 0);
        assert([pixels colorAtX:0 y:height - 1].alphaComponent == 0);
        assert([pixels colorAtX:width - 1 y:height - 1].alphaComponent == 0);
        assert([pixels colorAtX:width / 2 y:height / 2].alphaComponent == 1);
        assert([pixels colorAtX:width / 2 y:2].alphaComponent == 1);
        puts("通知遮罩检查通过：四角透明，中心和直边保留。");
    }
}
