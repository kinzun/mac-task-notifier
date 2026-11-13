#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <UserNotifications/UserNotifications.h>

static NSString *const ShowSettingsNotification = @"local.mac-task-notifier.show-settings";
static NSString *const CompletionNotification = @"local.mac-task-notifier.completed";

@interface NotificationPanel : NSPanel
@end
@implementation NotificationPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

static void DeliverNotification(NSString *title, NSString *message, void (^completion)(NSError *)) {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        if (settings.authorizationStatus != UNAuthorizationStatusAuthorized && settings.authorizationStatus != UNAuthorizationStatusProvisional) {
            completion([NSError errorWithDomain:@"MacTaskNotifier.NotificationPermission" code:settings.authorizationStatus userInfo:nil]);
            return;
        }
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = title;
        content.body = message;
        content.sound = UNNotificationSound.defaultSound;
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:content trigger:nil];
        [center addNotificationRequest:request withCompletionHandler:completion];
    }];
}

@interface MacNotifierDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate>
@property NSWindow *window;
@property WKWebView *webView;
@property NSStatusItem *statusItem;
@property NSMenuItem *statusText;
@property NSMenuItem *retryItem;
@property NSTask *service;
@property NSPipe *output;
@property NSPipe *errors;
@property NSString *lastError;
@property BOOL ready;
@property BOOL quitting;
@property NSPanel *notificationPanel;
@property NSTimer *notificationTimer;
@property id outsideClickMonitor;
@property id localEventMonitor;
@property NSString *lastTitle;
@property NSString *lastMessage;
@property NSDate *lastReceivedAt;
@end

@implementation MacNotifierDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSApp.applicationIconImage = [[NSImage alloc] initWithContentsOfURL:[NSBundle.mainBundle URLForResource:@"AppIcon" withExtension:@"icns"]];
    NSMenu *main = [NSMenu new];
    NSMenuItem *app = [NSMenuItem new];
    app.submenu = [NSMenu new];
    NSMenuItem *recentMessage = [app.submenu addItemWithTitle:@"查看最近消息" action:@selector(showLastMessage:) keyEquivalent:@""];
    recentMessage.target = self;
    [app.submenu addItem:NSMenuItem.separatorItem];
    [app.submenu addItemWithTitle:@"退出 Mac 任务通知" action:@selector(terminate:) keyEquivalent:@"q"];
    [main addItem:app];
    NSMenuItem *edit = [NSMenuItem new];
    edit.submenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    [edit.submenu addItemWithTitle:@"复制" action:@selector(copy:) keyEquivalent:@"c"];
    [edit.submenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    [main addItem:edit];
    NSApp.mainMenu = main;

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.toolTip = @"Mac 任务通知";
    NSMenu *menu = [NSMenu new];
    self.statusText = [menu addItemWithTitle:@"正在启动…" action:nil keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    NSArray *titles = @[@"打开设置…", @"查看最近消息", @"复制接收地址", @"发送测试通知", @"重试启动服务"];
    SEL actions[] = {@selector(showSettings:), @selector(showLastMessage:), @selector(copyAddress:), @selector(testNotification:), @selector(startService:)};
    for (NSUInteger index = 0; index < titles.count; index++) {
        NSMenuItem *item = [menu addItemWithTitle:titles[index] action:actions[index] keyEquivalent:@""];
        item.target = self;
        if (index == 4) self.retryItem = item;
    }
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"退出 Mac 任务通知" action:@selector(terminate:) keyEquivalent:@"q"];
    self.statusItem.menu = menu;
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(showSettings:) name:ShowSettingsNotification object:nil];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(completed:) name:CompletionNotification object:nil];

    self.webView = [WKWebView new];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 820, 760)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Mac 任务通知";
    self.window.minSize = NSMakeSize(430, 540);
    self.window.delegate = self;
    self.window.contentView = self.webView;
    [self.window center];
    [self showSettings:nil];
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound completionHandler:^(BOOL granted, NSError *error) {
        if (error) NSLog(@"Notification authorization failed: %@/%ld", error.domain, (long)error.code);
    }];
    [self startService:nil];
}

- (void)showSettings:(id)sender {
    [self.window deminiaturize:nil];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [sender orderOut:nil];
    return NO;
}

- (void)setRunning:(BOOL)running message:(NSString *)message {
    self.ready = running;
    self.statusText.title = message;
    self.retryItem.hidden = running;
    NSImage *image = [NSImage imageWithSystemSymbolName:running ? @"bell.fill" : @"bell.badge" accessibilityDescription:@"Mac 任务通知"];
    image.template = YES;
    self.statusItem.button.image = image;
}

