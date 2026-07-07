#import <Foundation/Foundation.h>
#import <Preferences/Preferences.h>
#import <UIKit/UIKit.h>

#import <errno.h>
#import <signal.h>
#import <stdint.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

static NSString *const OPAgentPrefsSocketPath = @"/var/mobile/Library/OpenPhone/run/agentd.sock";

static BOOL OPAgentPrefsWriteAll(int fd, NSData *data) {
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
        return NO;
    }
    return YES;
}

static NSString *OPAgentPrefsString(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value stringValue];
    }
    return @"";
}

static NSString *OPAgentPrefsBoolString(id value) {
    if (![value respondsToSelector:@selector(boolValue)]) {
        return @"unknown";
    }
    return [value boolValue] ? @"on" : @"off";
}

static NSNumber *OPAgentPrefsBoolNumber(id value, BOOL fallback) {
    if ([value respondsToSelector:@selector(boolValue)]) {
        return @([value boolValue]);
    }
    return @(fallback);
}

static id OPAgentPrefsNestedValue(NSDictionary *dictionary, NSArray<NSString *> *keys) {
    id current = dictionary;
    for (NSString *key in keys) {
        if (![current isKindOfClass:[NSDictionary class]]) {
            return nil;
        }
        current = [(NSDictionary *)current objectForKey:key];
        if (!current || current == (id)kCFNull) {
            return nil;
        }
    }
    return current;
}

static NSDictionary *OPAgentPrefsSendRequest(NSDictionary *request, NSError **errorOut) {
    NSData *requestData = [NSJSONSerialization dataWithJSONObject:request ?: @{}
            options:0 error:errorOut];
    if (requestData.length == 0) {
        return nil;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        return nil;
    }

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, OPAgentPrefsSocketPath.UTF8String, sizeof(address.sun_path));

    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"connect %@ failed: %s",
                    OPAgentPrefsSocketPath, strerror(errno)]
            }];
        }
        close(fd);
        return nil;
    }

    NSMutableData *lineData = [requestData mutableCopy];
    const char newline = '\n';
    [lineData appendBytes:&newline length:1];
    if (!OPAgentPrefsWriteAll(fd, lineData)) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        close(fd);
        return nil;
    }
    shutdown(fd, SHUT_WR);

    NSMutableData *responseData = [NSMutableData data];
    char buffer[4096];
    while (true) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count > 0) {
            [responseData appendBytes:buffer length:(NSUInteger)count];
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        break;
    }
    close(fd);

    if (responseData.length == 0) {
        if (errorOut) {
            *errorOut = [NSError errorWithDomain:@"OpenPhoneAgentPrefs" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"empty agentd response"
            }];
        }
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:errorOut];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

@interface OpenPhoneAgentPrefsRootListController : PSListController
@property (nonatomic, retain) NSDictionary *latestStatus;
@property (nonatomic, copy) NSString *lastError;
@end

@implementation OpenPhoneAgentPrefsRootListController

- (instancetype)init {
    self = [super init];
    if (self) {
        signal(SIGPIPE, SIG_IGN);
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"OpenPhone Agent";
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        [self reloadAgentStatus];
        _specifiers = [[self buildSpecifiers] mutableCopy];
    }
    return _specifiers;
}

- (void)reloadAgentStatus {
    NSError *error = nil;
    NSDictionary *status = OPAgentPrefsSendRequest(@{@"command": @"agent_status", @"limit": @5}, &error);
    if ([status isKindOfClass:[NSDictionary class]] && [status[@"status"] isEqualToString:@"ok"]) {
        self.latestStatus = status;
        self.lastError = @"";
        return;
    }
    self.latestStatus = status ?: @{};
    self.lastError = error.localizedDescription ?: OPAgentPrefsString(status[@"reason"]);
    if (self.lastError.length == 0) {
        self.lastError = @"agent_status failed";
    }
}

