//
// BackgroundAudio.dylib
//
// Injected into the iOS Steam Link app so audio keeps playing when the
// device is locked or the app is backgrounded, and so AirPods Pro
// personalized Spatial Audio activates correctly.
//
// What this dylib does at constructor time:
//
//   AVAudioSession swizzles
//     -setCategory:error:                              -> Playback
//     -setCategory:withOptions:error:                  -> Playback (options sanitised*)
//     -setCategory:mode:options:error:                 -> Playback / Default (options sanitised*)
//     -setCategory:mode:routeSharingPolicy:options:error:
//                                                       -> Playback / Default /
//                                                          caller's routeSharingPolicy
//                                                          (options sanitised*)
//     -setMode:error:                                  -> Default
//     -setActive:(error|withOptions:error):            -> NO requests swallowed
//
//     * MixWithOthers and DuckOthers are stripped because both disable AirPods
//       Pro personalized Spatial Audio.  MixWithOthers can be restored with
//       the env var BGAUDIO_MIX_WITH_OTHERS=1 if you'd rather coexist with
//       Apple Music / podcasts than use Spatial Audio.
//
//   UIApplication / UIScene / CADisplayLink lies
//     -[UIApplication applicationState]          -> Active
//     -[UIApplication backgroundTimeRemaining]   -> DBL_MAX
//     -[UIScene activationState]                 -> ForegroundActive
//     -[CADisplayLink setPaused:YES]             -> no-op
//     -[CADisplayLink isPaused]                  -> NO
//
//   NSNotificationCenter post-... swizzles drop the app-backgrounding
//   notifications so SteamLink's Qt + Steam streaming pipeline never sees
//   them and never calls StopStream / OnBackground.
//
//   Scene delegate lifecycle methods (sceneWillResignActive:,
//   sceneDidEnterBackground:, applicationWillResignActive:,
//   applicationDidEnterBackground:) are replaced with no-ops on every class
//   that implements them.
//
//   On AVAudioSessionRouteChangeNotification reason=2 (OldDeviceUnavailable,
//   e.g. AirPods taken out of ear) or reason=8 (Override), the observer
//   synthesises UIApplicationWillEnterForegroundNotification +
//   UIApplicationDidBecomeActiveNotification, which is what finally kicks
//   iOS + SDL to rebind the output to the built-in speaker.
//
//   SDL hints and SDL_SetEventEnabled are poked via dlsym so SDL stops
//   emitting background events to the app code.
//
//   A silent 1 s WAV loop plays on an AVAudioPlayer to keep the output
//   pipeline alive in background.  MPNowPlayingInfoCenter is seeded so iOS
//   treats the app as a media playback session.
//
// Environment variables (settable via TrollStore Run-as etc.):
//
//   BGAUDIO_MIX_WITH_OTHERS=1   keep AVAudioSessionCategoryOptionMixWithOthers
//                               (disables AirPods Pro Spatial Audio)
//   BGAUDIO_ROUTE_POLICY=longformvideo|longformaudio|default|<int>
//                               override routeSharingPolicy (auto-detected
//                               from iOS version by default)
//   BGAUDIO_MOVIE_MODE=1        use AVAudioSessionModeMoviePlayback instead
//                               of AVAudioSessionModeDefault

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <float.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>

#define BGLOG(fmt, ...) bg_log_both((@"[BGAudio] " fmt), ##__VA_ARGS__)

// Forward declaration: defined near the bottom of the file.
static AVAudioPlayer *gSilencePlayer = nil;

// Write a line to NSLog AND append to a rolling file in Documents so it can
// be pulled off-device via Files / iTunes File Sharing on Windows.
static FILE *gLogFile = NULL;
static dispatch_queue_t gLogQueue = NULL;

static void bg_log_open(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogQueue = dispatch_queue_create("bgaudio.log", DISPATCH_QUEUE_SERIAL);
        NSArray *paths = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *dir = paths.firstObject;
        if (!dir) return;
        NSString *path = [dir stringByAppendingPathComponent:@"bgaudio.log"];
        // Truncate on each launch so the file stays small.
        gLogFile = fopen(path.UTF8String, "w");
        if (gLogFile) {
            setvbuf(gLogFile, NULL, _IOLBF, 0);
            fprintf(gLogFile, "== BackgroundAudio log (%s) ==\n", path.UTF8String);
            fflush(gLogFile);
        }
    });
}

