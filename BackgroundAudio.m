// BackgroundAudio.m - Steam Link Background Audio Tweak v7
//
// Nuclear option: swizzle AVAudioSession's setCategory methods to ALWAYS
// force Playback category, regardless of what SDL or the app requests.
// Also register MPNowPlayingInfoCenter.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#define SDL_EVENT_WILL_ENTER_BACKGROUND 0x102
#define SDL_EVENT_DID_ENTER_BACKGROUND  0x103

typedef void (*SDL_SetEventEnabled_t)(uint32_t type, int enabled);

static IMP orig_setCategory1 = NULL;
static IMP orig_setCategory2 = NULL;
static IMP orig_setCategory3 = NULL;

// Force all setCategory calls to use Playback
static BOOL forced_setCategory_error(id self, SEL _cmd, AVAudioSessionCategory cat, NSError **err) {
    NSLog(@"[BGAudio] setCategory:%@ -> forcing Playback", cat);
    return ((BOOL(*)(id,SEL,AVAudioSessionCategory,NSError**))orig_setCategory1)(
        self, _cmd, AVAudioSessionCategoryPlayback, err);
}

static BOOL forced_setCategory_options_error(id self, SEL _cmd, AVAudioSessionCategory cat,
                                              AVAudioSessionCategoryOptions opts, NSError **err) {
    NSLog(@"[BGAudio] setCategory:%@ options:%lu -> forcing Playback", cat, (unsigned long)opts);
    return ((BOOL(*)(id,SEL,AVAudioSessionCategory,AVAudioSessionCategoryOptions,NSError**))orig_setCategory2)(
        self, _cmd, AVAudioSessionCategoryPlayback, 0, err);
}

static BOOL forced_setCategory_mode_options_error(id self, SEL _cmd, AVAudioSessionCategory cat,
                                                   AVAudioSessionMode mode,
                                                   AVAudioSessionCategoryOptions opts, NSError **err) {
    NSLog(@"[BGAudio] setCategory:%@ mode:%@ options:%lu -> forcing Playback", cat, mode, (unsigned long)opts);
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

__attribute__((constructor))
static void bgaudio_init(void) {
    @autoreleasepool {
        NSLog(@"[BGAudio] === v7 loaded ===");

        // 1. Swizzle ALL AVAudioSession setCategory: variants
        Class sessionClass = [AVAudioSession class];

        Method m1 = class_getInstanceMethod(sessionClass, @selector(setCategory:error:));
        Method m2 = class_getInstanceMethod(sessionClass, @selector(setCategory:withOptions:error:));
        Method m3 = class_getInstanceMethod(sessionClass, @selector(setCategory:mode:options:error:));

        if (m1) { orig_setCategory1 = method_setImplementation(m1, (IMP)forced_setCategory_error); }
        if (m2) { orig_setCategory2 = method_setImplementation(m2, (IMP)forced_setCategory_options_error); }
        if (m3) { orig_setCategory3 = method_setImplementation(m3, (IMP)forced_setCategory_mode_options_error); }

        // 2. Set it now
        AVAudioSession *session = [AVAudioSession sharedInstance];
        // Call the original directly to avoid our own hook
        if (orig_setCategory1) {
            ((BOOL(*)(id,SEL,AVAudioSessionCategory,NSError**))orig_setCategory1)(
                session, @selector(setCategory:error:), AVAudioSessionCategoryPlayback, nil);
        }
        [session setActive:YES error:nil];

        // 3. Disable SDL background events
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                SDL_SetEventEnabled_t fn = (SDL_SetEventEnabled_t)dlsym(RTLD_DEFAULT, "SDL_SetEventEnabled");
                if (fn) { fn(SDL_EVENT_WILL_ENTER_BACKGROUND, 0); fn(SDL_EVENT_DID_ENTER_BACKGROUND, 0); }

                registerNowPlaying();

                // Swizzle AppDelegate
                Class appDel = [[UIApplication sharedApplication].delegate class];
                if (appDel) {
                    Method m = class_getInstanceMethod(appDel, @selector(applicationWillResignActive:));
                    if (m) method_setImplementation(m, imp_implementationWithBlock(^(id s, id a) {}));
                }
                NSLog(@"[BGAudio] Post-launch complete");
            }];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillResignActiveNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                [[AVAudioSession sharedInstance] setActive:YES error:nil];
                registerNowPlaying();
            }];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionInterruptionNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                [[AVAudioSession sharedInstance] setActive:YES error:nil];
            }];
    }
}
