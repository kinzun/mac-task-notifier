#import <AppKit/AppKit.h>
#import "../mac/StatusIcon.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        NSImage *ready = NotificationStatusIcon(YES);
        NSImage *offline = NotificationStatusIcon(NO);
        assert(ready.isTemplate && offline.isTemplate);
        assert(NSEqualSizes(ready.size, NSMakeSize(22, 18)));
        NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:ready.TIFFRepresentation];
        assert(bitmap.hasAlpha);
        NSUInteger visible = 0, transparent = 0;
        for (NSInteger y = 0; y < bitmap.pixelsHigh; y++) {
            for (NSInteger x = 0; x < bitmap.pixelsWide; x++) {
                if ([bitmap colorAtX:x y:y].alphaComponent > 0) visible++; else transparent++;
            }
        }
        assert(visible > 40 && transparent > visible);
        assert(![ready.TIFFRepresentation isEqualToData:offline.TIFFRepresentation]);
        puts("菜单栏图标检查通过：原生模板、尺寸、透明背景与异常状态区分。");
    }
}
