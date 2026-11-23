//
//  MyVCamPicker.m
//  Generic-injection video picker.
//
//  Why this file exists
//  --------------------
//  The jailbreak build reads an absolute path
//  (/var/mobile/Documents/MyVCam/test.mp4) that only Camera can open because
//  a root helper mirrors it into the Camera container. A third-party app
//  injected through TrollFools has its own sandbox, so that path is
//  unreadable and the feed never arms.
//
//  This module stores the chosen video inside the *host app's* Documents
//  directory and reuses the existing MediaReader pipeline unchanged.
//  PHPickerViewController runs out of process, therefore the host app does
//  not need NSPhotoLibraryUsageDescription.
//

#import "MyVCamPicker.h"

#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdarg.h>

// 诊断日志：写进 <Documents>/MyVCam/picker.log，用 Filza 就能直接看。
static void MyVCamPickerLog(NSString *format, ...) {
    @autoreleasepool {
        NSArray<NSString *> *paths =
            NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documents = paths.firstObject;
        if (documents.length == 0) {
            return;
        }
        NSString *dir = [documents stringByAppendingPathComponent:@"MyVCam"];
        NSString *file = [dir stringByAppendingPathComponent:@"picker.log"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        va_list args;
        va_start(args, format);
        NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (![[NSFileManager defaultManager] fileExistsAtPath:file]) {
            [data writeToFile:file atomically:YES];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:file];
            [fh seekToEndOfFile];
            [fh writeData:data];
            [fh closeFile];
        }
    }
}

// 全屏浮窗必须做点击穿透：空白处返回 nil，触摸才会落到下层 App 上。
@interface MyVCamPassthroughView : UIView
@end

@implementation MyVCamPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

// 关键：命中测试返回 nil 的必须是窗口本身。UIWindow 在空白处会把自己
// 当成命中结果，只改 root view 不够，触摸仍会被这层全屏窗口吞掉。
@interface MyVCamPassthroughWindow : UIWindow
@end

@implementation MyVCamPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

static NSString * const kMyVCamPickerDirName = @"MyVCam";
static NSString * const kMyVCamPickerFileName = @"test.mp4";
static NSString * const kMyVCamPickerVoiceBaseName = @"voice";
static NSString * const kMyVCamPickerModeFileName = @"audio.mode";

static UIWindow *gMyVCamPickerWindow = nil;
static id gMyVCamPickerDelegate = nil;
static id gMyVCamPickerButtonController = nil;
static id gMyVCamPickerAudioDelegate = nil;
static UIButton *gMyVCamPickerAudioButton = nil;
static NSInteger gMyVCamPickerAttempts = 0;

static void MyVCamPickerAudioButtonRefresh(void);

#pragma mark - Paths

static NSURL *MyVCamPickerVideoDirectory(void) {
    NSArray<NSString *> *paths =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = paths.firstObject;
    if (documents.length == 0) {
        return nil;
    }
    return [[NSURL fileURLWithPath:documents isDirectory:YES]
        URLByAppendingPathComponent:kMyVCamPickerDirName
                        isDirectory:YES];
}

static NSURL *MyVCamPickerVideoURL(void) {
    NSURL *directory = MyVCamPickerVideoDirectory();
    if (directory == nil) {
        return nil;
    }
    return [directory URLByAppendingPathComponent:kMyVCamPickerFileName isDirectory:NO];
}

NSURL *MyVCamPickerPreferredVideoURL(void) {
    NSURL *url = MyVCamPickerVideoURL();
    if (url == nil) {
        return nil;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        return nil;
    }
    return url;
}

#pragma mark - Audio source

static NSArray<NSString *> *MyVCamPickerVoiceExtensions(void) {
    return @[@"m4a", @"mp3", @"wav", @"caf", @"aac", @"aiff", @"flac"];
}

static NSURL *MyVCamPickerVoiceURL(void) {
    NSURL *directory = MyVCamPickerVideoDirectory();
    if (directory == nil) {
        return nil;
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *extension in MyVCamPickerVoiceExtensions()) {
        NSString *name = [NSString stringWithFormat:@"%@.%@",
                          kMyVCamPickerVoiceBaseName,
                          extension];
        NSURL *url = [directory URLByAppendingPathComponent:name isDirectory:NO];
        if ([manager fileExistsAtPath:url.path]) {
            return url;
        }
    }
    return nil;
}

