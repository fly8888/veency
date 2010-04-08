/* Veency - VNC Remote Access Server for iPhoneOS
 * Copyright (C) 2008-2010  Jay Freeman (saurik)
*/

/*
 *        Redistribution and use in source and binary
 * forms, with or without modification, are permitted
 * provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the
 *    above copyright notice, this list of conditions
 *    and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the
 *    above copyright notice, this list of conditions
 *    and the following disclaimer in the documentation
 *    and/or other materials provided with the
 *    distribution.
 * 3. The name of the author may not be used to endorse
 *    or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING,
 * BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
 * TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#define _trace() \
    fprintf(stderr, "_trace()@%s:%u[%s]\n", __FILE__, __LINE__, __FUNCTION__)
#define _unlikely(expr) \
    __builtin_expect(expr, 0)

#include <substrate.h>

#include <rfb/rfb.h>
#include <rfb/keysym.h>

#include <mach/mach_port.h>
#include <sys/mman.h>

#import <QuartzCore/CAWindowServer.h>
#import <QuartzCore/CAWindowServerDisplay.h>

#import <CoreGraphics/CGGeometry.h>
#import <GraphicsServices/GraphicsServices.h>
#import <Foundation/Foundation.h>
#import <IOMobileFramebuffer/IOMobileFramebuffer.h>
#import <IOKit/IOKitLib.h>
#import <UIKit/UIKit.h>

#import <SpringBoard/SBAlertItemsController.h>
#import <SpringBoard/SBDismissOnlyAlertItem.h>
#import <SpringBoard/SBStatusBarController.h>

extern "C" void CoreSurfaceBufferFlushProcessorCaches(CoreSurfaceBufferRef buffer);

static size_t width_;
static size_t height_;

static const size_t BytesPerPixel = 4;
static const size_t BitsPerSample = 8;

static CoreSurfaceAcceleratorRef accelerator_;
static CoreSurfaceBufferRef buffer_;
static CFDictionaryRef options_;

static NSMutableSet *handlers_;
static rfbScreenInfoPtr screen_;
static bool running_;
static int buttons_;
static int x_, y_;

static unsigned clients_;

static CFMessagePortRef ashikase_;
static bool cursor_;

static bool Ashikase(bool always) {
    if (!always && !cursor_)
        return false;

    if (ashikase_ == NULL)
        ashikase_ = CFMessagePortCreateRemote(kCFAllocatorDefault, CFSTR("jp.ashikase.mousesupport"));
    if (ashikase_ != NULL)
        return true;

    cursor_ = false;
    return false;
}

static CFDataRef cfTrue_;
static CFDataRef cfFalse_;

typedef struct {
    float x, y;
    int buttons;
    BOOL absolute;
} MouseEvent;

static MouseEvent event_;
static CFDataRef cfEvent_;

typedef enum {
    MouseMessageTypeEvent,
    MouseMessageTypeSetEnabled
} MouseMessageType;

static void AshikaseSendEvent(float x, float y, int buttons = 0) {
    event_.x = x;
    event_.y = y;
    event_.buttons = buttons;
    event_.absolute = true;

    CFMessagePortSendRequest(ashikase_, MouseMessageTypeEvent, cfEvent_, 0, 0, NULL, NULL);
}

static void AshikaseSetEnabled(bool enabled, bool always) {
    if (!Ashikase(always))
        return;

    CFMessagePortSendRequest(ashikase_, MouseMessageTypeSetEnabled, enabled ? cfTrue_ : cfFalse_, 0, 0, NULL, NULL);

    if (enabled)
        AshikaseSendEvent(x_, y_);
}

MSClassHook(SBAlertItemsController)
MSClassHook(SBStatusBarController)

@class VNCAlertItem;
static Class $VNCAlertItem;

static rfbNewClientAction action_ = RFB_CLIENT_ON_HOLD;
static NSCondition *condition_;
static NSLock *lock_;

static rfbClientPtr client_;

@interface VNCBridge : NSObject {
}

+ (void) askForConnection;
+ (void) removeStatusBarItem;
+ (void) registerClient;

@end

@implementation VNCBridge

+ (void) askForConnection {
    [[$SBAlertItemsController sharedInstance] activateAlertItem:[[[$VNCAlertItem alloc] init] autorelease]];
}

+ (void) removeStatusBarItem {
    AshikaseSetEnabled(false, false);
    [[$SBStatusBarController sharedStatusBarController] removeStatusBarItem:@"Veency"];
}

+ (void) registerClient {
    ++clients_;
    AshikaseSetEnabled(true, false);
    [[$SBStatusBarController sharedStatusBarController] addStatusBarItem:@"Veency"];
}

@end

MSInstanceMessage2(void, VNCAlertItem, alertSheet,buttonClicked, id, sheet, int, button) {
    [condition_ lock];

    switch (button) {
        case 1:
            action_ = RFB_CLIENT_ACCEPT;

            @synchronized (condition_) {
                [VNCBridge registerClient];
            }
        break;

        case 2:
            action_ = RFB_CLIENT_REFUSE;
        break;
    }

    [condition_ signal];
    [condition_ unlock];
    [self dismiss];
}

MSInstanceMessage2(void, VNCAlertItem, configure,requirePasscodeForActions, BOOL, configure, BOOL, require) {
    UIModalView *sheet([self alertSheet]);
    [sheet setDelegate:self];
    [sheet setTitle:@"Remote Access Request"];
    [sheet setBodyText:[NSString stringWithFormat:@"Accept connection from\n%s?\n\nVeency VNC Server\nby Jay Freeman (saurik)\nsaurik@saurik.com\nhttp://www.saurik.com/\n\nSet a VNC password in Settings!", client_->host]];
    [sheet addButtonWithTitle:@"Accept"];
    [sheet addButtonWithTitle:@"Reject"];
}

MSInstanceMessage0(void, VNCAlertItem, performUnlockAction) {
    [[$SBAlertItemsController sharedInstance] activateAlertItem:self];
}

static mach_port_t (*GSTakePurpleSystemEventPort)(void);
static bool PurpleAllocated;
static int Level_;

static void FixRecord(GSEventRecord *record) {
    if (Level_ < 1)
        memmove(&record->windowContextId, &record->windowContextId + 1, sizeof(*record) - (reinterpret_cast<uint8_t *>(&record->windowContextId + 1) - reinterpret_cast<uint8_t *>(record)) + record->size);
}

static void VNCSettings() {
    NSDictionary *settings([NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Preferences/com.saurik.Veency.plist", NSHomeDirectory()]]);

    @synchronized (lock_) {
        for (NSValue *handler in handlers_)
            rfbUnregisterSecurityHandler(reinterpret_cast<rfbSecurityHandler *>([handler pointerValue]));
        [handlers_ removeAllObjects];
    }

    @synchronized (condition_) {
        if (screen_ == NULL)
            return;

        [reinterpret_cast<NSString *>(screen_->authPasswdData) release];
        screen_->authPasswdData = NULL;

        if (settings != nil)
            if (NSString *password = [settings objectForKey:@"Password"])
                if ([password length] != 0)
                    screen_->authPasswdData = [password retain];

        NSNumber *cursor = [settings objectForKey:@"ShowCursor"];
        cursor_ = cursor == nil ? true : [cursor boolValue];

        if (clients_ != 0)
            AshikaseSetEnabled(cursor_, true);
    }
}

static void VNCNotifySettings(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef info
) {
    VNCSettings();
}

static rfbBool VNCCheck(rfbClientPtr client, const char *data, int size) {
    @synchronized (condition_) {
        if (NSString *password = reinterpret_cast<NSString *>(screen_->authPasswdData)) {
            NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);
            rfbEncryptBytes(client->authChallenge, const_cast<char *>([password UTF8String]));
            bool good(memcmp(client->authChallenge, data, size) == 0);
            [pool release];
            return good;
        } return TRUE;
    }
}

static void VNCPointer(int buttons, int x, int y, rfbClientPtr client) {
    if (Level_ == 2) {
        int t(x);
        x = height_ - 1 - y;
        y = t;
    }

    x_ = x; y_ = y;
    int diff = buttons_ ^ buttons;
    bool twas((buttons_ & 0x1) != 0);
    bool tis((buttons & 0x1) != 0);
    buttons_ = buttons;

    rfbDefaultPtrAddEvent(buttons, x, y, client);

    if (Ashikase(false)) {
        AshikaseSendEvent(x, y, buttons);
        return;
    }

    mach_port_t purple(0);

    if ((diff & 0x10) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x4) != 0 ?
            GSEventTypeHeadsetButtonDown :
            GSEventTypeHeadsetButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if ((diff & 0x04) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x4) != 0 ?
            GSEventTypeMenuButtonDown :
            GSEventTypeMenuButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if ((diff & 0x02) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x2) != 0 ?
            GSEventTypeLockButtonDown :
            GSEventTypeLockButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if (twas != tis || tis) {
        struct {
            struct GSEventRecord record;
            struct {
                struct GSEventRecordInfo info;
                struct GSPathInfo path;
            } data;
        } event;

        memset(&event, 0, sizeof(event));

        event.record.type = GSEventTypeMouse;
        event.record.locationInWindow.x = x;
        event.record.locationInWindow.y = y;
        event.record.timestamp = GSCurrentEventTimestamp();
        event.record.size = sizeof(event.data);

        event.data.info.handInfo.type = twas == tis ?
            GSMouseEventTypeDragged :
        tis ?
            GSMouseEventTypeDown :
            GSMouseEventTypeUp;

        event.data.info.handInfo.x34 = 0x1;
        event.data.info.handInfo.x38 = tis ? 0x1 : 0x0;

        event.data.info.pathPositions = 1;

        event.data.path.x00 = 0x01;
        event.data.path.x01 = 0x02;
        event.data.path.x02 = tis ? 0x03 : 0x00;
        event.data.path.position = event.record.locationInWindow;

        mach_port_t port(0);

        if (CAWindowServer *server = [CAWindowServer serverIfRunning]) {
            NSArray *displays([server displays]);
            if (displays != nil && [displays count] != 0)
                if (CAWindowServerDisplay *display = [displays objectAtIndex:0])
                    port = [display clientPortAtPosition:event.record.locationInWindow];
        }

        if (port == 0) {
            if (purple == 0)
                purple = (*GSTakePurpleSystemEventPort)();
            port = purple;
        }

        FixRecord(&event.record);
        GSSendEvent(&event.record, port);
    }

    if (purple != 0 && PurpleAllocated)
        mach_port_deallocate(mach_task_self(), purple);
}

static void VNCKeyboard(rfbBool down, rfbKeySym key, rfbClientPtr client) {
    if (!down)
        return;

    switch (key) {
        case XK_Return: key = '\r'; break;
        case XK_BackSpace: key = 0x7f; break;
    }

    if (key > 0xfff)
        return;

    GSEventRef event(_GSCreateSyntheticKeyEvent(key, YES, YES));
    GSEventRecord *record(_GSEventGetGSEventRecord(event));
    record->type = GSEventTypeKeyDown;

    mach_port_t port(0);

    if (CAWindowServer *server = [CAWindowServer serverIfRunning]) {
        NSArray *displays([server displays]);
        if (displays != nil && [displays count] != 0)
            if (CAWindowServerDisplay *display = [displays objectAtIndex:0])
                port = [display clientPortAtPosition:CGPointMake(x_, y_)];
    }

    mach_port_t purple(0);

    if (port == 0) {
        if (purple == 0)
            purple = (*GSTakePurpleSystemEventPort)();
        port = purple;
    }

    if (port != 0)
        GSSendEvent(record, port);

    if (purple != 0 && PurpleAllocated)
        mach_port_deallocate(mach_task_self(), purple);

    CFRelease(event);
}

static void VNCDisconnect(rfbClientPtr client) {
    @synchronized (condition_) {
        if (--clients_ == 0)
            [VNCBridge performSelectorOnMainThread:@selector(removeStatusBarItem) withObject:nil waitUntilDone:YES];
    }
}

static rfbNewClientAction VNCClient(rfbClientPtr client) {
    @synchronized (condition_) {
        if (screen_->authPasswdData != NULL) {
            [VNCBridge performSelectorOnMainThread:@selector(registerClient) withObject:nil waitUntilDone:YES];
            client->clientGoneHook = &VNCDisconnect;
            return RFB_CLIENT_ACCEPT;
        }
    }

    [condition_ lock];
    client_ = client;
    [VNCBridge performSelectorOnMainThread:@selector(askForConnection) withObject:nil waitUntilDone:NO];
    while (action_ == RFB_CLIENT_ON_HOLD)
        [condition_ wait];
    rfbNewClientAction action(action_);
    action_ = RFB_CLIENT_ON_HOLD;
    [condition_ unlock];

    if (action == RFB_CLIENT_ACCEPT)
        client->clientGoneHook = &VNCDisconnect;
    return action;
}

static void VNCSetup() {
    rfbLogEnable(false);

    @synchronized (condition_) {
        int argc(1);
        char *arg0(strdup("VNCServer"));
        char *argv[] = {arg0, NULL};
        screen_ = rfbGetScreen(&argc, argv, width_, height_, BitsPerSample, 3, BytesPerPixel);
        free(arg0);

        VNCSettings();
    }

    screen_->desktopName = strdup([[[NSProcessInfo processInfo] hostName] UTF8String]);

    screen_->alwaysShared = TRUE;
    screen_->handleEventsEagerly = TRUE;
    screen_->deferUpdateTime = 1000 / 25;

    screen_->serverFormat.redShift = BitsPerSample * 2;
    screen_->serverFormat.greenShift = BitsPerSample * 1;
    screen_->serverFormat.blueShift = BitsPerSample * 0;

    buffer_ = CoreSurfaceBufferCreate((CFDictionaryRef) [NSDictionary dictionaryWithObjectsAndKeys:
        @"PurpleEDRAM", kCoreSurfaceBufferMemoryRegion,
        [NSNumber numberWithBool:YES], kCoreSurfaceBufferGlobal,
        [NSNumber numberWithInt:(width_ * BytesPerPixel)], kCoreSurfaceBufferPitch,
        [NSNumber numberWithInt:width_], kCoreSurfaceBufferWidth,
        [NSNumber numberWithInt:height_], kCoreSurfaceBufferHeight,
        [NSNumber numberWithInt:'BGRA'], kCoreSurfaceBufferPixelFormat,
        [NSNumber numberWithInt:(width_ * height_ * BytesPerPixel)], kCoreSurfaceBufferAllocSize,
    nil]);

    //screen_->frameBuffer = reinterpret_cast<char *>(mmap(NULL, sizeof(rfbPixel) * width_ * height_, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NOCACHE, VM_FLAGS_PURGABLE, 0));

    CoreSurfaceBufferLock(buffer_, 3);
    screen_->frameBuffer = reinterpret_cast<char *>(CoreSurfaceBufferGetBaseAddress(buffer_));
    CoreSurfaceBufferUnlock(buffer_);

    screen_->kbdAddEvent = &VNCKeyboard;
    screen_->ptrAddEvent = &VNCPointer;

    screen_->newClientHook = &VNCClient;
    screen_->passwordCheck = &VNCCheck;

    screen_->cursor = NULL;
}

static void VNCEnabled() {
    [lock_ lock];

    bool enabled(true);
    if (NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Preferences/com.saurik.Veency.plist", NSHomeDirectory()]])
        if (NSNumber *number = [settings objectForKey:@"Enabled"])
            enabled = [number boolValue];

    if (enabled != running_)
        if (enabled) {
            running_ = true;
            screen_->socketState = RFB_SOCKET_INIT;
            rfbInitServer(screen_);
            rfbRunEventLoop(screen_, -1, true);
        } else {
            rfbShutdownServer(screen_, true);
            running_ = false;
        }

    [lock_ unlock];
}

static void VNCNotifyEnabled(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef info
) {
    VNCEnabled();
}

MSHook(kern_return_t, IOMobileFramebufferSwapSetLayer,
    IOMobileFramebufferRef fb,
    int layer,
    CoreSurfaceBufferRef buffer,
    CGRect bounds,
    CGRect frame,
    int flags
) {
    if (_unlikely(screen_ == NULL)) {
        CGSize size;
        IOMobileFramebufferGetDisplaySize(fb, &size);

        width_ = size.width;
        height_ = size.height;

        NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);
        VNCSetup();
        VNCEnabled();
        [pool release];
    } else if (_unlikely(clients_ != 0)) {
        if (buffer == NULL) {
            //CoreSurfaceBufferLock(buffer_, 3);
            memset(screen_->frameBuffer, 0, sizeof(rfbPixel) * width_ * height_);
            //CoreSurfaceBufferUnlock(buffer_);
        } else {
            //CoreSurfaceBufferLock(buffer_, 3);
            //CoreSurfaceBufferLock(buffer, 2);

            //rfbPixel *data(reinterpret_cast<rfbPixel *>(CoreSurfaceBufferGetBaseAddress(buffer)));

            /*rfbPixel corner(data[0]);
            data[0] = 0;
            data[0] = corner;*/

            CoreSurfaceAcceleratorTransferSurface(accelerator_, buffer, buffer_, options_);

            //CoreSurfaceBufferUnlock(buffer);
            //CoreSurfaceBufferUnlock(buffer_);
        }

        //CoreSurfaceBufferFlushProcessorCaches(buffer);
        rfbMarkRectAsModified(screen_, 0, 0, width_, height_);
    }

    return _IOMobileFramebufferSwapSetLayer(fb, layer, buffer, bounds, frame, flags);
}