static void bg_log_both(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void bg_log_both(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"%@", msg);

    bg_log_open();
    if (!gLogFile || !gLogQueue) return;
    NSDate *now = [NSDate date];
    NSTimeInterval t = now.timeIntervalSince1970;
    NSString *line = [NSString stringWithFormat:@"%.3f %@\n", t, msg];
    const char *cstr = line.UTF8String;
    size_t n = strlen(cstr);
    dispatch_async(gLogQueue, ^{
        if (!gLogFile) return;
        fwrite(cstr, 1, n, gLogFile);
        fflush(gLogFile);
    });
}

#pragma mark - SDL helpers (via dlsym)

typedef int  (*SDL_SetEventEnabled_t)(uint32_t type, int enabled);
typedef void (*SDL_SetHint_t)(const char *name, const char *value);

static const uint32_t SDL_EVENT_TERMINATING           = 0x101;
static const uint32_t SDL_EVENT_LOW_MEMORY            = 0x102;
static const uint32_t SDL_EVENT_WILL_ENTER_BACKGROUND = 0x103;
static const uint32_t SDL_EVENT_DID_ENTER_BACKGROUND  = 0x104;

static void disable_sdl_background_events(void) {
    SDL_SetEventEnabled_t set_enabled =
        (SDL_SetEventEnabled_t)dlsym(RTLD_DEFAULT, "SDL_SetEventEnabled");
    if (set_enabled) {
        set_enabled(SDL_EVENT_TERMINATING,           0);
        set_enabled(SDL_EVENT_LOW_MEMORY,            0);
        set_enabled(SDL_EVENT_WILL_ENTER_BACKGROUND, 0);
        set_enabled(SDL_EVENT_DID_ENTER_BACKGROUND,  0);
        BGLOG(@"SDL_SetEventEnabled(background)=0");
    } else {
        BGLOG(@"SDL_SetEventEnabled not found via dlsym");
    }
    SDL_SetHint_t set_hint = (SDL_SetHint_t)dlsym(RTLD_DEFAULT, "SDL_SetHint");
    if (set_hint) {
        set_hint("SDL_AUDIO_CATEGORY", "playback");
        set_hint("SDL_IOS_BACKGROUNDING_REMOVES_EVENTS", "1");
    }
}

#pragma mark - Core AVAudioSession enforcement

// AVAudioSessionCategoryOptionMixWithOthers disables AirPods Pro personalized
// Spatial Audio.  Default: strip it everywhere.  Override by exporting
// BGAUDIO_MIX_WITH_OTHERS=1 in the app environment before launch.
static BOOL gAllowMixWithOthers = NO;

static void bg_init_flags(void) {
    const char *v = getenv("BGAUDIO_MIX_WITH_OTHERS");
    gAllowMixWithOthers = (v && v[0] && v[0] != '0');
    BGLOG(@"flags: MixWithOthers=%@ (env=%s)",
          gAllowMixWithOthers ? @"ALLOW" : @"STRIP",
          v ? v : "unset");
}

// Normalise caller-supplied options so spatial audio isn't disabled.
// Both MixWithOthers and DuckOthers suppress AirPods Pro personalized Spatial
// Audio — iOS treats the session as a non-media mixer stream and refuses to
// spatialise it.  SDL sets both (log shows opts=0x1 then opts=0x2), so we
// strip them here.  MixWithOthers can be kept by exporting
// BGAUDIO_MIX_WITH_OTHERS=1.  DuckOthers is always stripped because there is
// no legitimate reason SteamLink needs to duck other audio at the iOS layer.
static AVAudioSessionCategoryOptions bg_fix_options(AVAudioSessionCategoryOptions opts) {
    if (!gAllowMixWithOthers) {
        opts &= ~AVAudioSessionCategoryOptionMixWithOthers;
    }
    opts &= ~AVAudioSessionCategoryOptionDuckOthers;
    return opts;
}

