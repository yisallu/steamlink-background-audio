// BackgroundAudio.m - Steam Link Background Audio Tweak v8
//
// - Keeps audio alive on lock screen and background
// - Fixes AirPods auto-switch: re-activates audio session when interruption ends

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define SDL_EVENT_WILL_ENTER_BACKGROUND 0x102
#define SDL_EVENT_DID_ENTER_BACKGROUND  0x103

typedef void (*SDL_SetEventEnabled_t)(uint32_t type, int enabled);
typedef int (*SDL_SetHint_t)(const char *name, const char *value);
typedef int (*SDL_ResumeAudioDevice_t)(uint32_t devid);

static IMP orig_setCategory1 = NULL;
static IMP orig_setCategory2 = NULL;
static IMP orig_setCategory3 = NULL;

static BOOL forced_setCategory_error(id self, SEL _cmd, AVAudioSessionCategory cat, NSError **err) {
    return ((BOOL(*)(id,SEL,AVAudioSessionCategory,NSError**))orig_setCategory1)(
        self, _cmd, AVAudioSessionCategoryPlayback, err);
}

static BOOL forced_setCategory_options_error(id self, SEL _cmd, AVAudioSessionCategory cat,
                                              AVAudioSessionCategoryOptions opts, NSError **err) {
    return ((BOOL(*)(id,SEL,AVAudioSessionCategory,AVAudioSessionCategoryOptions,NSError**))orig_setCategory2)(
        self, _cmd, AVAudioSessionCategoryPlayback, 0, err);
}

static BOOL forced_setCategory_mode_options_error(id self, SEL _cmd, AVAudioSessionCategory cat,
                                                   AVAudioSessionMode mode,
                                                   AVAudioSessionCategoryOptions opts, NSError **err) {
    return ((BOOL(*)(id,SEL,AVAudioSessionCategory,AVAudioSessionMode,AVAudioSessionCategoryOptions,NSError**))orig_setCategory3)(
        self, _cmd, AVAudioSessionCategoryPlayback, mode, 0, err);
}

static void registerNowPlaying(void) {
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    center.nowPlayingInfo = @{
        MPMediaItemPropertyTitle: @"Steam Link",
        MPMediaItemPropertyArtist: @"Streaming",
        MPNowPlayingInfoPropertyPlaybackRate: @(1.0),
    };
    MPRemoteCommandCenter *cmd = [MPRemoteCommandCenter sharedCommandCenter];
    [cmd.playCommand setEnabled:YES];
    [cmd.pauseCommand setEnabled:YES];
    [cmd.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    [cmd.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

static void reactivateAudio(void) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *err = nil;
    [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    [session setCategory:AVAudioSessionCategoryPlayback error:nil];
    [session setActive:YES error:&err];
    if (err) {
        NSLog(@"[BGAudio] reactivate error: %@, retrying...", err);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[AVAudioSession sharedInstance] setActive:YES error:nil];
        });
    }

    // Resume SDL audio device (device ID 1 is typically the default output)
    SDL_ResumeAudioDevice_t resume = (SDL_ResumeAudioDevice_t)dlsym(RTLD_DEFAULT, "SDL_ResumeAudioDevice");
    if (resume) {
        // SDL3 uses device IDs starting from 1; try common IDs
        resume(1);
        resume(2);
        NSLog(@"[BGAudio] SDL_ResumeAudioDevice called");
    }
}

__attribute__((constructor))
static void bgaudio_init(void) {
    @autoreleasepool {
        NSLog(@"[BGAudio] === v8 loaded ===");

        // Swizzle AVAudioSession setCategory
        Class sc = [AVAudioSession class];
        Method m1 = class_getInstanceMethod(sc, @selector(setCategory:error:));
        Method m2 = class_getInstanceMethod(sc, @selector(setCategory:withOptions:error:));
        Method m3 = class_getInstanceMethod(sc, @selector(setCategory:mode:options:error:));
        if (m1) orig_setCategory1 = method_setImplementation(m1, (IMP)forced_setCategory_error);
        if (m2) orig_setCategory2 = method_setImplementation(m2, (IMP)forced_setCategory_options_error);
        if (m3) orig_setCategory3 = method_setImplementation(m3, (IMP)forced_setCategory_mode_options_error);

        // Set audio session
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (orig_setCategory1) {
            ((BOOL(*)(id,SEL,AVAudioSessionCategory,NSError**))orig_setCategory1)(
                session, @selector(setCategory:error:), AVAudioSessionCategoryPlayback, nil);
        }
        [session setActive:YES error:nil];

        // SDL hints
        SDL_SetHint_t setHint = (SDL_SetHint_t)dlsym(RTLD_DEFAULT, "SDL_SetHint");
        if (setHint) setHint("SDL_AUDIO_CATEGORY", "playback");

        // Disable background events
        SDL_SetEventEnabled_t setEvent = (SDL_SetEventEnabled_t)dlsym(RTLD_DEFAULT, "SDL_SetEventEnabled");
        if (setEvent) { setEvent(SDL_EVENT_WILL_ENTER_BACKGROUND, 0); setEvent(SDL_EVENT_DID_ENTER_BACKGROUND, 0); }

        // Post-launch setup
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                SDL_SetEventEnabled_t fn = (SDL_SetEventEnabled_t)dlsym(RTLD_DEFAULT, "SDL_SetEventEnabled");
                if (fn) { fn(SDL_EVENT_WILL_ENTER_BACKGROUND, 0); fn(SDL_EVENT_DID_ENTER_BACKGROUND, 0); }
                registerNowPlaying();

                Class appDel = [[UIApplication sharedApplication].delegate class];
                if (appDel) {
                    Method m = class_getInstanceMethod(appDel, @selector(applicationWillResignActive:));
                    if (m) method_setImplementation(m, imp_implementationWithBlock(^(id s, id a) {
                        [[AVAudioSession sharedInstance] setActive:YES error:nil];
                    }));
                }
            }];

        // Keep audio alive on resign/background
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillResignActiveNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                [[AVAudioSession sharedInstance] setActive:YES error:nil];
                registerNowPlaying();
            }];

        // Handle audio interruption (AirPods switch, phone call, etc.)
        [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionInterruptionNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
                if (type == AVAudioSessionInterruptionTypeEnded) {
                    NSLog(@"[BGAudio] Audio interruption ended - reactivating");
                    reactivateAudio();
                } else {
                    NSLog(@"[BGAudio] Audio interruption began - will recover");
                    // Schedule recovery in case we don't get the "ended" notification
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        reactivateAudio();
                    });
                }
            }];

        // Handle audio route change (AirPods connected/disconnected/switched)
        [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                NSUInteger reason = [n.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
                NSLog(@"[BGAudio] Route changed, reason=%lu", (unsigned long)reason);
                // Re-activate after a short delay to let the route settle
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    reactivateAudio();
                });
            }];
    }
}
