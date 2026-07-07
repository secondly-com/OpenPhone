#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#import <dlfcn.h>
#import <errno.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <stdarg.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <notify.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

static NSString *const OPVTPreferencesId = @"com.openphone.volumetrigger";
static NSString *const OPVTPreferencesPath = @"/var/mobile/Library/Preferences/com.openphone.volumetrigger.plist";
static NSString *const OPVTDefaultTriggerGoal = @"Use the current phone context to handle this hardware volume trigger as an immediate OpenPhone agent turn. Inspect the visible state, act only when the next useful phone action is clear, otherwise finish with a concise status.";
static NSString *const OPVTLegacyTriggerGoal = @"Handle the OpenPhone hardware volume trigger using the current phone context.";
static const char *OPVTSocketPath = "/var/mobile/Library/OpenPhone/run/agentd.sock";
static const char *OPVTLogPath = "/var/mobile/Library/OpenPhone/openphone-volume-trigger.log";
static NSString *const OPVTStorePath = @"/var/mobile/Library/OpenPhone";
static NSString *const OPVTSpringBoardStateDir = @"/var/mobile/Library/OpenPhone/springboard";
static NSString *const OPVTSpringBoardStatePath = @"/var/mobile/Library/OpenPhone/springboard/state.json";
static NSString *const OPVTScreenshotsDir = @"/var/mobile/Library/OpenPhone/screenshots";
static NSString *const OPVTScreenshotRequestPath = @"/var/mobile/Library/OpenPhone/springboard/screenshot-request.json";
static NSString *const OPVTScreenshotResponsePath = @"/var/mobile/Library/OpenPhone/springboard/screenshot-response.json";
static NSString *const OPVTInputRequestPath = @"/var/mobile/Library/OpenPhone/springboard/input-request.json";
static NSString *const OPVTInputResponsePath = @"/var/mobile/Library/OpenPhone/springboard/input-response.json";
static NSString *const OPVTClipboardRequestPath = @"/var/mobile/Library/OpenPhone/springboard/clipboard-request.json";
static NSString *const OPVTClipboardResponsePath = @"/var/mobile/Library/OpenPhone/springboard/clipboard-response.json";
static NSString *const OPVTPromptRequestPath = @"/var/mobile/Library/OpenPhone/springboard/prompt-request.json";
static NSString *const OPVTPromptResponsePath = @"/var/mobile/Library/OpenPhone/springboard/prompt-response.json";
static NSString *const OPVTTriggerStatusPath = @"/var/mobile/Library/OpenPhone/springboard/trigger-status.json";

static CFAbsoluteTime OPVTLastUp = 0;
static CFAbsoluteTime OPVTLastDown = 0;
static CFAbsoluteTime OPVTLastTrigger = 0;
static CFAbsoluteTime OPVTLastUpLog = 0;
static CFAbsoluteTime OPVTLastDownLog = 0;
static long long OPVTButtonEventCount = 0;
static long long OPVTComboEventCount = 0;
static long long OPVTLastButtonEventMs = 0;
static long long OPVTLastComboEventMs = 0;
static NSString *OPVTLastButtonEventName = nil;
static NSString *OPVTLastButtonEventSource = nil;
static NSString *OPVTLastTriggerRoute = nil;
static UIWindow *OPVTOverlayWindow = nil;
static UIWindow *OPVTPromptWindow = nil;
static NSString *OPVTIslandCurrentMode = @"idle";
static void OPVTIslandApplyState(NSDictionary *state);
static BOOL OPVTPromptVisible = NO;
static id OPVTVolumeNotificationObserverObject = nil;
static BOOL OPVTVolumeNotificationInstalled = NO;
static long long OPVTVolumeNotificationEventCount = 0;
static long long OPVTLastVolumeNotificationMs = 0;
static double OPVTLastSystemVolume = -1.0;
static NSString *OPVTLastVolumeNotificationReason = nil;
static NSString *OPVTLastVolumeNotificationCategory = nil;
static NSString *OPVTLastVolumeNotificationDirection = nil;
static int OPVTStatePublishSuccessCount = 0;
static int OPVTStatePublishFailureCount = 0;
static pthread_mutex_t OPVTForegroundCacheLock = PTHREAD_MUTEX_INITIALIZER;
static NSString *OPVTLastForegroundBundleId = nil;
static NSString *OPVTLastForegroundSource = nil;
static long long OPVTLastForegroundAtMs = 0;

typedef struct {
    const char *className;
    const char *selectorName;
    BOOL volumeUp;
    IMP original;
    BOOL hooked;
} OPVTHookSpec;

typedef struct {
    const char *className;
    const char *selectorName;
    BOOL volumeUp;
    IMP original;
    BOOL hooked;
} OPVTFixedArgHookSpec;

typedef struct {
    const char *className;
    const char *selectorName;
    IMP original;
    BOOL hooked;
} OPVTBoolArgHookSpec;

typedef struct {
    const char *className;
    const char *selectorName;
    BOOL secondArgumentMeansDown;
    IMP original;
    BOOL hooked;
} OPVTBoolPairHookSpec;

typedef struct {
    const char *className;
    const char *selectorName;
    IMP original;
    BOOL hooked;
} OPVTButtonObjectVoidHookSpec;

typedef struct {
    const char *className;
    const char *selectorName;
    IMP original;
    BOOL hooked;
} OPVTButtonObjectBoolHookSpec;

typedef struct {
    const char *className;
    const char *selectorName;
    IMP original;
    BOOL hooked;
} OPVTButtonRawHIDVoidHookSpec;

typedef struct {
    const char *className;
    const char *selectorName;
    IMP original;
    BOOL hooked;
} OPVTForegroundNoArgObjectHookSpec;

typedef struct {
    const char *className;
    const char *selectorName;
    IMP original;
    BOOL hooked;
} OPVTForegroundObjectArgVoidHookSpec;

typedef struct {
    const char *className;
    const char *selectorName;
    IMP original;
    BOOL hooked;
} OPVTForegroundObjectArgObjectHookSpec;

typedef struct {
    const char *className;
    const char *selectorName;
    IMP original;
    BOOL hooked;
} OPVTForegroundNoArgBoolHookSpec;

static void OPVTVolumeNoArgReplacement(id self, SEL _cmd);
static void OPVTVolumeFixedArgReplacement(id self, SEL _cmd, uintptr_t arg);
static void OPVTVolumeBoolArgReplacement(id self, SEL _cmd, BOOL increase);
static void OPVTVolumeBoolPairReplacement(id self, SEL _cmd, BOOL increase, uintptr_t second);
static void OPVTButtonObjectVoidReplacement(id self, SEL _cmd, id event);
static BOOL OPVTButtonObjectBoolReplacement(id self, SEL _cmd, id event);
static void OPVTButtonRawHIDVoidReplacement(id self, SEL _cmd, void *event);
static id OPVTForegroundNoArgObjectReplacement(id self, SEL _cmd);
static void OPVTForegroundObjectArgVoidReplacement(id self, SEL _cmd, id arg);
static id OPVTForegroundObjectArgObjectReplacement(id self, SEL _cmd, id arg);
static BOOL OPVTForegroundNoArgBoolReplacement(id self, SEL _cmd);
static BOOL OPVTShouldLogHookMiss(NSString *phase);
static void OPVTRecordButtonFromSource(BOOL volumeUp, NSString *source);
static void OPVTPresentTriggerPrompt(void);
static void OPVTCallDaemonVoiceAgent(void);
static void OPVTCallAgentWithGoal(NSString *requestedGoal, BOOL userProvidedGoal);
static void OPVTPublishTriggerStatus(NSString *eventName, NSDictionary *extra);
static void OPVTInstallVolumeNotificationObserver(void);
static void OPVTHandleSystemVolumeNotification(NSNotification *notification);
static BOOL OPVTMethodReturnTypeStartsWith(Method method, char expected);
static BOOL OPVTMethodReturnTypeLooksBool(Method method);
static BOOL OPVTMethodArgumentTypeLooksObject(Method method, unsigned int index);

@interface OPVTVolumeNotificationObserver : NSObject
- (void)openphoneSystemVolumeDidChange:(NSNotification *)notification;
@end

static OPVTHookSpec OPVTHookSpecs[] = {
    {"SBVolumeControl", "increaseVolume", YES, NULL, NO},
    {"SBVolumeControl", "decreaseVolume", NO, NULL, NO},
    {"VolumeControl", "increaseVolume", YES, NULL, NO},
    {"VolumeControl", "decreaseVolume", NO, NULL, NO},
    {"SBMediaController", "increaseVolume", YES, NULL, NO},
    {"SBMediaController", "decreaseVolume", NO, NULL, NO},
    {"MPVolumeController", "increaseVolume", YES, NULL, NO},
    {"MPVolumeController", "decreaseVolume", NO, NULL, NO},
    {"SBVolumeHardwareButtonActions", "volumeIncreasePressUp", YES, NULL, NO},
    {"SBVolumeHardwareButtonActions", "volumeDecreasePressUp", NO, NULL, NO},
    {"SBVolumeHardwareButtonActions", "_handleVolumeIncreaseUp", YES, NULL, NO},
    {"SBVolumeHardwareButtonActions", "_handleVolumeDecreaseUp", NO, NULL, NO},
    {"SBSystemApertureController", "handleVolumeUpButtonPress", YES, NULL, NO},
    {"SBSystemApertureController", "handleVolumeDownButtonPress", NO, NULL, NO},
    {"SBSystemApertureSceneElement", "handleVolumeUpButtonPress", YES, NULL, NO},
    {"SBSystemApertureSceneElement", "handleVolumeDownButtonPress", NO, NULL, NO},
    {"SBTransientOverlayScenePresenter", "handleVolumeUpButtonPress", YES, NULL, NO},
    {"SBTransientOverlayScenePresenter", "handleVolumeDownButtonPress", NO, NULL, NO},
    {"SBDashBoardLockScreenEnvironment", "handleVolumeUpButtonPress", YES, NULL, NO},
    {"SBDashBoardLockScreenEnvironment", "handleVolumeDownButtonPress", NO, NULL, NO},
    {"SBBannerManager", "handleVolumeUpButtonPress", YES, NULL, NO},
    {"SBBannerManager", "handleVolumeDownButtonPress", NO, NULL, NO},
};

static OPVTFixedArgHookSpec OPVTFixedArgHookSpecs[] = {
    {"SBVolumeHardwareButtonActions", "volumeIncreasePressDownWithModifiers:", YES, NULL, NO},
    {"SBVolumeHardwareButtonActions", "volumeDecreasePressDownWithModifiers:", NO, NULL, NO},
};

static OPVTBoolArgHookSpec OPVTBoolArgHookSpecs[] = {
    {"SBVolumeHardwareButtonActions", "_handleVolumeButtonUpForIncrease:", NULL, NO},
    {"SBVolumeHardwareButtonActions", "_sendVolumeButtonDownToLegacyRegisteredClientsForIncrease:", NULL, NO},
    {"SBVolumeHardwareButtonActions", "_sendVolumeButtonDownToSBUIControllerForIncrease:", NULL, NO},
    {"SBVolumeHardwareButtonActions", "_sendVolumeButtonDownToSpringBoardInternalUIForIncrease:", NULL, NO},
};

static OPVTBoolPairHookSpec OPVTBoolPairHookSpecs[] = {
    {"SBVolumeHardwareButtonActions", "_handleVolumeButtonDownForIncrease:modifiers:", NO, NULL, NO},
    {"SBVolumeHardwareButtonActions", "_sendVolumeButtonToSBUIControllerForIncrease:down:", YES, NULL, NO},
};

static OPVTButtonObjectVoidHookSpec OPVTButtonObjectVoidHookSpecs[] = {
    {"SBNCSoundController", "_hardwareButtonPressed:", NULL, NO},
    {"SBCameraHardwareButtonStudyLogger", "logButtonEvent:", NULL, NO},
};

static OPVTButtonObjectBoolHookSpec OPVTButtonObjectBoolHookSpecs[] = {
    {"SBHomeScreenOverlayController", "wouldHandleButtonEvent:", NULL, NO},
    {"SBLiftToWakeManager", "wouldHandleButtonEvent:", NULL, NO},
    {"SBDashBoardBiometricUnlockController", "wouldHandleButtonEvent:", NULL, NO},
    {"SBRemoteTransientOverlaySession", "hasPendingButtonEvents:", NULL, NO},
};

static OPVTButtonRawHIDVoidHookSpec OPVTButtonRawHIDVoidHookSpecs[] = {
    {"SBCameraHardwareButtonStudyLogger", "logButtonEvent:", NULL, NO},
};

static OPVTForegroundNoArgObjectHookSpec OPVTForegroundNoArgObjectHookSpecs[] = {
    {"AXSpringBoardServerSideAppManager", "_activeApplicationBundleIdentifiers", NULL, NO},
    {"AXSpringBoardServerSideAppManager", "sceneLayoutState", NULL, NO},
    {"AXSpringBoardServer", "focusedOccludedAppScenes", NULL, NO},
};

static OPVTForegroundObjectArgVoidHookSpec OPVTForegroundObjectArgVoidHookSpecs[] = {
    {"AXSpringBoardServerHelper", "updateFrontMostApplicationWithServerInstance:", NULL, NO},
    {"AXSpringBoardServerHelper", "launchApplication:", NULL, NO},
    {"AXSpringBoardServerSideAppManager", "launchApplication:", NULL, NO},
};

static OPVTForegroundObjectArgObjectHookSpec OPVTForegroundObjectArgObjectHookSpecs[] = {
    {"AXSpringBoardServerHelper", "frontmostAppProcessWithServerInstance:", NULL, NO},
};

static OPVTForegroundNoArgBoolHookSpec OPVTForegroundNoArgBoolHookSpecs[] = {
    {"SBApplicationProcessState", "isForeground", NULL, NO},
};

static void OPVTLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [formatter stringFromDate:[NSDate date]], message ?: @""];
    FILE *file = fopen(OPVTLogPath, "a");
    if (file) {
        fputs(line.UTF8String, file);
        fclose(file);
    }
    NSLog(@"[OpenPhoneVolumeTrigger] %@", message ?: @"");
}

static NSDictionary *OPVTPreferences(void) {
    CFPreferencesAppSynchronize((CFStringRef)OPVTPreferencesId);
    NSDictionary *preferences = (__bridge_transfer NSDictionary *)CFPreferencesCopyMultiple(
            NULL, (CFStringRef)OPVTPreferencesId, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    NSDictionary *filePreferences = [NSDictionary dictionaryWithContentsOfFile:OPVTPreferencesPath];
    if (filePreferences.count == 0) {
        return preferences ?: @{};
    }
    NSMutableDictionary *merged = [preferences mutableCopy] ?: [NSMutableDictionary dictionary];
    [merged addEntriesFromDictionary:filePreferences];
    return merged;
}

static BOOL OPVTBoolPreference(NSString *key, BOOL defaultValue) {
    id value = OPVTPreferences()[key];
    return value ? [value boolValue] : defaultValue;
}

static NSTimeInterval OPVTMillisecondsPreference(NSString *key,
        double defaultMs, double minMs, double maxMs) {
    id value = OPVTPreferences()[key];
    double ms = value ? [value doubleValue] : defaultMs;
    if (ms < minMs) {
        ms = minMs;
    }
    if (ms > maxMs) {
        ms = maxMs;
    }
    return ms / 1000.0;
}

static NSString *OPVTStringPreference(NSString *key, NSString *defaultValue) {
    id value = OPVTPreferences()[key];
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
        return value;
    }
    return defaultValue ?: @"";
}

static BOOL OPVTEnabled(void) {
    return OPVTBoolPreference(@"Enabled", YES);
}

static BOOL OPVTPromptForGoalEnabled(void) {
    return OPVTBoolPreference(@"PromptForGoal", YES);
}

static BOOL OPVTDaemonVoiceAgentEnabled(void) {
    return OPVTBoolPreference(@"DaemonVoiceAgent", YES);
}

static NSString *OPVTTrimmedString(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) {
        return @"";
    }
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

static long long OPVTNowMs(void) {
    return (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

static NSDictionary *OPVTReadJSONDictionary(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path ?: @""];
    if (data.length == 0) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static BOOL OPVTWriteJSONDictionary(NSString *path, NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object ?: @{}
                                                   options:0
                                                     error:nil];
    if (data.length == 0 || path.length == 0) {
        return NO;
    }
    BOOL wrote = [data writeToFile:path atomically:YES];
    if (wrote) {
        chmod(path.UTF8String, 0644);
    }
    return wrote;
}

static void OPVTAddHookStatus(NSMutableArray *methods,
        NSString *kind, const char *className, const char *selectorName, BOOL hooked) {
    if (!hooked) {
        return;
    }
    [methods addObject:@{
        @"kind": kind ?: @"unknown",
        @"class": className ? [NSString stringWithUTF8String:className] : @"",
        @"selector": selectorName ? [NSString stringWithUTF8String:selectorName] : @""
    }];
}

static NSDictionary *OPVTHookStatus(void) {
    NSMutableArray *hookedMethods = [NSMutableArray array];
    NSUInteger volumeTotal = 0;
    NSUInteger volumeHooked = 0;
    NSUInteger foregroundTotal = 0;
    NSUInteger foregroundHooked = 0;

    size_t count = sizeof(OPVTHookSpecs) / sizeof(OPVTHookSpecs[0]);
    volumeTotal += count;
    for (size_t index = 0; index < count; index++) {
        OPVTHookSpec *spec = &OPVTHookSpecs[index];
        if (spec->hooked) {
            volumeHooked++;
        }
        OPVTAddHookStatus(hookedMethods, @"volume_no_arg",
                spec->className, spec->selectorName, spec->hooked);
    }

    count = sizeof(OPVTFixedArgHookSpecs) / sizeof(OPVTFixedArgHookSpecs[0]);
    volumeTotal += count;
    for (size_t index = 0; index < count; index++) {
        OPVTFixedArgHookSpec *spec = &OPVTFixedArgHookSpecs[index];
        if (spec->hooked) {
            volumeHooked++;
        }
        OPVTAddHookStatus(hookedMethods, @"volume_fixed_arg",
                spec->className, spec->selectorName, spec->hooked);
    }

    count = sizeof(OPVTBoolArgHookSpecs) / sizeof(OPVTBoolArgHookSpecs[0]);
    volumeTotal += count;
    for (size_t index = 0; index < count; index++) {
        OPVTBoolArgHookSpec *spec = &OPVTBoolArgHookSpecs[index];
        if (spec->hooked) {
            volumeHooked++;
        }
        OPVTAddHookStatus(hookedMethods, @"volume_bool_arg",
                spec->className, spec->selectorName, spec->hooked);
    }

    count = sizeof(OPVTBoolPairHookSpecs) / sizeof(OPVTBoolPairHookSpecs[0]);
    volumeTotal += count;
    for (size_t index = 0; index < count; index++) {
        OPVTBoolPairHookSpec *spec = &OPVTBoolPairHookSpecs[index];
        if (spec->hooked) {
            volumeHooked++;
        }
        OPVTAddHookStatus(hookedMethods, @"volume_bool_pair",
                spec->className, spec->selectorName, spec->hooked);
    }

    count = sizeof(OPVTButtonObjectVoidHookSpecs) / sizeof(OPVTButtonObjectVoidHookSpecs[0]);
    volumeTotal += count;
    for (size_t index = 0; index < count; index++) {
        OPVTButtonObjectVoidHookSpec *spec = &OPVTButtonObjectVoidHookSpecs[index];
        if (spec->hooked) {
            volumeHooked++;
        }
        OPVTAddHookStatus(hookedMethods, @"button_object_void",
                spec->className, spec->selectorName, spec->hooked);
    }

    count = sizeof(OPVTButtonObjectBoolHookSpecs) / sizeof(OPVTButtonObjectBoolHookSpecs[0]);
    volumeTotal += count;
    for (size_t index = 0; index < count; index++) {
        OPVTButtonObjectBoolHookSpec *spec = &OPVTButtonObjectBoolHookSpecs[index];
        if (spec->hooked) {
            volumeHooked++;
        }
        OPVTAddHookStatus(hookedMethods, @"button_object_bool",
                spec->className, spec->selectorName, spec->hooked);
    }

    count = sizeof(OPVTButtonRawHIDVoidHookSpecs) / sizeof(OPVTButtonRawHIDVoidHookSpecs[0]);
    volumeTotal += count;
    for (size_t index = 0; index < count; index++) {
        OPVTButtonRawHIDVoidHookSpec *spec = &OPVTButtonRawHIDVoidHookSpecs[index];
        if (spec->hooked) {
            volumeHooked++;
        }
        OPVTAddHookStatus(hookedMethods, @"button_raw_hid_void",
                spec->className, spec->selectorName, spec->hooked);
    }

    count = sizeof(OPVTForegroundNoArgObjectHookSpecs) / sizeof(OPVTForegroundNoArgObjectHookSpecs[0]);
    foregroundTotal += count;
    for (size_t index = 0; index < count; index++) {
        OPVTForegroundNoArgObjectHookSpec *spec = &OPVTForegroundNoArgObjectHookSpecs[index];
        if (spec->hooked) {
            foregroundHooked++;
        }
        OPVTAddHookStatus(hookedMethods, @"foreground_no_arg_object",
                spec->className, spec->selectorName, spec->hooked);
    }

    count = sizeof(OPVTForegroundObjectArgVoidHookSpecs) / sizeof(OPVTForegroundObjectArgVoidHookSpecs[0]);
    foregroundTotal += count;
    for (size_t index = 0; index < count; index++) {
        OPVTForegroundObjectArgVoidHookSpec *spec = &OPVTForegroundObjectArgVoidHookSpecs[index];
        if (spec->hooked) {
            foregroundHooked++;
        }
        OPVTAddHookStatus(hookedMethods, @"foreground_object_arg_void",
                spec->className, spec->selectorName, spec->hooked);
    }

    count = sizeof(OPVTForegroundObjectArgObjectHookSpecs) / sizeof(OPVTForegroundObjectArgObjectHookSpecs[0]);
    foregroundTotal += count;
    for (size_t index = 0; index < count; index++) {
        OPVTForegroundObjectArgObjectHookSpec *spec = &OPVTForegroundObjectArgObjectHookSpecs[index];
        if (spec->hooked) {
            foregroundHooked++;
        }
        OPVTAddHookStatus(hookedMethods, @"foreground_object_arg_object",
                spec->className, spec->selectorName, spec->hooked);
    }

    count = sizeof(OPVTForegroundNoArgBoolHookSpecs) / sizeof(OPVTForegroundNoArgBoolHookSpecs[0]);
    foregroundTotal += count;
    for (size_t index = 0; index < count; index++) {
        OPVTForegroundNoArgBoolHookSpec *spec = &OPVTForegroundNoArgBoolHookSpecs[index];
        if (spec->hooked) {
            foregroundHooked++;
        }
        OPVTAddHookStatus(hookedMethods, @"foreground_no_arg_bool",
                spec->className, spec->selectorName, spec->hooked);
    }

    return @{
        @"volume_total": @(volumeTotal),
        @"volume_hooked": @(volumeHooked),
        @"foreground_total": @(foregroundTotal),
        @"foreground_hooked": @(foregroundHooked),
        @"any_volume_hooked": @(volumeHooked > 0),
        @"hooked_methods": hookedMethods
    };
}

static NSDictionary *OPVTVolumeNotificationStatus(void) {
    NSMutableDictionary *status = [@{
        @"installed": @(OPVTVolumeNotificationInstalled),
        @"events_seen": @(OPVTVolumeNotificationEventCount),
        @"last_event_ms": @(OPVTLastVolumeNotificationMs),
        @"last_volume": @(OPVTLastSystemVolume >= 0.0 ? OPVTLastSystemVolume : -1.0),
        @"last_reason": OPVTLastVolumeNotificationReason ?: @"",
        @"last_category": OPVTLastVolumeNotificationCategory ?: @"",
        @"last_direction": OPVTLastVolumeNotificationDirection ?: @"",
        @"seeded": @(OPVTLastSystemVolume >= 0.0)
    } mutableCopy];
    return status;
}

static NSDictionary *OPVTTriggerPreferenceStatus(void) {
    NSDictionary *preferences = OPVTPreferences();
    NSString *goal = OPVTStringPreference(@"TriggerGoal", @"");
    return @{
        @"enabled": @(OPVTBoolPreference(@"Enabled", YES)),
        @"prompt_for_goal": @(OPVTBoolPreference(@"PromptForGoal", YES)),
        @"daemon_voice_agent": @(OPVTBoolPreference(@"DaemonVoiceAgent", YES)),
        @"run_task": @(OPVTBoolPreference(@"RunTask", YES)),
        @"create_background_job": @(OPVTBoolPreference(@"CreateBackgroundJob", NO)),
        @"run_background_jobs": @(OPVTBoolPreference(@"RunBackgroundJobs", NO)),
        @"window_ms": preferences[@"WindowMs"] ?: @1200,
        @"cooldown_ms": preferences[@"CooldownMs"] ?: @10000,
        @"trigger_goal_present": @(goal.length > 0),
        @"trigger_goal_length": @(goal.length)
    };
}

static void OPVTPublishTriggerStatus(NSString *eventName, NSDictionary *extra) {
    NSMutableDictionary *status = [@{
        @"schema": @"openphone.springboard_trigger_status.v1",
        @"timestamp_ms": @(OPVTNowMs()),
        @"provider": @"OpenPhoneVolumeTrigger.SpringBoardVolumeHooks",
        @"status": OPVTEnabled() ? @"enabled" : @"disabled",
        @"event": eventName ?: @"status",
        @"preferences": OPVTTriggerPreferenceStatus(),
        @"hooks": OPVTHookStatus(),
        @"volume_notification": OPVTVolumeNotificationStatus(),
        @"button_events_seen": @(OPVTButtonEventCount),
        @"combo_events_seen": @(OPVTComboEventCount),
        @"last_button_event_ms": @(OPVTLastButtonEventMs),
        @"last_button_event": OPVTLastButtonEventName ?: @"",
        @"last_button_event_source": OPVTLastButtonEventSource ?: @"",
        @"last_combo_event_ms": @(OPVTLastComboEventMs),
        @"last_trigger_route": OPVTLastTriggerRoute ?: @"",
        @"source": @"springboard"
    } mutableCopy];
    if (extra.count > 0) {
        status[@"event_detail"] = extra;
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:OPVTStorePath
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0755}
                                                    error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:OPVTSpringBoardStateDir
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0755}
                                                    error:nil];
    if (OPVTWriteJSONDictionary(OPVTTriggerStatusPath, status)) {
        chmod(OPVTTriggerStatusPath.UTF8String, 0644);
    }
}

static double OPVTDoubleValue(id value, double defaultValue) {
    if ([value respondsToSelector:@selector(doubleValue)]) {
        double parsed = [value doubleValue];
        return isfinite(parsed) ? parsed : defaultValue;
    }
    return defaultValue;
}

static long long OPVTLongLongValue(id value, long long defaultValue) {
    if ([value respondsToSelector:@selector(longLongValue)]) {
        return [value longLongValue];
    }
    return defaultValue;
}