static void force_playback(NSString *where) {
    AVAudioSession *sess = [AVAudioSession sharedInstance];
    NSError *err = nil;
    AVAudioSessionCategoryOptions opts = bg_fix_options(0);
    [sess setCategory:AVAudioSessionCategoryPlayback
                 mode:AVAudioSessionModeDefault
              options:opts
                error:&err];
    if (err) BGLOG(@"[%@] setCategory error: %@", where, err);
    err = nil;
    [sess setActive:YES withOptions:0 error:&err];
    if (err) BGLOG(@"[%@] setActive error: %@", where, err);
    BGLOG(@"[%@] category=%@ mode=%@ options=0x%lx active",
          where, sess.category, sess.mode, (unsigned long)sess.categoryOptions);

    if (gSilencePlayer && !gSilencePlayer.isPlaying) {
        [gSilencePlayer play];
        BGLOG(@"[%@] silent player re-started", where);
    }
}

#pragma mark - AVAudioSession swizzles

static IMP orig_setCategory_error_ = NULL;
static IMP orig_setCategory_withOptions_error_ = NULL;
static IMP orig_setCategory_mode_options_error_ = NULL;
static IMP orig_setCategory_mode_routeSharingPolicy_options_error_ = NULL;
static IMP orig_setMode_error_ = NULL;
static IMP orig_setActive_error_ = NULL;
static IMP orig_setActive_withOptions_error_ = NULL;

static BOOL new_setCategory_error_(id self, SEL _cmd, NSString *cat, NSError **err) {
    typedef BOOL (*fn_t)(id, SEL, NSString *, NSError **);
    BGLOG(@"setCategory:%@  -> Playback", cat);
    return ((fn_t)orig_setCategory_error_)(self, _cmd, AVAudioSessionCategoryPlayback, err);
}

static BOOL new_setCategory_withOptions_error_(id self, SEL _cmd, NSString *cat,
                                               AVAudioSessionCategoryOptions opts, NSError **err) {
    typedef BOOL (*fn_t)(id, SEL, NSString *, AVAudioSessionCategoryOptions, NSError **);
    AVAudioSessionCategoryOptions clean = bg_fix_options(opts);
    BGLOG(@"setCategory:%@ options:0x%lx -> Playback opts:0x%lx",
          cat, (unsigned long)opts, (unsigned long)clean);
    return ((fn_t)orig_setCategory_withOptions_error_)(self, _cmd,
                                                       AVAudioSessionCategoryPlayback,
                                                       clean,
                                                       err);
}

static BOOL new_setCategory_mode_options_error_(id self, SEL _cmd, NSString *cat, NSString *mode,
                                                AVAudioSessionCategoryOptions opts, NSError **err) {
    typedef BOOL (*fn_t)(id, SEL, NSString *, NSString *, AVAudioSessionCategoryOptions, NSError **);
    AVAudioSessionCategoryOptions clean = bg_fix_options(opts);
    BGLOG(@"setCategory:%@ mode:%@ opts:0x%lx -> Playback/Default opts:0x%lx",
          cat, mode, (unsigned long)opts, (unsigned long)clean);
    return ((fn_t)orig_setCategory_mode_options_error_)(self, _cmd,
                                                        AVAudioSessionCategoryPlayback,
                                                        AVAudioSessionModeDefault,
                                                        clean,
                                                        err);
}

static BOOL new_setCategory_mode_routeSharingPolicy_options_error_(id self, SEL _cmd,
                                                                   NSString *cat, NSString *mode,
                                                                   AVAudioSessionRouteSharingPolicy policy,
                                                                   AVAudioSessionCategoryOptions opts,
                                                                   NSError **err) {
    typedef BOOL (*fn_t)(id, SEL, NSString *, NSString *,
                         AVAudioSessionRouteSharingPolicy,
                         AVAudioSessionCategoryOptions, NSError **);
    AVAudioSessionCategoryOptions clean = bg_fix_options(opts);
    // Preserve the caller's routeSharingPolicy — setting LongForm{Audio,Video}
    // is how apps opt in to AirPods Pro spatial audio for long-form content.
    BGLOG(@"setCategory:%@ mode:%@ policy:%ld opts:0x%lx -> Playback/Default policy:%ld opts:0x%lx",
          cat, mode, (long)policy, (unsigned long)opts,
          (long)policy, (unsigned long)clean);
    return ((fn_t)orig_setCategory_mode_routeSharingPolicy_options_error_)(self, _cmd,
                                                                            AVAudioSessionCategoryPlayback,
                                                                            AVAudioSessionModeDefault,
                                                                            policy,
                                                                            clean,
                                                                            err);
}