static void MyVCamPickerRemoveVoice(void) {
    NSURL *directory = MyVCamPickerVideoDirectory();
    if (directory == nil) {
        return;
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *extension in MyVCamPickerVoiceExtensions()) {
        NSString *name = [NSString stringWithFormat:@"%@.%@",
                          kMyVCamPickerVoiceBaseName,
                          extension];
        [manager removeItemAtURL:[directory URLByAppendingPathComponent:name isDirectory:NO]
                          error:NULL];
    }
}

static NSURL *MyVCamPickerModeURL(void) {
    NSURL *directory = MyVCamPickerVideoDirectory();
    if (directory == nil) {
        return nil;
    }
    return [directory URLByAppendingPathComponent:kMyVCamPickerModeFileName isDirectory:NO];
}

int MyVCamPickerAudioMode(void) {
    NSURL *url = MyVCamPickerModeURL();
    if (url == nil) {
        return 0;
    }
    NSString *value = [NSString stringWithContentsOfURL:url
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    value = [value stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([value isEqualToString:@"voice"] && MyVCamPickerVoiceURL() != nil) {
        return 1;
    }
    return 0;
}

void MyVCamPickerSetAudioMode(int mode) {
    if (mode != 0) {
        mode = 1;
    }
    if (mode == 1 && MyVCamPickerVoiceURL() == nil) {
        mode = 0;
    }
    NSURL *url = MyVCamPickerModeURL();
    if (url == nil) {
        return;
    }
    [[NSFileManager defaultManager] createDirectoryAtURL:url.URLByDeletingLastPathComponent
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];
    NSString *value = mode == 1 ? @"voice" : @"video";
    [value writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

NSURL *MyVCamPickerPreferredAudioURL(void) {
    if (MyVCamPickerAudioMode() != 1) {
        return nil;
    }
    return MyVCamPickerVoiceURL();
}

static void MyVCamPickerAudioButtonRefresh(void) {
    UIButton *button = gMyVCamPickerAudioButton;
    if (button == nil) {
        return;
    }
    BOOL voice = MyVCamPickerAudioMode() == 1;
    UIColor *color = voice ? UIColor.systemOrangeColor : UIColor.systemPurpleColor;
    [button setTitle:voice ? @"声*" : @"声" forState:UIControlStateNormal];
    button.backgroundColor = [color colorWithAlphaComponent:0.82];
}

#pragma mark - Toast

static void MyVCamPickerToast(NSString *text) {
    UIWindow *window = gMyVCamPickerWindow;
    if (window == nil || text.length == 0) {
        return;
    }
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = text;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
    label.layer.cornerRadius = 10.0;
    label.layer.masksToBounds = YES;

    CGSize maxSize = CGSizeMake(window.bounds.size.width - 64.0, CGFLOAT_MAX);
    CGSize fitted = [label sizeThatFits:maxSize];
    CGFloat width = fitted.width + 28.0;
    CGFloat height = fitted.height + 20.0;
    label.frame = CGRectMake((window.bounds.size.width - width) / 2.0,
                             window.bounds.size.height * 0.72,
                             width,
                             height);
    [window addSubview:label];

    NSTimeInterval stay = 2.0;
    if ([text containsString:@"copy="] || [text containsString:@"url="] || [text containsString:@"log="]) {
        stay = 30.0;   // 诊断信息停留久一点，方便截图
    }
    [UIView animateWithDuration:0.35
                          delay:stay
                        options:UIViewAnimationOptionCurveEaseInOut
                     animations:^{
                         label.alpha = 0.0;
                     }
                     completion:^(BOOL finished) {
                         [label removeFromSuperview];
                     }];
}

#pragma mark - Picker delegate

@interface MyVCamPickerDelegate : NSObject <PHPickerViewControllerDelegate>
@end

@implementation MyVCamPickerDelegate

- (void)picker:(PHPickerViewController *)picker
    didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];

    MyVCamPickerLog(@"didFinishPicking results=%lu", (unsigned long)results.count);

    PHPickerResult *result = results.firstObject;
    if (result == nil) {
        return;
    }
    NSItemProvider *provider = result.itemProvider;
    if (![provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        MyVCamPickerToast(@"请选择视频文件");
        return;
    }

    [provider loadFileRepresentationForTypeIdentifier:@"public.movie"
                                   completionHandler:^(NSURL *url, NSError *error) {
        if (url == nil) {
            MyVCamPickerLog(@"loadFileRepresentation nil err=%@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                MyVCamPickerToast([NSString stringWithFormat:@"url=nil %@", error]);
            });
            return;
        }
        NSFileManager *manager = [NSFileManager defaultManager];
        NSURL *directory = MyVCamPickerVideoDirectory();
        NSURL *destination = MyVCamPickerVideoURL();
        if (directory == nil || destination == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                MyVCamPickerToast(@"沙盒路径不可用");
            });
            return;
        }
        [manager createDirectoryAtURL:directory
          withIntermediateDirectories:YES
                           attributes:nil
                                error:NULL];
        [manager removeItemAtURL:destination error:NULL];
        NSError *copyError = nil;
        BOOL copied = [manager copyItemAtURL:url toURL:destination error:&copyError];
        MyVCamPickerLog(@"copy=%d dest=%@ err=%@", copied, destination.path, copyError);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (copied) {
                // Re-arm the live session so the change is visible at once.
                MyVCamPickerSetDisabled(0);
                MyVCamPickerVideoDidChange();
                MyVCamPickerToast([NSString stringWithFormat:@"copy=1\n%@\n%@", destination.path, url.path]);
            } else {
                MyVCamPickerToast([NSString stringWithFormat:@"copy=0\n%@", copyError]);
                NSLog(@"[MyVCam Picker] copy failed: %@", copyError);
            }
        });
    }];
}