static BOOL OPVTBoolValue(id value, BOOL defaultValue) {
    if ([value respondsToSelector:@selector(boolValue)]) {
        return [value boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *lower = [(NSString *)value lowercaseString];
        if ([lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"] ||
                [lower isEqualToString:@"1"]) {
            return YES;
        }
        if ([lower isEqualToString:@"false"] || [lower isEqualToString:@"no"] ||
                [lower isEqualToString:@"0"]) {
            return NO;
        }
    }
    return defaultValue;
}

static id OPVTInvokeObjectNoArg(id target, NSString *selectorName) {
    if (!target || selectorName.length == 0) {
        return nil;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        return nil;
    }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) {
        return nil;
    }
    const char *returnType = signature.methodReturnType;
    if (!returnType || (returnType[0] != '@' && returnType[0] != '#')) {
        return nil;
    }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    @try {
        [invocation invoke];
        __unsafe_unretained id value = nil;
        [invocation getReturnValue:&value];
        return value;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id OPVTInvokeObjectOneArg(id target, NSString *selectorName, id argument) {
    if (!target || selectorName.length == 0) {
        return nil;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        return nil;
    }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 3) {
        return nil;
    }
    const char *returnType = signature.methodReturnType;
    if (!returnType || (returnType[0] != '@' && returnType[0] != '#')) {
        return nil;
    }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    id retainedArgument = argument;
    [invocation setArgument:&retainedArgument atIndex:2];
    @try {
        [invocation invoke];
        __unsafe_unretained id value = nil;
        [invocation getReturnValue:&value];
        return value;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL OPVTInvokeBoolNoArg(id target, NSString *selectorName, BOOL *outValue) {
    if (!target || selectorName.length == 0 || !outValue) {
        return NO;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        return NO;
    }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) {
        return NO;
    }
    const char *returnType = signature.methodReturnType;
    if (!returnType || (returnType[0] != 'B' && returnType[0] != 'c' && returnType[0] != 'C')) {
        return NO;
    }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    @try {
        [invocation invoke];
        BOOL value = NO;
        [invocation getReturnValue:&value];
        *outValue = value;
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL OPVTMethodTypeLooksBool(const char *type) {
    return type && (type[0] == 'B' || type[0] == 'c' || type[0] == 'C');
}

static BOOL OPVTInvokeVoidOrBoolBoolBool(id target,
        NSString *selectorName,
        BOOL first,
        BOOL second,
        NSString **outError) {
    if (outError) {
        *outError = nil;
    }
    if (!target || selectorName.length == 0) {
        if (outError) {
            *outError = @"target_missing";
        }
        return NO;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        if (outError) {
            *outError = @"selector_missing";
        }
        return NO;
    }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 4) {
        if (outError) {
            *outError = @"signature_mismatch";
        }
        return NO;
    }
    const char *returnType = signature.methodReturnType;
    BOOL returnsBool = OPVTMethodTypeLooksBool(returnType);
    if (!returnType || (returnType[0] != 'v' && !returnsBool)) {
        if (outError) {
            *outError = @"return_type_mismatch";
        }
        return NO;
    }
    const char *arg2 = [signature getArgumentTypeAtIndex:2];
    const char *arg3 = [signature getArgumentTypeAtIndex:3];
    if (!OPVTMethodTypeLooksBool(arg2) || !OPVTMethodTypeLooksBool(arg3)) {
        if (outError) {
            *outError = @"argument_type_mismatch";
        }
        return NO;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    BOOL firstValue = first;
    BOOL secondValue = second;
    [invocation setArgument:&firstValue atIndex:2];
    [invocation setArgument:&secondValue atIndex:3];
    @try {
        [invocation invoke];
        if (returnsBool) {
            BOOL value = NO;
            [invocation getReturnValue:&value];
            if (!value) {
                if (outError) {
                    *outError = @"method_returned_false";
                }
                return NO;
            }
        }
        return YES;
    } @catch (NSException *exception) {
        if (outError) {
            *outError = exception.name ?: @"exception";
        }
        return NO;
    }
}

static BOOL OPVTInvokeVoidOrBoolObjectBoolObject(id target,
        NSString *selectorName,
        id object,
        BOOL flag,
        id trailingObject,
        NSString **outError) {
    if (outError) {
        *outError = nil;
    }
    if (!target || selectorName.length == 0) {
        if (outError) {
            *outError = @"target_missing";
        }
        return NO;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        if (outError) {
            *outError = @"selector_missing";
        }
        return NO;
    }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 5) {
        if (outError) {
            *outError = @"signature_mismatch";
        }
        return NO;
    }
    const char *returnType = signature.methodReturnType;
    BOOL returnsBool = OPVTMethodTypeLooksBool(returnType);
    if (!returnType || (returnType[0] != 'v' && !returnsBool)) {
        if (outError) {
            *outError = @"return_type_mismatch";
        }
        return NO;
    }
    const char *arg2 = [signature getArgumentTypeAtIndex:2];
    const char *arg3 = [signature getArgumentTypeAtIndex:3];
    const char *arg4 = [signature getArgumentTypeAtIndex:4];
    if (!arg2 || arg2[0] != '@' || !OPVTMethodTypeLooksBool(arg3) ||
            !arg4 || arg4[0] != '@') {
        if (outError) {
            *outError = @"argument_type_mismatch";
        }
        return NO;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    id retainedObject = object;
    BOOL flagValue = flag;
    id retainedTrailingObject = trailingObject;
    [invocation setArgument:&retainedObject atIndex:2];
    [invocation setArgument:&flagValue atIndex:3];
    [invocation setArgument:&retainedTrailingObject atIndex:4];
    @try {
        [invocation invoke];
        if (returnsBool) {
            BOOL value = NO;
            [invocation getReturnValue:&value];
            if (!value) {
                if (outError) {
                    *outError = @"method_returned_false";
                }
                return NO;
            }
        }
        return YES;
    } @catch (NSException *exception) {
        if (outError) {
            *outError = exception.name ?: @"exception";
        }
        return NO;
    }
}

static BOOL OPVTInvokeBoolObjectBoolBoolObject(id target,
        NSString *selectorName,
        id object,
        BOOL firstFlag,
        BOOL secondFlag,
        id trailingObject,
        NSString **outError) {
    if (outError) {
        *outError = nil;
    }
    if (!target || selectorName.length == 0) {
        if (outError) {
            *outError = @"target_missing";
        }
        return NO;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        if (outError) {
            *outError = @"selector_missing";
        }
        return NO;
    }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 6 ||
            !OPVTMethodTypeLooksBool(signature.methodReturnType)) {
        if (outError) {
            *outError = @"signature_mismatch";
        }
        return NO;
    }
    const char *arg2 = [signature getArgumentTypeAtIndex:2];
    const char *arg3 = [signature getArgumentTypeAtIndex:3];
    const char *arg4 = [signature getArgumentTypeAtIndex:4];
    const char *arg5 = [signature getArgumentTypeAtIndex:5];
    if (!arg2 || arg2[0] != '@' || !OPVTMethodTypeLooksBool(arg3) ||
            !OPVTMethodTypeLooksBool(arg4) || !arg5 || arg5[0] != '@') {
        if (outError) {
            *outError = @"argument_type_mismatch";
        }
        return NO;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    id retainedObject = object;
    BOOL firstValue = firstFlag;
    BOOL secondValue = secondFlag;
    id retainedTrailingObject = trailingObject;
    [invocation setArgument:&retainedObject atIndex:2];
    [invocation setArgument:&firstValue atIndex:3];
    [invocation setArgument:&secondValue atIndex:4];
    [invocation setArgument:&retainedTrailingObject atIndex:5];
    @try {
        [invocation invoke];
        BOOL value = NO;
        [invocation getReturnValue:&value];
        if (!value) {
            if (outError) {
                *outError = @"method_returned_false";
            }
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        if (outError) {
            *outError = exception.name ?: @"exception";
        }
        return NO;
    }
}

static BOOL OPVTInvokeBoolIntegerObject(id target,
        NSString *selectorName,
        int integer,
        id object,
        NSString **outError) {
    if (outError) {
        *outError = nil;
    }
    if (!target || selectorName.length == 0) {
        if (outError) {
            *outError = @"target_missing";
        }
        return NO;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        if (outError) {
            *outError = @"selector_missing";
        }
        return NO;
    }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 4 ||
            !OPVTMethodTypeLooksBool(signature.methodReturnType)) {
        if (outError) {
            *outError = @"signature_mismatch";
        }
        return NO;
    }
    const char *arg2 = [signature getArgumentTypeAtIndex:2];
    const char *arg3 = [signature getArgumentTypeAtIndex:3];
    if (!arg2 || (arg2[0] != 'i' && arg2[0] != 'q' && arg2[0] != 'Q') ||
            !arg3 || arg3[0] != '@') {
        if (outError) {
            *outError = @"argument_type_mismatch";
        }
        return NO;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    int integerValue = integer;
    long long longValue = integer;
    unsigned long long unsignedValue = (unsigned long long)MAX(integer, 0);
    id retainedObject = object;
    if (arg2[0] == 'q') {
        [invocation setArgument:&longValue atIndex:2];
    } else if (arg2[0] == 'Q') {
        [invocation setArgument:&unsignedValue atIndex:2];
    } else {
        [invocation setArgument:&integerValue atIndex:2];
    }
    [invocation setArgument:&retainedObject atIndex:3];
    @try {
        [invocation invoke];
        BOOL value = NO;
        [invocation getReturnValue:&value];
        if (!value) {
            if (outError) {
                *outError = @"method_returned_false";
            }
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        if (outError) {
            *outError = exception.name ?: @"exception";
        }
        return NO;
    }
}

static BOOL OPVTInvokeIntegerNoArg(id target, NSString *selectorName, long long *outValue) {
    if (!target || selectorName.length == 0 || !outValue) {
        return NO;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        return NO;
    }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) {
        return NO;
    }
    const char *returnType = signature.methodReturnType;
    if (!returnType) {
        return NO;
    }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    @try {
        [invocation invoke];
        if (returnType[0] == 'q' || returnType[0] == 'l' || returnType[0] == 'i' ||
                returnType[0] == 's' || returnType[0] == 'c') {
            long long value = 0;
            [invocation getReturnValue:&value];
            *outValue = value;
            return YES;
        }
        if (returnType[0] == 'Q' || returnType[0] == 'L' || returnType[0] == 'I' ||
                returnType[0] == 'S' || returnType[0] == 'C') {
            unsigned long long value = 0;
            [invocation getReturnValue:&value];
            *outValue = (long long)value;
            return YES;
        }
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return NO;
}

static BOOL OPVTBundleIdentifierLooksValid(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length < 3 || value.length > 200) {
        return NO;
    }
    if (![value containsString:@"."]) {
        return NO;
    }
    NSArray<NSString *> *prefixes = @[@"com.", @"org.", @"net.", @"io.", @"app."];
    BOOL hasKnownPrefix = NO;
    for (NSString *prefix in prefixes) {
        if ([value hasPrefix:prefix]) {
            hasKnownPrefix = YES;
            break;
        }
    }
    if (!hasKnownPrefix) {
        return NO;
    }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    for (NSUInteger i = 0; i < value.length; i++) {
        if (![allowed characterIsMember:[value characterAtIndex:i]]) {
            return NO;
        }
    }
    return YES;
}

static NSString *OPVTBundleIdentifierFromSceneIdentifier(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || ![value hasPrefix:@"sceneID:"]) {
        return nil;
    }
    NSString *identifier = [value substringFromIndex:@"sceneID:".length];
    NSRange paren = [identifier rangeOfString:@"("];
    if (paren.location != NSNotFound) {
        identifier = [identifier substringToIndex:paren.location];
    }
    if ([identifier hasSuffix:@"-default"]) {
        identifier = [identifier substringToIndex:identifier.length - @"-default".length];
    } else if (identifier.length > 37) {
        NSString *suffix = [identifier substringFromIndex:identifier.length - 37];
        NSRegularExpression *uuidSuffix = [NSRegularExpression regularExpressionWithPattern:
                @"^-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
                options:0 error:nil];
        if ([uuidSuffix numberOfMatchesInString:suffix
                                         options:0
                                           range:NSMakeRange(0, suffix.length)] > 0) {
            identifier = [identifier substringToIndex:identifier.length - 37];
        }
    }
    return OPVTBundleIdentifierLooksValid(identifier) ? identifier : nil;
}

static NSString *OPVTStringFromObject(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    }
    return nil;
}

static NSString *OPVTBundleIdentifierFromObject(id object, NSUInteger depth) {
    if (!object || depth > 4) {
        return nil;
    }
    NSArray<NSString *> *stringSelectors = @[
        @"bundleIdentifier",
        @"displayIdentifier",
        @"bundleID",
        @"applicationIdentifier",
        @"applicationBundleIdentifier",
        @"clientProcessBundleIdentifier",
        @"containingBundleIdentifier",
        @"identifier"
    ];
    for (NSString *selector in stringSelectors) {
        NSString *value = OPVTStringFromObject(OPVTInvokeObjectNoArg(object, selector));
        NSString *sceneBundle = OPVTBundleIdentifierFromSceneIdentifier(value);
        if (sceneBundle.length > 0) {
            return sceneBundle;
        }
        if (OPVTBundleIdentifierLooksValid(value)) {
            return value;
        }
    }
    NSArray<NSString *> *objectSelectors = @[
        @"application",
        @"bundle",
        @"process",
        @"clientProcess",
        @"clientHandle",
        @"scene",
        @"settings",
        @"displayIdentity",
        @"layoutItem",
        @"entity"
    ];
    for (NSString *selector in objectSelectors) {
        id nested = OPVTInvokeObjectNoArg(object, selector);
        NSString *value = OPVTBundleIdentifierFromObject(nested, depth + 1);
        if (value.length > 0) {
            return value;
        }
    }
    return nil;
}

static NSTimeInterval OPVTWindowSeconds(void) {
    return OPVTMillisecondsPreference(@"WindowMs", 1200.0, 50.0, 3000.0);
}

static NSTimeInterval OPVTCooldownSeconds(void) {
    return OPVTMillisecondsPreference(@"CooldownMs", 10000.0, 250.0, 60000.0);
}

static void OPVTPlayHapticSuccess(void) {
    AudioServicesPlaySystemSound(1519);
}

static void OPVTPlayHapticFailure(void) {
    AudioServicesPlaySystemSound(1521);
}

static UIApplication *OPVTSafeSharedApplication(void) {
    @try {
        return [UIApplication sharedApplication];
    } @catch (NSException *exception) {
        OPVTLog(@"springboard state UIApplication unavailable name=%@ reason=%@",
                exception.name ?: @"", exception.reason ?: @"");
        return nil;
    }
}

static UIScreen *OPVTSafeMainScreen(void) {
    @try {
        return [UIScreen mainScreen];
    } @catch (NSException *exception) {
        int count = __sync_add_and_fetch(&OPVTStatePublishFailureCount, 1);
        if (count <= 3 || count % 30 == 0) {
            OPVTLog(@"springboard state UIScreen unavailable count=%d name=%@ reason=%@",
                    count, exception.name ?: @"", exception.reason ?: @"");
        }
        return nil;
    }
}

static UIWindowScene *OPVTActiveWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        UIApplication *application = OPVTSafeSharedApplication();
        UIScreen *mainScreen = OPVTSafeMainScreen();
        NSSet<UIScene *> *scenes = application.connectedScenes;
        UIWindowScene *fallback = nil;
        for (UIScene *scene in scenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (mainScreen && windowScene.screen != mainScreen) {
                continue;
            }
            if (!fallback) {
                fallback = windowScene;
            }
            if (scene.activationState == UISceneActivationStateForegroundActive ||
                    scene.activationState == UISceneActivationStateForegroundInactive) {
                return windowScene;
            }
        }
        return fallback;
    }
    return nil;
}

static NSArray *OPVTArrayFromCollection(id collection) {
    if (!collection) {
        return @[];
    }
    if ([collection isKindOfClass:[NSArray class]]) {
        return collection;
    }
    if ([collection isKindOfClass:[NSSet class]]) {
        return [(NSSet *)collection allObjects];
    }
    if ([collection isKindOfClass:[NSDictionary class]]) {
        return [(NSDictionary *)collection allValues];
    }
    id allObjects = OPVTInvokeObjectNoArg(collection, @"allObjects");
    if ([allObjects isKindOfClass:[NSArray class]]) {
        return allObjects;
    }
    id enumerator = OPVTInvokeObjectNoArg(collection, @"objectEnumerator");
    if (!enumerator || ![enumerator respondsToSelector:@selector(nextObject)]) {
        return @[];
    }
    NSMutableArray *objects = [NSMutableArray array];
    for (NSUInteger i = 0; i < 64; i++) {
        id object = [enumerator nextObject];
        if (!object) {
            break;
        }
        [objects addObject:object];
    }
    return objects;
}

static void OPVTRecordForegroundBundleId(NSString *bundleId, NSString *source) {
    if (!OPVTBundleIdentifierLooksValid(bundleId) ||
            [bundleId isEqualToString:@"com.apple.springboard"]) {
        return;
    }
    long long now = OPVTNowMs();
    pthread_mutex_lock(&OPVTForegroundCacheLock);
    BOOL changed = ![OPVTLastForegroundBundleId isEqualToString:bundleId];
    OPVTLastForegroundBundleId = [bundleId copy];
    OPVTLastForegroundSource = [source ?: @"runtime" copy];
    OPVTLastForegroundAtMs = now;
    pthread_mutex_unlock(&OPVTForegroundCacheLock);
    if (changed) {
        OPVTLog(@"foreground cache updated bundle=%@ source=%@",
                bundleId ?: @"", source ?: @"runtime");
    }
}

static void OPVTRecordForegroundObject(id object, NSString *source) {
    if (!object) {
        return;
    }
    NSArray *objects = OPVTArrayFromCollection(object);
    if (objects.count == 0) {
        objects = @[object];
    }
    for (id candidate in objects) {
        NSString *bundleId = OPVTBundleIdentifierFromObject(candidate, 0);
        NSString *stringValue = OPVTStringFromObject(candidate);
        if (bundleId.length == 0 && OPVTBundleIdentifierLooksValid(stringValue)) {
            bundleId = stringValue;
        }
        if (bundleId.length > 0) {
            OPVTRecordForegroundBundleId(bundleId, source);
            return;
        }
    }
}

static NSDictionary *OPVTForegroundCacheSnapshot(void) {
    pthread_mutex_lock(&OPVTForegroundCacheLock);
    NSString *bundleId = [OPVTLastForegroundBundleId copy];
    NSString *source = [OPVTLastForegroundSource copy];
    long long timestamp = OPVTLastForegroundAtMs;
    pthread_mutex_unlock(&OPVTForegroundCacheLock);

    if (bundleId.length == 0 || timestamp <= 0) {
        return @{
            @"status": @"empty",
            @"provider": @"OpenPhoneVolumeTrigger.ForegroundRuntimeCache"
        };
    }
    long long age = MAX(0, OPVTNowMs() - timestamp);
    return @{
        @"status": age <= 30000 ? @"ok" : @"stale",
        @"provider": @"OpenPhoneVolumeTrigger.ForegroundRuntimeCache",
        @"bundle_id": bundleId,
        @"source": source ?: @"runtime",
        @"timestamp_ms": @(timestamp),
        @"age_ms": @(age)
    };
}

static NSNumber *OPVTScreenInteger(CGFloat value) {
    return @((NSInteger)llround((double)value));
}

static NSArray<NSNumber *> *OPVTBoundsArray(CGRect rect) {
    return @[
        OPVTScreenInteger(rect.origin.x),
        OPVTScreenInteger(rect.origin.y),
        OPVTScreenInteger(rect.size.width),
        OPVTScreenInteger(rect.size.height)
    ];
}

static NSString *OPVTAccessibilityString(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = [(NSString *)value stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return string.length > 0 ? string : nil;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }
    return nil;
}

static NSString *OPVTViewLabel(UIView *view) {
    NSString *label = OPVTAccessibilityString(view.accessibilityLabel);
    if (label.length > 0) {
        return label;
    }
    if ([view isKindOfClass:[UIButton class]]) {
        label = OPVTAccessibilityString([(UIButton *)view currentTitle]);
        if (label.length > 0) {
            return label;
        }
    }
    if ([view isKindOfClass:[UILabel class]]) {
        label = OPVTAccessibilityString([(UILabel *)view text]);
        if (label.length > 0) {
            return label;
        }
    }
    if ([view isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)view;
        label = OPVTAccessibilityString(field.placeholder);
        if (label.length > 0) {
            return label;
        }
    }
    return OPVTAccessibilityString(view.accessibilityIdentifier);
}

static NSString *OPVTViewVisibleText(UIView *view) {
    NSString *label = OPVTAccessibilityString(view.accessibilityLabel);
    if (label.length > 0) {
        return label;
    }
    if ([view isKindOfClass:[UIButton class]]) {
        label = OPVTAccessibilityString([(UIButton *)view currentTitle]);
        if (label.length > 0) {
            return label;
        }
    }
    if ([view isKindOfClass:[UILabel class]]) {
        label = OPVTAccessibilityString([(UILabel *)view text]);
        if (label.length > 0) {
            return label;
        }
    }
    if ([view isKindOfClass:[UITextField class]]) {
        return OPVTAccessibilityString([(UITextField *)view placeholder]);
    }
    return nil;
}

static NSString *OPVTViewKind(UIView *view) {
    UIAccessibilityTraits traits = view.accessibilityTraits;
    if ((traits & UIAccessibilityTraitButton) == UIAccessibilityTraitButton) {
        return @"button";
    }
    if ((traits & UIAccessibilityTraitLink) == UIAccessibilityTraitLink) {
        return @"link";
    }
    if ((traits & UIAccessibilityTraitKeyboardKey) == UIAccessibilityTraitKeyboardKey) {
        return @"keyboard_key";
    }
    if ((traits & UIAccessibilityTraitSearchField) == UIAccessibilityTraitSearchField) {
        return @"search_field";
    }
    if ([view isKindOfClass:[UIButton class]]) {
        return @"button";
    }
    if ([view isKindOfClass:[UITextField class]]) {
        return @"text_field";
    }
    if ([view isKindOfClass:[UILabel class]]) {
        return @"text";
    }
    return view.userInteractionEnabled ? @"view" : @"text";
}

static NSNumber *OPVTWindowLevelNumber(UIWindow *window) {
    double level = (double)window.windowLevel;
    if (!isfinite(level)) {
        return @0;
    }
    if (level > 100000.0) {
        level = 100000.0;
    } else if (level < -100000.0) {
        level = -100000.0;
    }
    return @((NSInteger)llround(level));
}

static NSArray<UIWindow *> *OPVTApplicationWindows(UIApplication *application) {
    if (!application) {
        return @[];
    }
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *window in application.windows ?: @[]) {
            NSValue *key = [NSValue valueWithNonretainedObject:window];
            if (![seen containsObject:key]) {
                [seen addObject:key];
                [windows addObject:window];
            }
        }
#pragma clang diagnostic pop
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in application.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) {
                    continue;
                }
                for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) {
                    NSValue *key = [NSValue valueWithNonretainedObject:window];
                    if (![seen containsObject:key]) {
                        [seen addObject:key];
                        [windows addObject:window];
                    }
                }
            }
        }
    } @catch (NSException *exception) {
        OPVTLog(@"window enumeration exception name=%@ reason=%@",
                exception.name ?: @"", exception.reason ?: @"");
    }
    return windows;
}

static void OPVTCollectViewTree(UIView *view,
        UIWindow *window,
        NSInteger windowIndex,
        NSUInteger depth,
        NSUInteger *elementIndex,
        NSMutableArray<NSDictionary *> *interactiveElements,
        NSMutableArray<NSString *> *visibleText) {
    if (!view || depth > 8 || interactiveElements.count >= 80) {
        return;
    }
    if (view.hidden || view.alpha < 0.02) {
        return;
    }

    CGRect bounds = CGRectZero;
    @try {
        bounds = [view convertRect:view.bounds toView:window];
    } @catch (__unused NSException *exception) {
        bounds = CGRectZero;
    }
    if (CGRectIsEmpty(bounds) || bounds.size.width < 1.0 || bounds.size.height < 1.0) {
        return;
    }

    NSString *visibleLabel = OPVTViewVisibleText(view);
    if (visibleLabel.length > 0 && visibleText.count < 80 &&
            ![visibleText containsObject:visibleLabel]) {
        [visibleText addObject:visibleLabel];
    }

    NSString *label = OPVTViewLabel(view);
    BOOL accessible = view.isAccessibilityElement || view.userInteractionEnabled ||
            [view isKindOfClass:[UIButton class]] || [view isKindOfClass:[UITextField class]];
    if (accessible && (label.length > 0 || view.accessibilityIdentifier.length > 0)) {
        NSString *elementId = [NSString stringWithFormat:@"springboard-%ld-%lu",
                (long)windowIndex, (unsigned long)(*elementIndex)];
        (*elementIndex)++;
        NSMutableDictionary *element = [@{
            @"id": elementId,
            @"kind": OPVTViewKind(view),
            @"class": NSStringFromClass([view class]) ?: @"",
            @"label": label ?: @"",
            @"bounds": OPVTBoundsArray(bounds),
            @"enabled": @(view.userInteractionEnabled),
            @"focused": @(view.isFirstResponder),
            @"window_id": @(windowIndex),
            @"sensitive": @NO,
            @"risk_hint": @"springboard_only"
        } mutableCopy];
        NSString *identifier = OPVTAccessibilityString(view.accessibilityIdentifier);
        if (identifier.length > 0) {
            element[@"view_id"] = identifier;
        }
        [interactiveElements addObject:element];
        if (interactiveElements.count >= 80) {
            return;
        }
    }

    NSArray<UIView *> *subviews = view.subviews;
    for (UIView *subview in subviews) {
        OPVTCollectViewTree(subview, window, windowIndex, depth + 1,
                elementIndex, interactiveElements, visibleText);
        if (interactiveElements.count >= 80) {
            return;
        }
    }
}

static NSDictionary *OPVTUITreeSnapshot(void) {
    NSMutableDictionary *snapshot = [@{
        @"status": @"unavailable",
        @"provider": @"SpringBoard.UIKitAccessibility"
    } mutableCopy];
    UIApplication *application = OPVTSafeSharedApplication();
    if (!application) {
        snapshot[@"reason"] = @"application_unavailable";
        return snapshot;
    }

    @try {
        NSArray<UIWindow *> *windows = OPVTApplicationWindows(application);

        NSMutableArray<NSDictionary *> *windowSnapshots = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *interactiveElements = [NSMutableArray array];
        NSMutableArray<NSString *> *visibleText = [NSMutableArray array];
        NSInteger windowIndex = 0;
        NSUInteger elementIndex = 0;
        for (UIWindow *window in windows) {
            if (!window || window.hidden || window.alpha < 0.02) {
                windowIndex++;
                continue;
            }
            CGRect bounds = window.bounds;
            [windowSnapshots addObject:@{
                @"id": @(windowIndex),
                @"type": OPVTWindowLevelNumber(window),
                @"focused": @(window.isKeyWindow),
                @"active": @(!window.hidden && window.alpha >= 0.02),
                @"bounds": OPVTBoundsArray(bounds)
            }];
            OPVTCollectViewTree(window, window, windowIndex, 0,
                    &elementIndex, interactiveElements, visibleText);
            windowIndex++;
            if (windowSnapshots.count >= 16 || interactiveElements.count >= 80) {
                break;
            }
        }

        snapshot[@"status"] = @"ok";
        snapshot[@"window_count"] = @(windowSnapshots.count);
        snapshot[@"element_count"] = @(interactiveElements.count);
        snapshot[@"text_count"] = @(visibleText.count);
        snapshot[@"windows"] = windowSnapshots;
        snapshot[@"interactive_elements"] = interactiveElements;
        snapshot[@"visible_text"] = visibleText;
        snapshot[@"scope"] = @"springboard_only";
        return snapshot;
    } @catch (NSException *exception) {
        snapshot[@"reason"] = @"exception";
        snapshot[@"exception_name"] = exception.name ?: @"";
        return snapshot;
    }
}

static NSDictionary *OPVTScreenshotBridgeStatus(void) {
    return @{
        @"status": @"ready",
        @"provider": @"OpenPhoneVolumeTrigger.SpringBoardScreenshot",
        @"request_path": OPVTScreenshotRequestPath,
        @"response_path": OPVTScreenshotResponsePath,
        @"storage": OPVTScreenshotsDir,
        @"scope": @"springboard_windows"
    };
}

static BOOL OPVTScreenshotPathAllowed(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
        return NO;
    }
    NSString *standardPath = [path stringByStandardizingPath];
    NSString *standardDir = [OPVTScreenshotsDir stringByStandardizingPath];
    NSString *prefix = [standardDir stringByAppendingString:@"/"];
    NSString *ext = [standardPath.pathExtension lowercaseString];
    return [standardPath hasPrefix:prefix] &&
            ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"]
                    || [ext isEqualToString:@"jpeg"]);
}

static NSDictionary *OPVTScreenshotResponse(NSString *status,
        NSString *reason,
        NSString *requestId,
        NSString *path,
        NSDictionary *extra) {
    NSMutableDictionary *response = [@{
        @"schema": @"openphone.springboard_screenshot_response.v1",
        @"status": status ?: @"unavailable",
        @"provider": @"OpenPhoneVolumeTrigger.SpringBoardScreenshot",
        @"request_id": requestId ?: @"",
        @"timestamp_ms": @(OPVTNowMs()),
        @"path": path ?: @"",
        @"bytes_returned": @"never",
        @"storage": OPVTScreenshotsDir,
        @"scope": @"springboard_windows",
        @"source": @"springboard"
    } mutableCopy];
    if (reason.length > 0) {
        response[@"reason"] = reason;
    }
    [response addEntriesFromDictionary:extra ?: @{}];
    return response;
}

static NSDictionary *OPVTCaptureSpringBoardScreenshot(NSDictionary *request) {
    NSString *requestId = [request[@"request_id"] isKindOfClass:[NSString class]]
            ? request[@"request_id"] : @"";
    NSString *path = [request[@"path"] isKindOfClass:[NSString class]]
            ? request[@"path"] : @"";
    if (requestId.length == 0) {
        return OPVTScreenshotResponse(@"unavailable", @"missing_request_id", requestId, path, nil);
    }
    if (!OPVTScreenshotPathAllowed(path)) {
        return OPVTScreenshotResponse(@"unavailable", @"path_not_allowed", requestId, path, nil);
    }

    UIApplication *application = OPVTSafeSharedApplication();
    if (!application) {
        return OPVTScreenshotResponse(@"unavailable", @"application_unavailable", requestId, path, nil);
    }
    UIScreen *screen = OPVTSafeMainScreen();
    if (!screen) {
        return OPVTScreenshotResponse(@"unavailable", @"main_screen_unavailable", requestId, path, nil);
    }

    CGRect bounds = CGRectZero;
    CGFloat scale = 0.0;
    @try {
        bounds = screen.bounds;
        scale = screen.scale;
    } @catch (NSException *exception) {
        return OPVTScreenshotResponse(@"unavailable", @"screen_metrics_exception",
                requestId, path, @{@"exception_name": exception.name ?: @""});
    }
    if (CGRectIsEmpty(bounds) || bounds.size.width < 1.0 || bounds.size.height < 1.0) {
        return OPVTScreenshotResponse(@"unavailable", @"screen_bounds_unavailable",
                requestId, path, nil);
    }
    if (scale <= 0.0 || !isfinite(scale)) {
        scale = 1.0;
    }

    // Cap the rendered longest edge to max_dimension_px so downstream base64 /
    // model memory stays small. Rendering at a reduced scale is cheaper than
    // rendering full then downscaling. 0 keeps native scale.
    long long maxDimension = 1024;
    if ([request[@"max_dimension_px"] respondsToSelector:@selector(longLongValue)]) {
        maxDimension = [request[@"max_dimension_px"] longLongValue];
    }
    CGFloat renderScale = scale;
    if (maxDimension > 0) {
        CGFloat nativeLongest = MAX(bounds.size.width, bounds.size.height) * scale;
        if (nativeLongest > (CGFloat)maxDimension) {
            renderScale = scale * ((CGFloat)maxDimension / nativeLongest);
            if (renderScale <= 0.0 || !isfinite(renderScale)) {
                renderScale = scale;
            }
        }
    }
    long long jpegQualityX100 = 60;
    if ([request[@"jpeg_quality_x100"] respondsToSelector:@selector(longLongValue)]) {
        jpegQualityX100 = [request[@"jpeg_quality_x100"] longLongValue];
    }
    jpegQualityX100 = MAX(10, MIN(100, jpegQualityX100));
    NSString *pathExt = [[path pathExtension] lowercaseString];
    BOOL wantJPEG = [pathExt isEqualToString:@"jpg"] || [pathExt isEqualToString:@"jpeg"];

    NSArray<UIWindow *> *windows = [OPVTApplicationWindows(application)
            sortedArrayUsingComparator:^NSComparisonResult(UIWindow *left, UIWindow *right) {
        CGFloat leftLevel = left.windowLevel;
        CGFloat rightLevel = right.windowLevel;
        if (leftLevel < rightLevel) {
            return NSOrderedAscending;
        }
        if (leftLevel > rightLevel) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    [[NSFileManager defaultManager] createDirectoryAtPath:OPVTScreenshotsDir
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0755}
                                                    error:nil];

    UIGraphicsBeginImageContextWithOptions(bounds.size, YES, renderScale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) {
        UIGraphicsEndImageContext();
        return OPVTScreenshotResponse(@"unavailable", @"graphics_context_unavailable",
                requestId, path, nil);
    }
    [[UIColor blackColor] setFill];
    UIRectFill(bounds);

    NSUInteger drawnCount = 0;
    NSUInteger visibleCount = 0;
    for (UIWindow *window in windows) {
        if (!window || window.hidden || window.alpha < 0.02) {
            continue;
        }
        CGRect frame = window.frame;
        if (CGRectIsEmpty(frame)) {
            frame = window.bounds;
        }
        if (CGRectIsEmpty(frame) || frame.size.width < 1.0 || frame.size.height < 1.0) {
            continue;
        }
        visibleCount++;
        BOOL drawn = NO;
        @try {
            drawn = [window drawViewHierarchyInRect:frame afterScreenUpdates:NO];
        } @catch (NSException *exception) {
            OPVTLog(@"screenshot drawViewHierarchy exception window=%@ name=%@",
                    NSStringFromClass([window class]) ?: @"", exception.name ?: @"");
            drawn = NO;
        }
        if (!drawn) {
            BOOL savedState = NO;
            @try {
                CGContextSaveGState(context);
                savedState = YES;
                CGContextTranslateCTM(context, frame.origin.x, frame.origin.y);
                [window.layer renderInContext:context];
                CGContextRestoreGState(context);
                savedState = NO;
                drawn = YES;
            } @catch (NSException *exception) {
                OPVTLog(@"screenshot layer render exception window=%@ name=%@",
                        NSStringFromClass([window class]) ?: @"", exception.name ?: @"");
                if (savedState) {
                    CGContextRestoreGState(context);
                }
            }
        }
        if (drawn) {
            drawnCount++;
        }
        if (visibleCount >= 24) {
            break;
        }
    }

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!image) {
        return OPVTScreenshotResponse(@"unavailable", @"image_create_failed",
                requestId, path, @{@"visible_window_count": @(visibleCount)});
    }
    NSData *encoded = wantJPEG
            ? UIImageJPEGRepresentation(image, (CGFloat)jpegQualityX100 / 100.0)
            : UIImagePNGRepresentation(image);
    if (encoded.length == 0) {
        return OPVTScreenshotResponse(@"unavailable",
                wantJPEG ? @"jpeg_encode_failed" : @"png_encode_failed",
                requestId, path, @{@"visible_window_count": @(visibleCount)});
    }
    BOOL wrote = [encoded writeToFile:path atomically:YES];
    if (!wrote) {
        return OPVTScreenshotResponse(@"unavailable", @"image_write_failed",
                requestId, path, @{@"bytes": @(encoded.length)});
    }
    chmod(path.UTF8String, 0644);

    return OPVTScreenshotResponse(@"ok", nil, requestId, path, @{
        @"format": wantJPEG ? @"jpeg" : @"png",
        @"width": @((NSInteger)llround((double)(bounds.size.width * renderScale))),
        @"height": @((NSInteger)llround((double)(bounds.size.height * renderScale))),
        @"point_width": @((double)bounds.size.width),
        @"point_height": @((double)bounds.size.height),
        @"scale": @((double)renderScale),
        @"native_scale": @((double)scale),
        @"max_dimension_px": @(maxDimension),
        @"jpeg_quality_x100": wantJPEG ? @(jpegQualityX100) : @0,
        @"bytes": @(encoded.length),
        @"window_count": @(windows.count),
        @"visible_window_count": @(visibleCount),
        @"drawn_window_count": @(drawnCount)
    });
}

static NSDictionary *OPVTInputBridgeStatus(void) {
    return @{
        @"status": @"ready",
        @"provider": @"OpenPhoneVolumeTrigger.SpringBoardInput",
        @"request_path": OPVTInputRequestPath,
        @"response_path": OPVTInputResponsePath,
        @"scope": @"springboard_windows",
        @"actions": @[@"tap", @"tap_element", @"long_press", @"show_passcode", @"unlock_with_passcode"],
        @"strategy": @"uikit_accessibility_activation"
    };
}

static NSDictionary *OPVTClipboardBridgeStatus(void) {
    return @{
        @"status": @"ready",
        @"provider": @"OpenPhoneVolumeTrigger.SpringBoardClipboard",
        @"request_path": OPVTClipboardRequestPath,
        @"response_path": OPVTClipboardResponsePath,
        @"scope": @"springboard_uipasteboard",
        @"actions": @[@"read", @"write"],
        @"strategy": @"uikit_uipasteboard"
    };
}

static NSDictionary *OPVTPromptBridgeStatus(void) {
    return @{
        @"status": @"ready",
        @"provider": @"OpenPhoneVolumeTrigger.SpringBoardPrompt",
        @"request_path": OPVTPromptRequestPath,
        @"response_path": OPVTPromptResponsePath,
        @"scope": @"springboard_prompt",
        @"actions": @[@"present", @"run_goal"],
        @"strategy": @"uikit_alert_agent_handoff"
    };
}

static NSDictionary *OPVTPromptResponse(NSString *status,
        NSString *reason,
        NSString *requestId,
        NSString *operation,
        NSDictionary *extra) {
    NSMutableDictionary *response = [@{
        @"schema": @"openphone.springboard_prompt_response.v1",
        @"status": status ?: @"unavailable",
        @"provider": @"OpenPhoneVolumeTrigger.SpringBoardPrompt",
        @"request_id": requestId ?: @"",
        @"operation": operation ?: @"",
        @"timestamp_ms": @(OPVTNowMs()),
        @"source": @"springboard",
        @"strategy": @"uikit_alert_agent_handoff"
    } mutableCopy];
    if (reason.length > 0) {
        response[@"reason"] = reason;
    }
    [response addEntriesFromDictionary:extra ?: @{}];
    return response;
}

static NSDictionary *OPVTPerformPromptRequest(NSDictionary *request) {
    NSString *requestId = [request[@"request_id"] isKindOfClass:[NSString class]]
            ? request[@"request_id"] : @"";
    NSString *operationValue = [request[@"operation"] isKindOfClass:[NSString class]]
            ? request[@"operation"] : @"present";
    NSString *operation = [operationValue lowercaseString];
    if (requestId.length == 0) {
        return OPVTPromptResponse(@"unavailable", @"missing_request_id", requestId, operation, nil);
    }
    if ([operation isEqualToString:@"present"]) {
        OPVTPresentTriggerPrompt();
        return OPVTPromptResponse(@"ok", nil, requestId, operation, @{
            @"prompt_requested": @YES
        });
    }
    if ([operation isEqualToString:@"run_goal"]) {
        NSString *goal = OPVTTrimmedString([request[@"goal"] isKindOfClass:[NSString class]]
                ? request[@"goal"] : @"");
        if (goal.length == 0) {
            return OPVTPromptResponse(@"unavailable", @"missing_goal", requestId, operation, nil);
        }
        OPVTCallAgentWithGoal(goal, YES);
        return OPVTPromptResponse(@"ok", nil, requestId, operation, @{
            @"goal_length": @(goal.length)
        });
    }
    return OPVTPromptResponse(@"unavailable", @"unsupported_operation",
            requestId, operation, nil);
}

static NSDictionary *OPVTClipboardResponse(NSString *status,
        NSString *reason,
        NSString *requestId,
        NSString *operation,
        NSDictionary *extra) {
    NSMutableDictionary *response = [@{
        @"schema": @"openphone.springboard_clipboard_response.v1",
        @"status": status ?: @"unavailable",
        @"provider": @"OpenPhoneVolumeTrigger.SpringBoardClipboard",
        @"request_id": requestId ?: @"",
        @"operation": operation ?: @"",
        @"timestamp_ms": @(OPVTNowMs()),
        @"source": @"springboard",
        @"strategy": @"uikit_uipasteboard"
    } mutableCopy];
    if (reason.length > 0) {
        response[@"reason"] = reason;
    }
    [response addEntriesFromDictionary:extra ?: @{}];
    return response;
}

