#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <UserNotifications/UserNotifications.h>

static NSString *const ShowSettingsNotification = @"local.mac-task-notifier.show-settings";
static NSString *const CompletionNotification = @"local.mac-task-notifier.completed";

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
@property NSPopover *popover;
@property NSTimer *popoverTimer;
@property NSString *lastTitle;
@property NSString *lastMessage;
@end

@implementation MacNotifierDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSMenu *main = [NSMenu new];
    NSMenuItem *app = [NSMenuItem new];
    app.submenu = [NSMenu new];
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
        [self showLastMessage:nil];
    });
}

- (void)showLastMessage:(id)sender {
    [self.popoverTimer invalidate];
    [self.popover close];
    NSViewController *controller = [NSViewController new];
    controller.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 120)];
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(14, 65, 38, 38)];
    icon.image = NSApp.applicationIconImage;
    NSTextField *caption = [NSTextField labelWithString:@"Mac 任务通知"];
    caption.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    caption.textColor = NSColor.secondaryLabelColor;
    NSTextField *title = [NSTextField labelWithString:self.lastTitle ?: @"尚未收到消息"];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    NSTextField *body = [NSTextField wrappingLabelWithString:self.lastMessage ?: @"任务完成时，会在这里告诉你。"];
    body.font = [NSFont systemFontOfSize:13];
    body.textColor = NSColor.secondaryLabelColor;
    body.maximumNumberOfLines = 3;
    body.lineBreakMode = NSLineBreakByTruncatingTail;
    caption.frame = NSMakeRect(62, 88, 260, 15);
    title.frame = NSMakeRect(62, 60, 260, 22);
    body.frame = NSMakeRect(62, 15, 260, 40);
    [controller.view addSubview:icon];
    [controller.view addSubview:caption];
    [controller.view addSubview:title];
    [controller.view addSubview:body];
    self.popover = [NSPopover new];
    self.popover.contentViewController = controller;
    self.popover.contentSize = NSMakeSize(340, 120);
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.animates = YES;
    [self.popover showRelativeToRect:self.statusItem.button.bounds ofView:self.statusItem.button preferredEdge:NSRectEdgeMinY];
    __weak MacNotifierDelegate *weakSelf = self;
    self.popoverTimer = [NSTimer scheduledTimerWithTimeInterval:6 repeats:NO block:^(NSTimer *timer) { [weakSelf.popover close]; }];
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
