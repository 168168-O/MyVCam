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

static NSString * const kMyVCamPickerDirName = @"MyVCam";
static NSString * const kMyVCamPickerFileName = @"test.mp4";

static UIWindow *gMyVCamPickerWindow = nil;
static id gMyVCamPickerDelegate = nil;
static id gMyVCamPickerButtonController = nil;
static NSInteger gMyVCamPickerAttempts = 0;

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

    [UIView animateWithDuration:0.35
                          delay:2.0
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
            dispatch_async(dispatch_get_main_queue(), ^{
                MyVCamPickerToast(@"读取视频失败");
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
        dispatch_async(dispatch_get_main_queue(), ^{
            if (copied) {
                MyVCamPickerToast(@"已保存，重开相机界面生效");
            } else {
                MyVCamPickerToast(@"保存失败，换个视频试试");
                NSLog(@"[MyVCam Picker] copy failed: %@", copyError);
            }
        });
    }];
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
    [self presentPicker];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *button = gesture.view;
    UIWindow *window = button.window;
    if (button == nil || window == nil) {
        return;
    }
    CGPoint translation = [gesture translationInView:window];
    CGPoint center = button.center;
    center.x += translation.x;
    center.y += translation.y;

    CGFloat halfWidth = button.bounds.size.width / 2.0;
    CGFloat halfHeight = button.bounds.size.height / 2.0;
    center.x = MAX(halfWidth + 6.0, MIN(window.bounds.size.width - halfWidth - 6.0, center.x));
    center.y = MAX(halfHeight + 40.0, MIN(window.bounds.size.height - halfHeight - 40.0, center.y));
    button.center = center;
    [gesture setTranslation:CGPointZero inView:window];
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
}

@end

#pragma mark - Install

static void MyVCamPickerAttachButton(void) {
    UIWindowScene *scene = MyVCamPickerActiveScene();
    if (scene == nil) {
        return;
    }

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = scene.coordinateSpace.bounds;
    window.windowLevel = UIWindowLevelAlert + 1;
    window.backgroundColor = UIColor.clearColor;
    window.rootViewController = [[UIViewController alloc] init];
    window.rootViewController.view.backgroundColor = UIColor.clearColor;
    window.hidden = NO;

    MyVCamPickerButtonController *controller = [[MyVCamPickerButtonController alloc] init];
    gMyVCamPickerButtonController = controller;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"VC" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    button.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.82];
    button.layer.cornerRadius = 24.0;
    button.layer.masksToBounds = YES;
    button.frame = CGRectMake(window.bounds.size.width - 66.0,
                              window.bounds.size.height * 0.5,
                              48.0,
                              48.0);
    [button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:controller
                                                                        action:@selector(handlePan:)]];
    [button addTarget:controller
               action:@selector(handleTap:)
     forControlEvents:UIControlEventTouchUpInside];

    [window.rootViewController.view addSubview:button];
    gMyVCamPickerWindow = window;

    NSLog(@"[MyVCam Picker] button installed");
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