@end

#pragma mark - Audio picker delegate

@interface MyVCamAudioPickerDelegate : NSObject <UIDocumentPickerDelegate>
@end

@implementation MyVCamAudioPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [controller dismissViewControllerAnimated:YES completion:nil];

    NSURL *source = urls.firstObject;
    if (source == nil) {
        return;
    }
    NSURL *directory = MyVCamPickerVideoDirectory();
    if (directory == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MyVCamPickerToast(@"沙盒路径不可用");
        });
        return;
    }

    NSString *extension = source.pathExtension.lowercaseString;
    if (![MyVCamPickerVoiceExtensions() containsObject:extension]) {
        extension = @"m4a";
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    [manager createDirectoryAtURL:directory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:NULL];
    NSURL *destination = [directory URLByAppendingPathComponent:
                             [NSString stringWithFormat:@"%@.%@",
                              kMyVCamPickerVoiceBaseName,
                              extension]
                                                      isDirectory:NO];

    BOOL scoped = [source startAccessingSecurityScopedResource];
    MyVCamPickerRemoveVoice();
    [manager removeItemAtURL:destination error:NULL];
    NSError *copyError = nil;
    BOOL copied = [manager copyItemAtURL:source toURL:destination error:&copyError];
    if (scoped) {
        [source stopAccessingSecurityScopedResource];
    }

    if (copied) {
        MyVCamPickerSetAudioMode(1);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (copied) {
            MyVCamPickerAudioButtonRefresh();
            MyVCamPickerAudioDidChange();
            MyVCamPickerToast(@"已切换为克隆声音");
        } else {
            MyVCamPickerToast(@"保存音频失败，换个文件试试");
            NSLog(@"[MyVCam Picker] audio copy failed: %@", copyError);
        }
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [controller dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Window helpers

static UIWindowScene *MyVCamPickerActiveScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static UIViewController *MyVCamPickerTopViewController(UIWindowScene *scene) {
    UIViewController *top = nil;
    for (UIWindow *window in scene.windows) {
        if (window.isKeyWindow && window.rootViewController != nil) {
            top = window.rootViewController;
            break;
        }
    }
    if (top == nil) {
        for (UIWindow *window in scene.windows) {
            if (window.rootViewController != nil) {
                top = window.rootViewController;
                break;
            }
        }
    }
    while (top.presentedViewController != nil) {
        top = top.presentedViewController;
    }
    return top;
}

#pragma mark - Button controller

@interface MyVCamPickerButtonController : NSObject
@end

@implementation MyVCamPickerButtonController

- (void)handleTap:(UIButton *)sender {
    (void)sender;
    MyVCamPickerLog(@"VC tap");
    [self presentPicker];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *button = gesture.view;
    // Both buttons share a panel; the VC button drags the panel.
    UIView *panel = button.superview ?: button;
    UIWindow *window = panel.window;
    if (button == nil || window == nil) {
        return;
    }
    CGPoint translation = [gesture translationInView:window];
    CGPoint center = panel.center;
    center.x += translation.x;
    center.y += translation.y;

    CGFloat halfWidth = CGRectGetWidth(panel.bounds) / 2.0;
    CGFloat halfHeight = CGRectGetHeight(panel.bounds) / 2.0;
    center.x = MAX(halfWidth + 6.0, MIN(window.bounds.size.width - halfWidth - 6.0, center.x));
    center.y = MAX(halfHeight + 40.0, MIN(window.bounds.size.height - halfHeight - 40.0, center.y));
    panel.center = center;
    [gesture setTranslation:CGPointZero inView:window];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }
    int nextDisabled = MyVCamPickerIsDisabled() ? 0 : 1;
    MyVCamPickerSetDisabled(nextDisabled);
    MyVCamPickerToast(nextDisabled ? @"已切回真实相机" : @"已恢复视频替换");
    NSLog(@"[MyVCam Picker] long press, disabled=%d", nextDisabled);
}

- (void)presentPicker {
    UIWindowScene *scene = MyVCamPickerActiveScene();
    UIViewController *presenter = scene != nil ? MyVCamPickerTopViewController(scene) : nil;
    if (presenter == nil) {
        MyVCamPickerToast(@"当前界面无法打开相册");
        return;
    }

    PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
    configuration.filter = [PHPickerFilter videosFilter];
    configuration.selectionLimit = 1;

    PHPickerViewController *picker =
        [[PHPickerViewController alloc] initWithConfiguration:configuration];
    MyVCamPickerDelegate *delegate = [[MyVCamPickerDelegate alloc] init];
    picker.delegate = delegate;
    gMyVCamPickerDelegate = delegate;

    [presenter presentViewController:picker animated:YES completion:nil];
    MyVCamPickerLog(@"present picker ok");
}

#pragma mark - Audio button

- (void)handleAudioTap:(UIButton *)sender {
    [self presentAudioMenuFromView:sender];
}

- (void)handleAudioLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }
    if (MyVCamPickerVoiceURL() == nil) {
        MyVCamPickerToast(@"还没有克隆声音文件，先点“声”导入");
        return;
    }
    int next = MyVCamPickerAudioMode() == 1 ? 0 : 1;
    MyVCamPickerSetAudioMode(next);
    MyVCamPickerAudioButtonRefresh();
    MyVCamPickerAudioDidChange();
    MyVCamPickerToast(next == 1 ? @"声音：克隆声音" : @"声音：视频原声");
}

