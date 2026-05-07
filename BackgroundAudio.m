// BackgroundAudio.m - Steam Link Background Audio Tweak v9
//
// - Background/lock screen audio
// - Fix audio route change (AirPods switch, speaker/headphone toggle)
//   by calling SDL_ResumeAudioStreamDevice after route settles

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
// SDL3: SDL_GetAudioPlaybackDevices(int *count) returns SDL_AudioDeviceID*
typedef uint32_t* (*SDL_GetAudioPlaybackDevices_t)(int *count);
typedef int (*SDL_ResumeAudioDevice_t)(uint32_t devid);
typedef void (*SDL_free_t)(void *mem);

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

static void resumeAllSDLAudio(void) {
    // Get all playback devices and resume them
    SDL_GetAudioPlaybackDevices_t getDevices = (SDL_GetAudioPlaybackDevices_t)dlsym(RTLD_DEFAULT, "SDL_GetAudioPlaybackDevices");
    SDL_ResumeAudioDevice_t resume = (SDL_ResumeAudioDevice_t)dlsym(RTLD_DEFAULT, "SDL_ResumeAudioDevice");
    SDL_free_t sdl_free = (SDL_free_t)dlsym(RTLD_DEFAULT, "SDL_free");

    if (getDevices && resume) {
        int count = 0;
        uint32_t *devices = getDevices(&count);
        if (devices) {
            for (int i = 0; i < count; i++) {
                resume(devices[i]);
                NSLog(@"[BGAudio] Resumed audio device %u", devices[i]);
            }
            if (sdl_free) sdl_free(devices);
        }
    }

    // Also try the opened device (SDL3 opened devices have IDs starting from 2^0+1)
    if (resume) {
        // Opened devices in SDL3 are separate from physical devices
        // Try common opened device IDs
        resume(1);
    }
}

static void registerNowPlaying(void) {
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    center.nowPlayingInfo = @{
        MPMediaItemPropertyTitle: @"Steam Link",
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

__attribute__((constructor))
static void bgaudio_init(void) {
    @autoreleasepool {
        NSLog(@"[BGAudio] === v9 loaded ===");

        // Swizzle AVAudioSession setCategory to force Playback
        Class sc = [AVAudioSession class];
        Method m1 = class_getInstanceMethod(sc, @selector(setCategory:error:));
        Method m2 = class_getInstanceMethod(sc, @selector(setCategory:withOptions:error:));
        Method m3 = class_getInstanceMethod(sc, @selector(setCategory:mode:options:error:));
        if (m1) orig_setCategory1 = method_setImplementation(m1, (IMP)forced_setCategory_error);
        if (m2) orig_setCategory2 = method_setImplementation(m2, (IMP)forced_setCategory_options_error);
        if (m3) orig_setCategory3 = method_setImplementation(m3, (IMP)forced_setCategory_mode_options_error);

        // Initial audio session setup
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (orig_setCategory1) {
            ((BOOL(*)(id,SEL,AVAudioSessionCategory,NSError**))orig_setCategory1)(
                session, @selector(setCategory:error:), AVAudioSessionCategoryPlayback, nil);
        }
        [session setActive:YES error:nil];

        SDL_SetHint_t setHint = (SDL_SetHint_t)dlsym(RTLD_DEFAULT, "SDL_SetHint");
        if (setHint) setHint("SDL_AUDIO_CATEGORY", "playback");

        // Post-launch
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

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillResignActiveNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                [[AVAudioSession sharedInstance] setActive:YES error:nil];
            }];

        // Audio interruption: let SDL handle it, but ensure recovery
        [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionInterruptionNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
                if (type == AVAudioSessionInterruptionTypeEnded) {
                    NSLog(@"[BGAudio] Interruption ended, recovering audio");
                    [[AVAudioSession sharedInstance] setActive:YES error:nil];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        resumeAllSDLAudio();
                    });
                }
            }];

        // Audio route change: recover after switch
        [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                NSUInteger reason = [n.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
                NSLog(@"[BGAudio] Route change reason=%lu", (unsigned long)reason);
                // Reactivate and resume after route settles
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [[AVAudioSession sharedInstance] setActive:YES error:nil];
                    resumeAllSDLAudio();
                });
            }];
    }
}
