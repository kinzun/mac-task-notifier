#import <AppKit/AppKit.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 1;
        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1024 pixelsHigh:1024 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
        NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(64, 64, 896, 896) xRadius:202 yRadius:202];
        NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithRed:0.30 green:0.66 blue:1 alpha:1] endingColor:[NSColor colorWithRed:0 green:0.40 blue:0.94 alpha:1]];
        [gradient drawInBezierPath:shape angle:-90];
        [[NSColor colorWithWhite:1 alpha:0.22] setStroke];
        shape.lineWidth = 3;
        [shape stroke];
        NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:500 weight:NSFontWeightRegular];
        configuration = [configuration configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.whiteColor]]];
        NSImage *bell = [[NSImage imageWithSystemSymbolName:@"bell.fill" accessibilityDescription:nil] imageWithSymbolConfiguration:configuration];
        [bell drawInRect:NSMakeRect(250, 238, 524, 548)];
        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        return [png writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES] ? 0 : 1;
    }
}