- (void)presentAudioMenuFromView:(UIView *)view {
    UIWindowScene *scene = MyVCamPickerActiveScene();
    UIViewController *presenter = scene != nil ? MyVCamPickerTopViewController(scene) : nil;
    if (presenter == nil) {
        MyVCamPickerToast(@"当前界面无法弹出菜单");
        return;
    }

    BOOL hasVoice = MyVCamPickerVoiceURL() != nil;
    BOOL voiceMode = MyVCamPickerAudioMode() == 1;
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:@"声音来源"
                                            message:@"视频原声 = 视频自带的音轨；克隆声音 = 你导入的音频文件"
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *videoTitle = voiceMode ? @"使用视频原声" : @"使用视频原声（当前）";
    [sheet addAction:[UIAlertAction actionWithTitle:videoTitle
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        (void)action;
        MyVCamPickerSetAudioMode(0);
        MyVCamPickerAudioButtonRefresh();
        MyVCamPickerAudioDidChange();
        MyVCamPickerToast(@"声音：视频原声");
    }]];

    if (hasVoice) {
        NSString *voiceTitle = voiceMode ? @"使用克隆声音（当前）" : @"使用克隆声音";
        [sheet addAction:[UIAlertAction actionWithTitle:voiceTitle
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            (void)action;
            MyVCamPickerSetAudioMode(1);
            MyVCamPickerAudioButtonRefresh();
            MyVCamPickerAudioDidChange();
            MyVCamPickerToast(@"声音：克隆声音");
        }]];
    }

    NSString *importTitle = hasVoice ? @"更换克隆声音文件…" : @"导入克隆声音文件…";
    [sheet addAction:[UIAlertAction actionWithTitle:importTitle
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        (void)action;
        [self presentAudioPicker];
    }]];

    if (hasVoice) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"移除克隆声音"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *action) {
            (void)action;
            MyVCamPickerRemoveVoice();
            MyVCamPickerSetAudioMode(0);
            MyVCamPickerAudioButtonRefresh();
            MyVCamPickerAudioDidChange();
            MyVCamPickerToast(@"已移除克隆声音，恢复视频原声");
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = view;
    sheet.popoverPresentationController.sourceRect = view.bounds;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

- (void)presentAudioPicker {
    UIWindowScene *scene = MyVCamPickerActiveScene();
    UIViewController *presenter = scene != nil ? MyVCamPickerTopViewController(scene) : nil;
    if (presenter == nil) {
        MyVCamPickerToast(@"当前界面无法打开文件");
        return;
    }

    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeAudio]
                                                                   asCopy:YES];
    picker.allowsMultipleSelection = NO;
    MyVCamAudioPickerDelegate *delegate = [[MyVCamAudioPickerDelegate alloc] init];
    picker.delegate = delegate;
    gMyVCamPickerAudioDelegate = delegate;
    [presenter presentViewController:picker animated:YES completion:nil];
}