static NSDictionary *OPVTPerformClipboardRequest(NSDictionary *request) {
    NSString *requestId = [request[@"request_id"] isKindOfClass:[NSString class]]
            ? request[@"request_id"] : @"";
    NSString *operationValue = [request[@"operation"] isKindOfClass:[NSString class]]
            ? request[@"operation"] : @"read";
    NSString *operation = [operationValue lowercaseString];
    if (requestId.length == 0) {
        return OPVTClipboardResponse(@"unavailable", @"missing_request_id", requestId, operation, nil);
    }
    @try {
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        if (!pasteboard) {
            return OPVTClipboardResponse(@"unavailable", @"pasteboard_unavailable",
                    requestId, operation, nil);
        }
        if ([operation isEqualToString:@"read"]) {
            NSString *text = pasteboard.string ?: @"";
            return OPVTClipboardResponse(@"ok", nil, requestId, operation, @{
                @"text": text,
                @"text_length": @(text.length),
                @"system_clipboard": @YES
            });
        }
        if ([operation isEqualToString:@"write"]) {
            NSString *text = [request[@"text"] isKindOfClass:[NSString class]]
                    ? request[@"text"] : @"";
            pasteboard.string = text ?: @"";
            NSString *after = pasteboard.string ?: @"";
            NSString *expected = text ?: @"";
            BOOL verified = [after isEqualToString:expected];
            if (!verified) {
                return OPVTClipboardResponse(@"unavailable", @"pasteboard_write_not_verified",
                        requestId, operation, @{
                    @"text_length": @(text.length),
                    @"after_text_length": @(after.length),
                    @"system_clipboard": @YES
                });
            }
            return OPVTClipboardResponse(@"ok", nil, requestId, operation, @{
                @"text_length": @(text.length),
                @"verified": @YES,
                @"system_clipboard": @YES
            });
        }
        return OPVTClipboardResponse(@"unavailable", @"unsupported_operation",
                requestId, operation, nil);
    } @catch (NSException *exception) {
        return OPVTClipboardResponse(@"unavailable", @"exception", requestId, operation, @{
            @"exception_name": exception.name ?: @"",
            @"exception_reason": exception.reason ?: @""
        });
    }
}

static NSDictionary *OPVTInputResponse(NSString *status,
        NSString *reason,
        NSString *requestId,
        NSString *actionType,
        NSDictionary *extra) {
    NSMutableDictionary *response = [@{
        @"schema": @"openphone.springboard_input_response.v1",
        @"status": status ?: @"unavailable",
        @"provider": @"OpenPhoneVolumeTrigger.SpringBoardInput",
        @"request_id": requestId ?: @"",
        @"action_type": actionType ?: @"",
        @"timestamp_ms": @(OPVTNowMs()),
        @"source": @"springboard",
        @"strategy": @"uikit_accessibility_activation"
    } mutableCopy];
    if (reason.length > 0) {
        response[@"reason"] = reason;
    }
    [response addEntriesFromDictionary:extra ?: @{}];
    return response;
}

static BOOL OPVTNameContainsAny(const char *name, NSArray<NSString *> *needles) {
    if (!name) {
        return NO;
    }
    NSString *value = [NSString stringWithUTF8String:name];
    for (NSString *needle in needles) {
        if ([value rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static NSString *OPVTSafeStringFromCString(const char *value) {
    if (!value || value[0] == '\0') {
        return @"";
    }
    NSString *string = [NSString stringWithUTF8String:value];
    return string ?: @"";
}

static BOOL OPVTInputDiagnosticMethodNameLooksRelevant(const char *name) {
    return OPVTNameContainsAny(name, @[
        @"activate", @"action", @"tap", @"touch", @"press", @"gesture", @"swipe",
        @"unlock", @"lock", @"dismiss", @"present", @"cover", @"dashboard",
        @"passcode", @"authenticate", @"authenticated", @"home", @"reveal",
        @"scroll", @"pan", @"grabber", @"transition", @"settle"
    ]);
}

static NSDictionary *OPVTMethodDiagnostic(Method method) {
    if (!method) {
        return @{};
    }
    SEL selector = method_getName(method);
    char returnType[96] = {0};
    char arg2[96] = {0};
    char arg3[96] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (method_getNumberOfArguments(method) > 2) {
        method_getArgumentType(method, 2, arg2, sizeof(arg2));
    }
    if (method_getNumberOfArguments(method) > 3) {
        method_getArgumentType(method, 3, arg3, sizeof(arg3));
    }
    NSString *selectorName = selector ? NSStringFromSelector(selector) : @"";
    selectorName = selectorName ?: @"";
    NSString *returnTypeString = OPVTSafeStringFromCString(returnType);
    NSString *arg2String = OPVTSafeStringFromCString(arg2);
    NSString *arg3String = OPVTSafeStringFromCString(arg3);
    NSMutableDictionary *info = [@{
        @"selector": selectorName,
        @"args": @(method_getNumberOfArguments(method)),
        @"return": returnTypeString
    } mutableCopy];
    if (arg2String.length > 0) {
        info[@"arg2"] = arg2String;
    }
    if (arg3String.length > 0) {
        info[@"arg3"] = arg3String;
    }
    return info;
}

static NSArray<NSDictionary *> *OPVTMethodDiagnosticsForClass(Class cls,
        NSUInteger maxMethods,
        BOOL requireRelevantMethodName) {
    if (!cls || maxMethods == 0) {
        return @[];
    }
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (unsigned int index = 0; methods && index < methodCount && result.count < maxMethods; index++) {
        SEL selector = method_getName(methods[index]);
        const char *name = sel_getName(selector);
        if (requireRelevantMethodName && !OPVTInputDiagnosticMethodNameLooksRelevant(name)) {
            continue;
        }
        [result addObject:OPVTMethodDiagnostic(methods[index])];
    }
    if (methods) {
        free(methods);
    }
    return result;
}

static NSArray<NSDictionary *> *OPVTTargetInputDiagnostics(id target) {
    if (!target) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *classes = [NSMutableArray array];
    Class cls = [target class];
    NSUInteger depth = 0;
    while (cls && depth < 8 && classes.count < 8) {
        NSArray<NSDictionary *> *methods = OPVTMethodDiagnosticsForClass(cls, 60, YES);
        [classes addObject:@{
            @"class": NSStringFromClass(cls) ?: @"",
            @"method_count": @(methods.count),
            @"methods": methods
        }];
        cls = class_getSuperclass(cls);
        depth++;
    }
    return classes;
}

static NSDictionary *OPVTClassInputDiagnosticEntry(Class cls, BOOL targeted) {
    if (!cls) {
        return @{};
    }
    NSArray<NSDictionary *> *methods = OPVTMethodDiagnosticsForClass(cls, targeted ? 100 : 20, YES);
    NSArray<NSDictionary *> *classMethods = OPVTMethodDiagnosticsForClass(object_getClass(cls),
            targeted ? 100 : 20,
            !targeted);
    NSMutableDictionary *entry = [@{
        @"class": NSStringFromClass(cls) ?: @"",
        @"methods": methods
    } mutableCopy];
    if (classMethods.count > 0) {
        entry[@"class_methods"] = classMethods;
    }

    NSMutableArray<NSDictionary *> *singletons = [NSMutableArray array];
    for (NSString *selectorName in @[@"sharedInstance", @"sharedManager",
            @"sharedController", @"sharedApplication", @"mainWorkspace",
            @"sharedWorkspace"]) {
        id singleton = OPVTInvokeObjectNoArg(cls, selectorName);
        if (singleton) {
            [singletons addObject:@{
                @"selector": selectorName,
                @"class": NSStringFromClass([singleton class]) ?: @"",
                @"methods": OPVTMethodDiagnosticsForClass([singleton class],
                        targeted ? 100 : 20,
                        YES)
            }];
        }
    }
    if (singletons.count > 0) {
        entry[@"singletons"] = singletons;
        NSDictionary *first = singletons.firstObject;
        entry[@"singleton"] = first[@"selector"] ?: @"";
        entry[@"singleton_class"] = first[@"class"] ?: @"";
    }
    return entry;
}

static NSArray<NSDictionary *> *OPVTTargetedGlobalInputDiagnostics(void) {
    NSArray<NSString *> *classNames = @[
        @"SpringBoard",
        @"SBUIController",
        @"SBMainWorkspace",
        @"SBWorkspaceController",
        @"SBLockScreenManager",
        @"SBLockScreenController",
        @"SBLockScreenViewController",
        @"SBLegacyLockScreenEnvironment",
        @"SBDashBoardViewController",
        @"SBDashBoardLockScreenEnvironment",
        @"SBDashBoardHomeAffordanceController",
        @"SBCoverSheetPresentationManager",
        @"SBCoverSheetPrimarySlidingViewController",
        @"SBCoverSheetViewController",
        @"SBCoverSheetWindow",
        @"CSCoverSheetViewController",
        @"CSCombinedListViewController",
        @"CSPasscodeViewController",
        @"CSPasscodeBackgroundViewController",
        @"SBPlatterHomeGestureContext",
        @"SBHomeGestureManager",
        @"SBSystemGestureManager",
        @"SBSystemGestureStateAggregator",
        @"SBFluidSwitcherGestureManager",
        @"SBBacklightController",
        @"SBLockHardwareButton",
        @"SBLockScreenUnlockRequest",
        @"SBLockScreenBiometricAuthenticationCoordinator",
        @"SBAuthenticationFeedback",
        @"SBUIPasscodeLockViewBase",
        @"SBUIPasscodeLockViewWithKeypad",
        @"FBSystemService",
        @"BKSDisplayServices"
    ];

    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        if (!cls) {
            [result addObject:@{@"class": className, @"status": @"absent"}];
            continue;
        }
        NSMutableDictionary *entry = [OPVTClassInputDiagnosticEntry(cls, YES) mutableCopy];
        entry[@"status"] = @"present";
        [result addObject:entry];
    }
    return result;
}

static BOOL OPVTTargetLooksLikeSwipeUpToUnlock(NSDictionary *targetSummary) {
    NSString *label = [targetSummary[@"label"] isKindOfClass:[NSString class]]
            ? targetSummary[@"label"] : @"";
    if ([label rangeOfString:@"swipe up to unlock" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }
    return [label rangeOfString:@"unlock" options:NSCaseInsensitiveSearch].location != NSNotFound &&
            [label rangeOfString:@"swipe" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSMutableDictionary *OPVTAddLockScreenFallbackAttempt(NSMutableArray<NSDictionary *> *attempts,
        NSString *targetName,
        id target,
        NSString *selectorName,
        NSString *status,
        NSString *reason) {
    NSMutableDictionary *attempt = [@{
        @"target": targetName ?: @"",
        @"target_class": target ? (NSStringFromClass([target class]) ?: @"") : @"",
        @"selector": selectorName ?: @"",
        @"status": status ?: @"unavailable"
    } mutableCopy];
    if (reason.length > 0) {
        attempt[@"reason"] = reason;
    }
    [attempts addObject:attempt];
    return attempt;
}

static BOOL OPVTTryLockScreenPasscodeSelector(id target,
        NSString *targetName,
        NSString *selectorName,
        BOOL requireVisibilityCheck,
        NSMutableArray<NSDictionary *> *attempts,
        NSMutableDictionary *extra) {
    NSString *error = nil;
    BOOL ok = OPVTInvokeVoidOrBoolBoolBool(target, selectorName, YES, YES, &error);
    NSMutableDictionary *attempt = OPVTAddLockScreenFallbackAttempt(attempts, targetName, target, selectorName,
            ok ? @"ok" : @"unavailable", error);
    BOOL visible = NO;
    if (ok && OPVTInvokeBoolNoArg(target, @"isPasscodeLockVisible", &visible)) {
        attempt[@"passcode_visible"] = @(visible);
        if (requireVisibilityCheck && !visible) {
            attempt[@"status"] = @"unavailable";
            attempt[@"reason"] = @"passcode_not_visible_after_invocation";
            ok = NO;
        }
    } else if (ok && requireVisibilityCheck) {
        attempt[@"status"] = @"unavailable";
        attempt[@"reason"] = @"visibility_check_unavailable";
        ok = NO;
    }
    if (ok) {
        extra[@"activation_method"] = [NSString stringWithFormat:@"%@[%@]",
                targetName ?: @"lock_screen_target", selectorName ?: @""];
        return YES;
    }
    return NO;
}

static BOOL OPVTShowLockScreenPasscode(NSMutableDictionary *extra) {
    NSMutableArray<NSDictionary *> *attempts = [NSMutableArray array];
    Class managerClass = NSClassFromString(@"SBLockScreenManager");
    id manager = OPVTInvokeObjectNoArg(managerClass, @"sharedInstance");
    if (!manager) {
        OPVTAddLockScreenFallbackAttempt(attempts, @"SBLockScreenManager.sharedInstance",
                nil, @"sharedInstance", @"unavailable", @"target_missing");
    } else {
        id coverSheetViewController = OPVTInvokeObjectNoArg(manager, @"coverSheetViewController");
        if (OPVTTryLockScreenPasscodeSelector(coverSheetViewController, @"coverSheetViewController",
                @"setPasscodeLockVisible:animated:", YES, attempts, extra)) {
            extra[@"lockscreen_fallback"] = @{@"status": @"ok", @"attempts": attempts};
            return YES;
        }

        id environment = OPVTInvokeObjectNoArg(manager, @"lockScreenEnvironment");
        if (OPVTTryLockScreenPasscodeSelector(environment, @"lockScreenEnvironment",
                @"setPasscodeLockVisible:animated:", YES, attempts, extra)) {
            extra[@"lockscreen_fallback"] = @{@"status": @"ok", @"attempts": attempts};
            return YES;
        }

        if (OPVTTryLockScreenPasscodeSelector(manager, @"SBLockScreenManager",
                @"setPasscodeVisible:animated:", NO, attempts, extra)) {
            extra[@"lockscreen_fallback"] = @{@"status": @"ok", @"attempts": attempts};
            return YES;
        }
        if (OPVTTryLockScreenPasscodeSelector(manager, @"SBLockScreenManager",
                @"_setPasscodeVisible:animated:", NO, attempts, extra)) {
            extra[@"lockscreen_fallback"] = @{@"status": @"ok", @"attempts": attempts};
            return YES;
        }
    }

    Class presentationManagerClass = NSClassFromString(@"SBCoverSheetPresentationManager");
    id presentationManager = OPVTInvokeObjectNoArg(presentationManagerClass, @"sharedInstance");
    id coverSheetViewController = OPVTInvokeObjectNoArg(presentationManager, @"coverSheetViewController");
    if (OPVTTryLockScreenPasscodeSelector(coverSheetViewController,
            @"SBCoverSheetPresentationManager.coverSheetViewController",
            @"setPasscodeLockVisible:animated:", YES, attempts, extra)) {
        extra[@"lockscreen_fallback"] = @{@"status": @"ok", @"attempts": attempts};
        return YES;
    }

    extra[@"lockscreen_fallback"] = @{@"status": @"unavailable", @"attempts": attempts};
    return NO;
}

static BOOL OPVTSpringBoardLockedState(BOOL *outLocked) {
    if (!outLocked) {
        return NO;
    }
    id springBoard = OPVTInvokeObjectNoArg(NSClassFromString(@"SpringBoard"), @"sharedApplication");
    if (!springBoard) {
        springBoard = UIApplication.sharedApplication;
    }
    if (OPVTInvokeBoolNoArg(springBoard, @"isLocked", outLocked)) {
        return YES;
    }
    return OPVTInvokeBoolNoArg(springBoard, @"_accessibilityIsSystemLocked", outLocked);
}

static BOOL OPVTFinalizePasscodeUnlock(NSMutableDictionary *extra,
        NSMutableArray<NSDictionary *> *attempts,
        NSString *activationMethod) {
    usleep(800000);
    BOOL locked = YES;
    BOOL hasLockedState = OPVTSpringBoardLockedState(&locked);
    NSMutableDictionary *unlock = [@{@"attempts": attempts ?: @[]} mutableCopy];
    if (hasLockedState) {
        unlock[@"locked_after_attempt"] = @(locked);
    } else {
        unlock[@"lock_verification"] = @"unavailable";
    }
    if (hasLockedState && !locked) {
        unlock[@"status"] = @"ok";
        extra[@"activation_method"] = activationMethod ?: @"lockscreen_unlock";
        extra[@"lockscreen_unlock"] = unlock;
        return YES;
    }
    unlock[@"status"] = @"unavailable";
    unlock[@"reason"] = hasLockedState ? @"unlock_not_verified" : @"lock_verification_unavailable";
    extra[@"lockscreen_unlock"] = unlock;
    return NO;
}

static BOOL OPVTUnlockWithPasscode(NSString *passcode, NSMutableDictionary *extra) {
    NSMutableArray<NSDictionary *> *attempts = [NSMutableArray array];
    if (passcode.length == 0) {
        extra[@"lockscreen_unlock"] = @{
            @"status": @"unavailable",
            @"reason": @"missing_passcode"
        };
        return NO;
    }

    Class managerClass = NSClassFromString(@"SBLockScreenManager");
    id manager = OPVTInvokeObjectNoArg(managerClass, @"sharedInstance");
    if (!manager) {
        OPVTAddLockScreenFallbackAttempt(attempts, @"SBLockScreenManager.sharedInstance",
                nil, @"sharedInstance", @"unavailable", @"target_missing");
        extra[@"lockscreen_unlock"] = @{@"status": @"unavailable", @"attempts": attempts};
        return NO;
    }

    NSString *error = nil;
    BOOL ok = OPVTInvokeBoolObjectBoolBoolObject(manager,
            @"_attemptUnlockWithPasscode:mesa:finishUIUnlock:completion:",
            passcode,
            NO,
            YES,
            nil,
            &error);
    OPVTAddLockScreenFallbackAttempt(attempts, @"SBLockScreenManager", manager,
            @"_attemptUnlockWithPasscode:mesa:finishUIUnlock:completion:",
            ok ? @"ok" : @"unavailable", error);
    if (ok) {
        NSString *finishError = nil;
        BOOL finishOK = OPVTInvokeBoolIntegerObject(manager,
                @"unlockUIFromSource:withOptions:", 0, nil, &finishError);
        OPVTAddLockScreenFallbackAttempt(attempts, @"SBLockScreenManager", manager,
                @"unlockUIFromSource:withOptions:",
                finishOK ? @"ok" : @"unavailable", finishError);
        if (!finishOK) {
            finishError = nil;
            finishOK = OPVTInvokeBoolIntegerObject(manager,
                    @"_finishUIUnlockFromSource:withOptions:", 0, nil, &finishError);
            OPVTAddLockScreenFallbackAttempt(attempts, @"SBLockScreenManager", manager,
                    @"_finishUIUnlockFromSource:withOptions:",
                    finishOK ? @"ok" : @"unavailable", finishError);
        }
        if (finishOK) {
            return OPVTFinalizePasscodeUnlock(extra, attempts,
                    @"SBLockScreenManager[_attemptUnlockWithPasscode + finishUIUnlock]");
        }
    }

    error = nil;
    ok = OPVTInvokeVoidOrBoolObjectBoolObject(manager,
            @"attemptUnlockWithPasscode:finishUIUnlock:completion:",
            passcode,
            YES,
            nil,
            &error);
    OPVTAddLockScreenFallbackAttempt(attempts, @"SBLockScreenManager", manager,
            @"attemptUnlockWithPasscode:finishUIUnlock:completion:",
            ok ? @"ok" : @"unavailable", error);
    if (ok) {
        return OPVTFinalizePasscodeUnlock(extra, attempts,
                @"SBLockScreenManager[attemptUnlockWithPasscode:finishUIUnlock:completion:]");
    }

    extra[@"lockscreen_unlock"] = @{@"status": @"unavailable", @"attempts": attempts};
    return NO;
}

static NSDictionary *OPVTElementSummaryForView(UIView *view,
        UIWindow *window,
        NSInteger windowIndex,
        NSString *elementId) {
    if (!view) {
        return @{};
    }
    CGRect bounds = CGRectZero;
    @try {
        bounds = [view convertRect:view.bounds toView:window ?: view.window];
    } @catch (__unused NSException *exception) {
        bounds = CGRectZero;
    }
    NSMutableDictionary *summary = [@{
        @"id": elementId ?: @"",
        @"kind": OPVTViewKind(view),
        @"class": NSStringFromClass([view class]) ?: @"",
        @"label": OPVTViewLabel(view) ?: @"",
        @"bounds": OPVTBoundsArray(bounds),
        @"enabled": @(view.userInteractionEnabled),
        @"focused": @(view.isFirstResponder),
        @"window_id": @(windowIndex),
        @"sensitive": @NO,
        @"risk_hint": @"springboard_only"
    } mutableCopy];
    NSString *identifier = OPVTAccessibilityString(view.accessibilityIdentifier);
    if (identifier.length > 0) {
        summary[@"view_id"] = identifier;
    }
    return summary;
}

static BOOL OPVTElementMatches(NSString *requestedId, NSString *elementId, NSString *viewId) {
    if (requestedId.length == 0) {
        return NO;
    }
    return [requestedId isEqualToString:elementId ?: @""] ||
            (viewId.length > 0 && [requestedId isEqualToString:viewId]);
}

static UIView *OPVTFindInteractiveElementInView(UIView *view,
        UIWindow *window,
        NSInteger windowIndex,
        NSUInteger depth,
        NSUInteger *elementIndex,
        NSString *requestedId,
        NSDictionary **outSummary) {
    if (!view || depth > 8 || requestedId.length == 0) {
        return nil;
    }
    if (view.hidden || view.alpha < 0.02) {
        return nil;
    }
    CGRect bounds = CGRectZero;
    @try {
        bounds = [view convertRect:view.bounds toView:window];
    } @catch (__unused NSException *exception) {
        bounds = CGRectZero;
    }
    if (CGRectIsEmpty(bounds) || bounds.size.width < 1.0 || bounds.size.height < 1.0) {
        return nil;
    }

    NSString *label = OPVTViewLabel(view);
    NSString *identifier = OPVTAccessibilityString(view.accessibilityIdentifier);
    BOOL accessible = view.isAccessibilityElement || view.userInteractionEnabled ||
            [view isKindOfClass:[UIButton class]] || [view isKindOfClass:[UITextField class]];
    if (accessible && (label.length > 0 || identifier.length > 0)) {
        NSString *elementId = [NSString stringWithFormat:@"springboard-%ld-%lu",
                (long)windowIndex, (unsigned long)(*elementIndex)];
        (*elementIndex)++;
        if (OPVTElementMatches(requestedId, elementId, identifier)) {
            if (outSummary) {
                *outSummary = OPVTElementSummaryForView(view, window, windowIndex, elementId);
            }
            return view;
        }
    }

    for (UIView *subview in view.subviews ?: @[]) {
        UIView *match = OPVTFindInteractiveElementInView(subview, window, windowIndex,
                depth + 1, elementIndex, requestedId, outSummary);
        if (match) {
            return match;
        }
    }
    return nil;
}

static UIView *OPVTFindInteractiveElement(NSString *requestedId, NSDictionary **outSummary) {
    UIApplication *application = OPVTSafeSharedApplication();
    if (!application || requestedId.length == 0) {
        return nil;
    }
    NSArray<UIWindow *> *windows = OPVTApplicationWindows(application);
    NSInteger windowIndex = 0;
    NSUInteger elementIndex = 0;
    for (UIWindow *window in windows) {
        if (!window || window.hidden || window.alpha < 0.02) {
            windowIndex++;
            continue;
        }
        UIView *match = OPVTFindInteractiveElementInView(window, window, windowIndex, 0,
                &elementIndex, requestedId, outSummary);
        if (match) {
            return match;
        }
        windowIndex++;
    }
    return nil;
}

static CGPoint OPVTNormalizeInputPoint(double x, double y, NSString **outCoordinateSpace) {
    NSString *coordinateSpace = @"points";
    UIScreen *screen = OPVTSafeMainScreen();
    if (screen) {
        @try {
            CGRect bounds = screen.bounds;
            CGFloat scale = screen.scale;
            BOOL looksLikePixels = scale > 0.5 &&
                    (x > bounds.size.width * 1.2 || y > bounds.size.height * 1.2) &&
                    x <= bounds.size.width * scale * 1.2 &&
                    y <= bounds.size.height * scale * 1.2;
            if (looksLikePixels) {
                x = x / scale;
                y = y / scale;
                coordinateSpace = @"pixels_scaled_to_points";
            }
        } @catch (__unused NSException *exception) {
        }
    }
    if (outCoordinateSpace) {
        *outCoordinateSpace = coordinateSpace;
    }
    return CGPointMake((CGFloat)x, (CGFloat)y);
}

static UIView *OPVTHitTestViewAtPoint(CGPoint point,
        UIWindow **outWindow,
        NSInteger *outWindowIndex,
        NSDictionary **outSummary) {
    UIApplication *application = OPVTSafeSharedApplication();
    if (!application) {
        return nil;
    }
    NSArray<UIWindow *> *windows = [OPVTApplicationWindows(application)
            sortedArrayUsingComparator:^NSComparisonResult(UIWindow *left, UIWindow *right) {
        CGFloat leftLevel = left.windowLevel;
        CGFloat rightLevel = right.windowLevel;
        if (leftLevel < rightLevel) {
            return NSOrderedDescending;
        }
        if (leftLevel > rightLevel) {
            return NSOrderedAscending;
        }
        return NSOrderedSame;
    }];

    NSInteger windowIndex = 0;
    for (UIWindow *window in windows) {
        if (!window || window == OPVTOverlayWindow || window.hidden || window.alpha < 0.02 ||
                !window.userInteractionEnabled) {
            windowIndex++;
            continue;
        }
        CGPoint localPoint = CGPointZero;
        @try {
            localPoint = [window convertPoint:point fromWindow:nil];
            if (!CGRectContainsPoint(window.bounds, localPoint)) {
                windowIndex++;
                continue;
            }
            UIView *hitView = [window hitTest:localPoint withEvent:nil];
            if (hitView) {
                if (outWindow) {
                    *outWindow = window;
                }
                if (outWindowIndex) {
                    *outWindowIndex = windowIndex;
                }
                if (outSummary) {
                    *outSummary = OPVTElementSummaryForView(hitView, window, windowIndex, @"");
                }
                return hitView;
            }
        } @catch (NSException *exception) {
            OPVTLog(@"input hitTest exception window=%@ name=%@",
                    NSStringFromClass([window class]) ?: @"", exception.name ?: @"");
        }
        windowIndex++;
    }
    return nil;
}

static NSDictionary *OPVTActivateView(UIView *view,
        NSDictionary *targetSummary,
        NSString *requestId,
        NSString *actionType,
        CGPoint point,
        NSString *coordinateSpace,
        long long durationMs,
        BOOL includeDiagnostics) {
    if (!view) {
        return OPVTInputResponse(@"unavailable", @"target_view_missing", requestId, actionType, nil);
    }

    NSMutableDictionary *extra = [@{
        @"target_found": @YES,
        @"target": targetSummary ?: @{},
        @"point": @{@"x": @((double)point.x), @"y": @((double)point.y)},
        @"coordinate_space": coordinateSpace ?: @"points"
    } mutableCopy];
    if (durationMs > 0) {
        extra[@"duration_ms"] = @(durationMs);
    }
    if (includeDiagnostics) {
        extra[@"diagnostics"] = @{
            @"target_methods": OPVTTargetInputDiagnostics(view),
            @"targeted_runtime_candidates": OPVTTargetedGlobalInputDiagnostics()
        };
    }

    @try {
        BOOL activated = [view accessibilityActivate];
        extra[@"accessibility_activate_attempted"] = @YES;
        extra[@"accessibility_activate_result"] = @(activated);
        if (activated) {
            extra[@"activation_method"] = @"accessibilityActivate";
            return OPVTInputResponse(@"ok", nil, requestId, actionType, extra);
        }
    } @catch (NSException *exception) {
        extra[@"accessibility_activate_exception"] = exception.name ?: @"";
    }

    if ([view isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)view;
        if (!control.enabled) {
            extra[@"control_enabled"] = @NO;
            return OPVTInputResponse(@"unavailable", @"control_disabled", requestId, actionType, extra);
        }
        @try {
            if ([actionType isEqualToString:@"long_press"]) {
                [control sendActionsForControlEvents:UIControlEventTouchDown];
                long long boundedDurationMs = MAX(100LL, MIN(durationMs > 0 ? durationMs : 700LL, 1500LL));
                usleep((useconds_t)(boundedDurationMs * 1000));
                extra[@"bounded_duration_ms"] = @(boundedDurationMs);
            }
            [control sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
            [control sendActionsForControlEvents:UIControlEventTouchUpInside];
            extra[@"activation_method"] = @"UIControlActions";
            return OPVTInputResponse(@"ok", nil, requestId, actionType, extra);
        } @catch (NSException *exception) {
            extra[@"control_action_exception"] = exception.name ?: @"";
        }
    }

    if (OPVTTargetLooksLikeSwipeUpToUnlock(targetSummary) &&
            OPVTShowLockScreenPasscode(extra)) {
        return OPVTInputResponse(@"ok", nil, requestId, actionType, extra);
    }

    return OPVTInputResponse(@"unavailable", @"no_activation_method", requestId, actionType, extra);
}

static NSDictionary *OPVTPerformSpringBoardInput(NSDictionary *request) {
    NSString *requestId = [request[@"request_id"] isKindOfClass:[NSString class]]
            ? request[@"request_id"] : @"";
    NSDictionary *action = [request[@"action"] isKindOfClass:[NSDictionary class]]
            ? request[@"action"] : @{};
    NSString *actionType = [action[@"type"] isKindOfClass:[NSString class]]
            ? action[@"type"] : @"";
    if (requestId.length == 0) {
        return OPVTInputResponse(@"unavailable", @"missing_request_id", requestId, actionType, nil);
    }
    if (![actionType isEqualToString:@"tap"] &&
            ![actionType isEqualToString:@"tap_element"] &&
            ![actionType isEqualToString:@"long_press"] &&
            ![actionType isEqualToString:@"show_passcode"] &&
            ![actionType isEqualToString:@"unlock_with_passcode"]) {
        return OPVTInputResponse(@"unavailable", @"unsupported_action_type", requestId, actionType, nil);
    }
    BOOL includeDiagnostics = OPVTBoolValue(action[@"diagnostics"], NO);
    if ([actionType isEqualToString:@"show_passcode"]) {
        NSMutableDictionary *extra = [@{
            @"target_found": @NO,
            @"coordinate_space": @"springboard_lock_screen"
        } mutableCopy];
        if (OPVTShowLockScreenPasscode(extra)) {
            return OPVTInputResponse(@"ok", nil, requestId, actionType, extra);
        }
        return OPVTInputResponse(@"unavailable", @"passcode_visibility_unavailable",
                requestId, actionType, extra);
    }
    if ([actionType isEqualToString:@"unlock_with_passcode"]) {
        NSString *passcode = [action[@"passcode"] isKindOfClass:[NSString class]]
                ? action[@"passcode"] : @"";
        NSMutableDictionary *extra = [@{
            @"target_found": @NO,
            @"coordinate_space": @"springboard_lock_screen"
        } mutableCopy];
        if (passcode.length == 0) {
            return OPVTInputResponse(@"unavailable", @"missing_passcode",
                    requestId, actionType, extra);
        }
        if (OPVTUnlockWithPasscode(passcode, extra)) {
            return OPVTInputResponse(@"ok", nil, requestId, actionType, extra);
        }
        return OPVTInputResponse(@"unavailable", @"unlock_invocation_failed",
                requestId, actionType, extra);
    }

    NSString *coordinateSpace = @"points";
    CGPoint point = CGPointZero;
    BOOL hasPoint = [action[@"x"] respondsToSelector:@selector(doubleValue)] &&
            [action[@"y"] respondsToSelector:@selector(doubleValue)];
    if (hasPoint) {
        point = OPVTNormalizeInputPoint(OPVTDoubleValue(action[@"x"], 0.0),
                OPVTDoubleValue(action[@"y"], 0.0), &coordinateSpace);
    }
    long long durationMs = OPVTLongLongValue(action[@"duration_ms"],
            [actionType isEqualToString:@"long_press"] ? 700 : 80);

    NSDictionary *targetSummary = nil;
    UIView *target = nil;
    if ([actionType isEqualToString:@"tap_element"]) {
        NSString *elementId = [action[@"element_id"] isKindOfClass:[NSString class]]
                ? action[@"element_id"] : @"";
        if (elementId.length == 0 && [action[@"view_id"] isKindOfClass:[NSString class]]) {
            elementId = action[@"view_id"];
        }
        if (elementId.length == 0) {
            return OPVTInputResponse(@"unavailable", @"missing_element_id", requestId, actionType, nil);
        }
        target = OPVTFindInteractiveElement(elementId, &targetSummary);
        if (!target) {
            return OPVTInputResponse(@"unavailable", @"element_not_found", requestId, actionType, @{
                @"element_id": elementId
            });
        }
        if (!hasPoint) {
            NSArray *bounds = targetSummary[@"bounds"];
            if ([bounds isKindOfClass:[NSArray class]] && bounds.count >= 4) {
                double bx = OPVTDoubleValue(bounds[0], 0.0);
                double by = OPVTDoubleValue(bounds[1], 0.0);
                double bw = OPVTDoubleValue(bounds[2], 0.0);
                double bh = OPVTDoubleValue(bounds[3], 0.0);
                point = CGPointMake((CGFloat)(bx + bw / 2.0), (CGFloat)(by + bh / 2.0));
                coordinateSpace = @"ui_tree.bounds_center";
            }
        }
    } else {
        if (!hasPoint) {
            return OPVTInputResponse(@"unavailable", @"missing_coordinates", requestId, actionType, nil);
        }
        UIWindow *window = nil;
        NSInteger windowIndex = -1;
        target = OPVTHitTestViewAtPoint(point, &window, &windowIndex, &targetSummary);
        if (!target) {
            return OPVTInputResponse(@"unavailable", @"hit_test_miss", requestId, actionType, @{
                @"point": @{@"x": @((double)point.x), @"y": @((double)point.y)},
                @"coordinate_space": coordinateSpace
            });
        }
    }

    return OPVTActivateView(target, targetSummary, requestId, actionType,
            point, coordinateSpace, durationMs, includeDiagnostics);
}

static NSDictionary *OPVTSceneSnapshot(id scene, NSString *provider) {
    if (!scene) {
        return nil;
    }
    NSString *identifier = nil;
    for (NSString *selector in @[@"identifier", @"sceneIdentifier", @"persistenceIdentifier"]) {
        identifier = OPVTStringFromObject(OPVTInvokeObjectNoArg(scene, selector));
        if (identifier.length > 0) {
            break;
        }
    }
    NSString *bundleId = OPVTBundleIdentifierFromObject(scene, 0);
    NSMutableDictionary *snapshot = [@{
        @"class": NSStringFromClass([scene class]) ?: @"",
        @"provider": provider ?: @"unknown"
    } mutableCopy];
    if (identifier.length > 0) {
        snapshot[@"identifier"] = identifier;
    }
    if (bundleId.length > 0) {
        snapshot[@"bundle_id"] = bundleId;
    }
    BOOL boolValue = NO;
    for (NSString *selector in @[
        @"isForeground",
        @"isForegroundActive",
        @"isActive",
        @"isUIApplicationScene",
        @"isVisible"
    ]) {
        if (OPVTInvokeBoolNoArg(scene, selector, &boolValue)) {
            snapshot[selector] = @(boolValue);
        }
    }
    long long integerValue = 0;
    for (NSString *selector in @[@"activationState", @"interfaceOrientation"]) {
        if (OPVTInvokeIntegerNoArg(scene, selector, &integerValue)) {
            snapshot[selector] = @(integerValue);
        }
    }
    return snapshot;
}

static NSArray<NSDictionary *> *OPVTFrontBoardSceneSnapshots(void) {
    NSMutableArray<NSDictionary *> *snapshots = [NSMutableArray array];
    Class managerClass = objc_getClass("FBSceneManager");
    id manager = OPVTInvokeObjectNoArg(managerClass, @"sharedInstance");
    if (!manager) {
        manager = OPVTInvokeObjectNoArg(managerClass, @"sharedManager");
    }
    for (NSString *selector in @[@"scenes", @"allScenes", @"mutableScenes"]) {
        NSArray *scenes = OPVTArrayFromCollection(OPVTInvokeObjectNoArg(manager, selector));
        for (id scene in scenes) {
            NSDictionary *snapshot = OPVTSceneSnapshot(scene, [NSString stringWithFormat:@"FBSceneManager.%@", selector]);
            if (snapshot) {
                [snapshots addObject:snapshot];
            }
            if (snapshots.count >= 32) {
                return snapshots;
            }
        }
        if (snapshots.count > 0) {
            break;
        }
    }
    return snapshots;
}

static NSDictionary *OPVTForegroundCandidateSnapshot(id object, NSString *provider) {
    if (!object) {
        return nil;
    }
    NSString *bundleId = OPVTBundleIdentifierFromObject(object, 0);
    NSString *stringValue = OPVTStringFromObject(object);
    if (bundleId.length == 0 && OPVTBundleIdentifierLooksValid(stringValue)) {
        bundleId = stringValue;
    }
    NSMutableDictionary *snapshot = [@{
        @"class": NSStringFromClass([object class]) ?: @"",
        @"provider": provider ?: @"unknown"
    } mutableCopy];
    if (bundleId.length > 0) {
        snapshot[@"bundle_id"] = bundleId;
    }
    if (stringValue.length > 0 && stringValue.length < 160) {
        snapshot[@"string_value"] = stringValue;
    }
    BOOL boolValue = NO;
    for (NSString *selector in @[
        @"isForeground",
        @"isForegroundActive",
        @"isActive",
        @"isVisible"
    ]) {
        if (OPVTInvokeBoolNoArg(object, selector, &boolValue)) {
            snapshot[selector] = @(boolValue);
        }
    }
    long long integerValue = 0;
    for (NSString *selector in @[@"activationState", @"pid", @"processIdentifier"]) {
        if (OPVTInvokeIntegerNoArg(object, selector, &integerValue)) {
            snapshot[selector] = @(integerValue);
        }
    }
    return snapshot.count > 2 ? snapshot : nil;
}

static void OPVTAddForegroundCandidatesForTarget(NSMutableArray<NSDictionary *> *candidates,
        id target, NSString *providerPrefix) {
    if (!target || candidates.count >= 32) {
        return;
    }
    NSArray<NSString *> *selectors = @[
        @"foregroundApplication",
        @"frontmostApplication",
        @"frontMostApplication",
        @"activeApplication",
        @"currentApplication",
        @"displayedApplication",
        @"focusedApplication",
        @"topApplication",
        @"application",
        @"_accessibilityFrontMostApplication",
        @"accessibilityFrontMostApplication",
        @"_accessibilityFocusedApplication",
        @"mainDisplayLayoutState",
        @"layoutState"
    ];
    for (NSString *selector in selectors) {
        id value = OPVTInvokeObjectNoArg(target, selector);
        NSArray *values = OPVTArrayFromCollection(value);
        if (values.count == 0 && value) {
            values = @[value];
        }
        for (id object in values) {
            NSDictionary *snapshot = OPVTForegroundCandidateSnapshot(
                    object, [NSString stringWithFormat:@"%@.%@", providerPrefix ?: @"unknown", selector]);
            if (snapshot) {
                [candidates addObject:snapshot];
            }
            if (candidates.count >= 32) {
                return;
            }
        }
    }
}

static NSArray<NSDictionary *> *OPVTForegroundCandidateSnapshots(void) {
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    UIApplication *application = OPVTSafeSharedApplication();
    OPVTAddForegroundCandidatesForTarget(candidates, application, @"UIApplication");

    NSArray<NSString *> *classNames = @[
        @"SpringBoard",
        @"SBMainWorkspace",
        @"SBWorkspace",
        @"SBUIController",
        @"SBMainSwitcherController",
        @"SBAppSwitcherModel",
        @"SBApplicationController",
        @"FBSceneManager"
    ];
    NSArray<NSString *> *singletonSelectors = @[
        @"sharedInstance",
        @"sharedManager",
        @"sharedApplication",
        @"sharedController"
    ];
    for (NSString *className in classNames) {
        Class cls = objc_getClass(className.UTF8String);
        if (!cls) {
            continue;
        }
        for (NSString *singletonSelector in singletonSelectors) {
            id singleton = OPVTInvokeObjectNoArg(cls, singletonSelector);
            if (!singleton) {
                continue;
            }
            OPVTAddForegroundCandidatesForTarget(
                    candidates,
                    singleton,
                    [NSString stringWithFormat:@"%@.%@", className, singletonSelector]);
            if (candidates.count >= 32) {
                return candidates;
            }
        }
    }
    return candidates;
}

static NSDictionary *OPVTProviderDiagnosticForTarget(id target, NSString *provider) {
    NSMutableDictionary *diagnostic = [@{
        @"provider": provider ?: @"unknown",
        @"available": @(target != nil)
    } mutableCopy];
    if (!target) {
        return diagnostic;
    }
    diagnostic[@"class"] = NSStringFromClass([target class]) ?: @"";
    NSArray<NSString *> *selectors = @[
        @"scenes",
        @"allScenes",
        @"mutableScenes",
        @"connectedScenes",
        @"foregroundScenes",
        @"applicationScenes",
        @"runningApplications",
        @"allApplications",
        @"applications",
        @"displayedApplications",
        @"mainDisplayLayouts",
        @"recentDisplayItems",
        @"items"
    ];
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    for (NSString *selector in selectors) {
        SEL sel = NSSelectorFromString(selector);
        if (![target respondsToSelector:sel]) {
            continue;
        }
        id value = OPVTInvokeObjectNoArg(target, selector);
        NSArray *items = OPVTArrayFromCollection(value);
        counts[selector] = @(items.count);
    }
    if (counts.count > 0) {
        diagnostic[@"collection_counts"] = counts;
    }
    return diagnostic;
}

static NSArray<NSDictionary *> *OPVTProviderDiagnostics(void) {
    NSMutableArray<NSDictionary *> *diagnostics = [NSMutableArray array];
    UIApplication *application = OPVTSafeSharedApplication();
    [diagnostics addObject:OPVTProviderDiagnosticForTarget(application, @"UIApplication.sharedApplication")];

    NSArray<NSString *> *classNames = @[
        @"FBSceneManager",
        @"SBMainWorkspace",
        @"SBWorkspace",
        @"SBUIController",
        @"SBMainSwitcherController",
        @"SBAppSwitcherModel",
        @"SBApplicationController",
        @"SpringBoard"
    ];
    NSArray<NSString *> *singletonSelectors = @[@"sharedInstance", @"sharedManager", @"sharedApplication", @"sharedController"];
    for (NSString *className in classNames) {
        Class cls = objc_getClass(className.UTF8String);
        if (!cls) {
            [diagnostics addObject:@{
                @"provider": className,
                @"available": @NO,
                @"reason": @"class_missing"
            }];
            continue;
        }
        BOOL addedSingleton = NO;
        for (NSString *singletonSelector in singletonSelectors) {
            id singleton = OPVTInvokeObjectNoArg(cls, singletonSelector);
            if (!singleton) {
                continue;
            }
            [diagnostics addObject:OPVTProviderDiagnosticForTarget(
                    singleton,
                    [NSString stringWithFormat:@"%@.%@", className, singletonSelector])];
            addedSingleton = YES;
        }
        if (!addedSingleton) {
            [diagnostics addObject:@{
                @"provider": className,
                @"available": @YES,
                @"reason": @"singleton_unavailable"
            }];
        }
    }
    return diagnostics;
}

static NSString *OPVTOrientationName(NSInteger orientation) {
    switch (orientation) {
        case UIInterfaceOrientationPortrait:
            return @"portrait";
        case UIInterfaceOrientationPortraitUpsideDown:
            return @"portrait_upside_down";
        case UIInterfaceOrientationLandscapeLeft:
            return @"landscape_left";
        case UIInterfaceOrientationLandscapeRight:
            return @"landscape_right";
        default:
            return @"unknown";
    }
}

static NSDictionary *OPVTDisplaySnapshot(void) {
    NSMutableDictionary *display = [@{
        @"status": @"unavailable",
        @"provider": @"UIKit.SpringBoard"
    } mutableCopy];
    UIScreen *screen = OPVTSafeMainScreen();
    if (!screen) {
        display[@"reason"] = @"main_screen_unavailable";
        return display;
    }
    CGRect bounds = CGRectZero;
    CGFloat scale = 0.0;
    @try {
        bounds = screen.bounds;
        scale = screen.scale;
    } @catch (NSException *exception) {
        display[@"reason"] = @"screen_metrics_exception";
        display[@"exception_name"] = exception.name ?: @"";
        return display;
    }
    NSInteger orientation = UIInterfaceOrientationUnknown;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = OPVTActiveWindowScene();
        orientation = scene ? scene.interfaceOrientation : UIInterfaceOrientationUnknown;
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIApplication *application = OPVTSafeSharedApplication();
        orientation = application ? application.statusBarOrientation : UIInterfaceOrientationUnknown;
#pragma clang diagnostic pop
    }
    display[@"status"] = @"available";
    display[@"bounds_width"] = @((double)bounds.size.width);
    display[@"bounds_height"] = @((double)bounds.size.height);
    display[@"scale"] = @((double)scale);
    display[@"pixel_width"] = @((double)(bounds.size.width * scale));
    display[@"pixel_height"] = @((double)(bounds.size.height * scale));
    display[@"orientation"] = @(orientation);
    display[@"orientation_name"] = OPVTOrientationName(orientation);
    return display;
}

static BOOL OPVTWriteSpringBoardState(NSDictionary *state) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:state
                                                   options:0
                                                     error:nil];
    if (data.length == 0) {
        OPVTLog(@"springboard state encode failed");
        return NO;
    }
    BOOL wrote = [data writeToFile:OPVTSpringBoardStatePath atomically:YES];
    if (wrote) {
        chmod(OPVTSpringBoardStatePath.UTF8String, 0644);
        int count = __sync_add_and_fetch(&OPVTStatePublishSuccessCount, 1);
        if (count <= 3 || count % 30 == 0) {
            NSDictionary *display = [state[@"display"] isKindOfClass:[NSDictionary class]]
                    ? state[@"display"] : @{};
            OPVTLog(@"springboard state published count=%d foreground=%@ scenes=%@ display=%@",
                    count,
                    state[@"foreground_app"] ?: @"",
                    state[@"scene_count"] ?: @0,
                    display[@"status"] ?: @"unknown");
        }
        return YES;
    }
    OPVTLog(@"springboard state write failed path=%@", OPVTSpringBoardStatePath);
    return NO;
}

static void OPVTPublishSpringBoardState(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:OPVTStorePath
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions: @0755}
                                                        error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:OPVTSpringBoardStateDir
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions: @0755}
                                                        error:nil];

        @try {
            NSArray<NSDictionary *> *sceneSnapshots = OPVTFrontBoardSceneSnapshots();
            BOOL includeForegroundDiagnostics = OPVTBoolPreference(@"ForegroundDiagnosticsEnabled", NO);
            NSArray<NSDictionary *> *foregroundCandidates = includeForegroundDiagnostics
                    ? OPVTForegroundCandidateSnapshots() : @[];
            NSArray<NSDictionary *> *providerDiagnostics = includeForegroundDiagnostics
                    ? OPVTProviderDiagnostics() : @[];
            NSDictionary *foregroundCache = OPVTForegroundCacheSnapshot();
            NSDictionary *uiTree = OPVTUITreeSnapshot();
            NSString *foreground = @"";
            NSString *foregroundSource = @"unavailable";
            NSUInteger activeSceneCount = 0;
            for (NSDictionary *scene in sceneSnapshots) {
                NSString *bundleId = [scene[@"bundle_id"] isKindOfClass:[NSString class]]
                        ? scene[@"bundle_id"] : @"";
                if (bundleId.length == 0 || [bundleId isEqualToString:@"com.apple.springboard"]) {
                    continue;
                }
                BOOL active = [scene[@"isForegroundActive"] boolValue] ||
                        [scene[@"isForeground"] boolValue] ||
                        [scene[@"isActive"] boolValue] ||
                        ([scene[@"activationState"] respondsToSelector:@selector(integerValue)] &&
                         [scene[@"activationState"] integerValue] <= 1);
                if (active) {
                    activeSceneCount++;
                }
                if (foreground.length == 0 && active) {
                    foreground = bundleId;
                    foregroundSource = scene[@"provider"] ?: @"frontboard_scene_active";
                }
            }
            if (foreground.length == 0) {
                for (NSDictionary *scene in sceneSnapshots) {
                    NSString *bundleId = [scene[@"bundle_id"] isKindOfClass:[NSString class]]
                            ? scene[@"bundle_id"] : @"";
                    if (bundleId.length > 0 && ![bundleId isEqualToString:@"com.apple.springboard"]) {
                        foreground = bundleId;
                        foregroundSource = scene[@"provider"] ?: @"frontboard_scene_first";
                        break;
                    }
                }
            }
            if (foreground.length == 0) {
                for (NSDictionary *candidate in foregroundCandidates) {
                    NSString *bundleId = [candidate[@"bundle_id"] isKindOfClass:[NSString class]]
                            ? candidate[@"bundle_id"] : @"";
                    if (bundleId.length > 0 && ![bundleId isEqualToString:@"com.apple.springboard"]) {
                        foreground = bundleId;
                        foregroundSource = candidate[@"provider"] ?: @"foreground_candidate";
                        break;
                    }
                }
            }
            if (foreground.length == 0 && [foregroundCache[@"status"] isEqualToString:@"ok"]) {
                NSString *bundleId = [foregroundCache[@"bundle_id"] isKindOfClass:[NSString class]]
                        ? foregroundCache[@"bundle_id"] : @"";
                if (bundleId.length > 0 && ![bundleId isEqualToString:@"com.apple.springboard"]) {
                    foreground = bundleId;
                    foregroundSource = [NSString stringWithFormat:@"foreground_cache.%@",
                            foregroundCache[@"source"] ?: @"runtime"];
                }
            }

            NSDictionary *state = @{
                @"schema": @"openphone.springboard_state.v1",
                @"timestamp_ms": @(OPVTNowMs()),
                @"provider": @"OpenPhoneVolumeTrigger.SpringBoardState",
                @"foreground_app": foreground ?: @"",
                @"foreground_source": foregroundSource ?: @"unavailable",
                @"active_scene_count": @(activeSceneCount),
                @"scene_count": @(sceneSnapshots.count),
                @"scenes": sceneSnapshots,
                @"foreground_candidates": foregroundCandidates,
                @"foreground_cache": foregroundCache,
                @"provider_diagnostics": providerDiagnostics,
                @"ui_tree": uiTree,
                @"screenshot_bridge": OPVTScreenshotBridgeStatus(),
                @"input_bridge": OPVTInputBridgeStatus(),
                @"clipboard_bridge": OPVTClipboardBridgeStatus(),
                @"prompt_bridge": OPVTPromptBridgeStatus(),
                @"display": OPVTDisplaySnapshot(),
                @"source": @"springboard"
            };
            OPVTWriteSpringBoardState(state);
        } @catch (NSException *exception) {
            OPVTLog(@"springboard state publish exception name=%@ reason=%@",
                    exception.name ?: @"", exception.reason ?: @"");
            NSDictionary *fallbackState = @{
                @"schema": @"openphone.springboard_state.v1",
                @"timestamp_ms": @(OPVTNowMs()),
                @"provider": @"OpenPhoneVolumeTrigger.SpringBoardState",
                @"foreground_app": @"",
                @"foreground_source": @"unavailable",
                @"active_scene_count": @0,
                @"scene_count": @0,
                @"scenes": @[],
                @"foreground_cache": OPVTForegroundCacheSnapshot(),
                @"ui_tree": OPVTUITreeSnapshot(),
                @"screenshot_bridge": OPVTScreenshotBridgeStatus(),
                @"input_bridge": OPVTInputBridgeStatus(),
                @"clipboard_bridge": OPVTClipboardBridgeStatus(),
                @"prompt_bridge": OPVTPromptBridgeStatus(),
                @"display": @{
                    @"status": @"unavailable",
                    @"provider": @"UIKit.SpringBoard",
                    @"reason": @"publisher_exception",
                    @"exception_name": exception.name ?: @""
                },
                @"source": @"springboard",
                @"publish_error": @"exception"
            };
            OPVTWriteSpringBoardState(fallbackState);
        }
    }
}