- (NSMutableArray *)buildSpecifiers {
    NSMutableArray *items = [NSMutableArray array];

    PSSpecifier *runtimeGroup = [PSSpecifier groupSpecifierWithName:@"Runtime"];
    [runtimeGroup setProperty:@"Phone-local daemon status. This pane talks to openphone-agentd over the on-device Unix socket." forKey:PSFooterTextGroupKey];
    [items addObject:runtimeGroup];

    [items addObject:[self valueSpecifierNamed:@"Status" value:[self statusSummary]]];
    [items addObject:[self valueSpecifierNamed:@"State" value:OPAgentPrefsString(self.latestStatus[@"state"])]];
    [items addObject:[self valueSpecifierNamed:@"Policy" value:[self policySummary]]];
    [items addObject:[self valueSpecifierNamed:@"Model" value:[self modelSummary]]];

    PSSpecifier *policyGroup = [PSSpecifier groupSpecifierWithName:@"Agent Policy"];
    [policyGroup setProperty:@"These controls update openphone-agentd policy on the phone. They do not edit Mac-side config." forKey:PSFooterTextGroupKey];
    [items addObject:policyGroup];
    [items addObject:[self switchSpecifierNamed:@"Hardware Triggers" key:@"hardware_triggers_enabled"]];
    [items addObject:[self switchSpecifierNamed:@"YOLO Execution" key:@"yolo_enabled"]];
    [items addObject:[self autonomyModeSpecifier]];

    PSSpecifier *modelGroup = [PSSpecifier groupSpecifierWithName:@"Model"];
    [modelGroup setProperty:@"Model provider and capture tuning. Provider credentials are external and never shown here." forKey:PSFooterTextGroupKey];
    [items addObject:modelGroup];
    [items addObject:[self modelProviderSpecifier]];
    [items addObject:[self valueSpecifierNamed:@"Model" value:[self nestedString:@[@"model", @"model"] fallback:@"unset"]]];
    [items addObject:[self valueSpecifierNamed:@"Screenshot Max Edge" value:[self screenshotDimensionSummary]]];

    PSSpecifier *triggerGroup = [PSSpecifier groupSpecifierWithName:@"Volume Trigger"];
    [items addObject:triggerGroup];
    [items addObject:[self valueSpecifierNamed:@"SpringBoard Hook" value:[self triggerSummary]]];
    [items addObject:[self valueSpecifierNamed:@"Button Events" value:[self triggerCounterSummary]]];
    [items addObject:[self valueSpecifierNamed:@"Last Route" value:[self nestedString:@[@"triggers", @"volume_combo", @"springboard_fallback", @"last_trigger_route"] fallback:@"none"]]];

    PSSpecifier *taskGroup = [PSSpecifier groupSpecifierWithName:@"Latest Task"];
    [items addObject:taskGroup];
    [items addObject:[self valueSpecifierNamed:@"Task" value:[self latestTaskSummary]]];
    [items addObject:[self valueSpecifierNamed:@"Current Task" value:[self currentTaskSummary]]];
    [items addObject:[self valueSpecifierNamed:@"Stop Reason" value:[self nestedString:@[@"latest_task", @"stop_reason"] fallback:@"none"]]];

    PSSpecifier *controlGroup = [PSSpecifier groupSpecifierWithName:@"Controls"];
    [items addObject:controlGroup];
    [items addObject:[self buttonSpecifierNamed:@"Refresh" action:@selector(refreshTapped)]];
    [items addObject:[self buttonSpecifierNamed:@"Pause YOLO Triggers" action:@selector(pauseTapped)]];
    [items addObject:[self buttonSpecifierNamed:@"Resume YOLO Triggers" action:@selector(resumeTapped)]];
    [items addObject:[self buttonSpecifierNamed:@"Stop Current Task" action:@selector(stopCurrentTaskTapped)]];
    [items addObject:[self buttonSpecifierNamed:@"Smaller Screenshots" action:@selector(shrinkScreenshotTapped)]];
    [items addObject:[self buttonSpecifierNamed:@"Larger Screenshots" action:@selector(growScreenshotTapped)]];

    if (self.lastError.length > 0) {
        PSSpecifier *errorGroup = [PSSpecifier groupSpecifierWithName:@"Error"];
        [items addObject:errorGroup];
        [items addObject:[self valueSpecifierNamed:@"Daemon" value:self.lastError]];
    }
    return items;
}

- (PSSpecifier *)switchSpecifierNamed:(NSString *)name key:(NSString *)key {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
            target:self
            set:@selector(setPreferenceValue:specifier:)
            get:@selector(readPreferenceValue:)
            detail:nil
            cell:PSSwitchCell
            edit:nil];
    [specifier setProperty:key ?: @"" forKey:PSKeyNameKey];
    [specifier setProperty:key ?: @"" forKey:PSIDKey];
    return specifier;
}

- (PSSpecifier *)valueSpecifierNamed:(NSString *)name value:(NSString *)value {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
            target:self set:nil get:nil detail:nil cell:PSTitleValueCell edit:nil];
    [specifier setProperty:value.length > 0 ? value : @"unknown" forKey:PSValueKey];
    [specifier setProperty:@YES forKey:PSCopyableCellKey];
    return specifier;
}