static BOOL new_setMode_error_(id self, SEL _cmd, NSString *mode, NSError **err) {
    typedef BOOL (*fn_t)(id, SEL, NSString *, NSError **);
    if (![mode isEqualToString:AVAudioSessionModeDefault]) {
        BGLOG(@"setMode:%@ -> Default", mode);
    }
    return ((fn_t)orig_setMode_error_)(self, _cmd, AVAudioSessionModeDefault, err);
}

static BOOL new_setActive_error_(id self, SEL _cmd, BOOL active, NSError **err) {
    typedef BOOL (*fn_t)(id, SEL, BOOL, NSError **);
    if (!active) {
        BGLOG(@"setActive:NO suppressed");
        return YES;  // pretend we did it
    }
    return ((fn_t)orig_setActive_error_)(self, _cmd, active, err);
}

static BOOL new_setActive_withOptions_error_(id self, SEL _cmd, BOOL active,
                                             AVAudioSessionSetActiveOptions opts, NSError **err) {
    typedef BOOL (*fn_t)(id, SEL, BOOL, AVAudioSessionSetActiveOptions, NSError **);
    if (!active) {
        BGLOG(@"setActive:NO options:0x%lx suppressed", (unsigned long)opts);
        return YES;
    }
    return ((fn_t)orig_setActive_withOptions_error_)(self, _cmd, active, opts, err);
}

static IMP swizzle(Class cls, SEL sel, IMP replacement) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP prev = method_getImplementation(m);
    method_setImplementation(m, replacement);
    return prev;
}

static void swizzle_avaudiosession(void) {
    Class cls = NSClassFromString(@"AVAudioSession");
    if (!cls) { BGLOG(@"AVAudioSession class not found"); return; }

    orig_setCategory_error_ = swizzle(cls, @selector(setCategory:error:),
                                      (IMP)new_setCategory_error_);
    orig_setCategory_withOptions_error_ = swizzle(cls, @selector(setCategory:withOptions:error:),
                                                   (IMP)new_setCategory_withOptions_error_);
    orig_setCategory_mode_options_error_ = swizzle(cls, @selector(setCategory:mode:options:error:),
                                                    (IMP)new_setCategory_mode_options_error_);
    orig_setCategory_mode_routeSharingPolicy_options_error_ = swizzle(cls,
        @selector(setCategory:mode:routeSharingPolicy:options:error:),
        (IMP)new_setCategory_mode_routeSharingPolicy_options_error_);
    orig_setMode_error_   = swizzle(cls, @selector(setMode:error:),   (IMP)new_setMode_error_);
    orig_setActive_error_ = swizzle(cls, @selector(setActive:error:), (IMP)new_setActive_error_);
    orig_setActive_withOptions_error_ = swizzle(cls, @selector(setActive:withOptions:error:),
                                                  (IMP)new_setActive_withOptions_error_);

    BGLOG(@"AVAudioSession swizzles installed");
}

#pragma mark - Kill UIApplicationDelegate lifecycle pause paths

static void noop_app_delegate(id self, SEL _cmd, UIApplication *app) {
    (void)self; (void)_cmd; (void)app;
}

static void neutralize_delegate_lifecycle(void) {
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
        id delegate = [UIApplication sharedApplication].delegate;
        if (!delegate) { BGLOG(@"no app delegate yet"); return; }
        Class dcls = object_getClass(delegate);
        SEL targets[] = {
            @selector(applicationWillResignActive:),
            @selector(applicationDidEnterBackground:),
        };
        for (size_t i = 0; i < sizeof(targets)/sizeof(targets[0]); i++) {
            Method m = class_getInstanceMethod(dcls, targets[i]);
            if (m) {
                method_setImplementation(m, (IMP)noop_app_delegate);
                BGLOG(@"neutralized -[%@ %@]",
                      NSStringFromClass(dcls), NSStringFromSelector(targets[i]));
            } else {
                class_addMethod(dcls, targets[i], (IMP)noop_app_delegate, "v@:@");
                BGLOG(@"added no-op -[%@ %@]",
                      NSStringFromClass(dcls), NSStringFromSelector(targets[i]));
            }
        }
    }];
}