static void OPVTPublishSpringBoardStateOnMain(void) {
    if ([NSThread isMainThread]) {
        OPVTPublishSpringBoardState();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            OPVTPublishSpringBoardState();
        });
    }
}

static void OPVTShowOverlay(NSString *title, NSString *subtitle, UIColor *color) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScreen *screen = OPVTSafeMainScreen();
        if (!screen) {
            OPVTLog(@"overlay skipped reason=main_screen_unavailable");
            return;
        }
        CGRect bounds = screen.bounds;
        UIWindowScene *windowScene = OPVTActiveWindowScene();
        if (!OPVTOverlayWindow) {
            if (@available(iOS 13.0, *)) {
                if (windowScene) {
                    OPVTOverlayWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
                    OPVTOverlayWindow.frame = bounds;
                } else {
                    OPVTOverlayWindow = [[UIWindow alloc] initWithFrame:bounds];
                }
            } else {
                OPVTOverlayWindow = [[UIWindow alloc] initWithFrame:bounds];
            }
            OPVTOverlayWindow.windowLevel = UIWindowLevelAlert + 2000;
            OPVTOverlayWindow.userInteractionEnabled = NO;
            OPVTOverlayWindow.backgroundColor = [UIColor clearColor];
            UIViewController *controller = [[UIViewController alloc] init];
            controller.view.backgroundColor = [UIColor clearColor];
            OPVTOverlayWindow.rootViewController = controller;
        } else if (@available(iOS 13.0, *)) {
            if (windowScene && OPVTOverlayWindow.windowScene != windowScene) {
                OPVTOverlayWindow.windowScene = windowScene;
            }
        }
        OPVTOverlayWindow.frame = bounds;
        UIView *root = OPVTOverlayWindow.rootViewController.view;
        [root.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

        CGFloat width = MIN(bounds.size.width - 32.0, 330.0);
        UIView *panel = [[UIView alloc] initWithFrame:CGRectMake((bounds.size.width - width) / 2.0, 58.0, width, 74.0)];
        panel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
        panel.layer.cornerRadius = 14.0;
        panel.layer.masksToBounds = YES;

        UIView *stripe = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 5.0, 74.0)];
        stripe.backgroundColor = color ?: [UIColor systemGreenColor];
        [panel addSubview:stripe];

        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(18.0, 11.0, width - 30.0, 26.0)];
        titleLabel.text = title ?: @"OpenPhone";
        titleLabel.textColor = [UIColor whiteColor];
        titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
        [panel addSubview:titleLabel];

        UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(18.0, 38.0, width - 30.0, 24.0)];
        subtitleLabel.text = subtitle ?: @"Triggered";
        subtitleLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.86];
        subtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
        subtitleLabel.adjustsFontSizeToFitWidth = YES;
        subtitleLabel.minimumScaleFactor = 0.72;
        [panel addSubview:subtitleLabel];

        panel.alpha = 0.0;
        [root addSubview:panel];
        OPVTOverlayWindow.hidden = NO;
        OPVTOverlayWindow.alpha = 1.0;
        OPVTLog(@"overlay shown title=%@ subtitle=%@ scene=%d",
                title ?: @"", subtitle ?: @"", windowScene != nil);

        [UIView animateWithDuration:0.16 animations:^{
            panel.alpha = 1.0;
        } completion:^(__unused BOOL finished) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.35 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.18 animations:^{
                    panel.alpha = 0.0;
                } completion:^(__unused BOOL done) {
                    [panel removeFromSuperview];
                    OPVTOverlayWindow.hidden = YES;
                }];
            });
        }];
    });
}

static BOOL OPVTWriteAll(int fd, NSData *data, int *errorOut) {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written > 0) {
            bytes += written;
            remaining -= (NSUInteger)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (errorOut) {
            *errorOut = errno;
        }
        return NO;
    }
    return YES;
}

static NSDictionary *OPVTAgentRequestOnce(NSData *data) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return @{@"status": @"error", @"reason": @"socket_failed", @"errno": @(errno)};
    }
#ifdef SO_NOSIGPIPE
    int noSigPipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
#endif

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, OPVTSocketPath, sizeof(address.sun_path));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        int savedErrno = errno;
        close(fd);
        return @{@"status": @"error", @"reason": @"connect_failed", @"errno": @(savedErrno)};
    }

    NSMutableData *line = [data mutableCopy];
    const char newline = '\n';
    [line appendBytes:&newline length:1];
    int writeErrno = 0;
    if (!OPVTWriteAll(fd, line, &writeErrno)) {
        close(fd);
        return @{@"status": @"error", @"reason": @"write_failed", @"errno": @(writeErrno)};
    }
    shutdown(fd, SHUT_WR);

    NSMutableData *response = [NSMutableData data];
    char buffer[4096];
    while (response.length < 65536) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count > 0) {
            [response appendBytes:buffer length:(NSUInteger)count];
            continue;
        }
        break;
    }
    close(fd);

    id object = [NSJSONSerialization JSONObjectWithData:response options:0 error:nil];
    if ([object isKindOfClass:[NSDictionary class]]) {
        return object;
    }
    return @{@"status": @"error", @"reason": @"json_decode_failed", @"bytes": @(response.length)};
}

static BOOL OPVTShouldRetryAgentResponse(NSDictionary *response) {
    if (![response[@"reason"] isEqualToString:@"connect_failed"]) {
        return NO;
    }
    NSInteger code = [response[@"errno"] integerValue];
    return code == ECONNREFUSED || code == ENOENT || code == ETIMEDOUT || code == EAGAIN;
}

static NSDictionary *OPVTAgentRequest(NSDictionary *request) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:request ?: @{} options:0 error:nil];
    if (!data) {
        return @{@"status": @"error", @"reason": @"json_encode_failed"};
    }

    NSDictionary *response = nil;
    const int attempts = 25;
    for (int attempt = 1; attempt <= attempts; attempt++) {
        response = OPVTAgentRequestOnce(data);
        if (!OPVTShouldRetryAgentResponse(response)) {
            if (attempt > 1) {
                OPVTLog(@"agent request recovered attempt=%d response=%@", attempt, response);
            }
            return response;
        }
        OPVTLog(@"agent connect retry attempt=%d/%d response=%@",
                attempt, attempts, response ?: @{});
        usleep(400000);
    }

    NSMutableDictionary *finalResponse = [response mutableCopy] ?: [NSMutableDictionary dictionary];
    finalResponse[@"attempts"] = @(attempts);
    return finalResponse;
}

static void OPVTCallAgentWithGoal(NSString *requestedGoal, BOOL userProvidedGoal) {
    OPVTPublishSpringBoardStateOnMain();
    NSString *goal = OPVTTrimmedString(requestedGoal);
    if (goal.length == 0) {
        goal = OPVTStringPreference(@"TriggerGoal", OPVTDefaultTriggerGoal);
    }
    if (goal.length == 0 || [goal isEqualToString:OPVTLegacyTriggerGoal]) {
        goal = OPVTDefaultTriggerGoal;
    }
    BOOL runTask = OPVTBoolPreference(@"RunTask", YES);
    BOOL createBackgroundJob = OPVTBoolPreference(@"CreateBackgroundJob", NO);
    BOOL runBackgroundJobs = OPVTBoolPreference(@"RunBackgroundJobs", NO);
    OPVTLastTriggerRoute = userProvidedGoal ? @"springboard_prompt_agent" : @"direct_agent";
    OPVTPublishTriggerStatus(@"agent_request", @{
        @"route": OPVTLastTriggerRoute ?: @"",
        @"goal_length": @(goal.length),
        @"user_provided_goal": @(userProvidedGoal)
    });

    NSDictionary *request = @{
        @"command": @"hardware_trigger",
        @"trigger": @"volume_up_down_combo",
        @"source": userProvidedGoal ? @"springboard_prompt" : @"springboard",
        @"reason": userProvidedGoal ? @"hardware volume combo user prompt" : @"hardware volume combo",
        @"goal": goal,
        @"mode": @"auto",
        @"run_task": @(runTask),
        @"create_background_job": @(createBackgroundJob),
        @"run_background_jobs": @(runBackgroundJobs),
        @"trigger_input": userProvidedGoal ? @"springboard_prompt" : @"preference_or_default"
    };

    OPVTPlayHapticSuccess();
    OPVTShowOverlay(@"OpenPhone",
            userProvidedGoal ? @"Agent request submitted" : @"Volume trigger detected",
            [UIColor systemGreenColor]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *response = OPVTAgentRequest(request);
        BOOL ok = [response[@"status"] isEqualToString:@"ok"];
        NSString *state = [response[@"state"] isKindOfClass:[NSString class]]
                ? response[@"state"] : @"";
        NSString *modelLoopStatus = [response[@"model_loop_status"] isKindOfClass:[NSString class]]
                ? response[@"model_loop_status"] : @"";
        NSString *detail = ok ? @"Agent trigger recorded locally" : @"Agent trigger failed";
        UIColor *overlayColor = ok ? [UIColor systemGreenColor] : [UIColor systemRedColor];
        if ([state isEqualToString:@"trigger.paused"] ||
                [state isEqualToString:@"trigger.disabled"] ||
                [state isEqualToString:@"trigger.yolo_disabled"]) {
            detail = @"Agent trigger paused";
            overlayColor = [UIColor systemOrangeColor];
        } else if ([state isEqualToString:@"trigger.ignored_duplicate"]) {
            detail = @"Duplicate trigger ignored";
            overlayColor = [UIColor systemOrangeColor];
        } else if ([modelLoopStatus isEqualToString:@"started_async"]) {
            detail = @"Agent loop started";
        } else if ([modelLoopStatus isEqualToString:@"provider_not_ready"]) {
            detail = @"Model provider not ready";
            overlayColor = [UIColor systemOrangeColor];
        } else if ([modelLoopStatus isEqualToString:@"start_failed"]) {
            detail = @"Agent loop failed";
            overlayColor = [UIColor systemRedColor];
        }
        OPVTLog(@"agent response ok=%d response=%@", ok, response);
        OPVTPublishTriggerStatus(@"agent_response", @{
            @"route": OPVTLastTriggerRoute ?: @"",
            @"ok": @(ok),
            @"state": state ?: @"",
            @"model_loop_status": modelLoopStatus ?: @"",
            @"agent_task_id": response[@"agent_task_id"] ?: @"",
            @"task_id": response[@"task_id"] ?: @""
        });
        if (ok) {
            OPVTPlayHapticSuccess();
        } else {
            OPVTPlayHapticFailure();
        }
        OPVTShowOverlay(@"OpenPhone", detail, overlayColor);
    });
}

static void OPVTCallAgent(void) {
    OPVTCallAgentWithGoal(nil, NO);
}

static NSString *OPVTVoiceOverlayDetail(NSDictionary *response) {
    NSString *state = [response[@"state"] isKindOfClass:[NSString class]]
            ? response[@"state"] : @"";
    NSString *reason = [response[@"reason"] isKindOfClass:[NSString class]]
            ? response[@"reason"] : @"";
    NSString *lastError = [response[@"last_error"] isKindOfClass:[NSString class]]
            ? response[@"last_error"] : @"";
    NSString *error = lastError.length > 0 ? lastError : reason;
    if ([state isEqualToString:@"voice.credential_missing"] ||
            [error isEqualToString:@"openai_voice_credential_missing"]) {
        return @"Need OpenAI voice key";
    }
    if ([state isEqualToString:@"voice.already_running"]) {
        return @"Already listening";
    }
    if ([state isEqualToString:@"voice.agent_started"]) {
        return @"Agent loop started";
    }
    if ([state isEqualToString:@"voice.transcription_failed"]) {
        return @"Voice transcription failed";
    }
    if ([state isEqualToString:@"voice.empty_transcript"]) {
        return @"No speech heard";
    }
    if ([state isEqualToString:@"voice.capture_failed"]) {
        return @"Microphone failed";
    }
    if ([state isEqualToString:@"voice.agent_not_started"]) {
        return @"Agent loop failed";
    }
    if ([state isEqualToString:@"voice.started_async"] ||
            [state isEqualToString:@"voice.listening_or_transcribing"] ||
            [state isEqualToString:@"voice.recording"] ||
            [state isEqualToString:@"voice.transcribing"]) {
        return @"Listening";
    }
    BOOL ok = [response[@"status"] isEqualToString:@"ok"];
    return ok ? @"Voice trigger recorded" : @"Voice agent failed";
}

// (Legacy toast-based helpers removed. The island observer now renders live
//  status directly from the daemon's island-status.json file.)

static void OPVTCallDaemonVoiceAgent(void) {
    OPVTPublishSpringBoardStateOnMain();
    OPVTLastTriggerRoute = @"daemon_voice_agent";
    OPVTPublishTriggerStatus(@"voice_request", @{
        @"route": OPVTLastTriggerRoute ?: @""
    });
    NSDictionary *request = @{
        @"command": @"voice_trigger",
        @"trigger": @"volume_up_down_combo",
        @"source": @"springboard_volume",
        @"reason": @"hardware volume combo voice trigger",
        @"mode": @"auto",
        @"max_steps": @25,
        @"max_duration_ms": @600000
    };

    OPVTPlayHapticSuccess();
    OPVTIslandApplyState(@{
        @"mode": @"listening",
        @"subtitle": @"Listening",
        @"accent": @"red"
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *response = OPVTAgentRequest(request);
        BOOL ok = [response[@"status"] isEqualToString:@"ok"];
        NSString *state = [response[@"state"] isKindOfClass:[NSString class]]
                ? response[@"state"] : @"";
        OPVTLog(@"daemon voice response ok=%d response=%@", ok, response);
        OPVTPublishTriggerStatus(@"voice_response", @{
            @"route": OPVTLastTriggerRoute ?: @"",
            @"ok": @(ok),
            @"state": state ?: @"",
            @"reason": response[@"reason"] ?: @""
        });
        // Only paint the island directly on early errors that the daemon
        // reports synchronously (credential missing, already running, etc.).
        // For the happy path the daemon will drive the island itself.
        if (!ok) {
            OPVTPlayHapticFailure();
            NSString *detail = OPVTVoiceOverlayDetail(response) ?: @"Voice trigger failed";
            NSString *accent = @"red";
            if ([state isEqualToString:@"voice.credential_missing"] ||
                    [state isEqualToString:@"voice.already_running"] ||
                    [state isEqualToString:@"voice.empty_transcript"]) {
                accent = @"orange";
            }
            OPVTIslandApplyState(@{
                @"mode": @"error",
                @"subtitle": detail ?: @"",
                @"accent": accent
            });
        }
        if (!ok && OPVTPromptForGoalEnabled() &&
                ![state isEqualToString:@"voice.credential_missing"]) {
            OPVTPresentTriggerPrompt();
        }
    });
}

static void OPVTHidePromptWindow(void) {
    OPVTPromptVisible = NO;
    if (!OPVTPromptWindow) {
        return;
    }
    [OPVTPromptWindow resignKeyWindow];
    OPVTPromptWindow.hidden = YES;
}

static void OPVTPresentTriggerPrompt(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (OPVTPromptVisible) {
            OPVTPlayHapticFailure();
            OPVTShowOverlay(@"OpenPhone", @"Prompt already open", [UIColor systemOrangeColor]);
            return;
        }
        UIScreen *screen = OPVTSafeMainScreen();
        if (!screen) {
            OPVTLog(@"prompt skipped reason=main_screen_unavailable");
            OPVTCallAgent();
            return;
        }

        OPVTPromptVisible = YES;
        CGRect bounds = screen.bounds;
        UIWindowScene *windowScene = OPVTActiveWindowScene();
        if (!OPVTPromptWindow) {
            if (@available(iOS 13.0, *)) {
                if (windowScene) {
                    OPVTPromptWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
                    OPVTPromptWindow.frame = bounds;
                } else {
                    OPVTPromptWindow = [[UIWindow alloc] initWithFrame:bounds];
                }
            } else {
                OPVTPromptWindow = [[UIWindow alloc] initWithFrame:bounds];
            }
            OPVTPromptWindow.windowLevel = UIWindowLevelAlert + 2500;
            OPVTPromptWindow.backgroundColor = [UIColor clearColor];
            OPVTPromptWindow.userInteractionEnabled = YES;
            UIViewController *controller = [[UIViewController alloc] init];
            controller.view.backgroundColor = [UIColor clearColor];
            OPVTPromptWindow.rootViewController = controller;
        } else if (@available(iOS 13.0, *)) {
            if (windowScene && OPVTPromptWindow.windowScene != windowScene) {
                OPVTPromptWindow.windowScene = windowScene;
            }
        }
        OPVTPromptWindow.frame = bounds;
        [OPVTPromptWindow makeKeyAndVisible];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"OpenPhone"
                message:@"What should I do?"
                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.placeholder = @"Speak or type a task";
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
            textField.returnKeyType = UIReturnKeyGo;
            textField.autocapitalizationType = UITextAutocapitalizationTypeSentences;
        }];

        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel"
                style:UIAlertActionStyleCancel
                handler:^(__unused UIAlertAction *action) {
            OPVTLog(@"prompt cancelled");
            OPVTHidePromptWindow();
            OPVTShowOverlay(@"OpenPhone", @"Agent trigger cancelled", [UIColor systemOrangeColor]);
        }];
        UIAlertAction *runAction = [UIAlertAction actionWithTitle:@"Run"
                style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
            NSString *goal = OPVTTrimmedString(alert.textFields.firstObject.text);
            OPVTLog(@"prompt submitted chars=%lu", (unsigned long)goal.length);
            OPVTHidePromptWindow();
            if (goal.length == 0) {
                OPVTPlayHapticFailure();
                OPVTShowOverlay(@"OpenPhone", @"No task entered", [UIColor systemOrangeColor]);
                return;
            }
            OPVTCallAgentWithGoal(goal, YES);
        }];
        [alert addAction:cancelAction];
        [alert addAction:runAction];
        alert.preferredAction = runAction;

        UIViewController *presenter = OPVTPromptWindow.rootViewController;
        [presenter presentViewController:alert animated:YES completion:^{
            [alert.textFields.firstObject becomeFirstResponder];
        }];
        OPVTPlayHapticSuccess();
        OPVTLog(@"prompt shown scene=%d", windowScene != nil);
    });
}