MSHook(void, rfbRegisterSecurityHandler, rfbSecurityHandler *handler) {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    @synchronized (lock_) {
        [handlers_ addObject:[NSValue valueWithPointer:handler]];
        _rfbRegisterSecurityHandler(handler);
    }

    [pool release];
}

MSInitialize {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    MSHookSymbol(GSTakePurpleSystemEventPort, "GSGetPurpleSystemEventPort");
    if (GSTakePurpleSystemEventPort == NULL) {
        MSHookSymbol(GSTakePurpleSystemEventPort, "GSCopyPurpleSystemEventPort");
        PurpleAllocated = true;
    }

    if (dlsym(RTLD_DEFAULT, "GSKeyboardCreate") != NULL)
        Level_ = 2;
    else if (dlsym(RTLD_DEFAULT, "GSEventGetWindowContextId") != NULL)
        Level_ = 1;
    else
        Level_ = 0;

    MSHookFunction(&IOMobileFramebufferSwapSetLayer, MSHake(IOMobileFramebufferSwapSetLayer));
    MSHookFunction(&rfbRegisterSecurityHandler, MSHake(rfbRegisterSecurityHandler));

    $VNCAlertItem = objc_allocateClassPair(objc_getClass("SBAlertItem"), "VNCAlertItem", 0);
    MSAddMessage2(VNCAlertItem, "v@:@i", alertSheet,buttonClicked);
    MSAddMessage2(VNCAlertItem, "v@:cc", configure,requirePasscodeForActions);
    MSAddMessage0(VNCAlertItem, "v@:", performUnlockAction);
    objc_registerClassPair($VNCAlertItem);

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, &VNCNotifyEnabled, CFSTR("com.saurik.Veency-Enabled"), NULL, 0
    );

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, &VNCNotifySettings, CFSTR("com.saurik.Veency-Settings"), NULL, 0
    );

    condition_ = [[NSCondition alloc] init];
    lock_ = [[NSLock alloc] init];
    handlers_ = [[NSMutableSet alloc] init];

    bool value;

    value = true;
    cfTrue_ = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<UInt8 *>(&value), sizeof(value));

    value = false;
    cfFalse_ = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<UInt8 *>(&value), sizeof(value));

    cfEvent_ = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, reinterpret_cast<UInt8 *>(&event_), sizeof(event_), kCFAllocatorNull);

    CoreSurfaceAcceleratorCreate(NULL, NULL, &accelerator_);

    options_ = (CFDictionaryRef) [[NSDictionary dictionaryWithObjectsAndKeys:
    nil] retain];

    [pool release];
}