#pragma mark - Now Playing / remote control (keeps the system treating us as active audio)

static void seed_now_playing(void) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle]  = @"Steam Link";
    info[MPMediaItemPropertyArtist] = @"Streaming";
    info[MPNowPlayingInfoPropertyPlaybackRate] = @1.0;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;

    MPRemoteCommandCenter *cc = [MPRemoteCommandCenter sharedCommandCenter];
    cc.playCommand.enabled = YES;
    cc.pauseCommand.enabled = YES;
    [cc.playCommand  addTargetWithHandler:^(MPRemoteCommandEvent *e){ return MPRemoteCommandHandlerStatusSuccess; }];
    [cc.pauseCommand addTargetWithHandler:^(MPRemoteCommandEvent *e){ return MPRemoteCommandHandlerStatusSuccess; }];
    BGLOG(@"MPNowPlayingInfo seeded");
}

#pragma mark - Lifecycle re-enforcement

static void install_reenforcement_observers(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSOperationQueue     *q  = [NSOperationQueue mainQueue];

    [nc addObserverForName:UIApplicationWillResignActiveNotification
                    object:nil queue:q
                usingBlock:^(NSNotification *n){ force_playback(@"willResign"); }];

    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                    object:nil queue:q
                usingBlock:^(NSNotification *n){
        force_playback(@"didEnterBG");
        // Begin a background task to maximise the chance of the OS keeping
        // the process resident long enough for audio to continue.
        UIApplication *app = [UIApplication sharedApplication];
        __block UIBackgroundTaskIdentifier tid = UIBackgroundTaskInvalid;
        tid = [app beginBackgroundTaskWithName:@"BGAudioKeepAlive"
                             expirationHandler:^{
            if (tid != UIBackgroundTaskInvalid) {
                [app endBackgroundTask:tid];
                tid = UIBackgroundTaskInvalid;
            }
        }];
    }];

    [nc addObserverForName:UIApplicationWillEnterForegroundNotification
                    object:nil queue:q
                usingBlock:^(NSNotification *n){ force_playback(@"willForeground"); }];

    [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:q
                usingBlock:^(NSNotification *n){ force_playback(@"didBecomeActive"); }];

    [nc addObserverForName:AVAudioSessionRouteChangeNotification
                    object:nil queue:q
                usingBlock:^(NSNotification *n){
        NSNumber *reason = n.userInfo[AVAudioSessionRouteChangeReasonKey];
        BGLOG(@"routeChange reason=%@", reason);
        force_playback(@"routeChange");

        NSInteger r = reason.integerValue;  // 2 = OldDeviceUnavailable
        BOOL needRebind = (r == 2 || r == 8 /* Override */);
        if (!needRebind) return;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AVAudioSession *sess = [AVAudioSession sharedInstance];

            // Diagnostic: log current output route so we can see if iOS is
            // still stuck on the disappeared device.
            NSMutableString *outs = [NSMutableString string];
            for (AVAudioSessionPortDescription *p in sess.currentRoute.outputs) {
                [outs appendFormat:@"%@/%@ ", p.portType, p.portName];
            }
            BGLOG(@"[routeChange] currentOutputs: %@", outs);

            // When AirPods are taken out of ear / disconnect while the app is
            // in background, setCategory+setActive:YES and silent-player
            // restart both fail to make iOS re-evaluate the output route —
            // it stays bound to the disappeared AirPods.  What finally
            // unsticks it is the UIApplicationDidBecomeActive notification
            // that SDL's scene-delegate path receives on foregrounding.
            // Synthesise those lifecycle notifications here; they are not
            // in our NSNotificationCenter drop-list so they reach SDL.
            UIApplication *app = [UIApplication sharedApplication];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:UIApplicationWillEnterForegroundNotification
                              object:app];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:UIApplicationDidBecomeActiveNotification
                              object:app];
            BGLOG(@"[routeChange] posted WillEnterForeground + DidBecomeActive");

            // Belt-and-braces: also restart the silent keep-alive player and
            // re-activate the session.
            if (gSilencePlayer) {
                [gSilencePlayer stop];
                gSilencePlayer.currentTime = 0;
                BOOL ok = [gSilencePlayer play];
                BGLOG(@"[routeChange] silent player stop+play -> %d", ok);
            }
            NSError *e = nil;
            [sess setActive:YES withOptions:0 error:&e];
            BGLOG(@"[routeChange] reactivate err=%@", e);
        });
    }];

    [nc addObserverForName:AVAudioSessionInterruptionNotification
                    object:nil queue:q
                usingBlock:^(NSNotification *n){
        NSNumber *type = n.userInfo[AVAudioSessionInterruptionTypeKey];
        BGLOG(@"interruption type=%@", type);
        // When interruption ends (type=1), re-enforce.  When it begins (type=0)
        // iOS deactivates our session involuntarily; we reassert as soon as the
        // run loop is clear.
        dispatch_async(dispatch_get_main_queue(), ^{ force_playback(@"interruption"); });
    }];

    BGLOG(@"lifecycle observers installed");
}