- (void)startService:(id)sender {
    if (self.service.running) return;
    [self setRunning:NO message:@"正在启动通知服务…"];
    self.lastError = @"服务未启动，请检查端口 8765 或接收配置后重试";
    [self.webView loadHTMLString:@"<p style='font:16px -apple-system;padding:40px;color:#666'>正在启动通知服务…</p>" baseURL:nil];
    self.service = [NSTask new];
    NSURL *resources = NSBundle.mainBundle.resourceURL;
    self.service.executableURL = [resources URLByAppendingPathComponent:@"node"];
    self.service.arguments = @[[[resources URLByAppendingPathComponent:@"service/server.mjs"] path]];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"MAC_NOTIFY_PORT"] = @"8765";
    environment[@"MAC_NOTIFY_CONFIG_DIR"] = [NSHomeDirectory() stringByAppendingPathComponent:@".config/mac-task-notifier"];
    environment[@"MAC_NOTIFY_APP"] = NSBundle.mainBundle.executablePath;
    self.service.environment = environment;
    self.output = [NSPipe pipe];
    self.errors = [NSPipe pipe];
    self.service.standardOutput = self.output;
    self.service.standardError = self.errors;
    __weak MacNotifierDelegate *weakSelf = self;
    self.output.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        if (!handle.availableData.length) { handle.readabilityHandler = nil; return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            MacNotifierDelegate *owner = weakSelf;
            if (!owner || owner.ready || owner.quitting || owner.output.fileHandleForReading != handle) return;
            [owner setRunning:YES message:@"通知服务运行中"];
            [owner.webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:8765"]]];
        });
    };
    self.errors.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) { handle.readabilityHandler = nil; return; }
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        dispatch_async(dispatch_get_main_queue(), ^{
            MacNotifierDelegate *owner = weakSelf;
            if ([text containsString:@"EADDRINUSE"]) owner.lastError = @"端口 8765 被其他程序占用，请关闭占用程序后重试";
        });
    };
    self.service.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MacNotifierDelegate *owner = weakSelf;
            if (!owner || owner.quitting || owner.service != task) return;
            [owner setRunning:NO message:owner.lastError];
            [owner.webView loadHTMLString:@"<p style='font:16px -apple-system;padding:40px;color:#666'>服务未连接。请从菜单栏查看状态并重试启动。</p>" baseURL:nil];
        });
    };
    NSError *error;
    if (![self.service launchAndReturnError:&error]) [self setRunning:NO message:@"无法启动内置服务，请重新安装完整应用"];
}

- (void)copyAddress:(id)sender {
    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:8765/api/config"];
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *config = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *endpoint = config[@"endpoint"];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![endpoint isKindOfClass:NSString.class]) { [self showSettings:nil]; return; }
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard setString:endpoint forType:NSPasteboardTypeString];
        });
    }] resume];
}

- (void)testNotification:(id)sender {
    [self completed:[NSNotification notificationWithName:CompletionNotification object:nil userInfo:@{@"title": @"任务完成", @"message": @"任务已完成，可以回来看看了。"}]];
    DeliverNotification(@"任务完成", @"任务已完成，可以回来看看了。", ^(NSError *error) {});
}

- (void)completed:(NSNotification *)notification {
    NSDictionary *data = notification.userInfo;
    if (![data[@"title"] isKindOfClass:NSString.class] || ![data[@"message"] isKindOfClass:NSString.class]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.lastTitle = [data[@"title"] substringToIndex:MIN(120, [data[@"title"] length])];
        self.lastMessage = [data[@"message"] substringToIndex:MIN(1000, [data[@"message"] length])];
        self.lastReceivedAt = NSDate.date;
        [self showLastMessage:nil];
    });
}

- (void)dismissNotification:(id)sender {
    [self.notificationTimer invalidate];
    [self.notificationPanel orderOut:nil];
    if (self.outsideClickMonitor) [NSEvent removeMonitor:self.outsideClickMonitor];
    if (self.localEventMonitor) [NSEvent removeMonitor:self.localEventMonitor];
    self.outsideClickMonitor = nil;
    self.localEventMonitor = nil;
}

