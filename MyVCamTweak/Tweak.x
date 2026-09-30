//
//  Tweak.x
//  MyVCam
//
//  Constructor only.
//  Builds the orchestrator object and returns. No %hook, no %init,
//  no mediaserverd, no AVFoundation capture replacement.
//
//  MyVCamTweak.plist matches only com.myvcam.stage21.placeholder.
//  A real filter is a later device stage. Do not point it at a camera
//  process from this file.
//

#import <Foundation/Foundation.h>
#import "MyVCamManager.h"

%ctor {
    @autoreleasepool {
        MyVCamManager *manager = [MyVCamManager sharedManager];
        (void)manager;
    }
}