#pragma mark - UIApplication state lie

static IMP orig_UIApplication_applicationState_ = NULL;
static IMP orig_UIApplication_backgroundTimeRemaining_ = NULL;

static NSInteger new_UIApplication_applicationState_(id self, SEL _cmd) {
    // UIApplicationStateActive = 0.
    return 0;
}

static double new_UIApplication_backgroundTimeRemaining_(id self, SEL _cmd) {
    return DBL_MAX;
}

static void swizzle_uiapplication(void) {
    Class cls = NSClassFromString(@"UIApplication");
    if (!cls) { BGLOG(@"UIApplication class not found"); return; }
    orig_UIApplication_applicationState_ = swizzle(cls,
        @selector(applicationState),
        (IMP)new_UIApplication_applicationState_);
    orig_UIApplication_backgroundTimeRemaining_ = swizzle(cls,
        @selector(backgroundTimeRemaining),
        (IMP)new_UIApplication_backgroundTimeRemaining_);
    BGLOG(@"UIApplication applicationState/backgroundTimeRemaining locked to active/infinite");
}

#pragma mark - Drop resign/background notifications

static NSSet<NSString *> *gDroppedNames = nil;

static BOOL should_drop_notification(NSString *name) {
    if (!name) return NO;
    return [gDroppedNames containsObject:name];
}

typedef void (*post_name_obj_t)(id, SEL, NSString *, id);
typedef void (*post_name_obj_info_t)(id, SEL, NSString *, id, NSDictionary *);
typedef void (*post_note_t)(id, SEL, NSNotification *);

static post_name_obj_t      orig_post_name_obj       = NULL;
static post_name_obj_info_t orig_post_name_obj_info  = NULL;
static post_note_t          orig_post_note           = NULL;

static void new_post_name_obj(id self, SEL _cmd, NSString *name, id obj) {
    if (should_drop_notification(name)) {
        BGLOG(@"drop post %@", name);
        return;
    }
    orig_post_name_obj(self, _cmd, name, obj);
}

static void new_post_name_obj_info(id self, SEL _cmd, NSString *name, id obj, NSDictionary *info) {
    if (should_drop_notification(name)) {
        BGLOG(@"drop post %@ (w/userInfo)", name);
        return;
    }
    orig_post_name_obj_info(self, _cmd, name, obj, info);
}

static void new_post_note(id self, SEL _cmd, NSNotification *note) {
    if (should_drop_notification(note.name)) {
        BGLOG(@"drop post %@ (note)", note.name);
        return;
    }
    orig_post_note(self, _cmd, note);
}

static void swizzle_notification_center(void) {
    gDroppedNames = [NSSet setWithArray:@[
        UIApplicationWillResignActiveNotification,
        UIApplicationDidEnterBackgroundNotification,
        @"UISceneWillDeactivateNotification",
        @"UISceneDidEnterBackgroundNotification",
        @"UIApplicationProtectedDataWillBecomeUnavailableNotification",
        @"UISceneWillDisconnectNotification",
        @"UIWindowSceneWillDisconnectNotification",
    ]];

    Class cls = [NSNotificationCenter class];
    Method m1 = class_getInstanceMethod(cls, @selector(postNotificationName:object:));
    Method m2 = class_getInstanceMethod(cls, @selector(postNotificationName:object:userInfo:));
    Method m3 = class_getInstanceMethod(cls, @selector(postNotification:));
    if (m1) {
        orig_post_name_obj = (post_name_obj_t)method_getImplementation(m1);
        method_setImplementation(m1, (IMP)new_post_name_obj);
    }
    if (m2) {
        orig_post_name_obj_info = (post_name_obj_info_t)method_getImplementation(m2);
        method_setImplementation(m2, (IMP)new_post_name_obj_info);
    }
    if (m3) {
        orig_post_note = (post_note_t)method_getImplementation(m3);
        method_setImplementation(m3, (IMP)new_post_note);
    }
    BGLOG(@"NSNotificationCenter post swizzled; dropping: %@",
          [[gDroppedNames allObjects] componentsJoinedByString:@", "]);
}