- (PSSpecifier *)buttonSpecifierNamed:(NSString *)name action:(SEL)action {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
            target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
    specifier->action = action;
    specifier.buttonAction = action;
    [specifier setProperty:NSStringFromSelector(action) forKey:PSButtonActionKey];
    return specifier;
}

- (PSSpecifier *)autonomyModeSpecifier {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:@"Autonomy Mode"
            target:self
            set:@selector(setPreferenceValue:specifier:)
            get:@selector(readPreferenceValue:)
            detail:[PSListItemsController class]
            cell:PSLinkListCell
            edit:nil];
    [specifier setProperty:@"autonomy_mode" forKey:PSKeyNameKey];
    [specifier setProperty:@"autonomy_mode" forKey:PSIDKey];
    [specifier setProperty:@[@"yolo", @"reviewed", @"dry_run"] forKey:@"values"];
    [specifier setProperty:@[@"YOLO (execute)", @"Reviewed (approve each UI action)",
            @"Dry Run (refuse UI mutations)"] forKey:@"titles"];
    return specifier;
}

- (PSSpecifier *)modelProviderSpecifier {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:@"Provider"
            target:self
            set:@selector(setPreferenceValue:specifier:)
            get:@selector(readPreferenceValue:)
            detail:[PSListItemsController class]
            cell:PSLinkListCell
            edit:nil];
    [specifier setProperty:@"model_mode" forKey:PSKeyNameKey];
    [specifier setProperty:@"model_mode" forKey:PSIDKey];
    [specifier setProperty:@[@"bedrock_converse", @"openai_realtime", @"broker"] forKey:@"values"];
    [specifier setProperty:@[@"Bedrock", @"OpenAI Realtime", @"Broker"] forKey:@"titles"];
    return specifier;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = OPAgentPrefsString([specifier propertyForKey:PSKeyNameKey]);
    if ([key isEqualToString:@"hardware_triggers_enabled"]) {
        return OPAgentPrefsBoolNumber(OPAgentPrefsNestedValue(self.latestStatus,
                @[@"control", @"hardware_triggers_enabled"]), YES);
    }
    if ([key isEqualToString:@"yolo_enabled"]) {
        return OPAgentPrefsBoolNumber(OPAgentPrefsNestedValue(self.latestStatus,
                @[@"control", @"yolo_enabled"]), YES);
    }
    if ([key isEqualToString:@"autonomy_mode"]) {
        NSString *mode = OPAgentPrefsString(OPAgentPrefsNestedValue(self.latestStatus,
                @[@"control", @"autonomy_mode"]));
        return mode.length > 0 ? mode : @"yolo";
    }
    if ([key isEqualToString:@"model_mode"]) {
        NSString *mode = OPAgentPrefsString(OPAgentPrefsNestedValue(self.latestStatus,
                @[@"model", @"mode"]));
        return mode.length > 0 ? mode : @"broker";
    }
    return @NO;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = OPAgentPrefsString([specifier propertyForKey:PSKeyNameKey]);
    if (key.length == 0) {
        return;
    }
    if ([key isEqualToString:@"autonomy_mode"]) {
        [self applyAutonomyMode:OPAgentPrefsString(value)];
        return;
    }
    if ([key isEqualToString:@"model_mode"]) {
        [self applyModelMode:OPAgentPrefsString(value)];
        return;
    }
    BOOL enabled = [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
    NSError *error = nil;
    NSDictionary *result = OPAgentPrefsSendRequest(@{
        @"command": @"agent_control",
        key: @(enabled),
        @"reason": [NSString stringWithFormat:@"OpenPhone Settings %@ %@",
            key, enabled ? @"enabled" : @"disabled"],
        @"source": @"OpenPhoneAgentPrefs"
    }, &error);
    if (![result isKindOfClass:[NSDictionary class]] || ![result[@"status"] isEqualToString:@"ok"]) {
        NSString *message = error.localizedDescription ?: OPAgentPrefsString(result[@"reason"]);
        [self showMessage:message.length > 0 ? message : @"agent_control failed" title:@"OpenPhone Agent"];
    }
    [self refreshTapped];
}

- (void)applyAutonomyMode:(NSString *)mode {
    if (mode.length == 0) {
        return;
    }
    NSError *error = nil;
    NSDictionary *result = OPAgentPrefsSendRequest(@{
        @"command": @"agent_control",
        @"autonomy_mode": mode,
        @"reason": [NSString stringWithFormat:@"OpenPhone Settings autonomy_mode %@", mode],
        @"source": @"OpenPhoneAgentPrefs"
    }, &error);
    if (![result isKindOfClass:[NSDictionary class]] || ![result[@"status"] isEqualToString:@"ok"]) {
        NSString *message = error.localizedDescription ?: OPAgentPrefsString(result[@"reason"]);
        [self showMessage:message.length > 0 ? message : @"agent_control failed" title:@"OpenPhone Agent"];
    }
    [self refreshTapped];
}