typedef CFTypeRef OPVTHIDEventRef;
typedef uint32_t (*OPVTIOHIDEventGetTypeFunc)(OPVTHIDEventRef event);
typedef int (*OPVTIOHIDEventGetIntegerValueFunc)(OPVTHIDEventRef event, uint32_t field);

static const uint32_t OPVTIOHIDEventTypeKeyboard = 3;
static const uint32_t OPVTIOHIDEventFieldKeyboardUsagePage = (OPVTIOHIDEventTypeKeyboard << 16);
static const uint32_t OPVTIOHIDEventFieldKeyboardUsage = (OPVTIOHIDEventTypeKeyboard << 16) + 1;
static const uint32_t OPVTIOHIDEventFieldKeyboardDown = (OPVTIOHIDEventTypeKeyboard << 16) + 2;
static const uint32_t OPVTIOHIDUsagePageConsumer = 0x0c;
static const uint32_t OPVTIOHIDUsageConsumerVolumeIncrement = 0xe9;
static const uint32_t OPVTIOHIDUsageConsumerVolumeDecrement = 0xea;

static BOOL OPVTRawHIDSymbolLoadAttempted = NO;
static BOOL OPVTRawHIDSymbolsAvailable = NO;
static OPVTIOHIDEventGetTypeFunc OPVTHIDEventGetType = NULL;
static OPVTIOHIDEventGetIntegerValueFunc OPVTHIDEventGetIntegerValue = NULL;

static void OPVTEnsureRawHIDSymbols(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        OPVTRawHIDSymbolLoadAttempted = YES;
        NSArray<NSString *> *frameworks = @[
            @"/System/Library/Frameworks/IOKit.framework/IOKit",
            @"/var/jb/System/Library/Frameworks/IOKit.framework/IOKit"
        ];
        void *handle = NULL;
        for (NSString *framework in frameworks) {
            handle = dlopen(framework.UTF8String, RTLD_LAZY);
            if (handle) {
                break;
            }
        }
        if (!handle) {
            OPVTLog(@"raw HID symbols unavailable reason=dlopen_failed");
            return;
        }
        OPVTHIDEventGetType = (OPVTIOHIDEventGetTypeFunc)dlsym(handle, "IOHIDEventGetType");
        OPVTHIDEventGetIntegerValue = (OPVTIOHIDEventGetIntegerValueFunc)dlsym(
                handle, "IOHIDEventGetIntegerValue");
        OPVTRawHIDSymbolsAvailable = OPVTHIDEventGetType && OPVTHIDEventGetIntegerValue;
        OPVTLog(@"raw HID symbols loaded available=%d", OPVTRawHIDSymbolsAvailable);
    });
}

static NSString *OPVTLimitedString(NSString *value, NSUInteger maxLength) {
    if (![value isKindOfClass:[NSString class]]) {
        return @"";
    }
    if (value.length <= maxLength) {
        return value;
    }
    return [[value substringToIndex:maxLength] stringByAppendingString:@"..."];
}

static NSString *OPVTObjectClassName(id object) {
    return object ? [NSString stringWithUTF8String:class_getName([object class]) ?: "unknown"] : @"";
}

static Method OPVTEventMethod(id object, SEL selector) {
    if (!object || !selector) {
        return NULL;
    }
    Class cls = [object class];
    while (cls) {
        Method method = class_getInstanceMethod(cls, selector);
        if (method) {
            return method;
        }
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static BOOL OPVTEventReturnTypeLooksBool(Method method) {
    if (!method) {
        return NO;
    }
    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == 'B' || returnType[0] == 'c' || returnType[0] == 'C';
}

static BOOL OPVTEventReturnTypeLooksInteger(Method method) {
    if (!method) {
        return NO;
    }
    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == 'c' || returnType[0] == 'C' ||
            returnType[0] == 's' || returnType[0] == 'S' ||
            returnType[0] == 'i' || returnType[0] == 'I' ||
            returnType[0] == 'l' || returnType[0] == 'L' ||
            returnType[0] == 'q' || returnType[0] == 'Q' ||
            returnType[0] == 'B';
}

static BOOL OPVTEventInvokeBool(id object, NSString *selectorName, BOOL *okOut) {
    if (okOut) {
        *okOut = NO;
    }
    SEL selector = NSSelectorFromString(selectorName ?: @"");
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return NO;
    }
    if (!OPVTEventReturnTypeLooksBool(OPVTEventMethod(object, selector))) {
        return NO;
    }
    BOOL result = NO;
    @try {
        BOOL (*sendBool)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
        result = sendBool(object, selector);
        if (okOut) {
            *okOut = YES;
        }
    } @catch (__unused NSException *exception) {
        result = NO;
    }
    return result;
}

static long long OPVTEventInvokeInteger(id object, NSString *selectorName, BOOL *okOut) {
    if (okOut) {
        *okOut = NO;
    }
    SEL selector = NSSelectorFromString(selectorName ?: @"");
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return 0;
    }
    if (!OPVTEventReturnTypeLooksInteger(OPVTEventMethod(object, selector))) {
        return 0;
    }
    long long result = 0;
    @try {
        long long (*sendInteger)(id, SEL) = (long long (*)(id, SEL))objc_msgSend;
        result = sendInteger(object, selector);
        if (okOut) {
            *okOut = YES;
        }
    } @catch (__unused NSException *exception) {
        result = 0;
    }
    return result;
}

static NSString *OPVTEventDescription(id object) {
    if (!object) {
        return @"";
    }
    NSString *description = @"";
    @try {
        description = [object description] ?: @"";
    } @catch (__unused NSException *exception) {
        description = @"";
    }
    return OPVTLimitedString(description, 220);
}

static NSDictionary *OPVTButtonEventSummary(id event, BOOL *volumeKnownOut, BOOL *volumeUpOut);

static NSDictionary *OPVTCollectionButtonEventSummary(id event, BOOL *volumeKnownOut, BOOL *volumeUpOut) {
    if (![event conformsToProtocol:@protocol(NSFastEnumeration)] ||
            [event isKindOfClass:[NSString class]] ||
            [event isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSMutableArray *items = [NSMutableArray array];
    BOOL known = NO;
    BOOL up = NO;
    NSUInteger index = 0;
    for (id item in event) {
        if (index >= 6) {
            break;
        }
        BOOL itemKnown = NO;
        BOOL itemUp = NO;
        NSDictionary *summary = OPVTButtonEventSummary(item, &itemKnown, &itemUp);
        if (summary) {
            [items addObject:summary];
        }
        if (itemKnown && !known) {
            known = YES;
            up = itemUp;
        }
        index++;
    }
    if (items.count == 0) {
        return nil;
    }
    if (volumeKnownOut) {
        *volumeKnownOut = known;
    }
    if (volumeUpOut) {
        *volumeUpOut = up;
    }
    return @{
        @"class": OPVTObjectClassName(event),
        @"collection_count_sampled": @(items.count),
        @"items": items
    };
}

static NSDictionary *OPVTButtonEventSummary(id event, BOOL *volumeKnownOut, BOOL *volumeUpOut) {
    if (volumeKnownOut) {
        *volumeKnownOut = NO;
    }
    if (volumeUpOut) {
        *volumeUpOut = NO;
    }
    if (!event) {
        return @{};
    }

    BOOL collectionKnown = NO;
    BOOL collectionUp = NO;
    NSDictionary *collectionSummary = OPVTCollectionButtonEventSummary(event, &collectionKnown, &collectionUp);
    if (collectionSummary) {
        if (volumeKnownOut) {
            *volumeKnownOut = collectionKnown;
        }
        if (volumeUpOut) {
            *volumeUpOut = collectionUp;
        }
        return collectionSummary;
    }

    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    NSString *className = OPVTObjectClassName(event);
    NSString *description = OPVTEventDescription(event);
    summary[@"class"] = className ?: @"";
    if (description.length > 0) {
        summary[@"description"] = description;
    }

    NSMutableDictionary *selectors = [NSMutableDictionary dictionary];
    NSArray<NSString *> *upBoolSelectors = @[
        @"isVolumeUp",
        @"isVolumeIncrease",
        @"isVolumeIncrement",
        @"volumeUp",
        @"volumeIncrease"
    ];
    NSArray<NSString *> *downBoolSelectors = @[
        @"isVolumeDown",
        @"isVolumeDecrease",
        @"isVolumeDecrement",
        @"volumeDown",
        @"volumeDecrease"
    ];
    for (NSString *selectorName in upBoolSelectors) {
        BOOL ok = NO;
        BOOL value = OPVTEventInvokeBool(event, selectorName, &ok);
        if (ok) {
            selectors[selectorName] = @(value);
            if (value) {
                if (volumeKnownOut) {
                    *volumeKnownOut = YES;
                }
                if (volumeUpOut) {
                    *volumeUpOut = YES;
                }
            }
        }
    }
    for (NSString *selectorName in downBoolSelectors) {
        BOOL ok = NO;
        BOOL value = OPVTEventInvokeBool(event, selectorName, &ok);
        if (ok) {
            selectors[selectorName] = @(value);
            if (value) {
                if (volumeKnownOut) {
                    *volumeKnownOut = YES;
                }
                if (volumeUpOut) {
                    *volumeUpOut = NO;
                }
            }
        }
    }

    NSArray<NSString *> *integerSelectors = @[
        @"usage",
        @"hidUsage",
        @"_usage",
        @"buttonUsage",
        @"usagePage",
        @"hidUsagePage",
        @"_usagePage",
        @"button",
        @"buttonType",
        @"type"
    ];
    for (NSString *selectorName in integerSelectors) {
        BOOL ok = NO;
        long long value = OPVTEventInvokeInteger(event, selectorName, &ok);
        if (ok) {
            selectors[selectorName] = @(value);
            if (value == 0xE9) {
                if (volumeKnownOut) {
                    *volumeKnownOut = YES;
                }
                if (volumeUpOut) {
                    *volumeUpOut = YES;
                }
            } else if (value == 0xEA) {
                if (volumeKnownOut) {
                    *volumeKnownOut = YES;
                }
                if (volumeUpOut) {
                    *volumeUpOut = NO;
                }
            }
        }
    }
    if (selectors.count > 0) {
        summary[@"selectors"] = selectors;
    }

    NSString *haystack = [[NSString stringWithFormat:@"%@ %@", className ?: @"", description ?: @""]
            lowercaseString];
    BOOL textSaysUp = [haystack containsString:@"volumeup"] ||
            [haystack containsString:@"volume up"] ||
            [haystack containsString:@"volumeincrease"] ||
            [haystack containsString:@"volume increase"] ||
            [haystack containsString:@"volumeincrement"] ||
            [haystack containsString:@"volume increment"];
    BOOL textSaysDown = [haystack containsString:@"volumedown"] ||
            [haystack containsString:@"volume down"] ||
            [haystack containsString:@"volumedecrease"] ||
            [haystack containsString:@"volume decrease"] ||
            [haystack containsString:@"volumedecrement"] ||
            [haystack containsString:@"volume decrement"];
    if (textSaysUp || textSaysDown) {
        if (volumeKnownOut) {
            *volumeKnownOut = YES;
        }
        if (volumeUpOut) {
            *volumeUpOut = textSaysUp && !textSaysDown;
        }
        summary[@"text_classified_volume"] = textSaysUp ? @"up" : @"down";
    }
    return summary;
}

static void OPVTRecordButtonObjectFromSource(id event, NSString *source) {
    BOOL volumeKnown = NO;
    BOOL volumeUp = NO;
    NSDictionary *summary = OPVTButtonEventSummary(event, &volumeKnown, &volumeUp);
    OPVTPublishTriggerStatus(volumeKnown ? @"button_event_object_volume" :
            @"button_event_object_unclassified", @{
        @"source": source ?: @"",
        @"volume_known": @(volumeKnown),
        @"volume_up": @(volumeUp),
        @"event": summary ?: @{}
    });
    OPVTLog(@"button object source=%@ volume_known=%d volume_up=%d event=%@",
            source ?: @"", volumeKnown, volumeUp, summary ?: @{});
    if (volumeKnown) {
        NSString *recordSource = [NSString stringWithFormat:@"%@.%@",
                source ?: @"button_object", volumeUp ? @"volume_up" : @"volume_down"];
        OPVTRecordButtonFromSource(volumeUp, recordSource);
    }
}

static NSDictionary *OPVTRawHIDEventSummary(void *event, BOOL *volumeKnownOut, BOOL *volumeUpOut) {
    if (volumeKnownOut) {
        *volumeKnownOut = NO;
    }
    if (volumeUpOut) {
        *volumeUpOut = NO;
    }

    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    summary[@"pointer"] = [NSString stringWithFormat:@"%p", event];
    OPVTEnsureRawHIDSymbols();
    summary[@"symbols_attempted"] = @(OPVTRawHIDSymbolLoadAttempted);
    summary[@"symbols_available"] = @(OPVTRawHIDSymbolsAvailable);
    if (!event) {
        summary[@"reason"] = @"null_event";
        return summary;
    }
    if (!OPVTRawHIDSymbolsAvailable || !OPVTHIDEventGetType || !OPVTHIDEventGetIntegerValue) {
        summary[@"reason"] = @"missing_hid_symbols";
        return summary;
    }

    OPVTHIDEventRef hidEvent = (OPVTHIDEventRef)event;
    uint32_t type = OPVTHIDEventGetType(hidEvent);
    summary[@"type"] = @(type);
    if (type != OPVTIOHIDEventTypeKeyboard) {
        summary[@"reason"] = @"not_keyboard_event";
        return summary;
    }

    uint32_t usagePage = (uint32_t)OPVTHIDEventGetIntegerValue(hidEvent,
            OPVTIOHIDEventFieldKeyboardUsagePage);
    uint32_t usage = (uint32_t)OPVTHIDEventGetIntegerValue(hidEvent,
            OPVTIOHIDEventFieldKeyboardUsage);
    int down = OPVTHIDEventGetIntegerValue(hidEvent,
            OPVTIOHIDEventFieldKeyboardDown);
    summary[@"usage_page"] = @(usagePage);
    summary[@"usage"] = @(usage);
    summary[@"down"] = @(down != 0);

    if (usagePage == OPVTIOHIDUsagePageConsumer &&
            usage == OPVTIOHIDUsageConsumerVolumeIncrement) {
        if (volumeKnownOut) {
            *volumeKnownOut = YES;
        }
        if (volumeUpOut) {
            *volumeUpOut = YES;
        }
        summary[@"classification"] = @"volume_up";
    } else if (usagePage == OPVTIOHIDUsagePageConsumer &&
            usage == OPVTIOHIDUsageConsumerVolumeDecrement) {
        if (volumeKnownOut) {
            *volumeKnownOut = YES;
        }
        if (volumeUpOut) {
            *volumeUpOut = NO;
        }
        summary[@"classification"] = @"volume_down";
    } else {
        summary[@"reason"] = @"not_volume_consumer_usage";
    }
    return summary;
}

static void OPVTRecordRawHIDButtonFromSource(void *event, NSString *source) {
    BOOL volumeKnown = NO;
    BOOL volumeUp = NO;
    NSDictionary *summary = OPVTRawHIDEventSummary(event, &volumeKnown, &volumeUp);
    OPVTPublishTriggerStatus(volumeKnown ? @"button_event_raw_hid_volume" :
            @"button_event_raw_hid_unclassified", @{
        @"source": source ?: @"",
        @"volume_known": @(volumeKnown),
        @"volume_up": @(volumeUp),
        @"event": summary ?: @{}
    });
    OPVTLog(@"raw HID button source=%@ volume_known=%d volume_up=%d event=%@",
            source ?: @"", volumeKnown, volumeUp, summary ?: @{});
    if (volumeKnown) {
        NSString *recordSource = [NSString stringWithFormat:@"%@.%@",
                source ?: @"raw_hid", volumeUp ? @"volume_up" : @"volume_down"];
        OPVTRecordButtonFromSource(volumeUp, recordSource);
    }
}

static NSString *OPVTNotificationString(NSDictionary *userInfo, NSString *key) {
    id value = [userInfo isKindOfClass:[NSDictionary class]] ? userInfo[key] : nil;
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if ([value respondsToSelector:@selector(stringValue)]) {
        return [value stringValue] ?: @"";
    }
    return @"";
}

static NSString *OPVTVolumeDirectionFromNotification(NSDictionary *userInfo) {
    NSArray<NSString *> *keys = @[
        @"AVSystemController_AudioVolumeChangeDirectionNotificationParameter",
        @"AVSystemController_AudioVolumeDirectionNotificationParameter",
        @"AVSystemController_AudioVolumeChangeDirection"
    ];
    for (NSString *key in keys) {
        NSString *value = OPVTNotificationString(userInfo, key).lowercaseString;
        if (value.length == 0) {
            continue;
        }
        if ([value containsString:@"up"] || [value containsString:@"increase"] ||
                [value containsString:@"increment"]) {
            return @"up";
        }
        if ([value containsString:@"down"] || [value containsString:@"decrease"] ||
                [value containsString:@"decrement"]) {
            return @"down";
        }
    }
    return @"";
}

static BOOL OPVTSeedSystemVolumeFromAVSystemController(void) {
    Class cls = NSClassFromString(@"AVSystemController");
    SEL sharedSelector = NSSelectorFromString(@"sharedAVSystemController");
    if (!cls || ![cls respondsToSelector:sharedSelector]) {
        return NO;
    }
    id controller = nil;
    @try {
        id (*sendShared)(Class, SEL) = (id (*)(Class, SEL))objc_msgSend;
        controller = sendShared(cls, sharedSelector);
    } @catch (__unused NSException *exception) {
        controller = nil;
    }
    SEL getVolumeSelector = NSSelectorFromString(@"getVolume:forCategory:");
    if (!controller || ![controller respondsToSelector:getVolumeSelector]) {
        return NO;
    }
    float volume = -1.0f;
    BOOL ok = NO;
    @try {
        BOOL (*sendGetVolume)(id, SEL, float *, id) =
                (BOOL (*)(id, SEL, float *, id))objc_msgSend;
        ok = sendGetVolume(controller, getVolumeSelector, &volume, @"Audio/Video");
    } @catch (__unused NSException *exception) {
        ok = NO;
    }
    if (!ok || !isfinite(volume) || volume < 0.0f || volume > 1.0f) {
        return NO;
    }
    OPVTLastSystemVolume = volume;
    return YES;
}

static void OPVTInstallVolumeNotificationObserver(void) {
    if (OPVTVolumeNotificationInstalled || OPVTVolumeNotificationObserverObject) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (OPVTVolumeNotificationInstalled || OPVTVolumeNotificationObserverObject) {
            return;
        }
        BOOL seeded = OPVTSeedSystemVolumeFromAVSystemController();
        OPVTVolumeNotificationObserverObject = [OPVTVolumeNotificationObserver new];
        [[NSNotificationCenter defaultCenter] addObserver:OPVTVolumeNotificationObserverObject
                                                 selector:@selector(openphoneSystemVolumeDidChange:)
                                                     name:@"AVSystemController_SystemVolumeDidChangeNotification"
                                                   object:nil];
        OPVTVolumeNotificationInstalled = YES;
        OPVTLog(@"volume notification observer installed seeded=%d volume=%0.3f",
                seeded, OPVTLastSystemVolume);
        OPVTPublishTriggerStatus(@"volume_notification_observer", @{
            @"installed": @YES,
            @"seeded": @(seeded),
            @"volume": @(OPVTLastSystemVolume >= 0.0 ? OPVTLastSystemVolume : -1.0)
        });
    });
}

static void OPVTHandleSystemVolumeNotification(NSNotification *notification) {
    NSDictionary *userInfo = [notification.userInfo isKindOfClass:[NSDictionary class]]
            ? notification.userInfo : @{};
    double volume = OPVTDoubleValue(userInfo[@"AVSystemController_AudioVolumeNotificationParameter"], -1.0);
    BOOL hasVolume = isfinite(volume) && volume >= 0.0 && volume <= 1.0;
    double previousVolume = OPVTLastSystemVolume;
    BOOL hadPreviousVolume = previousVolume >= 0.0;
    NSString *reason = OPVTNotificationString(userInfo,
            @"AVSystemController_AudioVolumeChangeReasonNotificationParameter");
    NSString *category = OPVTNotificationString(userInfo,
            @"AVSystemController_AudioCategoryNotificationParameter");
    NSString *notificationDirection = OPVTVolumeDirectionFromNotification(userInfo);

    OPVTVolumeNotificationEventCount++;
    OPVTLastVolumeNotificationMs = OPVTNowMs();
    OPVTLastVolumeNotificationReason = [reason copy] ?: @"";
    OPVTLastVolumeNotificationCategory = [category copy] ?: @"";
    OPVTLastVolumeNotificationDirection = notificationDirection.length > 0
            ? [notificationDirection copy] : @"";
    if (hasVolume) {
        OPVTLastSystemVolume = volume;
    }

    double delta = (hasVolume && hadPreviousVolume) ? (volume - previousVolume) : 0.0;
    BOOL directionKnown = NO;
    BOOL volumeUp = NO;
    if (fabs(delta) > 0.0005) {
        directionKnown = YES;
        volumeUp = delta > 0.0;
        OPVTLastVolumeNotificationDirection = volumeUp ? @"up" : @"down";
    } else if ([notificationDirection isEqualToString:@"up"] ||
            [notificationDirection isEqualToString:@"down"]) {
        directionKnown = YES;
        volumeUp = [notificationDirection isEqualToString:@"up"];
    }

    NSDictionary *detail = @{
        @"events_seen": @(OPVTVolumeNotificationEventCount),
        @"has_volume": @(hasVolume),
        @"volume": @(hasVolume ? volume : -1.0),
        @"previous_volume": @(hadPreviousVolume ? previousVolume : -1.0),
        @"delta": @(delta),
        @"direction_known": @(directionKnown),
        @"volume_up": @(volumeUp),
        @"reason": reason ?: @"",
        @"category": category ?: @""
    };
    OPVTPublishTriggerStatus(directionKnown ? @"volume_notification_button" :
            @"volume_notification_unclassified", detail);
    OPVTLog(@"volume notification direction_known=%d up=%d volume=%0.3f previous=%0.3f reason=%@ category=%@",
            directionKnown, volumeUp, hasVolume ? volume : -1.0,
            hadPreviousVolume ? previousVolume : -1.0, reason ?: @"", category ?: @"");
    if (directionKnown) {
        OPVTRecordButtonFromSource(volumeUp, @"notification.AVSystemController.volume");
    }
}

static void OPVTRecordButtonFromSource(BOOL volumeUp, NSString *source) {
    if (!OPVTEnabled()) {
        OPVTPublishTriggerStatus(@"button_ignored_disabled", @{
            @"volume_up": @(volumeUp),
            @"source": source ?: @""
        });
        return;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    OPVTButtonEventCount++;
    OPVTLastButtonEventMs = OPVTNowMs();
    OPVTLastButtonEventName = volumeUp ? @"volume_up" : @"volume_down";
    OPVTLastButtonEventSource = [source isKindOfClass:[NSString class]] && source.length > 0
            ? [source copy] : @"unknown";
    OPVTPublishTriggerStatus(@"button_event", @{
        @"button": OPVTLastButtonEventName ?: @"",
        @"button_event_count": @(OPVTButtonEventCount),
        @"source": OPVTLastButtonEventSource ?: @""
    });
    CFAbsoluteTime *lastLog = volumeUp ? &OPVTLastUpLog : &OPVTLastDownLog;
    if ((now - *lastLog) >= 0.08) {
        *lastLog = now;
        OPVTLog(@"button event=%@ source=%@",
                volumeUp ? @"volume_up" : @"volume_down",
                OPVTLastButtonEventSource ?: @"");
    }

    if (volumeUp) {
        OPVTLastUp = now;
    } else {
        OPVTLastDown = now;
    }

    BOOL combo = fabs(OPVTLastUp - OPVTLastDown) <= OPVTWindowSeconds();
    BOOL cooledDown = (now - OPVTLastTrigger) >= OPVTCooldownSeconds();
    if (combo && cooledDown) {
        OPVTLastTrigger = now;
        OPVTComboEventCount++;
        OPVTLastComboEventMs = OPVTNowMs();

        // If the island is in an active state, treat the combo as a cancel.
        BOOL activeIslandMode = [OPVTIslandCurrentMode isEqualToString:@"listening"] ||
                [OPVTIslandCurrentMode isEqualToString:@"realtime"] ||
                [OPVTIslandCurrentMode isEqualToString:@"transcribing"] ||
                [OPVTIslandCurrentMode isEqualToString:@"thinking"] ||
                [OPVTIslandCurrentMode isEqualToString:@"action"];
        if (activeIslandMode) {
            OPVTLog(@"volume combo -> cancel (island mode=%@)",
                    OPVTIslandCurrentMode ?: @"");
            OPVTPublishTriggerStatus(@"volume_combo_cancel", @{
                @"mode": OPVTIslandCurrentMode ?: @""
            });
            OPVTPlayHapticFailure();
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                OPVTAgentRequest(@{@"command": @"voice_cancel",
                                   @"reason": @"user_double_combo"});
            });
            return;
        }

        NSString *route = OPVTDaemonVoiceAgentEnabled()
                ? @"daemon_voice_agent"
                : (OPVTPromptForGoalEnabled() ? @"springboard_prompt" : @"direct_agent");
        OPVTLastTriggerRoute = route;
        OPVTPublishTriggerStatus(@"volume_combo", @{
            @"route": route ?: @"",
            @"combo_event_count": @(OPVTComboEventCount),
            @"source": OPVTLastButtonEventSource ?: @"",
            @"last_up_delta_s": @(now - OPVTLastUp),
            @"last_down_delta_s": @(now - OPVTLastDown)
        });
        OPVTLog(@"volume combo detected up=%0.3f down=%0.3f source=%@",
                OPVTLastUp, OPVTLastDown, OPVTLastButtonEventSource ?: @"");
        if (OPVTDaemonVoiceAgentEnabled()) {
            OPVTCallDaemonVoiceAgent();
        } else if (OPVTPromptForGoalEnabled()) {
            OPVTPresentTriggerPrompt();
        } else {
            OPVTCallAgent();
        }
    }
}

static OPVTHookSpec *OPVTHookSpecFor(id self, SEL selector) {
    size_t count = sizeof(OPVTHookSpecs) / sizeof(OPVTHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTHookSpec *spec = &OPVTHookSpecs[index];
        if (!spec->original) {
            continue;
        }
        SEL specSelector = sel_registerName(spec->selectorName);
        if (!sel_isEqual(selector, specSelector)) {
            continue;
        }
        Class cls = objc_getClass(spec->className);
        if (cls && [self isKindOfClass:cls]) {
            return spec;
        }
    }
    return NULL;
}

static void OPVTVolumeNoArgReplacement(id self, SEL _cmd) {
    OPVTHookSpec *spec = OPVTHookSpecFor(self, _cmd);
    const char *selectorName = sel_getName(_cmd);
    BOOL volumeUp = selectorName && strstr(selectorName, "increase") != NULL;
    NSString *source = [NSString stringWithFormat:@"runtime.%s.%s",
            class_getName([self class]) ?: "unknown", selectorName ?: "unknown"];
    if (spec) {
        volumeUp = spec->volumeUp;
        source = [NSString stringWithFormat:@"runtime.%s.%s",
                spec->className ?: "unknown", spec->selectorName ?: "unknown"];
    }

    OPVTRecordButtonFromSource(volumeUp, source);

    if (spec && spec->original && spec->original != (IMP)OPVTVolumeNoArgReplacement) {
        ((void (*)(id, SEL))spec->original)(self, _cmd);
    }
}

static OPVTFixedArgHookSpec *OPVTFixedArgHookSpecFor(id self, SEL selector) {
    size_t count = sizeof(OPVTFixedArgHookSpecs) / sizeof(OPVTFixedArgHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTFixedArgHookSpec *spec = &OPVTFixedArgHookSpecs[index];
        if (!spec->original) {
            continue;
        }
        SEL specSelector = sel_registerName(spec->selectorName);
        Class cls = objc_getClass(spec->className);
        if (sel_isEqual(selector, specSelector) && cls && [self isKindOfClass:cls]) {
            return spec;
        }
    }
    return NULL;
}

static OPVTBoolArgHookSpec *OPVTBoolArgHookSpecFor(id self, SEL selector) {
    size_t count = sizeof(OPVTBoolArgHookSpecs) / sizeof(OPVTBoolArgHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTBoolArgHookSpec *spec = &OPVTBoolArgHookSpecs[index];
        if (!spec->original) {
            continue;
        }
        SEL specSelector = sel_registerName(spec->selectorName);
        Class cls = objc_getClass(spec->className);
        if (sel_isEqual(selector, specSelector) && cls && [self isKindOfClass:cls]) {
            return spec;
        }
    }
    return NULL;
}

static OPVTBoolPairHookSpec *OPVTBoolPairHookSpecFor(id self, SEL selector) {
    size_t count = sizeof(OPVTBoolPairHookSpecs) / sizeof(OPVTBoolPairHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTBoolPairHookSpec *spec = &OPVTBoolPairHookSpecs[index];
        if (!spec->original) {
            continue;
        }
        SEL specSelector = sel_registerName(spec->selectorName);
        Class cls = objc_getClass(spec->className);
        if (sel_isEqual(selector, specSelector) && cls && [self isKindOfClass:cls]) {
            return spec;
        }
    }
    return NULL;
}

static OPVTButtonObjectVoidHookSpec *OPVTButtonObjectVoidHookSpecFor(id self, SEL selector) {
    size_t count = sizeof(OPVTButtonObjectVoidHookSpecs) / sizeof(OPVTButtonObjectVoidHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTButtonObjectVoidHookSpec *spec = &OPVTButtonObjectVoidHookSpecs[index];
        if (!spec->original) {
            continue;
        }
        SEL specSelector = sel_registerName(spec->selectorName);
        Class cls = objc_getClass(spec->className);
        if (sel_isEqual(selector, specSelector) && cls && [self isKindOfClass:cls]) {
            return spec;
        }
    }
    return NULL;
}

static OPVTButtonObjectBoolHookSpec *OPVTButtonObjectBoolHookSpecFor(id self, SEL selector) {
    size_t count = sizeof(OPVTButtonObjectBoolHookSpecs) / sizeof(OPVTButtonObjectBoolHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTButtonObjectBoolHookSpec *spec = &OPVTButtonObjectBoolHookSpecs[index];
        if (!spec->original) {
            continue;
        }
        SEL specSelector = sel_registerName(spec->selectorName);
        Class cls = objc_getClass(spec->className);
        if (sel_isEqual(selector, specSelector) && cls && [self isKindOfClass:cls]) {
            return spec;
        }
    }
    return NULL;
}

static OPVTButtonRawHIDVoidHookSpec *OPVTButtonRawHIDVoidHookSpecFor(id self, SEL selector) {
    size_t count = sizeof(OPVTButtonRawHIDVoidHookSpecs) / sizeof(OPVTButtonRawHIDVoidHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTButtonRawHIDVoidHookSpec *spec = &OPVTButtonRawHIDVoidHookSpecs[index];
        if (!spec->original) {
            continue;
        }
        SEL specSelector = sel_registerName(spec->selectorName);
        Class cls = objc_getClass(spec->className);
        if (sel_isEqual(selector, specSelector) && cls && [self isKindOfClass:cls]) {
            return spec;
        }
    }
    return NULL;
}

static NSString *OPVTForegroundSource(const char *className, const char *selectorName) {
    return [NSString stringWithFormat:@"runtime.%s.%s",
            className ?: "unknown", selectorName ?: "unknown"];
}

static OPVTForegroundNoArgObjectHookSpec *OPVTForegroundNoArgObjectHookSpecFor(id self, SEL selector) {
    size_t count = sizeof(OPVTForegroundNoArgObjectHookSpecs) / sizeof(OPVTForegroundNoArgObjectHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTForegroundNoArgObjectHookSpec *spec = &OPVTForegroundNoArgObjectHookSpecs[index];
        if (!spec->original) {
            continue;
        }
        SEL specSelector = sel_registerName(spec->selectorName);
        Class cls = objc_getClass(spec->className);
        if (sel_isEqual(selector, specSelector) && cls && [self isKindOfClass:cls]) {
            return spec;
        }
    }
    return NULL;
}

static OPVTForegroundObjectArgVoidHookSpec *OPVTForegroundObjectArgVoidHookSpecFor(id self, SEL selector) {
    size_t count = sizeof(OPVTForegroundObjectArgVoidHookSpecs) / sizeof(OPVTForegroundObjectArgVoidHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTForegroundObjectArgVoidHookSpec *spec = &OPVTForegroundObjectArgVoidHookSpecs[index];
        if (!spec->original) {
            continue;
        }
        SEL specSelector = sel_registerName(spec->selectorName);
        Class cls = objc_getClass(spec->className);
        if (sel_isEqual(selector, specSelector) && cls && [self isKindOfClass:cls]) {
            return spec;
        }
    }
    return NULL;
}

static OPVTForegroundObjectArgObjectHookSpec *OPVTForegroundObjectArgObjectHookSpecFor(id self, SEL selector) {
    size_t count = sizeof(OPVTForegroundObjectArgObjectHookSpecs) / sizeof(OPVTForegroundObjectArgObjectHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTForegroundObjectArgObjectHookSpec *spec = &OPVTForegroundObjectArgObjectHookSpecs[index];
        if (!spec->original) {
            continue;
        }
        SEL specSelector = sel_registerName(spec->selectorName);
        Class cls = objc_getClass(spec->className);
        if (sel_isEqual(selector, specSelector) && cls && [self isKindOfClass:cls]) {
            return spec;
        }
    }
    return NULL;
}

static OPVTForegroundNoArgBoolHookSpec *OPVTForegroundNoArgBoolHookSpecFor(id self, SEL selector) {
    size_t count = sizeof(OPVTForegroundNoArgBoolHookSpecs) / sizeof(OPVTForegroundNoArgBoolHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTForegroundNoArgBoolHookSpec *spec = &OPVTForegroundNoArgBoolHookSpecs[index];
        if (!spec->original) {
            continue;
        }
        SEL specSelector = sel_registerName(spec->selectorName);
        Class cls = objc_getClass(spec->className);
        if (sel_isEqual(selector, specSelector) && cls && [self isKindOfClass:cls]) {
            return spec;
        }
    }
    return NULL;
}