- (void)showLastMessage:(id)sender {
    [self dismissNotification:nil];
    NSRect bounds = NSMakeRect(0, 0, 364, 128);
    NSPanel *panel = [[NotificationPanel alloc] initWithContentRect:bounds
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed = NO;
    panel.title = @"任务通知";
    panel.backgroundColor = NSColor.clearColor;
    panel.opaque = NO;
    panel.hasShadow = YES;
    panel.hidesOnDeactivate = NO;
    panel.level = NSStatusWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
    [panel setAccessibilityLabel:@"任务通知"];
    NSVisualEffectView *surface = [[NSVisualEffectView alloc] initWithFrame:bounds];
    surface.material = NSVisualEffectMaterialPopover;
    surface.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    surface.state = NSVisualEffectStateActive;
    surface.wantsLayer = YES;
    surface.layer.cornerRadius = 20;
    surface.layer.masksToBounds = YES;
    panel.contentView = surface;
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(15, 49, 46, 46)];
    icon.image = NSApp.applicationIconImage;
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [icon setAccessibilityElement:NO];
    NSTextField *caption = [NSTextField labelWithString:@"Mac 任务通知"];
    caption.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    caption.textColor = NSColor.secondaryLabelColor;
    NSTextField *title = [NSTextField labelWithString:self.lastTitle ?: @"尚未收到消息"];
    title.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    NSTextField *body = [NSTextField wrappingLabelWithString:self.lastMessage ?: @"任务完成时，会在这里告诉你。"];
    body.font = [NSFont systemFontOfSize:13];
    body.textColor = NSColor.labelColor;
    body.maximumNumberOfLines = 2;
    body.lineBreakMode = NSLineBreakByTruncatingTail;
    caption.frame = NSMakeRect(73, 96, 176, 15);
    title.frame = NSMakeRect(73, 70, 270, 20);
    body.frame = NSMakeRect(73, 24, 270, 40);
    NSTextField *time = [NSTextField labelWithString:self.lastReceivedAt ?
        [NSDateFormatter localizedStringFromDate:self.lastReceivedAt dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle] : @""];
    time.font = [NSFont systemFontOfSize:10];
    time.textColor = NSColor.tertiaryLabelColor;
    time.alignment = NSTextAlignmentRight;
    time.frame = NSMakeRect(253, 97, 62, 13);
    NSButton *close = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"关闭通知"] target:self action:@selector(dismissNotification:)];
    close.bordered = NO;
    close.contentTintColor = NSColor.secondaryLabelColor;
    close.imageScaling = NSImageScaleProportionallyDown;
    close.frame = NSMakeRect(328, 94, 20, 20);
    close.toolTip = @"关闭通知";
    [close setAccessibilityLabel:@"关闭通知"];
    for (NSView *view in @[icon, caption, title, body, time, close]) [surface addSubview:view];

    NSScreen *screen = self.statusItem.button.window.screen ?: NSScreen.mainScreen;
    NSRect available = screen.visibleFrame;
    NSRect anchor = [self.statusItem.button.window convertRectToScreen:[self.statusItem.button convertRect:self.statusItem.button.bounds toView:nil]];
    CGFloat x = MIN(MAX(NSMidX(anchor) - bounds.size.width / 2, NSMinX(available) + 12), NSMaxX(available) - bounds.size.width - 12);
    [panel setFrameOrigin:NSMakePoint(x, NSMaxY(available) - bounds.size.height - 10)];
    self.notificationPanel = panel;
    BOOL reduceMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    panel.alphaValue = reduceMotion ? 1 : 0;
    [panel orderFrontRegardless];
    if (sender) [panel makeKeyAndOrderFront:nil];
    if (!reduceMotion) [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.18;
        panel.animator.alphaValue = 1;
    } completionHandler:nil];
    __weak MacNotifierDelegate *weakSelf = self;
    self.outsideClickMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown handler:^(NSEvent *event) {
        [weakSelf dismissNotification:nil];
    }];
    self.localEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if (event.type == NSEventTypeKeyDown) {
            if (event.keyCode == 53) [weakSelf dismissNotification:nil];
        } else if (event.window != weakSelf.notificationPanel) [weakSelf dismissNotification:nil];
        return event;
    }];
    self.notificationTimer = [NSTimer scheduledTimerWithTimeInterval:6 repeats:NO block:^(NSTimer *timer) { [weakSelf dismissNotification:nil]; }];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completion {
    completion(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(UNNotificationResponse *)response withCompletionHandler:(void (^)(void))completion {
    dispatch_async(dispatch_get_main_queue(), ^{ [self showSettings:nil]; completion(); });
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible { [self showSettings:nil]; return YES; }

- (void)applicationWillTerminate:(NSNotification *)notification {
    self.quitting = YES;
    [self dismissNotification:nil];
    self.output.fileHandleForReading.readabilityHandler = nil;
    self.errors.fileHandleForReading.readabilityHandler = nil;
    if (self.service.running) { [self.service terminate]; [self.service waitUntilExit]; }
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        if (argc == 4 && strcmp(argv[1], "--notify") == 0) {
            [[NSDistributedNotificationCenter defaultCenter] postNotificationName:CompletionNotification object:nil userInfo:@{@"title": [NSString stringWithUTF8String:argv[2]], @"message": [NSString stringWithUTF8String:argv[3]]} deliverImmediately:YES];
            DeliverNotification([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]], ^(NSError *error) {
                if (error) fprintf(stderr, "Notification failed: %s/%ld\n", error.domain.UTF8String, (long)error.code);
                // 菜单栏浮层已提交，系统横幅未获权限不阻断完成提醒。
                exit(0);
            });
            dispatch_main();
        }
        for (NSRunningApplication *existing in [NSRunningApplication runningApplicationsWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier]) {
            if (existing.processIdentifier != NSProcessInfo.processInfo.processIdentifier && !existing.terminated) {
                [existing activateWithOptions:NSApplicationActivateAllWindows | NSApplicationActivateIgnoringOtherApps];
                [[NSDistributedNotificationCenter defaultCenter] postNotificationName:ShowSettingsNotification object:nil userInfo:nil deliverImmediately:YES];
                return 0;
            }
        }
        static MacNotifierDelegate *delegate;
        delegate = [MacNotifierDelegate new];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [application run];
    }
    return 0;
}