#pragma mark - Scene delegate + CADisplayLink

static void noop_scene_method(id self, SEL _cmd, id scene) {
    (void)self; (void)_cmd; (void)scene;
}

static void neutralize_scene_delegates(void) {
    // Find every class that implements one of the scene lifecycle methods and
    // replace them with no-ops.  We do it directly on the class (not walking
    // superclasses) so UIKit's own bookkeeping isn't affected.
    SEL targets[] = {
        @selector(sceneWillResignActive:),
        @selector(sceneDidEnterBackground:),
    };
    unsigned int total = 0;
    Class *classes = objc_copyClassList(&total);
    if (!classes) return;
    int hits = 0;
    for (unsigned int i = 0; i < total; i++) {
        Class c = classes[i];
        if (!c) continue;
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(c, &mc);
        if (!ms) continue;
        for (unsigned int j = 0; j < mc; j++) {
            SEL sel = method_getName(ms[j]);
            for (size_t k = 0; k < sizeof(targets)/sizeof(targets[0]); k++) {
                if (sel_isEqual(sel, targets[k])) {
                    method_setImplementation(ms[j], (IMP)noop_scene_method);
                    BGLOG(@"neutralized -[%s %s]",
                          class_getName(c), sel_getName(sel));
                    hits++;
                }
            }
        }
        free(ms);
    }
    free(classes);
    BGLOG(@"scene delegate methods neutralized on %d entry(s)", hits);
}

static IMP orig_CADisplayLink_setPaused_ = NULL;
static IMP orig_CADisplayLink_paused_ = NULL;

static void new_CADisplayLink_setPaused_(id self, SEL _cmd, BOOL paused) {
    typedef void (*fn_t)(id, SEL, BOOL);
    if (paused) {
        BGLOG(@"CADisplayLink setPaused:YES suppressed on %p", self);
        return;  // never pause
    }
    ((fn_t)orig_CADisplayLink_setPaused_)(self, _cmd, paused);
}

static BOOL new_CADisplayLink_paused_(id self, SEL _cmd) {
    return NO;  // always report running
}

static void swizzle_cadisplaylink(void) {
    Class cls = NSClassFromString(@"CADisplayLink");
    if (!cls) { BGLOG(@"CADisplayLink class not found"); return; }
    orig_CADisplayLink_setPaused_ = swizzle(cls, @selector(setPaused:),
                                             (IMP)new_CADisplayLink_setPaused_);
    orig_CADisplayLink_paused_    = swizzle(cls, @selector(isPaused),
                                             (IMP)new_CADisplayLink_paused_);
    BGLOG(@"CADisplayLink setPaused:/isPaused swizzled");
}

#pragma mark - UIScene.activationState lie

static IMP orig_UIScene_activationState_ = NULL;

static NSInteger new_UIScene_activationState_(id self, SEL _cmd) {
    // UISceneActivationStateForegroundActive = 1
    return 1;
}

static void swizzle_uiscene(void) {
    Class cls = NSClassFromString(@"UIScene");
    if (!cls) { BGLOG(@"UIScene class not found"); return; }
    orig_UIScene_activationState_ = swizzle(cls,
        @selector(activationState),
        (IMP)new_UIScene_activationState_);
    BGLOG(@"UIScene activationState locked to ForegroundActive");
}

#pragma mark - Heartbeat + silent keep-alive player

// A timer that logs once a second.  If logs stop during lock, the process is
// being suspended by iOS.  If they continue, the process is alive and the
// issue is in Steam Link's audio pipeline instead.
static dispatch_source_t gHeartbeat = NULL;