- (void)applyModelMode:(NSString *)mode {
    if (mode.length == 0) {
        return;
    }
    NSError *error = nil;
    NSDictionary *result = OPAgentPrefsSendRequest(@{
        @"command": @"model_configure",
        @"mode": mode,
        @"reason": [NSString stringWithFormat:@"OpenPhone Settings model provider %@", mode],
        @"source": @"OpenPhoneAgentPrefs"
    }, &error);
    if (![result isKindOfClass:[NSDictionary class]] || ![result[@"status"] isEqualToString:@"ok"]) {
        NSString *message = error.localizedDescription ?: OPAgentPrefsString(result[@"reason"]);
        [self showMessage:message.length > 0 ? message : @"model_configure failed" title:@"OpenPhone Agent"];
    }
    [self refreshTapped];
}

- (NSString *)nestedString:(NSArray<NSString *> *)keys fallback:(NSString *)fallback {
    NSString *value = OPAgentPrefsString(OPAgentPrefsNestedValue(self.latestStatus, keys));
    return value.length > 0 ? value : (fallback ?: @"");
}

- (NSString *)statusSummary {
    if (self.lastError.length > 0) {
        return @"unavailable";
    }
    return [self nestedString:@[@"user_facing", @"summary"] fallback:@"unknown"];
}

- (NSString *)policySummary {
    NSString *policy = [self nestedString:@[@"control", @"trigger_policy"] fallback:@"unknown"];
    NSString *hardware = OPAgentPrefsBoolString(OPAgentPrefsNestedValue(self.latestStatus, @[@"control", @"hardware_triggers_enabled"]));
    NSString *yolo = OPAgentPrefsBoolString(OPAgentPrefsNestedValue(self.latestStatus, @[@"control", @"yolo_enabled"]));
    return [NSString stringWithFormat:@"%@, hardware %@, yolo %@", policy, hardware, yolo];
}

- (NSString *)modelSummary {
    NSString *mode = [self nestedString:@[@"model", @"mode"] fallback:@"unknown"];
    NSString *status = [self nestedString:@[@"model", @"status"] fallback:@"unknown"];
    return [NSString stringWithFormat:@"%@ / %@", mode, status];
}

- (long long)currentScreenshotDimension {
    id value = OPAgentPrefsNestedValue(self.latestStatus, @[@"model", @"screenshot_max_dimension_px"]);
    if ([value respondsToSelector:@selector(longLongValue)]) {
        return [value longLongValue];
    }
    return 1024;
}

- (NSString *)screenshotDimensionSummary {
    long long dimension = [self currentScreenshotDimension];
    NSString *quality = [self nestedString:@[@"model", @"screenshot_jpeg_quality_x100"] fallback:@"60"];
    if (dimension <= 0) {
        return [NSString stringWithFormat:@"full res, q%@", quality];
    }
    return [NSString stringWithFormat:@"%lld px, q%@", dimension, quality];
}

- (NSString *)triggerSummary {
    NSString *status = [self nestedString:@[@"triggers", @"volume_combo", @"springboard_fallback", @"status"] fallback:@"unknown"];
    id hooked = OPAgentPrefsNestedValue(self.latestStatus, @[@"triggers", @"volume_combo", @"springboard_fallback", @"hooks", @"volume_hooked"]);
    id total = OPAgentPrefsNestedValue(self.latestStatus, @[@"triggers", @"volume_combo", @"springboard_fallback", @"hooks", @"volume_total"]);
    if (hooked || total) {
        return [NSString stringWithFormat:@"%@, %@/%@ volume hooks", status,
            OPAgentPrefsString(hooked), OPAgentPrefsString(total)];
    }
    return status;
}

- (NSString *)triggerCounterSummary {
    NSString *buttons = [self nestedString:@[@"triggers", @"volume_combo", @"springboard_fallback", @"button_events_seen"] fallback:@"0"];
    NSString *combos = [self nestedString:@[@"triggers", @"volume_combo", @"springboard_fallback", @"combo_events_seen"] fallback:@"0"];
    return [NSString stringWithFormat:@"buttons %@, combos %@", buttons, combos];
}

