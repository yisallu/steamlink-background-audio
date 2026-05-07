// BackgroundAudio.m - Steam Link Background Audio Tweak v10
//
// Key fix: Play a silent AVAudioPlayer loop to keep iOS speaker output
// alive on lock screen. iOS mutes AudioQueue-based audio on lock unless
// a high-level audio player (AVAudioPlayer/AVPlayer) is also active.

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

static AVAudioPlayer *silentPlayer = nil;

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

static void startSilentAudio(void) {
    if (silentPlayer && silentPlayer.isPlaying) return;

    // Generate 1 second of silence as WAV in memory
    int sampleRate = 44100;
    int numSamples = sampleRate; // 1 second
    int dataSize = numSamples * 2; // 16-bit mono
    int fileSize = 44 + dataSize;

    NSMutableData *wav = [NSMutableData dataWithLength:fileSize];
    uint8_t *b = (uint8_t *)wav.mutableBytes;

    // WAV header
    memcpy(b, "RIFF", 4);
    *(uint32_t *)(b + 4) = fileSize - 8;
    memcpy(b + 8, "WAVE", 4);
    memcpy(b + 12, "fmt ", 4);
    *(uint32_t *)(b + 16) = 16; // chunk size
    *(uint16_t *)(b + 20) = 1;  // PCM
    *(uint16_t *)(b + 22) = 1;  // mono
    *(uint32_t *)(b + 24) = sampleRate;
    *(uint32_t *)(b + 28) = sampleRate * 2; // byte rate
    *(uint16_t *)(b + 32) = 2;  // block align
    *(uint16_t *)(b + 34) = 16; // bits per sample
    memcpy(b + 36, "data", 4);
    *(uint32_t *)(b + 40) = dataSize;
    // samples are all zero = silence

    NSError *err = nil;
    silentPlayer = [[AVAudioPlayer alloc] initWithData:wav error:&err];
    if (err) {
        NSLog(@"[BGAudio] Silent player error: %@", err);
        return;
    }
    silentPlayer.numberOfLoops = -1; // infinite loop
    silentPlayer.volume = 0.01; // near-silent
    [silentPlayer play];
    NSLog(@"[BGAudio] Silent audio player started");
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
        NSLog(@"[BGAudio] === v10 loaded ===");

        // Swizzle setCategory
        Class sc = [AVAudioSession class];
        Method m1 = class_getInstanceMethod(sc, @selector(setCategory:error:));
        Method m2 = class_getInstanceMethod(sc, @selector(setCategory:withOptions:error:));
        Method m3 = class_getInstanceMethod(sc, @selector(setCategory:mode:options:error:));
        if (m1) orig_setCategory1 = method_setImplementation(m1, (IMP)forced_setCategory_error);
        if (m2) orig_setCategory2 = method_setImplementation(m2, (IMP)forced_setCategory_options_error);
        if (m3) orig_setCategory3 = method_setImplementation(m3, (IMP)forced_setCategory_mode_options_error);

        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (orig_setCategory1) {
            ((BOOL(*)(id,SEL,AVAudioSessionCategory,NSError**))orig_setCategory1)(
                session, @selector(setCategory:error:), AVAudioSessionCategoryPlayback, nil);
        }
        [session setActive:YES error:nil];

        SDL_SetHint_t setHint = (SDL_SetHint_t)dlsym(RTLD_DEFAULT, "SDL_SetHint");
        if (setHint) setHint("SDL_AUDIO_CATEGORY", "playback");

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                SDL_SetEventEnabled_t fn = (SDL_SetEventEnabled_t)dlsym(RTLD_DEFAULT, "SDL_SetEventEnabled");
                if (fn) { fn(SDL_EVENT_WILL_ENTER_BACKGROUND, 0); fn(SDL_EVENT_DID_ENTER_BACKGROUND, 0); }

                registerNowPlaying();
                startSilentAudio();

                Class appDel = [[UIApplication sharedApplication].delegate class];
                if (appDel) {
                    Method m = class_getInstanceMethod(appDel, @selector(applicationWillResignActive:));
                    if (m) method_setImplementation(m, imp_implementationWithBlock(^(id s, id a) {
                        [[AVAudioSession sharedInstance] setActive:YES error:nil];
                        startSilentAudio();
                    }));
                }
            }];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillResignActiveNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                [[AVAudioSession sharedInstance] setActive:YES error:nil];
                startSilentAudio();
            }];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionInterruptionNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
                if (type == AVAudioSessionInterruptionTypeEnded) {
                    [[AVAudioSession sharedInstance] setActive:YES error:nil];
                    startSilentAudio();
                }
            }];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioSessionRouteChangeNotification
            object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [[AVAudioSession sharedInstance] setActive:YES error:nil];
                    startSilentAudio();
                });
            }];
    }
}