static void OPVTVolumeFixedArgReplacement(id self, SEL _cmd, uintptr_t arg) {
    OPVTFixedArgHookSpec *spec = OPVTFixedArgHookSpecFor(self, _cmd);
    if (spec) {
        OPVTRecordButtonFromSource(spec->volumeUp,
                [NSString stringWithFormat:@"runtime.%s.%s",
                spec->className ?: "unknown", spec->selectorName ?: "unknown"]);
        if (spec->original && spec->original != (IMP)OPVTVolumeFixedArgReplacement) {
            ((void (*)(id, SEL, uintptr_t))spec->original)(self, _cmd, arg);
        }
    }
}

static void OPVTVolumeBoolArgReplacement(id self, SEL _cmd, BOOL increase) {
    OPVTBoolArgHookSpec *spec = OPVTBoolArgHookSpecFor(self, _cmd);
    NSString *source = spec
            ? [NSString stringWithFormat:@"runtime.%s.%s",
                    spec->className ?: "unknown", spec->selectorName ?: "unknown"]
            : [NSString stringWithFormat:@"runtime.%s.%s",
                    class_getName([self class]) ?: "unknown", sel_getName(_cmd) ?: "unknown"];
    OPVTRecordButtonFromSource(increase, source);
    if (spec && spec->original && spec->original != (IMP)OPVTVolumeBoolArgReplacement) {
        ((void (*)(id, SEL, BOOL))spec->original)(self, _cmd, increase);
    }
}

static void OPVTVolumeBoolPairReplacement(id self, SEL _cmd, BOOL increase, uintptr_t second) {
    OPVTBoolPairHookSpec *spec = OPVTBoolPairHookSpecFor(self, _cmd);
    BOOL shouldRecord = YES;
    if (spec && spec->secondArgumentMeansDown) {
        shouldRecord = (second != 0);
    }
    if (shouldRecord) {
        NSString *source = spec
                ? [NSString stringWithFormat:@"runtime.%s.%s",
                        spec->className ?: "unknown", spec->selectorName ?: "unknown"]
                : [NSString stringWithFormat:@"runtime.%s.%s",
                        class_getName([self class]) ?: "unknown", sel_getName(_cmd) ?: "unknown"];
        OPVTRecordButtonFromSource(increase, source);
    }
    if (spec && spec->original && spec->original != (IMP)OPVTVolumeBoolPairReplacement) {
        ((void (*)(id, SEL, BOOL, uintptr_t))spec->original)(self, _cmd, increase, second);
    }
}

static void OPVTButtonObjectVoidReplacement(id self, SEL _cmd, id event) {
    OPVTButtonObjectVoidHookSpec *spec = OPVTButtonObjectVoidHookSpecFor(self, _cmd);
    NSString *source = spec
            ? [NSString stringWithFormat:@"runtime.%s.%s",
                    spec->className ?: "unknown", spec->selectorName ?: "unknown"]
            : [NSString stringWithFormat:@"runtime.%s.%s",
                    class_getName([self class]) ?: "unknown", sel_getName(_cmd) ?: "unknown"];
    if (spec && spec->original && spec->original != (IMP)OPVTButtonObjectVoidReplacement) {
        ((void (*)(id, SEL, id))spec->original)(self, _cmd, event);
    }
    OPVTRecordButtonObjectFromSource(event, source);
}

static BOOL OPVTButtonObjectBoolReplacement(id self, SEL _cmd, id event) {
    OPVTButtonObjectBoolHookSpec *spec = OPVTButtonObjectBoolHookSpecFor(self, _cmd);
    NSString *source = spec
            ? [NSString stringWithFormat:@"runtime.%s.%s",
                    spec->className ?: "unknown", spec->selectorName ?: "unknown"]
            : [NSString stringWithFormat:@"runtime.%s.%s",
                    class_getName([self class]) ?: "unknown", sel_getName(_cmd) ?: "unknown"];
    BOOL result = NO;
    if (spec && spec->original && spec->original != (IMP)OPVTButtonObjectBoolReplacement) {
        result = ((BOOL (*)(id, SEL, id))spec->original)(self, _cmd, event);
    }
    OPVTRecordButtonObjectFromSource(event, source);
    return result;
}

static void OPVTButtonRawHIDVoidReplacement(id self, SEL _cmd, void *event) {
    OPVTButtonRawHIDVoidHookSpec *spec = OPVTButtonRawHIDVoidHookSpecFor(self, _cmd);
    NSString *source = spec
            ? [NSString stringWithFormat:@"runtime.%s.%s",
                    spec->className ?: "unknown", spec->selectorName ?: "unknown"]
            : [NSString stringWithFormat:@"runtime.%s.%s",
                    class_getName([self class]) ?: "unknown", sel_getName(_cmd) ?: "unknown"];
    OPVTRecordRawHIDButtonFromSource(event, source);
    if (spec && spec->original && spec->original != (IMP)OPVTButtonRawHIDVoidReplacement) {
        ((void (*)(id, SEL, void *))spec->original)(self, _cmd, event);
    }
}

static id OPVTForegroundNoArgObjectReplacement(id self, SEL _cmd) {
    OPVTForegroundNoArgObjectHookSpec *spec = OPVTForegroundNoArgObjectHookSpecFor(self, _cmd);
    id result = nil;
    if (spec && spec->original && spec->original != (IMP)OPVTForegroundNoArgObjectReplacement) {
        result = ((id (*)(id, SEL))spec->original)(self, _cmd);
        OPVTRecordForegroundObject(result, OPVTForegroundSource(spec->className, spec->selectorName));
    }
    return result;
}

static void OPVTForegroundObjectArgVoidReplacement(id self, SEL _cmd, id arg) {
    OPVTForegroundObjectArgVoidHookSpec *spec = OPVTForegroundObjectArgVoidHookSpecFor(self, _cmd);
    if (spec && spec->original && spec->original != (IMP)OPVTForegroundObjectArgVoidReplacement) {
        ((void (*)(id, SEL, id))spec->original)(self, _cmd, arg);
        NSString *source = OPVTForegroundSource(spec->className, spec->selectorName);
        OPVTRecordForegroundObject(arg, source);
        if (strcmp(spec->selectorName, "updateFrontMostApplicationWithServerInstance:") == 0) {
            id foreground = OPVTInvokeObjectOneArg(self, @"frontmostAppProcessWithServerInstance:", arg);
            OPVTRecordForegroundObject(foreground, [source stringByAppendingString:@".frontmost"]);
        }
    }
}

static id OPVTForegroundObjectArgObjectReplacement(id self, SEL _cmd, id arg) {
    OPVTForegroundObjectArgObjectHookSpec *spec = OPVTForegroundObjectArgObjectHookSpecFor(self, _cmd);
    id result = nil;
    if (spec && spec->original && spec->original != (IMP)OPVTForegroundObjectArgObjectReplacement) {
        result = ((id (*)(id, SEL, id))spec->original)(self, _cmd, arg);
        OPVTRecordForegroundObject(result, OPVTForegroundSource(spec->className, spec->selectorName));
    }
    return result;
}

static BOOL OPVTForegroundNoArgBoolReplacement(id self, SEL _cmd) {
    OPVTForegroundNoArgBoolHookSpec *spec = OPVTForegroundNoArgBoolHookSpecFor(self, _cmd);
    BOOL result = NO;
    if (spec && spec->original && spec->original != (IMP)OPVTForegroundNoArgBoolReplacement) {
        result = ((BOOL (*)(id, SEL))spec->original)(self, _cmd);
        if (result) {
            OPVTRecordForegroundObject(self, OPVTForegroundSource(spec->className, spec->selectorName));
        }
    }
    return result;
}

static void OPVTTryHookSpec(OPVTHookSpec *spec, NSString *phase) {
    if (!spec || spec->hooked) {
        return;
    }

    Class cls = objc_getClass(spec->className);
    if (!cls) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"runtime hook missing class=%s phase=%@", spec->className, phase ?: @"");
        }
        return;
    }

    SEL selector = sel_registerName(spec->selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"runtime hook missing method=%s[%s] phase=%@",
                    spec->className, spec->selectorName, phase ?: @"");
        }
        return;
    }

    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount != 2) {
        OPVTLog(@"runtime hook skipped method=%s[%s] args=%u phase=%@",
                spec->className, spec->selectorName, argumentCount, phase ?: @"");
        return;
    }

    IMP current = method_getImplementation(method);
    if (current == (IMP)OPVTVolumeNoArgReplacement) {
        spec->hooked = YES;
        return;
    }

    spec->original = method_setImplementation(method, (IMP)OPVTVolumeNoArgReplacement);
    spec->hooked = YES;
    OPVTLog(@"runtime hook installed method=%s[%s] phase=%@",
            spec->className, spec->selectorName, phase ?: @"");
}

static void OPVTTryHookFixedArgSpec(OPVTFixedArgHookSpec *spec, NSString *phase) {
    if (!spec || spec->hooked) {
        return;
    }
    Class cls = objc_getClass(spec->className);
    if (!cls) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"runtime hook missing class=%s phase=%@", spec->className, phase ?: @"");
        }
        return;
    }
    SEL selector = sel_registerName(spec->selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"runtime hook missing method=%s[%s] phase=%@",
                    spec->className, spec->selectorName, phase ?: @"");
        }
        return;
    }
    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount != 3) {
        OPVTLog(@"runtime hook skipped method=%s[%s] args=%u phase=%@",
                spec->className, spec->selectorName, argumentCount, phase ?: @"");
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)OPVTVolumeFixedArgReplacement) {
        spec->hooked = YES;
        return;
    }
    spec->original = method_setImplementation(method, (IMP)OPVTVolumeFixedArgReplacement);
    spec->hooked = YES;
    OPVTLog(@"runtime hook installed method=%s[%s] phase=%@",
            spec->className, spec->selectorName, phase ?: @"");
}

static void OPVTTryHookBoolArgSpec(OPVTBoolArgHookSpec *spec, NSString *phase) {
    if (!spec || spec->hooked) {
        return;
    }
    Class cls = objc_getClass(spec->className);
    if (!cls) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"runtime hook missing class=%s phase=%@", spec->className, phase ?: @"");
        }
        return;
    }
    SEL selector = sel_registerName(spec->selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"runtime hook missing method=%s[%s] phase=%@",
                    spec->className, spec->selectorName, phase ?: @"");
        }
        return;
    }
    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount != 3) {
        OPVTLog(@"runtime hook skipped method=%s[%s] args=%u phase=%@",
                spec->className, spec->selectorName, argumentCount, phase ?: @"");
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)OPVTVolumeBoolArgReplacement) {
        spec->hooked = YES;
        return;
    }
    spec->original = method_setImplementation(method, (IMP)OPVTVolumeBoolArgReplacement);
    spec->hooked = YES;
    OPVTLog(@"runtime hook installed method=%s[%s] phase=%@",
            spec->className, spec->selectorName, phase ?: @"");
}

static void OPVTTryHookBoolPairSpec(OPVTBoolPairHookSpec *spec, NSString *phase) {
    if (!spec || spec->hooked) {
        return;
    }
    Class cls = objc_getClass(spec->className);
    if (!cls) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"runtime hook missing class=%s phase=%@", spec->className, phase ?: @"");
        }
        return;
    }
    SEL selector = sel_registerName(spec->selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"runtime hook missing method=%s[%s] phase=%@",
                    spec->className, spec->selectorName, phase ?: @"");
        }
        return;
    }
    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount != 4) {
        OPVTLog(@"runtime hook skipped method=%s[%s] args=%u phase=%@",
                spec->className, spec->selectorName, argumentCount, phase ?: @"");
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)OPVTVolumeBoolPairReplacement) {
        spec->hooked = YES;
        return;
    }
    spec->original = method_setImplementation(method, (IMP)OPVTVolumeBoolPairReplacement);
    spec->hooked = YES;
    OPVTLog(@"runtime hook installed method=%s[%s] phase=%@",
            spec->className, spec->selectorName, phase ?: @"");
}

static void OPVTTryButtonObjectVoidHookSpec(OPVTButtonObjectVoidHookSpec *spec, NSString *phase) {
    if (!spec || spec->hooked) {
        return;
    }
    Class cls = objc_getClass(spec->className);
    if (!cls) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"button object hook missing class=%s phase=%@",
                    spec->className, phase ?: @"");
        }
        return;
    }
    SEL selector = sel_registerName(spec->selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"button object hook missing method=%s[%s] phase=%@",
                    spec->className, spec->selectorName, phase ?: @"");
        }
        return;
    }
    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount != 3 || !OPVTMethodReturnTypeStartsWith(method, 'v') ||
            !OPVTMethodArgumentTypeLooksObject(method, 2)) {
        char returnType[64] = {0};
        char argumentType[64] = {0};
        method_getReturnType(method, returnType, sizeof(returnType));
        method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
        OPVTLog(@"button object hook skipped method=%s[%s] args=%u return=%s arg2=%s phase=%@",
                spec->className, spec->selectorName, argumentCount,
                returnType[0] ? returnType : "",
                argumentType[0] ? argumentType : "", phase ?: @"");
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)OPVTButtonObjectVoidReplacement) {
        spec->hooked = YES;
        return;
    }
    spec->original = method_setImplementation(method, (IMP)OPVTButtonObjectVoidReplacement);
    spec->hooked = YES;
    OPVTLog(@"button object hook installed method=%s[%s] phase=%@",
            spec->className, spec->selectorName, phase ?: @"");
}

static void OPVTTryButtonObjectBoolHookSpec(OPVTButtonObjectBoolHookSpec *spec, NSString *phase) {
    if (!spec || spec->hooked) {
        return;
    }
    Class cls = objc_getClass(spec->className);
    if (!cls) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"button object hook missing class=%s phase=%@",
                    spec->className, phase ?: @"");
        }
        return;
    }
    SEL selector = sel_registerName(spec->selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"button object hook missing method=%s[%s] phase=%@",
                    spec->className, spec->selectorName, phase ?: @"");
        }
        return;
    }
    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount != 3 || !OPVTMethodReturnTypeLooksBool(method) ||
            !OPVTMethodArgumentTypeLooksObject(method, 2)) {
        char returnType[64] = {0};
        char argumentType[64] = {0};
        method_getReturnType(method, returnType, sizeof(returnType));
        method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
        OPVTLog(@"button object hook skipped method=%s[%s] args=%u return=%s arg2=%s phase=%@",
                spec->className, spec->selectorName, argumentCount,
                returnType[0] ? returnType : "",
                argumentType[0] ? argumentType : "", phase ?: @"");
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)OPVTButtonObjectBoolReplacement) {
        spec->hooked = YES;
        return;
    }
    spec->original = method_setImplementation(method, (IMP)OPVTButtonObjectBoolReplacement);
    spec->hooked = YES;
    OPVTLog(@"button object hook installed method=%s[%s] phase=%@",
            spec->className, spec->selectorName, phase ?: @"");
}

static void OPVTTryButtonRawHIDVoidHookSpec(OPVTButtonRawHIDVoidHookSpec *spec, NSString *phase) {
    if (!spec || spec->hooked) {
        return;
    }
    Class cls = objc_getClass(spec->className);
    if (!cls) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"raw HID hook missing class=%s phase=%@",
                    spec->className, phase ?: @"");
        }
        return;
    }
    SEL selector = sel_registerName(spec->selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"raw HID hook missing method=%s[%s] phase=%@",
                    spec->className, spec->selectorName, phase ?: @"");
        }
        return;
    }
    unsigned int argumentCount = method_getNumberOfArguments(method);
    char returnType[64] = {0};
    char argumentType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    if (argumentCount != 3 || returnType[0] != 'v' || argumentType[0] != '^') {
        OPVTLog(@"raw HID hook skipped method=%s[%s] args=%u return=%s arg2=%s phase=%@",
                spec->className, spec->selectorName, argumentCount,
                returnType[0] ? returnType : "",
                argumentType[0] ? argumentType : "", phase ?: @"");
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)OPVTButtonRawHIDVoidReplacement) {
        spec->hooked = YES;
        return;
    }
    spec->original = method_setImplementation(method, (IMP)OPVTButtonRawHIDVoidReplacement);
    spec->hooked = YES;
    OPVTLog(@"raw HID hook installed method=%s[%s] arg2=%s phase=%@",
            spec->className, spec->selectorName,
            argumentType[0] ? argumentType : "", phase ?: @"");
}

static BOOL OPVTMethodReturnTypeStartsWith(Method method, char expected) {
    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == expected;
}

static BOOL OPVTMethodReturnTypeLooksBool(Method method) {
    char returnType[64] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    return returnType[0] == 'B' || returnType[0] == 'c' || returnType[0] == 'C';
}

static BOOL OPVTMethodArgumentTypeLooksObject(Method method, unsigned int index) {
    char argumentType[64] = {0};
    method_getArgumentType(method, index, argumentType, sizeof(argumentType));
    return argumentType[0] == '@';
}

static void OPVTTryForegroundNoArgObjectHookSpec(OPVTForegroundNoArgObjectHookSpec *spec, NSString *phase) {
    if (!spec || spec->hooked) {
        return;
    }
    Class cls = objc_getClass(spec->className);
    if (!cls) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"foreground hook missing class=%s phase=%@", spec->className, phase ?: @"");
        }
        return;
    }
    SEL selector = sel_registerName(spec->selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"foreground hook missing method=%s[%s] phase=%@",
                    spec->className, spec->selectorName, phase ?: @"");
        }
        return;
    }
    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount != 2 || !OPVTMethodReturnTypeStartsWith(method, '@')) {
        OPVTLog(@"foreground hook skipped method=%s[%s] args=%u phase=%@",
                spec->className, spec->selectorName, argumentCount, phase ?: @"");
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)OPVTForegroundNoArgObjectReplacement) {
        spec->hooked = YES;
        return;
    }
    spec->original = method_setImplementation(method, (IMP)OPVTForegroundNoArgObjectReplacement);
    spec->hooked = YES;
    OPVTLog(@"foreground hook installed method=%s[%s] phase=%@",
            spec->className, spec->selectorName, phase ?: @"");
}

static void OPVTTryForegroundObjectArgVoidHookSpec(OPVTForegroundObjectArgVoidHookSpec *spec, NSString *phase) {
    if (!spec || spec->hooked) {
        return;
    }
    Class cls = objc_getClass(spec->className);
    if (!cls) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"foreground hook missing class=%s phase=%@", spec->className, phase ?: @"");
        }
        return;
    }
    SEL selector = sel_registerName(spec->selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"foreground hook missing method=%s[%s] phase=%@",
                    spec->className, spec->selectorName, phase ?: @"");
        }
        return;
    }
    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount != 3 || !OPVTMethodReturnTypeStartsWith(method, 'v') ||
            !OPVTMethodArgumentTypeLooksObject(method, 2)) {
        OPVTLog(@"foreground hook skipped method=%s[%s] args=%u phase=%@",
                spec->className, spec->selectorName, argumentCount, phase ?: @"");
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)OPVTForegroundObjectArgVoidReplacement) {
        spec->hooked = YES;
        return;
    }
    spec->original = method_setImplementation(method, (IMP)OPVTForegroundObjectArgVoidReplacement);
    spec->hooked = YES;
    OPVTLog(@"foreground hook installed method=%s[%s] phase=%@",
            spec->className, spec->selectorName, phase ?: @"");
}

static void OPVTTryForegroundObjectArgObjectHookSpec(OPVTForegroundObjectArgObjectHookSpec *spec, NSString *phase) {
    if (!spec || spec->hooked) {
        return;
    }
    Class cls = objc_getClass(spec->className);
    if (!cls) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"foreground hook missing class=%s phase=%@", spec->className, phase ?: @"");
        }
        return;
    }
    SEL selector = sel_registerName(spec->selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"foreground hook missing method=%s[%s] phase=%@",
                    spec->className, spec->selectorName, phase ?: @"");
        }
        return;
    }
    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount != 3 || !OPVTMethodReturnTypeStartsWith(method, '@') ||
            !OPVTMethodArgumentTypeLooksObject(method, 2)) {
        OPVTLog(@"foreground hook skipped method=%s[%s] args=%u phase=%@",
                spec->className, spec->selectorName, argumentCount, phase ?: @"");
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)OPVTForegroundObjectArgObjectReplacement) {
        spec->hooked = YES;
        return;
    }
    spec->original = method_setImplementation(method, (IMP)OPVTForegroundObjectArgObjectReplacement);
    spec->hooked = YES;
    OPVTLog(@"foreground hook installed method=%s[%s] phase=%@",
            spec->className, spec->selectorName, phase ?: @"");
}

static void OPVTTryForegroundNoArgBoolHookSpec(OPVTForegroundNoArgBoolHookSpec *spec, NSString *phase) {
    if (!spec || spec->hooked) {
        return;
    }
    Class cls = objc_getClass(spec->className);
    if (!cls) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"foreground hook missing class=%s phase=%@", spec->className, phase ?: @"");
        }
        return;
    }
    SEL selector = sel_registerName(spec->selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        if (OPVTShouldLogHookMiss(phase)) {
            OPVTLog(@"foreground hook missing method=%s[%s] phase=%@",
                    spec->className, spec->selectorName, phase ?: @"");
        }
        return;
    }
    unsigned int argumentCount = method_getNumberOfArguments(method);
    if (argumentCount != 2 || !OPVTMethodReturnTypeLooksBool(method)) {
        OPVTLog(@"foreground hook skipped method=%s[%s] args=%u phase=%@",
                spec->className, spec->selectorName, argumentCount, phase ?: @"");
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == (IMP)OPVTForegroundNoArgBoolReplacement) {
        spec->hooked = YES;
        return;
    }
    spec->original = method_setImplementation(method, (IMP)OPVTForegroundNoArgBoolReplacement);
    spec->hooked = YES;
    OPVTLog(@"foreground hook installed method=%s[%s] phase=%@",
            spec->className, spec->selectorName, phase ?: @"");
}

static void OPVTTryForegroundRuntimeHooks(NSString *phase) {
    size_t count = sizeof(OPVTForegroundNoArgObjectHookSpecs) / sizeof(OPVTForegroundNoArgObjectHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTTryForegroundNoArgObjectHookSpec(&OPVTForegroundNoArgObjectHookSpecs[index], phase);
    }
    count = sizeof(OPVTForegroundObjectArgVoidHookSpecs) / sizeof(OPVTForegroundObjectArgVoidHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTTryForegroundObjectArgVoidHookSpec(&OPVTForegroundObjectArgVoidHookSpecs[index], phase);
    }
    count = sizeof(OPVTForegroundObjectArgObjectHookSpecs) / sizeof(OPVTForegroundObjectArgObjectHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTTryForegroundObjectArgObjectHookSpec(&OPVTForegroundObjectArgObjectHookSpecs[index], phase);
    }
    count = sizeof(OPVTForegroundNoArgBoolHookSpecs) / sizeof(OPVTForegroundNoArgBoolHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTTryForegroundNoArgBoolHookSpec(&OPVTForegroundNoArgBoolHookSpecs[index], phase);
    }
}

static BOOL OPVTHaveAnyRuntimeHook(void) {
    size_t count = sizeof(OPVTHookSpecs) / sizeof(OPVTHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        if (OPVTHookSpecs[index].hooked) {
            return YES;
        }
    }
    count = sizeof(OPVTFixedArgHookSpecs) / sizeof(OPVTFixedArgHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        if (OPVTFixedArgHookSpecs[index].hooked) {
            return YES;
        }
    }
    count = sizeof(OPVTBoolArgHookSpecs) / sizeof(OPVTBoolArgHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        if (OPVTBoolArgHookSpecs[index].hooked) {
            return YES;
        }
    }
    count = sizeof(OPVTBoolPairHookSpecs) / sizeof(OPVTBoolPairHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        if (OPVTBoolPairHookSpecs[index].hooked) {
            return YES;
        }
    }
    count = sizeof(OPVTButtonObjectVoidHookSpecs) / sizeof(OPVTButtonObjectVoidHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        if (OPVTButtonObjectVoidHookSpecs[index].hooked) {
            return YES;
        }
    }
    count = sizeof(OPVTButtonObjectBoolHookSpecs) / sizeof(OPVTButtonObjectBoolHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        if (OPVTButtonObjectBoolHookSpecs[index].hooked) {
            return YES;
        }
    }
    count = sizeof(OPVTButtonRawHIDVoidHookSpecs) / sizeof(OPVTButtonRawHIDVoidHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        if (OPVTButtonRawHIDVoidHookSpecs[index].hooked) {
            return YES;
        }
    }
    return NO;
}

static BOOL OPVTShouldLogHookMiss(NSString *phase) {
    if (![phase hasPrefix:@"delayed-"]) {
        return YES;
    }
    return [phase isEqualToString:@"delayed-1"] ||
            [phase isEqualToString:@"delayed-5"] ||
            [phase isEqualToString:@"delayed-20"];
}

static void OPVTTryRuntimeHooks(NSString *phase) {
    size_t count = sizeof(OPVTHookSpecs) / sizeof(OPVTHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTTryHookSpec(&OPVTHookSpecs[index], phase);
    }
    count = sizeof(OPVTFixedArgHookSpecs) / sizeof(OPVTFixedArgHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTTryHookFixedArgSpec(&OPVTFixedArgHookSpecs[index], phase);
    }
    count = sizeof(OPVTBoolArgHookSpecs) / sizeof(OPVTBoolArgHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTTryHookBoolArgSpec(&OPVTBoolArgHookSpecs[index], phase);
    }
    count = sizeof(OPVTBoolPairHookSpecs) / sizeof(OPVTBoolPairHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTTryHookBoolPairSpec(&OPVTBoolPairHookSpecs[index], phase);
    }
    count = sizeof(OPVTButtonObjectVoidHookSpecs) / sizeof(OPVTButtonObjectVoidHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTTryButtonObjectVoidHookSpec(&OPVTButtonObjectVoidHookSpecs[index], phase);
    }
    count = sizeof(OPVTButtonObjectBoolHookSpecs) / sizeof(OPVTButtonObjectBoolHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTTryButtonObjectBoolHookSpec(&OPVTButtonObjectBoolHookSpecs[index], phase);
    }
    count = sizeof(OPVTButtonRawHIDVoidHookSpecs) / sizeof(OPVTButtonRawHIDVoidHookSpecs[0]);
    for (size_t index = 0; index < count; index++) {
        OPVTTryButtonRawHIDVoidHookSpec(&OPVTButtonRawHIDVoidHookSpecs[index], phase);
    }
    OPVTTryForegroundRuntimeHooks(phase);
    OPVTPublishTriggerStatus(@"hook_scan", @{@"phase": phase ?: @""});
}

static BOOL OPVTNameLooksVolumeRelated(const char *name) {
    return name && (strstr(name, "Volume") ||
            strstr(name, "volume") ||
            strstr(name, "Button") ||
            strstr(name, "button"));
}

static BOOL OPVTNameLooksForegroundClassRelated(const char *name) {
    if (!name) {
        return NO;
    }
    return strstr(name, "SpringBoard") ||
            strstr(name, "SBMainWorkspace") ||
            strstr(name, "SBWorkspace") ||
            strstr(name, "SBApplication") ||
            strstr(name, "SBApp") ||
            strstr(name, "SBScene") ||
            strstr(name, "SBDisplay") ||
            strstr(name, "SBMainDisplay") ||
            strstr(name, "SBMainSwitcher") ||
            strstr(name, "SBHomeScreen") ||
            strstr(name, "SBIconController") ||
            strstr(name, "FBScene") ||
            strstr(name, "FBWorkspace") ||
            strstr(name, "FBSScene");
}

static BOOL OPVTNameLooksForegroundMethodRelated(const char *name) {
    if (!name) {
        return NO;
    }
    return strstr(name, "foreground") ||
            strstr(name, "Foreground") ||
            strstr(name, "frontmost") ||
            strstr(name, "Frontmost") ||
            strstr(name, "frontMost") ||
            strstr(name, "active") ||
            strstr(name, "Active") ||
            strstr(name, "activate") ||
            strstr(name, "Activate") ||
            strstr(name, "deactivate") ||
            strstr(name, "Deactivate") ||
            strstr(name, "application") ||
            strstr(name, "Application") ||
            strstr(name, "bundle") ||
            strstr(name, "Bundle") ||
            strstr(name, "scene") ||
            strstr(name, "Scene") ||
            strstr(name, "display") ||
            strstr(name, "Display") ||
            strstr(name, "layout") ||
            strstr(name, "Layout") ||
            strstr(name, "switcher") ||
            strstr(name, "Switcher") ||
            strstr(name, "launch") ||
            strstr(name, "Launch");
}

static void OPVTLogVolumeRuntimeSnapshot(NSString *phase) {
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) {
        OPVTLog(@"runtime snapshot empty phase=%@", phase ?: @"");
        return;
    }

    Class *classes = (Class *)calloc((size_t)classCount, sizeof(Class));
    if (!classes) {
        OPVTLog(@"runtime snapshot allocation failed count=%d phase=%@", classCount, phase ?: @"");
        return;
    }

    classCount = objc_getClassList(classes, classCount);
    int logged = 0;
    const int maxLines = 180;
    for (int index = 0; index < classCount && logged < maxLines; index++) {
        Class cls = classes[index];
        const char *className = class_getName(cls);
        BOOL classMatches = OPVTNameLooksVolumeRelated(className);
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int methodIndex = 0; methods && methodIndex < methodCount && logged < maxLines; methodIndex++) {
            SEL selector = method_getName(methods[methodIndex]);
            const char *selectorName = sel_getName(selector);
            if (!classMatches && !OPVTNameLooksVolumeRelated(selectorName)) {
                continue;
            }
            if (!strstr(selectorName ?: "", "Volume") &&
                    !strstr(selectorName ?: "", "volume") &&
                    !strstr(selectorName ?: "", "increase") &&
                    !strstr(selectorName ?: "", "decrease") &&
                    !strstr(selectorName ?: "", "button") &&
                    !strstr(selectorName ?: "", "Button")) {
                continue;
            }
            char returnType[64] = {0};
            char argumentType[64] = {0};
            method_getReturnType(methods[methodIndex], returnType, sizeof(returnType));
            if (method_getNumberOfArguments(methods[methodIndex]) > 2) {
                method_getArgumentType(methods[methodIndex], 2, argumentType, sizeof(argumentType));
            }
            OPVTLog(@"runtime volume candidate phase=%@ class=%s method=%s args=%u return=%s arg2=%s",
                    phase ?: @"", className ?: "(null)", selectorName ?: "(null)",
                    method_getNumberOfArguments(methods[methodIndex]),
                    returnType[0] ? returnType : "",
                    argumentType[0] ? argumentType : "");
            logged++;
        }
        if (methods) {
            free(methods);
        }
    }
    free(classes);
    OPVTLog(@"runtime snapshot complete phase=%@ lines=%d", phase ?: @"", logged);
}

static void OPVTLogForegroundRuntimeSnapshot(NSString *phase) {
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) {
        OPVTLog(@"foreground runtime snapshot empty phase=%@", phase ?: @"");
        return;
    }

    Class *classes = (Class *)calloc((size_t)classCount, sizeof(Class));
    if (!classes) {
        OPVTLog(@"foreground runtime snapshot allocation failed count=%d phase=%@", classCount, phase ?: @"");
        return;
    }

    classCount = objc_getClassList(classes, classCount);
    int logged = 0;
    const int maxLines = 260;
    for (int pass = 0; pass < 2 && logged < maxLines; pass++) {
        BOOL requireClassMatch = pass == 0;
        for (int index = 0; index < classCount && logged < maxLines; index++) {
            Class cls = classes[index];
            const char *className = class_getName(cls);
            BOOL classMatches = OPVTNameLooksForegroundClassRelated(className);
            if (requireClassMatch && !classMatches) {
                continue;
            }
            if (!requireClassMatch && classMatches) {
                continue;
            }
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(cls, &methodCount);
            for (unsigned int methodIndex = 0; methods && methodIndex < methodCount && logged < maxLines; methodIndex++) {
                Method method = methods[methodIndex];
                SEL selector = method_getName(method);
                const char *selectorName = sel_getName(selector);
                if (!OPVTNameLooksForegroundMethodRelated(selectorName)) {
                    continue;
                }
                char returnType[64] = {0};
                char argumentType[64] = {0};
                method_getReturnType(method, returnType, sizeof(returnType));
                if (method_getNumberOfArguments(method) > 2) {
                    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
                }
                OPVTLog(@"foreground runtime candidate phase=%@ pass=%d class=%s method=%s args=%u return=%s arg2=%s",
                        phase ?: @"", pass + 1, className ?: "(null)", selectorName ?: "(null)",
                        method_getNumberOfArguments(method),
                        returnType[0] ? returnType : "",
                        argumentType[0] ? argumentType : "");
                logged++;
            }
            if (methods) {
                free(methods);
            }
        }
    }
    free(classes);
    OPVTLog(@"foreground runtime snapshot complete phase=%@ lines=%d", phase ?: @"", logged);
}

static void *OPVTDelayedHookThread(void *unused) {
    (void)unused;
    @autoreleasepool {
        for (int attempt = 1; attempt <= 20; attempt++) {
            sleep(1);
            NSString *phase = [NSString stringWithFormat:@"delayed-%d", attempt];
            OPVTTryRuntimeHooks(phase);
            if (!OPVTHaveAnyRuntimeHook() &&
                    (attempt == 1 || attempt == 5 || attempt == 20)) {
                OPVTLogVolumeRuntimeSnapshot(phase);
            }
            if (OPVTBoolPreference(@"ForegroundRuntimeSnapshotEnabled", NO) &&
                    (attempt == 5 || attempt == 20)) {
                OPVTLogForegroundRuntimeSnapshot(phase);
            }
        }
    }
    return NULL;
}

static void *OPVTSpringBoardStateThread(void *unused) {
    (void)unused;
    for (int attempt = 0; attempt < 5; attempt++) {
        @autoreleasepool {
            OPVTPublishSpringBoardStateOnMain();
            OPVTPublishTriggerStatus(@"heartbeat", @{@"phase": @"startup"});
        }
        sleep(1);
    }
    while (true) {
        @autoreleasepool {
            OPVTPublishSpringBoardStateOnMain();
            OPVTPublishTriggerStatus(@"heartbeat", @{@"phase": @"steady"});
        }
        sleep(2);
    }
    return NULL;
}