static void start_heartbeat(void) {
    dispatch_queue_t q = dispatch_queue_create("bgaudio.heartbeat", DISPATCH_QUEUE_SERIAL);
    gHeartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(gHeartbeat, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC/10);
    __block uint64_t tick = 0;
    dispatch_source_set_event_handler(gHeartbeat, ^{
        tick++;
        BGLOG(@"tick %llu", tick);
    });
    dispatch_resume(gHeartbeat);
    BGLOG(@"heartbeat started (1 Hz)");
}

// Build a tiny silent WAV in-memory (1 second, 8 kHz, 16-bit mono, all zeros).
static NSData *build_silent_wav(void) {
    const uint32_t sampleRate = 8000;
    const uint16_t channels   = 1;
    const uint16_t bits       = 16;
    const uint32_t numSamples = sampleRate;  // 1 s
    const uint32_t dataBytes  = numSamples * channels * (bits / 8);
    const uint32_t byteRate   = sampleRate * channels * (bits / 8);
    const uint16_t blockAlign = channels * (bits / 8);
    NSMutableData *d = [NSMutableData dataWithCapacity:44 + dataBytes];
    // RIFF header
    [d appendBytes:"RIFF" length:4];
    uint32_t riffSize = 36 + dataBytes;
    [d appendBytes:&riffSize length:4];
    [d appendBytes:"WAVE" length:4];
    // fmt  chunk
    [d appendBytes:"fmt " length:4];
    uint32_t fmtSize = 16;     [d appendBytes:&fmtSize    length:4];
    uint16_t audioFmt = 1;     [d appendBytes:&audioFmt   length:2];  // PCM
    [d appendBytes:&channels   length:2];
    [d appendBytes:&sampleRate length:4];
    [d appendBytes:&byteRate   length:4];
    [d appendBytes:&blockAlign length:2];
    [d appendBytes:&bits       length:2];
    // data chunk
    [d appendBytes:"data" length:4];
    [d appendBytes:&dataBytes  length:4];
    char zero = 0;
    for (uint32_t i = 0; i < dataBytes; i++) [d appendBytes:&zero length:1];
    return d;
}

static void start_silent_keepalive(void) {
    NSError *err = nil;
    NSData *wav = build_silent_wav();
    gSilencePlayer = [[AVAudioPlayer alloc] initWithData:wav error:&err];
    if (!gSilencePlayer || err) {
        BGLOG(@"silent player init failed: %@", err);
        return;
    }
    gSilencePlayer.numberOfLoops = -1;  // infinite
    gSilencePlayer.volume = 0.001f;     // effectively silent but not muted
    [gSilencePlayer prepareToPlay];
    BOOL ok = [gSilencePlayer play];
    BGLOG(@"silent keep-alive player started: %d", ok);
}

#pragma mark - Entry point

__attribute__((constructor))
static void BGAudio_load(void) {
    @autoreleasepool {
        BGLOG(@"BackgroundAudio loaded");
        bg_init_flags();
        setenv("SDL_AUDIO_CATEGORY", "playback", 1);

        swizzle_avaudiosession();
        swizzle_uiapplication();
        swizzle_uiscene();
        swizzle_cadisplaylink();
        // Deliberately do NOT neutralize SDL's -[...audioSessionInterruption:]:
        // iOS-sent Interruption Ended events (AirPods re-inserted, Siri
        // dismissed, phone call ended, etc.) need to reach SDL so it re-
        // engages the RemoteIO audio unit.  Background-pause code paths are
        // already blocked by the SDL3 binary RET patches, so the selector
        // neutralisation was redundant anyway.
        neutralize_scene_delegates();
        disable_sdl_background_events();
        force_playback(@"load");
        start_silent_keepalive();
        seed_now_playing();
        neutralize_delegate_lifecycle();
        install_reenforcement_observers();
        swizzle_notification_center();
        start_heartbeat();

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            neutralize_scene_delegates();
            // Reassert the silent keep-alive after app launch, in case SDL
            // restarted the session.
            if (gSilencePlayer && !gSilencePlayer.isPlaying) {
                BGLOG(@"restarting silent keep-alive after didFinishLaunching");
                [gSilencePlayer play];
            }
        }];
    }
}