@end

#pragma mark - Install

static void MyVCamPickerAttachButton(void) {
    UIWindowScene *scene = MyVCamPickerActiveScene();
    if (scene == nil) {
        return;
    }

    MyVCamPassthroughWindow *window = [[MyVCamPassthroughWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    window.windowLevel = UIWindowLevelAlert + 1;
    window.backgroundColor = UIColor.clearColor;
    UIViewController *root = [[UIViewController alloc] init];
    root.view = [[MyVCamPassthroughView alloc] initWithFrame:window.bounds];
    root.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = root;
    window.hidden = NO;

    MyVCamPickerButtonController *controller = [[MyVCamPickerButtonController alloc] init];
    gMyVCamPickerButtonController = controller;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(window.bounds.size.width - 66.0,
                                                             window.bounds.size.height * 0.5,
                                                             48.0,
                                                             104.0)];
    panel.backgroundColor = UIColor.clearColor;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"VC" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    button.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.82];
    button.layer.cornerRadius = 24.0;
    button.layer.masksToBounds = YES;
    button.frame = CGRectMake(0.0, 0.0, 48.0, 48.0);
    [button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:controller
                                                                        action:@selector(handlePan:)]];
    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:controller
                                                      action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.6;
    [button addGestureRecognizer:longPress];
    [button addTarget:controller
               action:@selector(handleTap:)
     forControlEvents:UIControlEventTouchUpInside];

    UIButton *audioButton = [UIButton buttonWithType:UIButtonTypeSystem];
    audioButton.frame = CGRectMake(0.0, 56.0, 48.0, 48.0);
    audioButton.layer.cornerRadius = 24.0;
    audioButton.layer.masksToBounds = YES;
    [audioButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    audioButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    UILongPressGestureRecognizer *audioLongPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:controller
                                                      action:@selector(handleAudioLongPress:)];
    audioLongPress.minimumPressDuration = 0.6;
    [audioButton addGestureRecognizer:audioLongPress];
    [audioButton addTarget:controller
                    action:@selector(handleAudioTap:)
          forControlEvents:UIControlEventTouchUpInside];
    gMyVCamPickerAudioButton = audioButton;
    MyVCamPickerAudioButtonRefresh();

    [panel addSubview:button];
    [panel addSubview:audioButton];
    [window.rootViewController.view addSubview:panel];
    gMyVCamPickerWindow = window;

    NSLog(@"[MyVCam Picker] buttons installed, audio_mode=%d", MyVCamPickerAudioMode());
}

void MyVCamPickerInstall(void) {
    if (gMyVCamPickerWindow != nil) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MyVCamPickerInstall();
        });
        return;
    }
    if (MyVCamPickerActiveScene() != nil) {
        MyVCamPickerAttachButton();
        return;
    }
    // The scene is usually not ready inside %ctor; retry briefly.
    if (gMyVCamPickerAttempts >= 20) {
        return;
    }
    gMyVCamPickerAttempts += 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       MyVCamPickerInstall();
                   });
}