static void *OPVTScreenshotRequestThread(void *unused) {
    (void)unused;
    __strong NSString *lastRequestId = nil;
    while (true) {
        @autoreleasepool {
            NSDictionary *request = OPVTReadJSONDictionary(OPVTScreenshotRequestPath);
            NSString *requestId = [request[@"request_id"] isKindOfClass:[NSString class]]
                    ? request[@"request_id"] : @"";
            if (requestId.length > 0 && ![requestId isEqualToString:lastRequestId]) {
                lastRequestId = [requestId copy];
                long long requestTimestamp = [request[@"timestamp_ms"] respondsToSelector:@selector(longLongValue)]
                        ? [request[@"timestamp_ms"] longLongValue] : 0;
                long long requestAge = requestTimestamp > 0 ? MAX(0, OPVTNowMs() - requestTimestamp) : 0;
                NSDictionary *existingResponse = OPVTReadJSONDictionary(OPVTScreenshotResponsePath);
                NSString *existingResponseId = [existingResponse[@"request_id"] isKindOfClass:[NSString class]]
                        ? existingResponse[@"request_id"] : @"";
                if ([existingResponseId isEqualToString:requestId]) {
                    continue;
                }
                if (requestTimestamp <= 0 || requestAge > 10000) {
                    OPVTLog(@"screenshot request ignored stale request=%@ age_ms=%lld",
                            requestId, requestAge);
                    continue;
                }
                __block NSDictionary *response = nil;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    response = OPVTCaptureSpringBoardScreenshot(request);
                });
                if (!OPVTWriteJSONDictionary(OPVTScreenshotResponsePath, response ?: @{})) {
                    OPVTLog(@"screenshot response write failed request=%@", requestId);
                } else {
                    OPVTLog(@"screenshot response status=%@ request=%@ path=%@",
                            response[@"status"] ?: @"unknown",
                            requestId,
                            response[@"path"] ?: @"");
                }
            }
        }
        usleep(250000);
    }
    return NULL;
}

static void *OPVTInputRequestThread(void *unused) {
    (void)unused;
    __strong NSString *lastRequestId = nil;
    while (true) {
        @autoreleasepool {
            NSDictionary *request = OPVTReadJSONDictionary(OPVTInputRequestPath);
            NSString *requestId = [request[@"request_id"] isKindOfClass:[NSString class]]
                    ? request[@"request_id"] : @"";
            if (requestId.length > 0 && ![requestId isEqualToString:lastRequestId]) {
                lastRequestId = [requestId copy];
                long long requestTimestamp = OPVTLongLongValue(request[@"timestamp_ms"], 0);
                long long requestAge = requestTimestamp > 0 ? MAX(0, OPVTNowMs() - requestTimestamp) : 0;
                NSDictionary *existingResponse = OPVTReadJSONDictionary(OPVTInputResponsePath);
                NSString *existingResponseId = [existingResponse[@"request_id"] isKindOfClass:[NSString class]]
                        ? existingResponse[@"request_id"] : @"";
                if ([existingResponseId isEqualToString:requestId]) {
                    continue;
                }
                if (requestTimestamp <= 0 || requestAge > 10000) {
                    OPVTLog(@"input request ignored stale request=%@ age_ms=%lld",
                            requestId, requestAge);
                    [[NSFileManager defaultManager] removeItemAtPath:OPVTInputRequestPath error:nil];
                    continue;
                }
                __block NSDictionary *response = nil;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    response = OPVTPerformSpringBoardInput(request);
                });
                if (!OPVTWriteJSONDictionary(OPVTInputResponsePath, response ?: @{})) {
                    OPVTLog(@"input response write failed request=%@", requestId);
                } else {
                    OPVTLog(@"input response status=%@ request=%@ action=%@ reason=%@",
                            response[@"status"] ?: @"unknown",
                            requestId,
                            response[@"action_type"] ?: @"",
                            response[@"reason"] ?: @"");
                }
                [[NSFileManager defaultManager] removeItemAtPath:OPVTInputRequestPath error:nil];
            }
        }
        usleep(250000);
    }
    return NULL;
}

static void *OPVTClipboardRequestThread(void *unused) {
    (void)unused;
    __strong NSString *lastRequestId = nil;
    while (true) {
        @autoreleasepool {
            NSDictionary *request = OPVTReadJSONDictionary(OPVTClipboardRequestPath);
            NSString *requestId = [request[@"request_id"] isKindOfClass:[NSString class]]
                    ? request[@"request_id"] : @"";
            if (requestId.length > 0 && ![requestId isEqualToString:lastRequestId]) {
                lastRequestId = [requestId copy];
                long long requestTimestamp = OPVTLongLongValue(request[@"timestamp_ms"], 0);
                long long requestAge = requestTimestamp > 0 ? MAX(0, OPVTNowMs() - requestTimestamp) : 0;
                NSDictionary *existingResponse = OPVTReadJSONDictionary(OPVTClipboardResponsePath);
                NSString *existingResponseId = [existingResponse[@"request_id"] isKindOfClass:[NSString class]]
                        ? existingResponse[@"request_id"] : @"";
                if ([existingResponseId isEqualToString:requestId]) {
                    continue;
                }
                if (requestTimestamp <= 0 || requestAge > 10000) {
                    OPVTLog(@"clipboard request ignored stale request=%@ age_ms=%lld",
                            requestId, requestAge);
                    [[NSFileManager defaultManager] removeItemAtPath:OPVTClipboardRequestPath error:nil];
                    continue;
                }
                __block NSDictionary *response = nil;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    response = OPVTPerformClipboardRequest(request);
                });
                if (!OPVTWriteJSONDictionary(OPVTClipboardResponsePath, response ?: @{})) {
                    OPVTLog(@"clipboard response write failed request=%@", requestId);
                } else {
                    OPVTLog(@"clipboard response status=%@ request=%@ operation=%@ reason=%@",
                            response[@"status"] ?: @"unknown",
                            requestId,
                            response[@"operation"] ?: @"",
                            response[@"reason"] ?: @"");
                }
                [[NSFileManager defaultManager] removeItemAtPath:OPVTClipboardRequestPath error:nil];
            }
        }
        usleep(250000);
    }
    return NULL;
}

static void *OPVTPromptRequestThread(void *unused) {
    (void)unused;
    __strong NSString *lastRequestId = nil;
    while (true) {
        @autoreleasepool {
            NSDictionary *request = OPVTReadJSONDictionary(OPVTPromptRequestPath);
            NSString *requestId = [request[@"request_id"] isKindOfClass:[NSString class]]
                    ? request[@"request_id"] : @"";
            if (requestId.length > 0 && ![requestId isEqualToString:lastRequestId]) {
                lastRequestId = [requestId copy];
                long long requestTimestamp = OPVTLongLongValue(request[@"timestamp_ms"], 0);
                long long requestAge = requestTimestamp > 0 ? MAX(0, OPVTNowMs() - requestTimestamp) : 0;
                NSDictionary *existingResponse = OPVTReadJSONDictionary(OPVTPromptResponsePath);
                NSString *existingResponseId = [existingResponse[@"request_id"] isKindOfClass:[NSString class]]
                        ? existingResponse[@"request_id"] : @"";
                if ([existingResponseId isEqualToString:requestId]) {
                    continue;
                }
                if (requestTimestamp <= 0 || requestAge > 10000) {
                    OPVTLog(@"prompt request ignored stale request=%@ age_ms=%lld",
                            requestId, requestAge);
                    [[NSFileManager defaultManager] removeItemAtPath:OPVTPromptRequestPath error:nil];
                    continue;
                }
                __block NSDictionary *response = nil;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    response = OPVTPerformPromptRequest(request);
                });
                if (!OPVTWriteJSONDictionary(OPVTPromptResponsePath, response ?: @{})) {
                    OPVTLog(@"prompt response write failed request=%@", requestId);
                } else {
                    OPVTLog(@"prompt response status=%@ request=%@ operation=%@ reason=%@",
                            response[@"status"] ?: @"unknown",
                            requestId,
                            response[@"operation"] ?: @"",
                            response[@"reason"] ?: @"");
                }
                [[NSFileManager defaultManager] removeItemAtPath:OPVTPromptRequestPath error:nil];
            }
        }
        usleep(250000);
    }
    return NULL;
}

@implementation OPVTVolumeNotificationObserver

- (void)openphoneSystemVolumeDidChange:(NSNotification *)notification {
    OPVTHandleSystemVolumeNotification(notification);
}

@end

%hook SBVolumeControl

- (void)increaseVolume {
    OPVTRecordButtonFromSource(YES, @"logos.SBVolumeControl.increaseVolume");
    %orig;
}

- (void)decreaseVolume {
    OPVTRecordButtonFromSource(NO, @"logos.SBVolumeControl.decreaseVolume");
    %orig;
}

%end

%hook VolumeControl

- (void)increaseVolume {
    OPVTRecordButtonFromSource(YES, @"logos.VolumeControl.increaseVolume");
    %orig;
}

- (void)decreaseVolume {
    OPVTRecordButtonFromSource(NO, @"logos.VolumeControl.decreaseVolume");
    %orig;
}

%end

// ---------------------------------------------------------------------------
// Notification provider. Hook NCNotificationDispatcher (SpringBoard's incoming
// banner pipeline) and forward each request to the daemon's notification_ingest
// command over the local Unix socket. The daemon keeps a bounded, redacted log
// and fires any active `notification`-source watchers. KVC-based field access
// keeps this resilient to private-API shape changes across iOS versions.
// ---------------------------------------------------------------------------

@interface NCNotificationRequest : NSObject
@end

static NSString *OPVTNotifKVCString(id object, NSString *key) {
    if (!object || key.length == 0) {
        return @"";
    }
    @try {
        id value = [object valueForKey:key];
        if ([value isKindOfClass:[NSString class]]) {
            return value;
        }
    } @catch (__unused NSException *e) {
    }
    return @"";
}

static void OPVTForwardNotification(id request) {
    if (!request) {
        return;
    }
    NSString *bundleId = OPVTNotifKVCString(request, @"sectionIdentifier");
    if (bundleId.length == 0) {
        bundleId = OPVTNotifKVCString(request, @"bundleIdentifier");
    }
    // Never forward our own island-driven signals or empty bundles.
    if (bundleId.length == 0 || [bundleId hasPrefix:@"com.openphone"]) {
        return;
    }
    id content = nil;
    @try {
        content = [request valueForKey:@"content"];
    } @catch (__unused NSException *e) {
    }
    NSString *title = OPVTNotifKVCString(content, @"title");
    NSString *subtitle = OPVTNotifKVCString(content, @"subtitle");
    NSString *body = OPVTNotifKVCString(content, @"message");
    if (body.length == 0) {
        body = OPVTNotifKVCString(content, @"body");
    }
    NSString *notifId = OPVTNotifKVCString(request, @"notificationIdentifier");
    NSString *threadId = OPVTNotifKVCString(request, @"threadIdentifier");
    if (title.length == 0 && body.length == 0 && subtitle.length == 0) {
        return;
    }
    NSDictionary *payload = @{
        @"command": @"notification_ingest",
        @"bundle_id": bundleId,
        @"title": title ?: @"",
        @"subtitle": subtitle ?: @"",
        @"body": body ?: @"",
        @"notification_id": notifId ?: @"",
        @"thread_id": threadId ?: @"",
        @"source": @"springboard_nc_dispatcher",
        @"reason": @"incoming notification banner"
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        OPVTAgentRequest(payload);
    });
}

%hook NCNotificationDispatcher

- (void)postNotificationRequest:(id)request {
    %orig;
    @try {
        OPVTForwardNotification(request);
    } @catch (__unused NSException *e) {
    }
}

- (void)postNotificationRequest:(id)request forCoalescedNotifications:(id)coalesced {
    %orig;
    @try {
        OPVTForwardNotification(request);
    } @catch (__unused NSException *e) {
    }
}

%end

// ---------------------------------------------------------------------------
// OpenPhone Island: persistent Dynamic-Island-style overlay driven by the
// daemon's live status file (island-status.json). Renders idle/listening/
// transcribing/thinking/action/success/error states with a live subtitle,
// tool label, and transcript. Mirrors the Android voice-agent island.
// ---------------------------------------------------------------------------

static NSString *const OPVTIslandStatusPath =
        @"/var/mobile/Library/OpenPhone/springboard/island-status.json";
static const char *const OPVTIslandNotification = "com.openphone.island.status";

@class OPVTIslandGestureBridge;
static void OPVTIslandCollapse(void);
static void OPVTIslandExpand(void);
static void OPVTIslandAnimateToLevel(NSInteger level);
static void OPVTIslandAttachGestures(void);
static void OPVTIslandStartTicker(void);

// Custom passthrough window: only forward touches to hits within the pill so
// the rest of the screen (SpringBoard, apps) is not blocked by the overlay.
@interface OPVTPassthroughWindow : UIWindow
@end
@implementation OPVTPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) {
        return nil; // Pass through
    }
    return hit;
}
@end

static UIWindow *OPVTIslandWindow = nil;
static UIView *OPVTIslandPill = nil;
static UIView *OPVTIslandExpanded = nil;
static UILabel *OPVTIslandTitleLabel = nil;
static UILabel *OPVTIslandSubtitleLabel = nil;
static UILabel *OPVTIslandExpandedLine1 = nil;
static UILabel *OPVTIslandExpandedLine2 = nil;
static UIView *OPVTIslandStatusDot = nil;
static CAShapeLayer *OPVTIslandGlowLayer = nil;
static CAGradientLayer *OPVTIslandGradientGlowLayer = nil;
static CAShapeLayer *OPVTIslandGradientMask = nil;
static CADisplayLink *OPVTIslandTicker = nil;
static CGFloat OPVTIslandGradientShift = 0.0;
static NSInteger OPVTIslandThinkingTick = 0;
static UIButton *OPVTIslandApproveBtn = nil;
static UIButton *OPVTIslandDenyBtn = nil;
static UIButton *OPVTIslandCancelChip = nil;
static UIView *OPVTIslandDragCatcher = nil;
static UIScrollView *OPVTIslandChatScroll = nil;
static UIView *OPVTIslandChatStack = nil;
static UIView *OPVTIslandTabBar = nil;
static UIButton *OPVTIslandTabChat = nil;
static UIButton *OPVTIslandTabRuns = nil;
static UIButton *OPVTIslandTabWatchers = nil;
static NSString *OPVTIslandActiveTab = @"chat";
// Expansion level: 0 = compact DI shape, 1 = medium panel, 2 = large full-screen panel.
static NSInteger OPVTIslandExpansionLevel = 0;
static NSArray *OPVTIslandChatTurns = nil;
static int OPVTIslandChatNotifyToken = 0;
static int OPVTIslandHideNotifyToken = 0;
static int OPVTIslandShowNotifyToken = 0;
static BOOL OPVTIslandCaptureObserverInstalled = NO;
static BOOL OPVTIslandChatObserverInstalled = NO;
static UIView *OPVTIslandUserBubble = nil;
static UILabel *OPVTIslandUserBubbleLabel = nil;
static UIView *OPVTIslandAssistantBubble = nil;
static UILabel *OPVTIslandAssistantBubbleLabel = nil;
static unsigned long long OPVTIslandLastSequence = 0;
static long long OPVTIslandLastAppliedMs = 0;
static NSDictionary *OPVTIslandCurrentState = nil;
static int OPVTIslandStatusNotifyToken = 0;
static BOOL OPVTIslandStatusNotifyRegistered = NO;

static UIColor *OPVTIslandAccentColor(NSString *accent) {
    NSString *key = [accent isKindOfClass:[NSString class]] ? accent.lowercaseString : @"cyan";
    if ([key isEqualToString:@"red"]) {
        return [UIColor colorWithRed:1.0 green:0.42 blue:0.42 alpha:1.0];
    }
    if ([key isEqualToString:@"green"]) {
        return [UIColor colorWithRed:0.125 green:0.89 blue:0.416 alpha:1.0];
    }
    if ([key isEqualToString:@"blue"]) {
        return [UIColor colorWithRed:0.604 green:0.722 blue:1.0 alpha:1.0];
    }
    if ([key isEqualToString:@"orange"] || [key isEqualToString:@"yellow"]) {
        return [UIColor colorWithRed:1.0 green:0.82 blue:0.42 alpha:1.0];
    }
    return [UIColor colorWithRed:0.447 green:0.878 blue:0.769 alpha:1.0]; // cyan
}

static BOOL OPVTIslandDeviceHasDynamicIsland(void) {
    // iPhone 14 Pro / 14 Pro Max, 15/16 Pro line: safeAreaTop ~59pt while
    // status bar is 54pt on non-DI devices. Simple heuristic works reliably.
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = OPVTActiveWindowScene();
        UIWindow *keyWindow = scene.windows.firstObject;
        if (keyWindow) {
            return keyWindow.safeAreaInsets.top >= 55.0;
        }
    }
    return NO;
}

// level: 0 = compact (DI shape), 1 = medium panel, 2 = large full-screen panel.
static CGRect OPVTIslandPillFrameForLevel(CGRect bounds, NSInteger level) {
    CGFloat topBase = OPVTIslandDeviceHasDynamicIsland() ? 11.0 : 12.0;
    if (!OPVTIslandDeviceHasDynamicIsland()) {
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = OPVTActiveWindowScene();
            UIWindow *keyWindow = scene.windows.firstObject;
            if (keyWindow && keyWindow.safeAreaInsets.top > 20.0) {
                topBase = MAX(topBase, keyWindow.safeAreaInsets.top - 34.0);
            }
        }
    }
    if (level >= 2) {
        // Large: full width minus small margin, ~75% of screen height.
        CGFloat pillWidth = bounds.size.width - 16.0;
        CGFloat pillHeight = bounds.size.height * 0.75;
        CGFloat originX = (bounds.size.width - pillWidth) / 2.0;
        return CGRectMake(originX, topBase, pillWidth, pillHeight);
    }
    if (level == 1) {
        // Medium panel.
        CGFloat pillWidth = OPVTIslandDeviceHasDynamicIsland()
                ? MIN(bounds.size.width - 16.0, 380.0)
                : MIN(bounds.size.width - 20.0, 360.0);
        CGFloat pillHeight = OPVTIslandDeviceHasDynamicIsland() ? 210.0 : 200.0;
        CGFloat originX = (bounds.size.width - pillWidth) / 2.0;
        return CGRectMake(originX, topBase, pillWidth, pillHeight);
    }
    // Compact: match Dynamic Island exactly on DI devices, plain pill elsewhere.
    if (OPVTIslandDeviceHasDynamicIsland()) {
        CGFloat pillWidth = 122.0;
        CGFloat pillHeight = 37.0;
        CGFloat originX = (bounds.size.width - pillWidth) / 2.0;
        return CGRectMake(originX, topBase, pillWidth, pillHeight);
    }
    CGFloat pillWidth = MIN(bounds.size.width - 20.0, 260.0);
    CGFloat pillHeight = 44.0;
    CGFloat originX = (bounds.size.width - pillWidth) / 2.0;
    return CGRectMake(originX, topBase, pillWidth, pillHeight);
}

// Legacy shim used elsewhere in the file — maps BOOL to level 0/1.
static CGRect OPVTIslandPillFrame(CGRect bounds, BOOL expanded) {
    return OPVTIslandPillFrameForLevel(bounds, expanded ? MAX(1, OPVTIslandExpansionLevel) : 0);
}

static void OPVTIslandEnsureWindow(void) {
    if (OPVTIslandWindow) {
        return;
    }
    dispatch_assert_queue(dispatch_get_main_queue());
    UIScreen *screen = OPVTSafeMainScreen();
    if (!screen) {
        return;
    }
    CGRect bounds = screen.bounds;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = OPVTActiveWindowScene();
        if (scene) {
            OPVTIslandWindow = [[OPVTPassthroughWindow alloc] initWithWindowScene:scene];
            OPVTIslandWindow.frame = bounds;
        } else {
            OPVTIslandWindow = [[OPVTPassthroughWindow alloc] initWithFrame:bounds];
        }
    } else {
        OPVTIslandWindow = [[OPVTPassthroughWindow alloc] initWithFrame:bounds];
    }
    OPVTIslandWindow.windowLevel = UIWindowLevelAlert + 2500;
    OPVTIslandWindow.userInteractionEnabled = YES;
    OPVTIslandWindow.backgroundColor = [UIColor clearColor];
    // Always visible so the user can tap into chat history at any time. Idle
    // opacity is set low in OPVTIslandApplyState.
    OPVTIslandWindow.hidden = NO;
    UIViewController *controller = [[UIViewController alloc] init];
    controller.view.backgroundColor = [UIColor clearColor];
    controller.view.userInteractionEnabled = YES;
    OPVTIslandWindow.rootViewController = controller;

    UIView *root = controller.view;

    // Pill container.
    OPVTIslandPill = [[UIView alloc] initWithFrame:OPVTIslandPillFrame(bounds, NO)];
    OPVTIslandPill.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.94];
    // Match the Dynamic Island's exact corner curvature — its height is ~37pt
    // and it's a full pill (radius = height/2). We keep that ratio on expand
    // too so the shape stays consistent.
    OPVTIslandPill.layer.cornerRadius = 18.5;
    OPVTIslandPill.layer.masksToBounds = NO;
    OPVTIslandPill.userInteractionEnabled = YES;

    // Animated rainbow gradient glow — matches Android's PointerOverlayController
    // GlowBorderView. Two layers: a soft outer shadow to bloom the light, and a
    // masked gradient stroke that shifts horizontally over time.
    OPVTIslandGlowLayer = [CAShapeLayer layer];
    OPVTIslandGlowLayer.fillColor = [UIColor clearColor].CGColor;
    OPVTIslandGlowLayer.strokeColor = OPVTIslandAccentColor(@"cyan").CGColor;
    OPVTIslandGlowLayer.lineWidth = 2.4;
    OPVTIslandGlowLayer.shadowColor = OPVTIslandAccentColor(@"cyan").CGColor;
    OPVTIslandGlowLayer.shadowRadius = 18.0;
    OPVTIslandGlowLayer.shadowOpacity = 0.85;
    OPVTIslandGlowLayer.shadowOffset = CGSizeZero;
    [OPVTIslandPill.layer addSublayer:OPVTIslandGlowLayer];

    OPVTIslandGradientGlowLayer = [CAGradientLayer layer];
    OPVTIslandGradientGlowLayer.colors = @[
        (id)[UIColor colorWithRed:0.365 green:0.863 blue:1.0 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.580 green:0.424 blue:1.0 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:1.0 green:0.337 blue:0.659 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:1.0 green:0.800 blue:0.424 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.365 green:0.863 blue:1.0 alpha:1.0].CGColor
    ];
    OPVTIslandGradientGlowLayer.startPoint = CGPointMake(0.0, 0.5);
    OPVTIslandGradientGlowLayer.endPoint = CGPointMake(1.0, 0.5);
    OPVTIslandGradientGlowLayer.opacity = 0.9;
    [OPVTIslandPill.layer addSublayer:OPVTIslandGradientGlowLayer];

    OPVTIslandGradientMask = [CAShapeLayer layer];
    OPVTIslandGradientMask.fillColor = [UIColor clearColor].CGColor;
    OPVTIslandGradientMask.strokeColor = [UIColor blackColor].CGColor;
    OPVTIslandGradientMask.lineWidth = 2.4;
    OPVTIslandGradientGlowLayer.mask = OPVTIslandGradientMask;

    // Left status dot (with pulse). Slightly larger + rounded so a pulse feels
    // premium rather than a bug.
    OPVTIslandStatusDot = [[UIView alloc] initWithFrame:CGRectMake(14, 14, 14, 14)];
    OPVTIslandStatusDot.backgroundColor = OPVTIslandAccentColor(@"cyan");
    OPVTIslandStatusDot.layer.cornerRadius = 7.0;
    OPVTIslandStatusDot.layer.shadowColor = OPVTIslandAccentColor(@"cyan").CGColor;
    OPVTIslandStatusDot.layer.shadowRadius = 6.0;
    OPVTIslandStatusDot.layer.shadowOpacity = 0.9;
    OPVTIslandStatusDot.layer.shadowOffset = CGSizeZero;
    [OPVTIslandPill addSubview:OPVTIslandStatusDot];

    OPVTIslandTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(34, 6, 200, 16)];
    OPVTIslandTitleLabel.text = @"OpenPhone";
    OPVTIslandTitleLabel.textColor = [UIColor colorWithRed:0.957 green:0.969 blue:0.973 alpha:1.0];
    OPVTIslandTitleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    [OPVTIslandPill addSubview:OPVTIslandTitleLabel];

    OPVTIslandSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(34, 20, 200, 16)];
    OPVTIslandSubtitleLabel.text = @"Idle";
    OPVTIslandSubtitleLabel.textColor = [UIColor colorWithRed:0.682 green:0.722 blue:0.749 alpha:1.0];
    OPVTIslandSubtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    OPVTIslandSubtitleLabel.adjustsFontSizeToFitWidth = YES;
    OPVTIslandSubtitleLabel.minimumScaleFactor = 0.72;
    [OPVTIslandPill addSubview:OPVTIslandSubtitleLabel];

    // Small × cancel chip on the right, shown only during active states.
    OPVTIslandCancelChip = [UIButton buttonWithType:UIButtonTypeCustom];
    OPVTIslandCancelChip.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    [OPVTIslandCancelChip setTitle:@"×" forState:UIControlStateNormal];
    [OPVTIslandCancelChip setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    OPVTIslandCancelChip.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    OPVTIslandCancelChip.layer.cornerRadius = 11.0;
    OPVTIslandCancelChip.hidden = YES;
    // Target wired later in OPVTIslandAttachGestures once the bridge class
    // is fully defined; before that, referencing @selector via a forward
    // declaration is not allowed.
    [OPVTIslandPill addSubview:OPVTIslandCancelChip];

    [root addSubview:OPVTIslandPill];

    // Invisible drag catcher below the pill so pan gestures work reliably
    // even when the pill is only 37pt tall (Dynamic Island geometry).
    OPVTIslandDragCatcher = [[UIView alloc] initWithFrame:CGRectZero];
    OPVTIslandDragCatcher.backgroundColor = [UIColor clearColor];
    OPVTIslandDragCatcher.userInteractionEnabled = YES;
    [root addSubview:OPVTIslandDragCatcher];

    OPVTIslandAttachGestures();
    OPVTIslandStartTicker();
}

@interface OPVTIslandGestureBridge : NSObject
+ (instancetype)shared;
- (void)handleTap:(UITapGestureRecognizer *)tap;
- (void)handleHold:(UILongPressGestureRecognizer *)hold;
- (void)handlePan:(UIPanGestureRecognizer *)pan;
- (void)tick:(CADisplayLink *)link;
- (void)thinkingDotsTick:(NSTimer *)timer;
- (void)cancelChipTapped:(id)sender;
@end

@implementation OPVTIslandGestureBridge
+ (instancetype)shared {
    static OPVTIslandGestureBridge *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[OPVTIslandGestureBridge alloc] init];
    });
    return instance;
}
- (void)handleTap:(UITapGestureRecognizer *)tap {
    (void)tap;
    // Tap toggles expansion. Never hides the pill entirely — it's always
    // present so the user can tap into chat history at any time. Fresh
    // volume trigger is the only way to start a new voice turn.
    if (OPVTIslandExpanded && !OPVTIslandExpanded.hidden) {
        OPVTIslandCollapse();
    } else {
        OPVTIslandExpand();
    }
}
- (void)handleHold:(UILongPressGestureRecognizer *)hold {
    if (hold.state != UIGestureRecognizerStateBegan) {
        return;
    }
    OPVTLog(@"island long-press -> voice_cancel");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        OPVTAgentRequest(@{@"command": @"voice_cancel", @"reason": @"user_long_press"});
    });
}
- (void)cancelChipTapped:(id)sender {
    (void)sender;
    OPVTLog(@"island cancel chip tapped -> voice_cancel");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        OPVTAgentRequest(@{@"command": @"voice_cancel", @"reason": @"user_cancel_chip"});
    });
}
- (void)tabChat:(id)sender { (void)sender; OPVTIslandActiveTab = @"chat"; OPVTIslandApplyState(OPVTIslandCurrentState ?: @{}); }
- (void)tabRuns:(id)sender { (void)sender; OPVTIslandActiveTab = @"runs"; OPVTIslandApplyState(OPVTIslandCurrentState ?: @{}); }
- (void)tabWatchers:(id)sender { (void)sender; OPVTIslandActiveTab = @"watchers"; OPVTIslandApplyState(OPVTIslandCurrentState ?: @{}); }
- (void)approve:(id)sender {
    (void)sender;
    OPVTLog(@"island approve chip -> voice_confirm");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        OPVTAgentRequest(@{@"command": @"voice_confirm", @"source": @"island_chip"});
    });
}
- (void)deny:(id)sender {
    (void)sender;
    OPVTLog(@"island deny chip -> voice_deny");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        OPVTAgentRequest(@{@"command": @"voice_deny", @"source": @"island_chip"});
    });
}
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (!OPVTIslandPill) return;
    // Skip pan events that start inside the chat scroll view — those should
    // scroll history, not resize the pill.
    CGPoint location = [pan locationInView:OPVTIslandPill];
    if (OPVTIslandChatScroll && !OPVTIslandChatScroll.hidden &&
            OPVTIslandExpanded && !OPVTIslandExpanded.hidden) {
        CGRect scrollFrame = [OPVTIslandChatScroll.superview convertRect:OPVTIslandChatScroll.frame
                                                                  toView:OPVTIslandPill];
        if (CGRectContainsPoint(scrollFrame, location)) {
            pan.enabled = NO; pan.enabled = YES;
            return;
        }
    }
    CGPoint translation = [pan translationInView:OPVTIslandPill];
    if (pan.state == UIGestureRecognizerStateEnded ||
            pan.state == UIGestureRecognizerStateChanged) {
        // Down drag: escalate level (0 → 1 → 2). Up drag: de-escalate.
        if (translation.y > 24.0) {
            NSInteger next = MIN(2, OPVTIslandExpansionLevel + 1);
            if (next != OPVTIslandExpansionLevel) {
                OPVTIslandAnimateToLevel(next);
                [pan setTranslation:CGPointZero inView:OPVTIslandPill];
            }
        } else if (translation.y < -24.0) {
            NSInteger next = MAX(0, OPVTIslandExpansionLevel - 1);
            if (next != OPVTIslandExpansionLevel) {
                OPVTIslandAnimateToLevel(next);
                [pan setTranslation:CGPointZero inView:OPVTIslandPill];
            }
        }
    }
}
- (void)tick:(CADisplayLink *)link {
    (void)link;
    if (!OPVTIslandWindow || OPVTIslandWindow.hidden) {
        return;
    }
    // Only gradient shift runs at framerate. Everything else (pulse, dots)
    // is driven by CABasicAnimation / repeating timers so we don't fight
    // daemon-driven subtitle updates.
    OPVTIslandGradientShift += 0.006;
    if (OPVTIslandGradientShift > 1.0) OPVTIslandGradientShift -= 1.0;
    if (OPVTIslandGradientGlowLayer) {
        OPVTIslandGradientGlowLayer.startPoint =
                CGPointMake(-1.0 + OPVTIslandGradientShift, 0.5);
        OPVTIslandGradientGlowLayer.endPoint =
                CGPointMake(2.0 + OPVTIslandGradientShift, 0.5);
    }
}
- (void)thinkingDotsTick:(NSTimer *)timer {
    (void)timer;
    if (!OPVTIslandWindow || OPVTIslandWindow.hidden) return;
    if (![OPVTIslandCurrentMode isEqualToString:@"thinking"] &&
            ![OPVTIslandCurrentMode isEqualToString:@"transcribing"]) return;
    NSString *subtitleRaw = [OPVTIslandCurrentState[@"subtitle"]
            isKindOfClass:[NSString class]]
            ? OPVTIslandCurrentState[@"subtitle"] : @"";
    NSString *lower = subtitleRaw.lowercaseString ?: @"";
    BOOL generic = [lower isEqualToString:@"thinking"] ||
            [lower isEqualToString:@"transcribing"] || subtitleRaw.length == 0;
    if (!generic) return;
    OPVTIslandThinkingTick += 1;
    NSString *base = [OPVTIslandCurrentMode isEqualToString:@"thinking"]
            ? @"Thinking" : @"Transcribing";
    NSString *dots = @[@".", @"..", @"..."][OPVTIslandThinkingTick % 3];
    OPVTIslandSubtitleLabel.text = [base stringByAppendingString:dots];
}
@end

static void OPVTIslandAttachGestures(void) {
    if (!OPVTIslandPill) {
        return;
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:[OPVTIslandGestureBridge shared]
                    action:@selector(handleTap:)];
    tap.cancelsTouchesInView = YES;
    [OPVTIslandPill addGestureRecognizer:tap];

    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc]
            initWithTarget:[OPVTIslandGestureBridge shared]
                    action:@selector(handleHold:)];
    hold.minimumPressDuration = 0.55;
    [OPVTIslandPill addGestureRecognizer:hold];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:[OPVTIslandGestureBridge shared]
                    action:@selector(handlePan:)];
    [OPVTIslandPill addGestureRecognizer:pan];

    if (OPVTIslandCancelChip) {
        [OPVTIslandCancelChip addTarget:[OPVTIslandGestureBridge shared]
                                 action:@selector(cancelChipTapped:)
                       forControlEvents:UIControlEventTouchUpInside];
    }

    // Pan gesture on the invisible drag catcher too so downward drags off
    // the bottom edge of the tiny compact pill still expand.
    if (OPVTIslandDragCatcher) {
        UIPanGestureRecognizer *panCatch = [[UIPanGestureRecognizer alloc]
                initWithTarget:[OPVTIslandGestureBridge shared]
                        action:@selector(handlePan:)];
        [OPVTIslandDragCatcher addGestureRecognizer:panCatch];

        UITapGestureRecognizer *tapCatch = [[UITapGestureRecognizer alloc]
                initWithTarget:[OPVTIslandGestureBridge shared]
                        action:@selector(handleTap:)];
        [OPVTIslandDragCatcher addGestureRecognizer:tapCatch];
    }
}

static void OPVTIslandStartTicker(void) {
    if (OPVTIslandTicker) return;
    OPVTIslandTicker = [CADisplayLink
            displayLinkWithTarget:[OPVTIslandGestureBridge shared]
                         selector:@selector(tick:)];
    [OPVTIslandTicker addToRunLoop:[NSRunLoop mainRunLoop]
                           forMode:NSRunLoopCommonModes];
    // 3Hz timer for "thinking..." dots — no need to run at 60fps for text.
    [NSTimer scheduledTimerWithTimeInterval:0.42
                                     target:[OPVTIslandGestureBridge shared]
                                   selector:@selector(thinkingDotsTick:)
                                   userInfo:nil
                                    repeats:YES];
}