- (NSString *)latestTaskSummary {
    NSString *taskId = [self nestedString:@[@"latest_task", @"task_id"] fallback:@"none"];
    NSString *status = [self nestedString:@[@"latest_task", @"status"] fallback:@"unknown"];
    NSString *tool = [self nestedString:@[@"latest_task", @"model_loop_tool"] fallback:@""];
    if (tool.length > 0) {
        return [NSString stringWithFormat:@"%@ / %@ / %@", taskId, status, tool];
    }
    return [NSString stringWithFormat:@"%@ / %@", taskId, status];
}

- (NSString *)currentTaskSummary {
    NSString *taskId = [self nestedString:@[@"current_task", @"task_id"] fallback:@""];
    if (taskId.length == 0 || [taskId isEqualToString:@"none"]) {
        return @"none";
    }
    NSString *status = [self nestedString:@[@"current_task", @"status"] fallback:@"unknown"];
    NSString *step = [self nestedString:@[@"current_task", @"current_step"] fallback:@"0"];
    return [NSString stringWithFormat:@"%@ / %@ / step %@", taskId, status, step];
}

- (void)refreshTapped {
    [self reloadAgentStatus];
    self.specifiers = [[self buildSpecifiers] mutableCopy];
    [self reloadSpecifiers];
}

- (void)pauseTapped {
    [self sendControlAction:@"pause" reason:@"OpenPhone Settings pause"];
}

- (void)resumeTapped {
    [self sendControlAction:@"resume" reason:@"OpenPhone Settings resume"];
}

- (void)stopCurrentTaskTapped {
    NSString *taskId = [self nestedString:@[@"current_task", @"task_id"] fallback:@""];
    if (taskId.length == 0) {
        [self showMessage:@"No active task is currently running." title:@"OpenPhone Agent"];
        return;
    }
    NSError *error = nil;
    NSDictionary *result = OPAgentPrefsSendRequest(@{
        @"command": @"stop_task",
        @"task_id": taskId,
        @"reason": @"OpenPhone Settings stop current task"
    }, &error);
    if (![result isKindOfClass:[NSDictionary class]] || ![result[@"status"] isEqualToString:@"ok"]) {
        NSString *message = error.localizedDescription ?: OPAgentPrefsString(result[@"reason"]);
        [self showMessage:message.length > 0 ? message : @"stop_task failed" title:@"OpenPhone Agent"];
        return;
    }
    [self refreshTapped];
}

- (void)shrinkScreenshotTapped {
    [self adjustScreenshotDimensionByFactor:0.5];
}

- (void)growScreenshotTapped {
    [self adjustScreenshotDimensionByFactor:2.0];
}

- (void)adjustScreenshotDimensionByFactor:(double)factor {
    long long current = [self currentScreenshotDimension];
    if (current <= 0) {
        current = 1024;
    }
    long long next = (long long)llround((double)current * factor);
    if (next < 256) {
        next = 256;
    }
    if (next > 4096) {
        next = 4096;
    }
    NSString *currentMode = [self nestedString:@[@"model", @"mode"] fallback:@"broker"];
    NSError *error = nil;
    NSDictionary *result = OPAgentPrefsSendRequest(@{
        @"command": @"model_configure",
        @"mode": currentMode,
        @"screenshot_max_dimension_px": @(next),
        @"reason": [NSString stringWithFormat:@"OpenPhone Settings screenshot_max_dimension_px %lld", next],
        @"source": @"OpenPhoneAgentPrefs"
    }, &error);
    if (![result isKindOfClass:[NSDictionary class]] || ![result[@"status"] isEqualToString:@"ok"]) {
        NSString *message = error.localizedDescription ?: OPAgentPrefsString(result[@"reason"]);
        [self showMessage:message.length > 0 ? message : @"model_configure failed" title:@"OpenPhone Agent"];
        return;
    }
    [self refreshTapped];
}

- (void)sendControlAction:(NSString *)action reason:(NSString *)reason {
    NSError *error = nil;
    NSDictionary *result = OPAgentPrefsSendRequest(@{
        @"command": @"agent_control",
        @"action": action ?: @"status",
        @"reason": reason ?: @"OpenPhone Settings",
        @"source": @"OpenPhoneAgentPrefs"
    }, &error);
    if (![result isKindOfClass:[NSDictionary class]] || ![result[@"status"] isEqualToString:@"ok"]) {
        NSString *message = error.localizedDescription ?: OPAgentPrefsString(result[@"reason"]);
        [self showMessage:message.length > 0 ? message : @"agent_control failed" title:@"OpenPhone Agent"];
        return;
    }
    [self refreshTapped];
}

- (void)showMessage:(NSString *)message title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title ?: @"OpenPhone Agent"
            message:message ?: @""
            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
