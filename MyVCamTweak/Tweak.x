//
//  Tweak.x
//  MyVCam
//
//  Stage 2.1 constructor only.
//  Builds the orchestrator object and returns. No %hook, no %init,
//  no mediaserverd, no AVFoundation capture replacement.
//
//  MyVCamTweak.plist matches only com.myvcam.stage21.placeholder.
//  Stage 2.2 is responsible for a real filter.
//

#import <Foundation/Foundation.h>
#import "MyVCamManager.h"

%ctor {
    @autoreleasepool {
        MyVCamManager *manager = [MyVCamManager sharedManager];
        (void)manager;
    }
}