static void OPVTIslandLayoutInterior(void) {
    if (!OPVTIslandPill) return;
    CGRect b = OPVTIslandPill.bounds;
    BOOL compact = b.size.height < 55.0;
    BOOL activeMode = [OPVTIslandCurrentMode isEqualToString:@"listening"] ||
            [OPVTIslandCurrentMode isEqualToString:@"realtime"] ||
            [OPVTIslandCurrentMode isEqualToString:@"transcribing"] ||
            [OPVTIslandCurrentMode isEqualToString:@"thinking"] ||
            [OPVTIslandCurrentMode isEqualToString:@"action"];
    // Show cancel chip only while active. Never during idle/terminal.
    if (OPVTIslandCancelChip) OPVTIslandCancelChip.hidden = !activeMode;
    CGFloat rightReserve = activeMode ? 30.0 : 0.0;
    if (compact) {
        OPVTIslandStatusDot.frame = CGRectMake(11, (b.size.height - 10) / 2.0, 10, 10);
        OPVTIslandStatusDot.layer.cornerRadius = 5.0;
        OPVTIslandTitleLabel.hidden = YES;
        OPVTIslandSubtitleLabel.frame = CGRectMake(28, 0, b.size.width - 40 - rightReserve, b.size.height);
        OPVTIslandSubtitleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
        OPVTIslandSubtitleLabel.textAlignment = NSTextAlignmentLeft;
        if (OPVTIslandCancelChip) {
            OPVTIslandCancelChip.frame = CGRectMake(b.size.width - 30, (b.size.height - 22) / 2.0, 22, 22);
        }
    } else {
        OPVTIslandStatusDot.frame = CGRectMake(14, 14, 14, 14);
        OPVTIslandStatusDot.layer.cornerRadius = 7.0;
        OPVTIslandTitleLabel.hidden = NO;
        OPVTIslandTitleLabel.frame = CGRectMake(34, 6, b.size.width - 48 - rightReserve, 16);
        OPVTIslandSubtitleLabel.frame = CGRectMake(34, 20, b.size.width - 48 - rightReserve, 16);
        OPVTIslandSubtitleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
        OPVTIslandSubtitleLabel.textAlignment = NSTextAlignmentLeft;
        if (OPVTIslandCancelChip) {
            OPVTIslandCancelChip.frame = CGRectMake(b.size.width - 32, 10, 22, 22);
        }
    }
}

static void OPVTIslandUpdateGlowPath(void) {
    if (!OPVTIslandGlowLayer || !OPVTIslandPill) {
        return;
    }
    CGRect bounds = OPVTIslandPill.bounds;
    // Keep the rounded-pill feel: radius = 22 when expanded (matches iOS
    // system smart-stack corner), 18.5 when compact (matches hardware DI).
    CGFloat radius = bounds.size.height > 60 ? 22.0 : 18.5;
    OPVTIslandPill.layer.cornerRadius = radius;
    OPVTIslandLayoutInterior();
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bounds
                                                    cornerRadius:radius];
    OPVTIslandGlowLayer.path = path.CGPath;
    OPVTIslandGlowLayer.frame = bounds;
    if (OPVTIslandGradientGlowLayer) {
        OPVTIslandGradientGlowLayer.frame = bounds;
    }
    if (OPVTIslandGradientMask) {
        OPVTIslandGradientMask.path = path.CGPath;
        OPVTIslandGradientMask.frame = bounds;
    }
}

static void OPVTIslandLayoutBubbles(CGFloat availableWidth);
static void OPVTIslandRenderChat(CGFloat availableWidth);
static void OPVTIslandRenderStubTab(NSString *label, CGFloat availableWidth);

static UIButton *OPVTIslandMakeTabButton(NSString *title, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithRed:0.957 green:0.969 blue:0.973 alpha:1.0]
            forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
    b.backgroundColor = [UIColor clearColor];
    b.layer.cornerRadius = 10.0;
    [b addTarget:[OPVTIslandGestureBridge shared] action:action
        forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static void OPVTIslandEnsureExpandedViews(CGFloat availableWidth) {
    if (OPVTIslandExpanded) {
        // Recompute expanded frame so scroll view width tracks pill width.
        CGFloat expandedH = OPVTIslandPill ? OPVTIslandPill.bounds.size.height - 50 : 78;
        expandedH = MAX(expandedH, 40);
        OPVTIslandExpanded.frame = CGRectMake(14, 46, availableWidth, expandedH);
        if (OPVTIslandTabBar) OPVTIslandTabBar.frame = CGRectMake(0, 0, availableWidth, 22);
        if (OPVTIslandChatScroll) {
            OPVTIslandChatScroll.frame = CGRectMake(0, 26, availableWidth, expandedH - 26);
        }
        return;
    }
    OPVTIslandExpanded = [[UIView alloc] initWithFrame:CGRectMake(14, 46, availableWidth, 78)];
    OPVTIslandExpanded.backgroundColor = [UIColor clearColor];
    OPVTIslandExpanded.hidden = YES;

    // Tab bar at the top of the expanded panel.
    OPVTIslandTabBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, availableWidth, 22)];
    OPVTIslandTabBar.backgroundColor = [UIColor clearColor];
    [OPVTIslandExpanded addSubview:OPVTIslandTabBar];

    OPVTIslandTabChat = OPVTIslandMakeTabButton(@"Chat", @selector(tabChat:));
    OPVTIslandTabRuns = OPVTIslandMakeTabButton(@"Runs", @selector(tabRuns:));
    OPVTIslandTabWatchers = OPVTIslandMakeTabButton(@"Watchers", @selector(tabWatchers:));
    OPVTIslandTabChat.frame = CGRectMake(0, 0, 60, 22);
    OPVTIslandTabRuns.frame = CGRectMake(64, 0, 60, 22);
    OPVTIslandTabWatchers.frame = CGRectMake(128, 0, 80, 22);
    [OPVTIslandTabBar addSubview:OPVTIslandTabChat];
    [OPVTIslandTabBar addSubview:OPVTIslandTabRuns];
    [OPVTIslandTabBar addSubview:OPVTIslandTabWatchers];

    // Scrolling chat area below the tab bar.
    OPVTIslandChatScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 26, availableWidth, 52)];
    OPVTIslandChatScroll.backgroundColor = [UIColor clearColor];
    OPVTIslandChatScroll.showsVerticalScrollIndicator = YES;
    OPVTIslandChatScroll.alwaysBounceVertical = YES;
    OPVTIslandChatScroll.clipsToBounds = YES;
    [OPVTIslandExpanded addSubview:OPVTIslandChatScroll];

    OPVTIslandChatStack = [[UIView alloc] initWithFrame:CGRectMake(0, 0, availableWidth, 0)];
    OPVTIslandChatStack.backgroundColor = [UIColor clearColor];
    [OPVTIslandChatScroll addSubview:OPVTIslandChatStack];

    // Kept as legacy placeholder views so lingering references in ApplyState
    // don't crash. They stay hidden — the scroll stack renders everything.
    OPVTIslandUserBubble = [[UIView alloc] init]; OPVTIslandUserBubble.hidden = YES;
    OPVTIslandUserBubbleLabel = [[UILabel alloc] init]; OPVTIslandUserBubbleLabel.hidden = YES;
    OPVTIslandAssistantBubble = [[UIView alloc] init]; OPVTIslandAssistantBubble.hidden = YES;
    OPVTIslandAssistantBubbleLabel = [[UILabel alloc] init]; OPVTIslandAssistantBubbleLabel.hidden = YES;

    // Approve / Deny chips for needs_review mode.
    OPVTIslandApproveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    OPVTIslandApproveBtn.backgroundColor = [UIColor colorWithRed:0.125 green:0.89 blue:0.416 alpha:1.0];
    OPVTIslandApproveBtn.tintColor = [UIColor colorWithRed:0.063 green:0.078 blue:0.094 alpha:1.0];
    [OPVTIslandApproveBtn setTitle:@"✓ Approve" forState:UIControlStateNormal];
    [OPVTIslandApproveBtn setTitleColor:[UIColor colorWithRed:0.063 green:0.078 blue:0.094 alpha:1.0]
                              forState:UIControlStateNormal];
    OPVTIslandApproveBtn.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    OPVTIslandApproveBtn.layer.cornerRadius = 12.0;
    OPVTIslandApproveBtn.hidden = YES;
    [OPVTIslandApproveBtn addTarget:[OPVTIslandGestureBridge shared]
                             action:@selector(approve:)
                   forControlEvents:UIControlEventTouchUpInside];
    [OPVTIslandExpanded addSubview:OPVTIslandApproveBtn];

    OPVTIslandDenyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    OPVTIslandDenyBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.2];
    [OPVTIslandDenyBtn setTitle:@"× Deny" forState:UIControlStateNormal];
    [OPVTIslandDenyBtn setTitleColor:[UIColor colorWithRed:0.957 green:0.969 blue:0.973 alpha:1.0]
                           forState:UIControlStateNormal];
    OPVTIslandDenyBtn.titleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    OPVTIslandDenyBtn.layer.cornerRadius = 12.0;
    OPVTIslandDenyBtn.hidden = YES;
    [OPVTIslandDenyBtn addTarget:[OPVTIslandGestureBridge shared]
                          action:@selector(deny:)
                forControlEvents:UIControlEventTouchUpInside];
    [OPVTIslandExpanded addSubview:OPVTIslandDenyBtn];

    // Keep the old plain labels as invisible fallbacks so existing references
    // in ApplyState don't crash. They stay hidden.
    OPVTIslandExpandedLine1 = [[UILabel alloc] init];
    OPVTIslandExpandedLine1.hidden = YES;
    [OPVTIslandExpanded addSubview:OPVTIslandExpandedLine1];
    OPVTIslandExpandedLine2 = [[UILabel alloc] init];
    OPVTIslandExpandedLine2.hidden = YES;
    [OPVTIslandExpanded addSubview:OPVTIslandExpandedLine2];

    [OPVTIslandPill addSubview:OPVTIslandExpanded];
    OPVTIslandLayoutBubbles(availableWidth);
}

static void OPVTIslandLayoutBubbles(CGFloat availableWidth) { (void)availableWidth; /* legacy no-op */ }

// Render Chat tab: rebuild scroll stack from chat-history.json plus the
// current in-flight turn (from island-status transcript/reply).
static void OPVTIslandRenderChat(CGFloat availableWidth) {
    if (!OPVTIslandChatStack || !OPVTIslandChatScroll) return;
    for (UIView *v in [OPVTIslandChatStack.subviews copy]) {
        [v removeFromSuperview];
    }
    CGFloat maxBubbleWidth = MIN(availableWidth - 40.0, availableWidth * 0.72);
    UIFont *font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    UIColor *userBg = [UIColor colorWithRed:0.122 green:0.368 blue:1.0 alpha:1.0];
    UIColor *assistantBg = [UIColor colorWithRed:0.125 green:0.153 blue:0.176 alpha:1.0];
    UIColor *lightText = [UIColor colorWithRed:0.957 green:0.969 blue:0.973 alpha:1.0];
    CGFloat y = 0;

    // Merge chat history with current in-flight turn.
    NSMutableArray *turns = [NSMutableArray arrayWithArray:OPVTIslandChatTurns ?: @[]];
    NSString *liveTranscript = [OPVTIslandCurrentState[@"transcript"] isKindOfClass:[NSString class]]
            ? OPVTIslandCurrentState[@"transcript"] : @"";
    NSString *liveReply = [OPVTIslandCurrentState[@"reply"] isKindOfClass:[NSString class]]
            ? OPVTIslandCurrentState[@"reply"] : @"";
    NSString *liveTaskId = [OPVTIslandCurrentState[@"task_id"] isKindOfClass:[NSString class]]
            ? OPVTIslandCurrentState[@"task_id"] : @"";
    if (liveTranscript.length > 0) {
        BOOL alreadyInHistory = NO;
        for (NSDictionary *t in turns.reverseObjectEnumerator) {
            if ([t[@"role"] isEqualToString:@"user"] &&
                    [t[@"text"] isEqualToString:liveTranscript]) {
                alreadyInHistory = YES; break;
            }
        }
        if (!alreadyInHistory) {
            [turns addObject:@{@"role": @"user", @"text": liveTranscript, @"task_id": liveTaskId ?: @""}];
        }
    }
    if (liveReply.length > 0) {
        BOOL alreadyInHistory = NO;
        for (NSDictionary *t in turns.reverseObjectEnumerator) {
            if ([t[@"role"] isEqualToString:@"assistant"] &&
                    [t[@"text"] isEqualToString:liveReply]) {
                alreadyInHistory = YES; break;
            }
        }
        if (!alreadyInHistory) {
            [turns addObject:@{@"role": @"assistant", @"text": liveReply}];
        }
    }

    for (NSDictionary *turn in turns) {
        if (![turn isKindOfClass:[NSDictionary class]]) continue;
        NSString *role = [turn[@"role"] isKindOfClass:[NSString class]] ? turn[@"role"] : @"user";
        NSString *text = [turn[@"text"] isKindOfClass:[NSString class]] ? turn[@"text"] : @"";
        if (text.length == 0) continue;
        BOOL isUser = [role isEqualToString:@"user"];
        CGSize sz = [text boundingRectWithSize:CGSizeMake(maxBubbleWidth - 20.0, 400.0)
                                       options:NSStringDrawingUsesLineFragmentOrigin
                                    attributes:@{NSFontAttributeName: font}
                                       context:nil].size;
        CGFloat w = ceil(sz.width) + 20.0;
        CGFloat h = MAX(28.0, ceil(sz.height) + 12.0);
        UIView *bubble = [[UIView alloc] initWithFrame:CGRectMake(
                isUser ? (availableWidth - w) : 0, y, w, h)];
        bubble.backgroundColor = isUser ? userBg : assistantBg;
        bubble.layer.cornerRadius = 12.0;
        bubble.layer.masksToBounds = YES;
        if (!isUser) {
            bubble.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
            bubble.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
        }
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 6, w - 20, h - 12)];
        label.font = font;
        label.textColor = isUser ? [UIColor whiteColor] : lightText;
        label.numberOfLines = 0;
        label.text = text;
        [bubble addSubview:label];
        [OPVTIslandChatStack addSubview:bubble];
        y += h + 6;
    }
    OPVTIslandChatStack.frame = CGRectMake(0, 0, availableWidth, MAX(y, 0));
    OPVTIslandChatScroll.contentSize = CGSizeMake(availableWidth, y);
    // Scroll to bottom to show newest turn.
    if (y > OPVTIslandChatScroll.bounds.size.height) {
        CGPoint bottom = CGPointMake(0, y - OPVTIslandChatScroll.bounds.size.height);
        [OPVTIslandChatScroll setContentOffset:bottom animated:YES];
    }
}

static void OPVTIslandRenderStubTab(NSString *label, CGFloat availableWidth) {
    if (!OPVTIslandChatStack || !OPVTIslandChatScroll) return;
    for (UIView *v in [OPVTIslandChatStack.subviews copy]) {
        [v removeFromSuperview];
    }
    UILabel *msg = [[UILabel alloc] initWithFrame:CGRectMake(0, 8, availableWidth, 24)];
    msg.text = label;
    msg.textAlignment = NSTextAlignmentCenter;
    msg.textColor = [UIColor colorWithRed:0.682 green:0.722 blue:0.749 alpha:1.0];
    msg.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    [OPVTIslandChatStack addSubview:msg];
    OPVTIslandChatStack.frame = CGRectMake(0, 0, availableWidth, 32);
    OPVTIslandChatScroll.contentSize = CGSizeMake(availableWidth, 32);
    [OPVTIslandChatScroll setContentOffset:CGPointZero animated:NO];
}

static void OPVTIslandRepositionDragCatcher(CGRect pillFrame, NSInteger level) {
    if (!OPVTIslandDragCatcher) return;
    // On compact, place a 60pt tall transparent catcher below the pill so
    // the user can start a downward drag well past the tiny pill's edge.
    // On expanded levels the pill has plenty of vertical area itself so we
    // still keep a small catcher below for symmetry.
    CGFloat catcherHeight = level == 0 ? 60.0 : 20.0;
    CGFloat catcherWidth = MAX(pillFrame.size.width + 40.0, 200.0);
    CGFloat catcherX = pillFrame.origin.x + (pillFrame.size.width - catcherWidth) / 2.0;
    CGFloat catcherY = pillFrame.origin.y + pillFrame.size.height;
    OPVTIslandDragCatcher.frame = CGRectMake(catcherX, catcherY, catcherWidth, catcherHeight);
}

static void OPVTIslandAnimateToLevel(NSInteger level) {
    if (!OPVTIslandWindow || !OPVTIslandPill) return;
    NSInteger clamped = MAX(0, MIN(2, level));
    NSInteger prev = OPVTIslandExpansionLevel;
    OPVTIslandExpansionLevel = clamped;
    CGRect bounds = OPVTIslandWindow.bounds;
    CGRect target = OPVTIslandPillFrameForLevel(bounds, clamped);
    BOOL wasCollapsed = prev == 0;
    BOOL nowCollapsed = clamped == 0;

    if (nowCollapsed) {
        [UIView animateWithDuration:0.16 delay:0
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            if (OPVTIslandExpanded) OPVTIslandExpanded.alpha = 0.0;
        } completion:^(BOOL f) {
            (void)f;
            if (OPVTIslandExpanded) OPVTIslandExpanded.hidden = YES;
            [UIView animateWithDuration:0.34 delay:0
                 usingSpringWithDamping:0.80
                  initialSpringVelocity:0.4
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:^{
                OPVTIslandPill.frame = target;
                OPVTIslandUpdateGlowPath();
            } completion:nil];
        }];
        return;
    }
    OPVTIslandEnsureExpandedViews(target.size.width - 28);
    if (wasCollapsed) {
        OPVTIslandExpanded.alpha = 0.0;
        OPVTIslandExpanded.hidden = NO;
    }
    [UIView animateWithDuration:0.42 delay:0
         usingSpringWithDamping:0.75
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        OPVTIslandPill.frame = target;
        OPVTIslandUpdateGlowPath();
        OPVTIslandRepositionDragCatcher(target, clamped);
    } completion:nil];
    [UIView animateWithDuration:0.24 delay:wasCollapsed ? 0.18 : 0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        OPVTIslandExpanded.alpha = 1.0;
    } completion:nil];
    // Re-render expanded contents with the new width.
    OPVTIslandApplyState(OPVTIslandCurrentState ?: @{});
}

static void OPVTIslandExpand(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger next = OPVTIslandExpansionLevel == 0 ? 1
                : (OPVTIslandExpansionLevel == 1 ? 2 : 2);
        OPVTIslandAnimateToLevel(next);
    });
}

static void OPVTIslandCollapse(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger next = OPVTIslandExpansionLevel > 1 ? 1 : 0;
        OPVTIslandAnimateToLevel(next);
    });
}

static void OPVTIslandApplyState(NSDictionary *state) {
    if (![state isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSString *mode = [state[@"mode"] isKindOfClass:[NSString class]]
            ? state[@"mode"] : @"idle";
    NSString *subtitle = [state[@"subtitle"] isKindOfClass:[NSString class]]
            ? state[@"subtitle"] : @"";
    NSString *transcript = [state[@"transcript"] isKindOfClass:[NSString class]]
            ? state[@"transcript"] : @"";
    NSString *tool = [state[@"tool"] isKindOfClass:[NSString class]]
            ? state[@"tool"] : @"";
    NSString *goal = [state[@"goal"] isKindOfClass:[NSString class]]
            ? state[@"goal"] : @"";
    NSString *accent = [state[@"accent"] isKindOfClass:[NSString class]]
            ? state[@"accent"] : @"cyan";

    long long step = [state[@"step"] isKindOfClass:[NSNumber class]]
            ? [state[@"step"] longLongValue] : 0;
    long long maxSteps = [state[@"max_steps"] isKindOfClass:[NSNumber class]]
            ? [state[@"max_steps"] longLongValue] : 0;
    // reply is rendered by OPVTIslandRenderChat via OPVTIslandCurrentState.
    (void)state;

    dispatch_async(dispatch_get_main_queue(), ^{
        OPVTIslandEnsureWindow();
        if (!OPVTIslandWindow) {
            return;
        }
        // Persistent overlay: always visible so user can tap into chat history.
        // Idle/hidden modes just get low opacity — never fully hidden.
        OPVTIslandWindow.hidden = NO;
        BOOL isIdle = ![mode isKindOfClass:[NSString class]] ||
                mode.length == 0 ||
                [mode isEqualToString:@"hidden"] ||
                [mode isEqualToString:@"idle"];
        OPVTIslandPill.alpha = isIdle ? 0.55 : 1.0;
        // Fire haptic on state transitions to terminal (Android-parity feel).
        BOOL modeChanged = ![OPVTIslandCurrentMode isEqualToString:mode];
        if (modeChanged && [mode isEqualToString:@"success"]) {
            OPVTPlayHapticSuccess();
        } else if (modeChanged && [mode isEqualToString:@"error"]) {
            OPVTPlayHapticFailure();
        } else if (modeChanged && [mode isEqualToString:@"needs_review"]) {
            OPVTPlayHapticFailure();  // Attention-grabbing double-tap.
        }
        // Toggle the CAAnimation-based dot pulse when entering/leaving
        // listening. Way smoother than frame-by-frame transform math.
        if (modeChanged && OPVTIslandStatusDot) {
            [OPVTIslandStatusDot.layer removeAnimationForKey:@"pulse"];
            if ([mode isEqualToString:@"listening"]) {
                CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
                pulse.fromValue = @(1.0);
                pulse.toValue = @(1.35);
                pulse.duration = 0.6;
                pulse.autoreverses = YES;
                pulse.repeatCount = HUGE_VALF;
                pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                [OPVTIslandStatusDot.layer addAnimation:pulse forKey:@"pulse"];
            }
        }
        OPVTIslandCurrentMode = mode ?: @"idle";
        UIColor *accentColor = OPVTIslandAccentColor(accent);
        OPVTIslandStatusDot.backgroundColor = accentColor;
        OPVTIslandGlowLayer.strokeColor = accentColor.CGColor;
        OPVTIslandGlowLayer.shadowColor = accentColor.CGColor;

        NSString *title = @"OpenPhone";
        if ([mode isEqualToString:@"listening"]) title = @"Listening";
        else if ([mode isEqualToString:@"realtime"]) title = @"Listening";
        else if ([mode isEqualToString:@"transcribing"]) title = @"Transcribing";
        else if ([mode isEqualToString:@"thinking"]) title = @"Thinking";
        else if ([mode isEqualToString:@"action"]) title = @"Acting";
        else if ([mode isEqualToString:@"success"]) title = @"Done";
        else if ([mode isEqualToString:@"error"]) title = @"Error";

        // Show step counter next to title once we're past capture.
        if (step > 0) {
            title = [NSString stringWithFormat:@"%@ · %lld/%lld",
                    title, step, maxSteps > 0 ? maxSteps : (long long)25];
        }
        OPVTIslandTitleLabel.text = title;
        OPVTIslandSubtitleLabel.text = subtitle.length > 0 ? subtitle : @"";

        // Auto-expand when we have any meaningful content to show. The pill
        // stays expanded across states until it collapses on terminal.
        NSString *primaryText = goal.length > 0 ? goal : transcript;
        BOOL hasContent = primaryText.length > 0 ||
                tool.length > 0 ||
                [mode isEqualToString:@"success"] ||
                [mode isEqualToString:@"error"] ||
                [mode isEqualToString:@"needs_review"];
        BOOL isTerminal = [mode isEqualToString:@"success"] ||
                [mode isEqualToString:@"error"];
        BOOL shouldExpand = hasContent && !isTerminal;
        if (shouldExpand) {
            OPVTIslandPill.frame = OPVTIslandPillFrame(OPVTIslandWindow.bounds, YES);
            OPVTIslandEnsureExpandedViews(OPVTIslandPill.bounds.size.width - 28);
            OPVTIslandExpanded.hidden = NO;
        } else if (isTerminal && primaryText.length > 0) {
            // Keep expanded on terminal so user can read summary.
            OPVTIslandPill.frame = OPVTIslandPillFrame(OPVTIslandWindow.bounds, YES);
            OPVTIslandEnsureExpandedViews(OPVTIslandPill.bounds.size.width - 28);
            OPVTIslandExpanded.hidden = NO;
        } else {
            OPVTIslandPill.frame = OPVTIslandPillFrame(OPVTIslandWindow.bounds, NO);
            if (OPVTIslandExpanded) {
                OPVTIslandExpanded.hidden = YES;
            }
        }
        OPVTIslandUpdateGlowPath();

        if (OPVTIslandExpanded && !OPVTIslandExpanded.hidden) {
            CGFloat availW = OPVTIslandPill.bounds.size.width - 28;
            // Highlight active tab.
            UIColor *activeBg = [UIColor colorWithWhite:1.0 alpha:0.18];
            OPVTIslandTabChat.backgroundColor = [OPVTIslandActiveTab isEqualToString:@"chat"] ? activeBg : [UIColor clearColor];
            OPVTIslandTabRuns.backgroundColor = [OPVTIslandActiveTab isEqualToString:@"runs"] ? activeBg : [UIColor clearColor];
            OPVTIslandTabWatchers.backgroundColor = [OPVTIslandActiveTab isEqualToString:@"watchers"] ? activeBg : [UIColor clearColor];
            if ([OPVTIslandActiveTab isEqualToString:@"chat"]) {
                OPVTIslandRenderChat(availW);
            } else if ([OPVTIslandActiveTab isEqualToString:@"runs"]) {
                OPVTIslandRenderStubTab(@"Runs — no active tasks", availW);
            } else {
                OPVTIslandRenderStubTab(@"Watchers — no active watchers", availW);
            }

            BOOL showChips = [mode isEqualToString:@"needs_review"];
            if (OPVTIslandApproveBtn && OPVTIslandDenyBtn) {
                OPVTIslandApproveBtn.hidden = !showChips;
                OPVTIslandDenyBtn.hidden = !showChips;
                if (showChips) {
                    CGFloat w = OPVTIslandExpanded.bounds.size.width;
                    CGFloat y = OPVTIslandExpanded.bounds.size.height - 34;
                    OPVTIslandApproveBtn.frame = CGRectMake(w - 108, y, 100, 30);
                    OPVTIslandDenyBtn.frame = CGRectMake(w - 216, y, 100, 30);
                    if (!OPVTIslandApproveBtn.superview) {
                        [OPVTIslandExpanded addSubview:OPVTIslandApproveBtn];
                        [OPVTIslandExpanded addSubview:OPVTIslandDenyBtn];
                    }
                }
            }
        }

        [OPVTIslandWindow.rootViewController.view setNeedsLayout];
        OPVTIslandRepositionDragCatcher(OPVTIslandPill.frame, OPVTIslandExpansionLevel);
        // Terminal states: keep the pill visible with the assistant message
        // as the subtitle so the user can actually read the answer. Shrink
        // the expanded panel back to compact after a short beat so it's
        // out of the way, but never hide entirely. Tap or a fresh trigger
        // is the only dismissal.
        if (isTerminal) {
            NSString *terminalMode = [mode copy];
            unsigned long long snapshotSeq = OPVTIslandLastSequence;
            double delay = [mode isEqualToString:@"success"] ? 2.2 : 4.0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                if ([OPVTIslandCurrentMode isEqualToString:terminalMode] &&
                        OPVTIslandExpansionLevel > 0) {
                    OPVTIslandAnimateToLevel(0);
                }
            });
            // After 20s, fade the answer to idle so the persistent pill sits
            // at low opacity — Android auto-collapses at 7s but iOS is more
            // conservative because there's no gesture-away like Android has.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                if ([OPVTIslandCurrentMode isEqualToString:terminalMode] &&
                        OPVTIslandLastSequence == snapshotSeq) {
                    OPVTIslandApplyState(@{
                        @"mode": @"idle",
                        @"subtitle": @"OpenPhone",
                        @"accent": @"cyan"
                    });
                }
            });
        }
    });
}

static void OPVTIslandRefreshFromDisk(void) {
    NSData *data = [NSData dataWithContentsOfFile:OPVTIslandStatusPath];
    if (data.length == 0) {
        return;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return;
    }
    NSDictionary *state = object;
    unsigned long long sequence = [state[@"sequence"] isKindOfClass:[NSNumber class]]
            ? [state[@"sequence"] unsignedLongLongValue] : 0;
    if (sequence != 0 && sequence == OPVTIslandLastSequence) {
        return;
    }
    OPVTIslandLastSequence = sequence;
    OPVTIslandCurrentState = state;
    OPVTIslandLastAppliedMs = (long long)(CFAbsoluteTimeGetCurrent() * 1000.0);
    OPVTIslandApplyState(state);
}

static void OPVTIslandNotificationCallback(int token) {
    (void)token;
    OPVTIslandRefreshFromDisk();
}

static void OPVTIslandLoadChatHistory(void) {
    NSData *data = [NSData dataWithContentsOfFile:@"/var/mobile/Library/OpenPhone/springboard/chat-history.json"];
    if (!data) { OPVTIslandChatTurns = @[]; return; }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) { OPVTIslandChatTurns = @[]; return; }
    NSArray *turns = obj[@"turns"];
    OPVTIslandChatTurns = [turns isKindOfClass:[NSArray class]] ? turns : @[];
}

// Daemon posts these notifications around every screen capture so our
// island overlay does not appear in the screenshot — otherwise the model
// sees its own pill covering the app UI and loops "trying" to finish.
static void OPVTStartIslandCaptureObserver(void) {
    if (OPVTIslandCaptureObserverInstalled) return;
    uint32_t rc1 = notify_register_dispatch("com.openphone.island.hide-for-capture",
            &OPVTIslandHideNotifyToken, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        if (OPVTIslandPill) OPVTIslandPill.hidden = YES;
        if (OPVTIslandDragCatcher) OPVTIslandDragCatcher.hidden = YES;
    });
    uint32_t rc2 = notify_register_dispatch("com.openphone.island.show-after-capture",
            &OPVTIslandShowNotifyToken, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        if (OPVTIslandPill) OPVTIslandPill.hidden = NO;
        if (OPVTIslandDragCatcher) OPVTIslandDragCatcher.hidden = NO;
    });
    if (rc1 == NOTIFY_STATUS_OK && rc2 == NOTIFY_STATUS_OK) {
        OPVTIslandCaptureObserverInstalled = YES;
    }
}

static void OPVTStartIslandChatObserver(void) {
    if (OPVTIslandChatObserverInstalled) return;
    uint32_t rc = notify_register_dispatch("com.openphone.island.chat",
            &OPVTIslandChatNotifyToken, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        OPVTIslandLoadChatHistory();
        if (OPVTIslandExpanded && !OPVTIslandExpanded.hidden &&
                [OPVTIslandActiveTab isEqualToString:@"chat"]) {
            OPVTIslandApplyState(OPVTIslandCurrentState ?: @{});
        }
    });
    if (rc == NOTIFY_STATUS_OK) OPVTIslandChatObserverInstalled = YES;
    OPVTIslandLoadChatHistory();
}

static void OPVTStartIslandStatusObserver(void) {
    if (OPVTIslandStatusNotifyRegistered) {
        return;
    }
    uint32_t rc = notify_register_dispatch(OPVTIslandNotification,
            &OPVTIslandStatusNotifyToken, dispatch_get_main_queue(), ^(int token) {
        OPVTIslandNotificationCallback(token);
    });
    if (rc == NOTIFY_STATUS_OK) {
        OPVTIslandStatusNotifyRegistered = YES;
        OPVTLog(@"island status notification observer installed");
    } else {
        OPVTLog(@"island status notification observer failed rc=%u", rc);
    }
    // Initial paint from any existing snapshot. If none, still paint an idle
    // pill so the persistent overlay is visible from boot.
    dispatch_async(dispatch_get_main_queue(), ^{
        OPVTIslandRefreshFromDisk();
        if (!OPVTIslandCurrentState || OPVTIslandCurrentState.count == 0) {
            OPVTIslandApplyState(@{
                @"mode": @"idle",
                @"subtitle": @"OpenPhone",
                @"accent": @"cyan",
                @"sequence": @(0)
            });
        }
    });
}

%ctor {
    BOOL enabled = OPVTEnabled();
    OPVTLog(@"loaded local daemon socket=%s enabled=%d prompt_for_goal=%d",
            OPVTSocketPath, enabled, OPVTPromptForGoalEnabled());
    OPVTPublishTriggerStatus(@"loaded", @{@"enabled": @(enabled)});
    if (!enabled) {
        OPVTLog(@"disabled by preference; skipping SpringBoard hooks");
        return;
    }
    OPVTPublishSpringBoardStateOnMain();
    OPVTStartIslandStatusObserver();
    OPVTStartIslandChatObserver();
    OPVTStartIslandCaptureObserver();
    OPVTInstallVolumeNotificationObserver();
    OPVTTryRuntimeHooks(@"ctor");
    if (OPVTBoolPreference(@"RuntimeSnapshotEnabled", NO)) {
        OPVTLogVolumeRuntimeSnapshot(@"ctor");
    }
    pthread_t thread;
    int rc = pthread_create(&thread, NULL, OPVTDelayedHookThread, NULL);
    if (rc == 0) {
        pthread_detach(thread);
    } else {
        OPVTLog(@"delayed hook thread failed rc=%d", rc);
    }
    pthread_t stateThread;
    rc = pthread_create(&stateThread, NULL, OPVTSpringBoardStateThread, NULL);
    if (rc == 0) {
        pthread_detach(stateThread);
    } else {
        OPVTLog(@"springboard state thread failed rc=%d", rc);
    }
    pthread_t screenshotThread;
    rc = pthread_create(&screenshotThread, NULL, OPVTScreenshotRequestThread, NULL);
    if (rc == 0) {
        pthread_detach(screenshotThread);
    } else {
        OPVTLog(@"screenshot request thread failed rc=%d", rc);
    }
    pthread_t inputThread;
    rc = pthread_create(&inputThread, NULL, OPVTInputRequestThread, NULL);
    if (rc == 0) {
        pthread_detach(inputThread);
    } else {
        OPVTLog(@"input request thread failed rc=%d", rc);
    }
    pthread_t clipboardThread;
    rc = pthread_create(&clipboardThread, NULL, OPVTClipboardRequestThread, NULL);
    if (rc == 0) {
        pthread_detach(clipboardThread);
    } else {
        OPVTLog(@"clipboard request thread failed rc=%d", rc);
    }
    pthread_t promptThread;
    rc = pthread_create(&promptThread, NULL, OPVTPromptRequestThread, NULL);
    if (rc == 0) {
        pthread_detach(promptThread);
    } else {
        OPVTLog(@"prompt request thread failed rc=%d", rc);
    }
}
