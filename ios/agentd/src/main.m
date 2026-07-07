#import <Foundation/Foundation.h>

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CommonCrypto/CommonDigest.h>
#import <Speech/Speech.h>

#import <compression.h>
#import <dlfcn.h>
#import <errno.h>
#import <arpa/inet.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <netinet/in.h>
#import <notify.h>
#import <pthread.h>
#import <pwd.h>
#import <signal.h>
#import <sqlite3.h>
#import <spawn.h>
#import <stdarg.h>
#import <stdbool.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/types.h>
#import <sys/un.h>
#import <sys/utsname.h>
#import <sys/wait.h>
#import <TargetConditionals.h>
#import <unistd.h>

extern char **environ;

// Private memorystatus syscall — public header (sys/kern_memorystatus.h) is not
// shipped in the SDK, but the syscall works under the rootless runtime prefix.
// Declaring the
// pieces we need locally so we can raise our jetsam priority and avoid being
// sacrificed under memory pressure during long model tasks.
extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags,
        void *buffer, size_t buffersize);
#ifndef MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES
#define MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES 2
#endif
#ifndef MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK
#define MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK 5
#endif
#ifndef MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT 7
#endif
// xnu jetsam priority bands are small integers (0..JETSAM_PRIORITY_MAX==21):
// 0=idle, 6=phone, 10=foreground app, 12=audio_and_accessory, 19=critical.
// Aim for the AUDIO band since we own the microphone and stream audio to
// STT / Realtime. NOTE: earlier code used 100/120 here, which are out of range
// and made memorystatus_control fail with EINVAL(22).
#ifndef JETSAM_PRIORITY_FOREGROUND
#define JETSAM_PRIORITY_FOREGROUND 10
#endif
#ifndef JETSAM_PRIORITY_AUDIO_AND_ACCESSORY
#define JETSAM_PRIORITY_AUDIO_AND_ACCESSORY 12
#endif
#ifndef JETSAM_PRIORITY_MAX
#define JETSAM_PRIORITY_MAX 21
#endif
// Must match xnu's layout exactly: the kernel rejects the call with EINVAL if
// buffersize != sizeof(memorystatus_priority_properties_t). user_data is
// uint64_t (an earlier uint32_t here made the struct 8 bytes instead of 16 and
// caused persistent EINVAL).
typedef struct {
    int32_t priority;
    uint64_t user_data;
} memorystatus_priority_properties_t;

static NSString *const OPAgentVersion = @"0.1.0-dev";
static NSString *const OPDefaultStorePath = @"/var/mobile/Library/OpenPhone";
static NSString *const OPVolumeTriggerPreferencesPath = @"/var/mobile/Library/Preferences/com.openphone.volumetrigger.plist";
static NSString *const OPDefaultHardwareTriggerGoal = @"Use the current phone context to handle this hardware volume trigger as an immediate OpenPhone agent turn. Inspect the visible state, act only when the next useful phone action is clear, otherwise finish with a concise status.";
static NSString *const OPLegacyHardwareTriggerGoal = @"Handle the OpenPhone hardware volume trigger using the current phone context.";
static NSString *const OPOpenAIRealtimeModel = @"gpt-realtime";
static NSString *const OPOpenAIRealtime2Model = @"gpt-realtime-2";

static volatile sig_atomic_t OPRunning = 1;
static int OPServerFd = -1;
static int OPAppUIIntakeFd = -1;
static pthread_mutex_t OPHardwareTriggerMutex = PTHREAD_MUTEX_INITIALIZER;
static long long OPHardwareTriggerLastAcceptedMs = 0;
static pthread_mutex_t OPVoiceTriggerMutex = PTHREAD_MUTEX_INITIALIZER;
static BOOL OPVoiceTriggerRunning = NO;
static volatile int OPVoiceCancelRequested = 0;
static long long OPVoiceTriggerLastStartedMs = 0;
static long long OPVoiceTriggerLastFinishedMs = 0;
static NSString *OPVoiceTriggerLastState = nil;
static NSString *OPVoiceTriggerLastTranscript = nil;
static NSString *OPVoiceTriggerLastError = nil;
static NSString *OPVoiceTriggerLastProvider = nil;
static volatile int OPAppUIIntakeThreadStarted = 0;
static volatile int OPAppUIIntakeReady = 0;
static unsigned long long OPAppUIIntakePublishCount = 0;
static long long OPAppUIIntakeLastPublishMs = 0;
static NSString *OPAppUIIntakeLastBundleId = nil;
static NSString *OPAppUIIntakeStartError = nil;
static unsigned long long OPNotificationIngestCount = 0;
static long long OPNotificationLastIngestMs = 0;
static NSString *OPNotificationLastBundleId = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *OPAppInputRequests = nil;
static pid_t OPProtectedDataHelperPid = 0;
static long long OPProtectedDataHelperLastSpawnMs = 0;
static NSString *OPProtectedDataHelperLastSpawnError = nil;
// Wall-clock ms at which this daemon process started. App-process UI state
// received before this instant is from a prior process (pre-restart) and must
// not be trusted as a fresh observation after a resume.
static long long OPProcessStartMs = 0;

static NSDictionary *OPVolumeTriggerStatus(void);
static void OPStartVolumeTriggerListener(void);
static NSDictionary *OPRunTask(NSDictionary *request);
static NSDictionary *OPVoiceTrigger(NSDictionary *request);
static NSDictionary *OPVoiceStatus(NSDictionary *request);
static NSDictionary *OPVoiceTranscribeFile(NSDictionary *request);
static NSDictionary *OPBackgroundJobRunDue(NSDictionary *request);
static void OPStartBackgroundJobScheduler(void);
static NSDictionary *OPSpringBoardPublishedState(void);
static NSDictionary *OPRepairStaleActiveTasks(NSDictionary *request);
static void OPStartAppUIIntakeServer(void);
static NSString *OPStringFromRequest(NSDictionary *request, NSString *key, NSString *defaultValue);
static NSDictionary *OPReadJSONFile(NSString *path);
static BOOL OPTaskCancellationRequested(NSString *taskId, NSString **reasonOut);
static void OPRecordTrajectory(NSString *taskId, NSString *event, NSDictionary *payload);
static BOOL OPModelModeIsOpenAIRealtime(NSString *mode);
static NSDictionary *OPJetsamPrioritySet(NSDictionary *request);
static NSString *OPExplicitURLFromText(NSString *text);
static NSDictionary *OPError(NSString *reason);
static NSData *OPJSONData(id object);
static BOOL OPWriteAll(int fd, NSData *data);
static NSData *OPReadClient(int clientFd);
static NSDictionary *OPContactsProviderStatus(void);
static NSDictionary *OPCalendarProviderStatus(void);
static NSDictionary *OPCallsProviderStatus(void);
static NSDictionary *OPMessagesProviderStatus(void);
static NSDictionary *OPNotificationProviderStatus(void);
static NSDictionary *OPNotificationIngest(NSDictionary *request);
static NSDictionary *OPNotificationList(NSDictionary *request);
static NSDictionary *OPNotificationFireWatchers(NSDictionary *notification);
static NSDictionary *OPModelScreenTraceSummary(NSDictionary *screen);

static NSString *OPBackgroundJobSchedulerStatus(void) {
    return @"implemented_agent_loop";
}

static NSString *OPCommitmentSchedulerStatus(void) {
    return @"implemented_time_bridge";
}

static NSString *OPWatcherSchedulerStatus(void) {
    return @"implemented_timer_bridge";
}

static NSString *OPStorePath(void) {
    const char *override = getenv("OPENPHONE_AGENTD_STORE");
    if (override && override[0] != '\0') {
        return [NSString stringWithUTF8String:override];
    }
    return OPDefaultStorePath;
}

static NSString *OPRunPath(void) {
    return [OPStorePath() stringByAppendingPathComponent:@"run"];
}

static NSString *OPSocketPath(void) {
    return [OPRunPath() stringByAppendingPathComponent:@"agentd.sock"];
}

static NSString *OPLogPath(void) {
    return [OPStorePath() stringByAppendingPathComponent:@"openphone-agentd.log"];
}

static NSString *OPTasksPath(void) {
    return [OPStorePath() stringByAppendingPathComponent:@"tasks"];
}

static NSString *OPConfigPath(void) {
    return [OPStorePath() stringByAppendingPathComponent:@"config"];
}

static NSString *OPModelConfigPath(void) {
    return [OPConfigPath() stringByAppendingPathComponent:@"model.json"];
}

static NSString *OPModelCredentialPath(void) {
    return [OPConfigPath() stringByAppendingPathComponent:@"model-credential.json"];
}

static NSString *OPAgentControlPath(void) {
    return [OPConfigPath() stringByAppendingPathComponent:@"agent-control.json"];
}

static NSString *OPVoiceCredentialPath(void) {
    return [OPConfigPath() stringByAppendingPathComponent:@"voice-credential.json"];
}

static NSString *OPVoicePath(void) {
    return [OPStorePath() stringByAppendingPathComponent:@"voice"];
}

static NSString *OPVoiceMemoryWatermarkPath(void) {
    return [[OPStorePath() stringByAppendingPathComponent:@"springboard"]
            stringByAppendingPathComponent:@"voice-memory-watermark.json"];
}

static NSString *OPContactsFixturePath(void) {
    return [OPConfigPath() stringByAppendingPathComponent:@"contacts-fixture.json"];
}

static NSString *OPCalendarFixturePath(void) {
    return [OPConfigPath() stringByAppendingPathComponent:@"calendar-fixture.json"];
}

static NSString *OPCallsFixturePath(void) {
    return [OPConfigPath() stringByAppendingPathComponent:@"calls-fixture.json"];
}

static NSString *OPMessagesFixturePath(void) {
    return [OPConfigPath() stringByAppendingPathComponent:@"messages-fixture.json"];
}

static NSString *OPAuditPath(void) {
    return [[OPStorePath() stringByAppendingPathComponent:@"audit"]
            stringByAppendingPathComponent:@"audit-events.jsonl"];
}

static NSString *OPTrajectoriesPath(void) {
    return [OPStorePath() stringByAppendingPathComponent:@"trajectories"];
}

static NSString *OPScreenshotsPath(void) {
    return [OPStorePath() stringByAppendingPathComponent:@"screenshots"];
}

static NSString *OPAppUIPath(void) {
    return [OPStorePath() stringByAppendingPathComponent:@"app-ui"];
}

static NSString *OPSpringBoardStatePath(void) {
    return [[OPStorePath() stringByAppendingPathComponent:@"springboard"]
            stringByAppendingPathComponent:@"state.json"];
}

static NSString *OPSpringBoardTriggerStatusPath(void) {
    return [[OPStorePath() stringByAppendingPathComponent:@"springboard"]
            stringByAppendingPathComponent:@"trigger-status.json"];
}

static NSString *OPSpringBoardScreenshotRequestPath(void) {
    return [[OPStorePath() stringByAppendingPathComponent:@"springboard"]
            stringByAppendingPathComponent:@"screenshot-request.json"];
}

static NSString *OPSpringBoardScreenshotResponsePath(void) {
    return [[OPStorePath() stringByAppendingPathComponent:@"springboard"]
            stringByAppendingPathComponent:@"screenshot-response.json"];
}

static NSString *OPSpringBoardInputRequestPath(void) {
    return [[OPStorePath() stringByAppendingPathComponent:@"springboard"]
            stringByAppendingPathComponent:@"input-request.json"];
}

static NSString *OPSpringBoardInputResponsePath(void) {
    return [[OPStorePath() stringByAppendingPathComponent:@"springboard"]
            stringByAppendingPathComponent:@"input-response.json"];
}

static NSString *OPSpringBoardClipboardRequestPath(void) {
    return [[OPStorePath() stringByAppendingPathComponent:@"springboard"]
            stringByAppendingPathComponent:@"clipboard-request.json"];
}

static NSString *OPSpringBoardClipboardResponsePath(void) {
    return [[OPStorePath() stringByAppendingPathComponent:@"springboard"]
            stringByAppendingPathComponent:@"clipboard-response.json"];
}

static NSString *OPNotificationsPath(void) {
    return [OPStorePath() stringByAppendingPathComponent:@"notifications"];
}

// Recent-notification ring buffer file. SpringBoard's OpenPhoneVolumeTrigger
// tweak hooks NCNotificationDispatcher and posts each banner here via the
// daemon Unix socket; the daemon keeps a bounded, redacted rolling log.
static NSString *OPNotificationLogPath(void) {
    return [OPNotificationsPath() stringByAppendingPathComponent:@"recent.json"];
}

static void OPHandleSignal(int signum) {
    (void)signum;
    OPRunning = 0;
    if (OPServerFd >= 0) {
        close(OPServerFd);
        OPServerFd = -1;
    }
    if (OPAppUIIntakeFd >= 0) {
        close(OPAppUIIntakeFd);
        OPAppUIIntakeFd = -1;
    }
}

static void OPEnsureDirectories(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSString *> *paths = @[
        OPStorePath(),
        OPRunPath(),
        OPTasksPath(),
        [OPStorePath() stringByAppendingPathComponent:@"audit"],
        [OPStorePath() stringByAppendingPathComponent:@"trajectories"],
        OPScreenshotsPath(),
        OPAppUIPath(),
        OPNotificationsPath(),
        OPVoicePath(),
        [OPStorePath() stringByAppendingPathComponent:@"springboard"],
        [OPStorePath() stringByAppendingPathComponent:@"db"],
        OPConfigPath()
    ];
    for (NSString *path in paths) {
        [fileManager createDirectoryAtPath:path
               withIntermediateDirectories:YES
                                attributes:@{NSFilePosixPermissions: @0755}
                                     error:nil];
    }
    chmod(OPConfigPath().UTF8String, 0700);
}

static long long OPNowMs(void) {
    return (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

static BOOL OPPathExists(NSString *path) {
    if (path.length == 0) {
        return NO;
    }
    struct stat st;
    return stat(path.UTF8String, &st) == 0;
}

static void OPRestrictSocketToMobile(NSString *path) {
    if (path.length == 0) {
        return;
    }
    struct passwd *mobile = getpwnam("mobile");
    uid_t uid = mobile ? mobile->pw_uid : 501;
    gid_t gid = mobile ? mobile->pw_gid : 501;
    chown(path.UTF8String, uid, gid);
    chmod(path.UTF8String, 0600);
}

static BOOL OPEnvFlagEnabled(const char *name) {
    const char *value = getenv(name);
    if (!value || value[0] == '\0') {
        return NO;
    }
    return strcmp(value, "0") != 0 &&
            strcasecmp(value, "false") != 0 &&
            strcasecmp(value, "no") != 0;
}

static BOOL OPProtectedDataHelperRole(void) {
    const char *role = getenv("OPENPHONE_AGENTD_ROLE");
    return role && strcmp(role, "protected_data_helper") == 0;
}

static BOOL OPProtectedDataHelperCommandAllowed(NSString *command) {
    if ([command isEqualToString:@"health"]) {
        return YES;
    }
    if ([command isEqualToString:@"calendar_search"] ||
            [command isEqualToString:@"calendar_events_search"] ||
            [command isEqualToString:@"openphone.calendar.search"] ||
            [command isEqualToString:@"openphone.calendar.events.search"]) {
        return YES;
    }
    if ([command isEqualToString:@"calls_search"] ||
            [command isEqualToString:@"call_history_search"] ||
            [command isEqualToString:@"openphone.calls.search"] ||
            [command isEqualToString:@"openphone.call_history.search"]) {
        return YES;
    }
    if ([command isEqualToString:@"messages_search"] ||
            [command isEqualToString:@"message_search"] ||
            [command isEqualToString:@"sms_search"] ||
            [command isEqualToString:@"openphone.messages.search"] ||
            [command isEqualToString:@"openphone.sms.search"]) {
        return YES;
    }
    // The helper runs setuid-root, so it can raise agentd's jetsam band when the
    // mobile-uid daemon itself gets EPERM from memorystatus_control.
    if ([command isEqualToString:@"jetsam_priority_set"] ||
            [command isEqualToString:@"openphone.jetsam.priority_set"]) {
        return YES;
    }
    return NO;
}

static NSString *OPProtectedDataHelperStorePath(void) {
    const char *override = getenv("OPENPHONE_PROTECTED_DATA_HELPER_STORE");
    if (override && override[0] != '\0') {
        return [NSString stringWithUTF8String:override];
    }
    return [OPDefaultStorePath stringByAppendingPathComponent:@"protected-data-helper"];
}

static NSString *OPProtectedDataHelperSocketPath(void) {
    const char *override = getenv("OPENPHONE_PROTECTED_DATA_HELPER_SOCKET");
    if (override && override[0] != '\0') {
        return [NSString stringWithUTF8String:override];
    }
    return [[OPProtectedDataHelperStorePath() stringByAppendingPathComponent:@"run"]
            stringByAppendingPathComponent:@"agentd.sock"];
}

static NSString *OPProtectedDataHelperBinaryPath(void) {
    NSArray<NSString *> *candidates = @[
        @"/var/jb/usr/local/bin/openphone-protected-data-helper",
        @"/usr/local/bin/openphone-protected-data-helper"
    ];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *candidate in candidates) {
        if ([fileManager isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

static void OPProtectedDataHelperEnsureDirectories(void) {
    NSString *storePath = OPProtectedDataHelperStorePath();
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSString *> *paths = @[
        storePath,
        [storePath stringByAppendingPathComponent:@"run"],
        [storePath stringByAppendingPathComponent:@"config"],
        [storePath stringByAppendingPathComponent:@"db"],
        [storePath stringByAppendingPathComponent:@"springboard"]
    ];
    for (NSString *path in paths) {
        [fileManager createDirectoryAtPath:path
               withIntermediateDirectories:YES
                                attributes:@{NSFilePosixPermissions: @0755}
                                     error:nil];
    }
}

static BOOL OPProtectedDataHelperSocketConnectable(void) {
    NSString *socketPath = OPProtectedDataHelperSocketPath();
    if (!OPPathExists(socketPath)) {
        return NO;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return NO;
    }
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, socketPath.UTF8String, sizeof(address.sun_path));
    BOOL ok = connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0;
    close(fd);
    return ok;
}

static BOOL OPProtectedDataHelperEnsureStarted(BOOL forceRestart) {
    if (OPProtectedDataHelperRole() || OPEnvFlagEnabled("OPENPHONE_DISABLE_PROTECTED_DATA_HELPER")) {
        return NO;
    }
    if (!OPEnvFlagEnabled("OPENPHONE_AGENTD_ALLOW_PROTECTED_HELPER_SPAWN")) {
        return OPProtectedDataHelperSocketConnectable();
    }
    if (!forceRestart && OPProtectedDataHelperSocketConnectable()) {
        return YES;
    }
    if (OPProtectedDataHelperPid > 0) {
        int status = 0;
        pid_t waited = waitpid(OPProtectedDataHelperPid, &status, WNOHANG);
        if (waited == 0 && !forceRestart) {
            return OPProtectedDataHelperSocketConnectable();
        }
        if (waited == OPProtectedDataHelperPid || waited < 0) {
            OPProtectedDataHelperPid = 0;
        }
    }
    long long nowMs = OPNowMs();
    if (!forceRestart && OPProtectedDataHelperLastSpawnMs > 0 &&
            nowMs - OPProtectedDataHelperLastSpawnMs < 1000) {
        return OPProtectedDataHelperSocketConnectable();
    }

    OPProtectedDataHelperEnsureDirectories();
    unlink(OPProtectedDataHelperSocketPath().UTF8String);

    NSString *binary = OPProtectedDataHelperBinaryPath();
    if (binary.length == 0) {
        OPProtectedDataHelperLastSpawnError = @"protected_data_helper_binary_missing";
        return NO;
    }

    NSArray<NSString *> *envStrings = @[
        [NSString stringWithFormat:@"OPENPHONE_AGENTD_STORE=%@", OPProtectedDataHelperStorePath()],
        @"OPENPHONE_AGENTD_ROLE=protected_data_helper",
        @"OPENPHONE_AGENTD_DISABLE_TASK_REPAIR=1",
        @"OPENPHONE_AGENTD_DISABLE_VOLUME_TRIGGER=1",
        @"OPENPHONE_AGENTD_DISABLE_APP_UI_INTAKE=1",
        @"OPENPHONE_AGENTD_DISABLE_BACKGROUND_SCHEDULER=1",
        @"HOME=/var/mobile",
        @"PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    ];

    char *argv[] = {(char *)binary.UTF8String, NULL};
    char **envp = calloc(envStrings.count + 1, sizeof(char *));
    if (!envp) {
        OPProtectedDataHelperLastSpawnError = @"protected_data_helper_env_alloc_failed";
        return NO;
    }
    for (NSUInteger i = 0; i < envStrings.count; i++) {
        envp[i] = strdup(envStrings[i].UTF8String ?: "");
        if (!envp[i]) {
            for (NSUInteger j = 0; j < i; j++) {
                free(envp[j]);
            }
            free(envp);
            OPProtectedDataHelperLastSpawnError = @"protected_data_helper_env_strdup_failed";
            return NO;
        }
    }
    envp[envStrings.count] = NULL;

    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, binary.UTF8String, NULL, NULL, argv, envp);
    for (NSUInteger i = 0; i < envStrings.count; i++) {
        free(envp[i]);
    }
    free(envp);
    OPProtectedDataHelperLastSpawnMs = nowMs;
    if (spawnResult != 0) {
        OPProtectedDataHelperLastSpawnError = [NSString stringWithFormat:@"protected_data_helper_spawn_failed:%s",
                strerror(spawnResult)];
        return NO;
    }
    OPProtectedDataHelperPid = pid;
    OPProtectedDataHelperLastSpawnError = @"";
    for (NSUInteger i = 0; i < 20; i++) {
        usleep(100000);
        if (OPProtectedDataHelperSocketConnectable()) {
            return YES;
        }
        int status = 0;
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) {
            OPProtectedDataHelperPid = 0;
            OPProtectedDataHelperLastSpawnError = [NSString stringWithFormat:@"protected_data_helper_exited:%d",
                    status];
            return NO;
        }
    }
    return OPProtectedDataHelperSocketConnectable();
}

static NSDictionary *OPJSONObjectFromData(NSData *data) {
    if (data.length == 0) {
        return @{};
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : @{};
}

static NSDictionary *OPProtectedDataHelperRequest(NSDictionary *request) {
    if (OPProtectedDataHelperRole() || OPEnvFlagEnabled("OPENPHONE_DISABLE_PROTECTED_DATA_HELPER")) {
        return nil;
    }
    OPProtectedDataHelperEnsureStarted(NO);
    NSString *socketPath = OPProtectedDataHelperSocketPath();
    if (!OPPathExists(socketPath)) {
        return nil;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return OPError([NSString stringWithFormat:@"protected_data_helper_socket_failed:%s", strerror(errno)]);
    }
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, socketPath.UTF8String, sizeof(address.sun_path));
    BOOL connected = connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0;
    if (!connected) {
        close(fd);
        OPProtectedDataHelperEnsureStarted(YES);
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) {
            return OPError([NSString stringWithFormat:@"protected_data_helper_socket_failed:%s", strerror(errno)]);
        }
        memset(&address, 0, sizeof(address));
        address.sun_family = AF_UNIX;
        strlcpy(address.sun_path, socketPath.UTF8String, sizeof(address.sun_path));
        connected = connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0;
    }
    if (!connected) {
        NSString *reason = [NSString stringWithFormat:@"protected_data_helper_connect_failed:%s", strerror(errno)];
        close(fd);
        return OPError(reason);
    }
    struct timeval timeout;
    timeout.tv_sec = 10;
    timeout.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    NSMutableData *payload = [NSMutableData dataWithData:OPJSONData(request ?: @{})];
    const char newline = '\n';
    [payload appendBytes:&newline length:1];
    if (!OPWriteAll(fd, payload)) {
        NSString *reason = [NSString stringWithFormat:@"protected_data_helper_write_failed:%s", strerror(errno)];
        close(fd);
        return OPError(reason);
    }
    NSData *responseData = OPReadClient(fd);
    close(fd);
    NSDictionary *response = OPJSONObjectFromData(responseData);
    if (response.count == 0) {
        return OPError(@"protected_data_helper_empty_response");
    }
    return response;
}

static void OPLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [formatter stringFromDate:[NSDate date]],
                      message ?: @""];

    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 0) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:OPLogPath()]) {
            [[NSFileManager defaultManager] createFileAtPath:OPLogPath() contents:nil attributes:nil];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:OPLogPath()];
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } @catch (NSException *exception) {
            (void)exception;
        }
        fwrite(data.bytes, 1, data.length, stderr);
    }
}

static NSArray<NSString *> *OPFullYoloCapabilities(void) {
    return @[
        @"screen.read.visible",
        @"screen.capture",
        @"input.perform",
        @"apps.read",
        @"apps.launch",
        @"tasks.observe",
        @"memory.read",
        @"memory.write",
        @"commitments.read",
        @"commitments.write",
        @"watchers.read",
        @"watchers.write",
        @"notifications.read",
        @"notifications.act",
        @"clipboard.read",
        @"clipboard.write",
        @"share.content",
        @"files.read.scoped",
        @"contacts.read",
        @"calendar.read",
        @"calendar.write",
        @"calendar.delete",
        @"messages.read",
        @"messages.draft",
        @"messages.send",
        @"calls.read",
        @"calls.place",
        @"settings.read",
        @"settings.write",
        @"background.run",
        @"network.use",
        @"account.access"
    ];
}

static NSString *OPTaskId(void) {
    long long ms = OPNowMs();
    return [NSString stringWithFormat:@"ios-task-%lld-%d", ms, getpid()];
}

static NSString *OPSafeFileComponent(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) {
        return @"unknown";
    }
    NSMutableString *out = [NSMutableString stringWithCapacity:value.length];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if ([allowed characterIsMember:c]) {
            [out appendFormat:@"%C", c];
        } else {
            [out appendString:@"_"];
        }
    }
    return out.length > 0 ? out : @"unknown";
}

static NSString *OPTaskPath(NSString *taskId) {
    return [OPTasksPath() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.json", OPSafeFileComponent(taskId)]];
}

static NSString *OPTrajectoryPath(NSString *taskId) {
    return [OPTrajectoriesPath() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.jsonl", OPSafeFileComponent(taskId)]];
}

static NSData *OPJSONData(id object) {
    if (!object) {
        object = @{};
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) {
        data = [@"{\"status\":\"error\",\"reason\":\"json_encode_failed\"}" dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSMutableData *line = [data mutableCopy];
    const char newline = '\n';
    [line appendBytes:&newline length:1];
    return line;
}

static BOOL OPWriteAll(int fd, NSData *data) {
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

static NSData *OPCanonicalJSONData(id object) {
    NSJSONWritingOptions options = NSJSONWritingSortedKeys;
    if (@available(iOS 13.0, macOS 10.15, *)) {
        options |= NSJSONWritingWithoutEscapingSlashes;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object ?: @{}
                                                   options:options
                                                     error:nil];
    if (!data) {
        data = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    }
    return data;
}

static NSString *OPSHA256Hex(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

static BOOL OPSensitiveKey(NSString *key) {
    NSString *lower = key.lowercaseString ?: @"";
    NSArray<NSString *> *markers = @[
        @"password",
        @"passcode",
        @"token",
        @"secret",
        @"authorization",
        @"cookie",
        @"api_key",
        @"apikey",
        @"private_key",
        @"hostkey",
        @"host_key"
    ];
    for (NSString *marker in markers) {
        if ([lower containsString:marker]) {
            return YES;
        }
    }
    return NO;
}

static NSString *OPRedactedKeyName(NSString *key) {
    NSData *data = [(key ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSString *hash = OPSHA256Hex(data);
    NSString *shortHash = hash.length >= 12 ? [hash substringToIndex:12] : hash;
    return [NSString stringWithFormat:@"redacted_field_%@", shortHash ?: @"unknown"];
}

static BOOL OPLooksBase64Payload(NSString *value) {
    if (value.length < 160) {
        return NO;
    }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=\r\n"];
    for (NSUInteger i = 0; i < value.length; i++) {
        if (![allowed characterIsMember:[value characterAtIndex:i]]) {
            return NO;
        }
    }
    return YES;
}

static id OPRedactedObject(id object, NSUInteger depth) {
    if (!object || object == [NSNull null]) {
        return [NSNull null];
    }
    if (depth > 8) {
        return @"<redacted:max_depth>";
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *redacted = [NSMutableDictionary dictionary];
        NSDictionary *dictionary = object;
        for (id key in dictionary) {
            NSString *keyString = [key isKindOfClass:[NSString class]]
                    ? key : [key description];
            id value = dictionary[key];
            if (OPSensitiveKey(keyString)) {
                redacted[OPRedactedKeyName(keyString)] = @"<redacted>";
            } else {
                redacted[keyString] = OPRedactedObject(value, depth + 1);
            }
        }
        return redacted;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        NSMutableArray *redacted = [NSMutableArray array];
        NSArray *array = object;
        NSUInteger maxItems = MIN(array.count, 200);
        for (NSUInteger i = 0; i < maxItems; i++) {
            [redacted addObject:OPRedactedObject(array[i], depth + 1)];
        }
        if (array.count > maxItems) {
            [redacted addObject:@{@"truncated_items": @(array.count - maxItems)}];
        }
        return redacted;
    }
    if ([object isKindOfClass:[NSString class]]) {
        NSString *value = object;
        if (OPLooksBase64Payload(value)) {
            return [NSString stringWithFormat:@"<redacted:base64:%lu>",
                    (unsigned long)value.length];
        }
        if (value.length > 4096) {
            return [NSString stringWithFormat:@"<redacted:large_string:%lu>",
                    (unsigned long)value.length];
        }
        return value;
    }
    if ([object isKindOfClass:[NSNumber class]]) {
        return object;
    }
    return [[object description] copy] ?: @"<redacted:unknown>";
}

static NSDictionary *OPError(NSString *reason) {
    return @{
        @"status": @"error",
        @"reason": reason ?: @"unknown",
        @"source": @"openphone.agentd"
    };
}

static BOOL OPWriteJSONFile(NSString *path, NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object ?: @{}
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (!data) {
        return NO;
    }
    return [data writeToFile:path atomically:YES];
}

static BOOL OPWriteProtectedJSONFile(NSString *path, NSDictionary *object) {
    BOOL ok = OPWriteJSONFile(path, object);
    if (ok) {
        chmod(path.UTF8String, 0600);
    }
    return ok;
}

// Live status the daemon publishes so SpringBoard's island UI can render
// listening/transcribing/thinking/tool/done states in real time. The path is
// atomic-write JSON; a Darwin notification wakes any observer.
static NSString *const OPIslandStatusPath =
        @"/var/mobile/Library/OpenPhone/springboard/island-status.json";
static const char *const OPIslandStatusNotification =
        "com.openphone.island.status";
static pthread_mutex_t OPIslandMutex = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary *OPIslandState = nil;
static unsigned long long OPIslandSequence = 0;

static long long OPNowMs(void);

static NSString *OPIslandDir(void) {
    return [OPStorePath() stringByAppendingPathComponent:@"springboard"];
}

static void OPIslandEnsureState(void) {
    if (!OPIslandState) {
        OPIslandState = [NSMutableDictionary dictionary];
        OPIslandState[@"mode"] = @"idle";
        OPIslandState[@"title"] = @"OpenPhone";
        OPIslandState[@"subtitle"] = @"";
        OPIslandState[@"transcript"] = @"";
        OPIslandState[@"tool"] = @"";
        OPIslandState[@"tool_arguments_summary"] = @"";
        OPIslandState[@"step"] = @0;
        OPIslandState[@"max_steps"] = @0;
        OPIslandState[@"task_id"] = @"";
        OPIslandState[@"goal"] = @"";
        OPIslandState[@"accent"] = @"cyan";
        OPIslandState[@"sequence"] = @0;
        OPIslandState[@"updated_at_ms"] = @0;
    }
}

static void OPIslandPublishLocked(void) {
    OPIslandSequence += 1;
    OPIslandState[@"sequence"] = @(OPIslandSequence);
    OPIslandState[@"updated_at_ms"] = @(OPNowMs());
    NSString *dir = OPIslandDir();
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    NSDictionary *snapshot = [OPIslandState copy];
    if (OPWriteJSONFile(OPIslandStatusPath, snapshot)) {
        chmod(OPIslandStatusPath.UTF8String, 0644);
    }
    notify_post(OPIslandStatusNotification);
}

static void OPIslandUpdate(NSDictionary *patch) {
    if (patch.count == 0) {
        return;
    }
    pthread_mutex_lock(&OPIslandMutex);
    OPIslandEnsureState();
    for (NSString *key in patch) {
        id value = patch[key];
        if (value == nil || value == [NSNull null]) {
            continue;
        }
        OPIslandState[key] = value;
    }
    OPIslandPublishLocked();
    pthread_mutex_unlock(&OPIslandMutex);
}

static NSString *OPIslandToolLabel(NSString *tool) {
    if (![tool isKindOfClass:[NSString class]] || tool.length == 0) {
        return @"Thinking";
    }
    NSDictionary *labels = @{
        @"get_screen": @"Looking at screen",
        @"tap_element": @"Tapping",
        @"type_text": @"Typing",
        @"scroll": @"Scrolling",
        @"swipe": @"Swiping",
        @"open_url": @"Opening URL",
        @"launch_app": @"Launching app",
        @"press_home": @"Going home",
        @"web_content_dom_state": @"Reading page",
        @"contacts_search": @"Searching contacts",
        @"calls_search": @"Searching calls",
        @"calendar_search": @"Searching calendar",
        @"messages_search": @"Searching messages",
        @"memory_search": @"Recalling memory",
        @"memory_save": @"Saving memory",
        @"finish_task": @"Finishing",
        @"fail_task": @"Failing",
        @"clipboard_read": @"Reading clipboard",
        @"clipboard_write": @"Writing clipboard"
    };
    NSString *label = labels[tool];
    if (label) {
        return label;
    }
    // Fallback: prettify the tool name.
    NSString *pretty = [tool stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    if (pretty.length == 0) {
        return @"Working";
    }
    return [[pretty substringToIndex:1].uppercaseString
            stringByAppendingString:[pretty substringFromIndex:1]];
}

static void OPIslandPublishToolStep(NSString *taskId, NSString *tool,
        NSString *status, long long step, long long maxSteps) {
    if (![taskId isKindOfClass:[NSString class]]) {
        taskId = @"";
    }
    NSString *mode = [status isEqualToString:@"tool_running"] ? @"action" : @"thinking";
    NSString *accent = [status isEqualToString:@"tool_running"] ? @"cyan" : @"blue";
    NSString *subtitle = OPIslandToolLabel(tool);
    OPIslandUpdate(@{
        @"mode": mode,
        @"subtitle": subtitle ?: @"",
        @"tool": tool ?: @"",
        @"step": @(step),
        @"max_steps": @(maxSteps),
        @"task_id": taskId ?: @"",
        @"accent": accent
    });
}

// Publish a short-form assistant reasoning line to the island so the pill's
// expanded row can render live streaming text like Android does. Called every
// time a model decision arrives with a "thought" field.
__attribute__((unused))
static void OPIslandPublishThought(NSString *thought) {
    // Legacy: kept as no-op. Reasoning is never shown. Use OPIslandPublishAssistantMessage.
    (void)thought;
}

// Show a user-facing message from the model on the island right now.
// Called per step so the pill breathes with real answers instead of dead
// state text. Also persists into the chat history so the answer stays
// visible in the expanded chat panel forever.
static void OPRecordAssistantTurn(NSString *text, NSString *taskId, BOOL succeeded);
static void OPIslandPublishAssistantMessage(NSString *msg, NSString *taskId) {
    if (![msg isKindOfClass:[NSString class]]) return;
    NSString *trimmed = [msg stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return;
    if (trimmed.length > 400) {
        trimmed = [[trimmed substringToIndex:397] stringByAppendingString:@"…"];
    }
    OPIslandUpdate(@{@"reply": trimmed, @"task_id": taskId ?: @""});
    OPRecordAssistantTurn(trimmed, taskId, YES);
}

// Remember the last few voice turns so a follow-up voice turn within 10s can
// reference "the one I just did". Persisted only in-memory; that's enough for
// Android-parity conversational follow-up.
static NSMutableArray<NSDictionary *> *OPRecentVoiceTurns = nil;
static pthread_mutex_t OPRecentVoiceTurnsMutex = PTHREAD_MUTEX_INITIALIZER;

static void OPPublishChatHistory(void); // fwd decl

static void OPRecordVoiceTurn(NSString *transcript, NSString *taskId) {
    if (transcript.length == 0) return;
    pthread_mutex_lock(&OPRecentVoiceTurnsMutex);
    if (!OPRecentVoiceTurns) OPRecentVoiceTurns = [NSMutableArray array];
    [OPRecentVoiceTurns addObject:@{
        @"role": @"user",
        @"text": transcript ?: @"",
        @"task_id": taskId ?: @"",
        @"at_ms": @(OPNowMs())
    }];
    if (OPRecentVoiceTurns.count > 20) {
        [OPRecentVoiceTurns removeObjectAtIndex:0];
    }
    pthread_mutex_unlock(&OPRecentVoiceTurnsMutex);
    OPPublishChatHistory();
}

static void OPRecordAssistantTurn(NSString *text, NSString *taskId, BOOL succeeded) {
    if (text.length == 0) return;
    pthread_mutex_lock(&OPRecentVoiceTurnsMutex);
    if (!OPRecentVoiceTurns) OPRecentVoiceTurns = [NSMutableArray array];
    // Skip if the previous assistant turn for the same task has the same
    // text (avoids the terminal publish dup'ing what the step already said).
    NSDictionary *last = OPRecentVoiceTurns.lastObject;
    if ([last isKindOfClass:[NSDictionary class]] &&
            [last[@"role"] isEqualToString:@"assistant"] &&
            [last[@"text"] isKindOfClass:[NSString class]] &&
            [last[@"text"] isEqualToString:text] &&
            (![last[@"task_id"] isKindOfClass:[NSString class]] ||
             [last[@"task_id"] isEqualToString:taskId ?: @""])) {
        pthread_mutex_unlock(&OPRecentVoiceTurnsMutex);
        return;
    }
    [OPRecentVoiceTurns addObject:@{
        @"role": @"assistant",
        @"text": text ?: @"",
        @"task_id": taskId ?: @"",
        @"at_ms": @(OPNowMs()),
        @"status": succeeded ? @"ok" : @"error"
    }];
    if (OPRecentVoiceTurns.count > 20) {
        [OPRecentVoiceTurns removeObjectAtIndex:0];
    }
    pthread_mutex_unlock(&OPRecentVoiceTurnsMutex);
    OPPublishChatHistory();
}

static void OPPublishChatHistory(void) {
    pthread_mutex_lock(&OPRecentVoiceTurnsMutex);
    NSArray *snapshot = [OPRecentVoiceTurns ?: @[] copy];
    pthread_mutex_unlock(&OPRecentVoiceTurnsMutex);
    NSString *dir = [OPStorePath() stringByAppendingPathComponent:@"springboard"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"chat-history.json"];
    OPWriteJSONFile(path, @{@"turns": snapshot});
    chmod(path.UTF8String, 0644);
    notify_post("com.openphone.island.chat");
}

static NSArray<NSDictionary *> *OPRecentVoiceTurnsSnapshot(long long withinMs) {
    long long cutoff = OPNowMs() - withinMs;
    pthread_mutex_lock(&OPRecentVoiceTurnsMutex);
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *t in OPRecentVoiceTurns ?: @[]) {
        long long at = [t[@"at_ms"] longLongValue];
        if (at >= cutoff) [out addObject:t];
    }
    pthread_mutex_unlock(&OPRecentVoiceTurnsMutex);
    return out;
}

static void OPIslandPublishTerminal(NSString *taskId, BOOL succeeded,
        NSString *summary) {
    NSString *mode = succeeded ? @"success" : @"error";
    NSString *accent = succeeded ? @"green" : @"red";
    NSString *fallback = succeeded ? @"Done" : @"Failed";
    NSString *display = summary.length > 0 ? summary : fallback;
    OPIslandUpdate(@{
        @"mode": mode,
        @"subtitle": display,
        @"reply": display,
        @"task_id": taskId ?: @"",
        @"accent": accent,
        @"tool": @""
    });
}

// Autonomy modes: yolo (default) executes without asking; reviewed pauses on
// UI-driving tools for an Approve/Deny chip; dry_run refuses all UI mutations.
static BOOL OPAutonomyModeValid(NSString *v) {
    return [v isEqualToString:@"reviewed"] || [v isEqualToString:@"dry_run"] ||
            [v isEqualToString:@"yolo"];
}

// Single source of truth is the daemon-owned agent-control config
// (set via the agent_control command / prefs pane). The volume-trigger
// prefs plist AutonomyMode is honored only as a legacy fallback for when
// the tweak wrote it directly and agent-control has not been set.
static NSString *OPAutonomyMode(void) {
    NSDictionary *stored = OPReadJSONFile(OPAgentControlPath());
    if ([stored isKindOfClass:[NSDictionary class]] &&
            [stored[@"autonomy_mode"] isKindOfClass:[NSString class]]) {
        NSString *v = [stored[@"autonomy_mode"] lowercaseString];
        if (OPAutonomyModeValid(v)) {
            return v;
        }
    }
    NSDictionary *prefs = OPReadJSONFile(OPVolumeTriggerPreferencesPath);
    if (![prefs isKindOfClass:[NSDictionary class]]) {
        // Try plist parse via NSDictionary API which handles binary plists.
        prefs = [NSDictionary dictionaryWithContentsOfFile:OPVolumeTriggerPreferencesPath];
    }
    if ([prefs[@"AutonomyMode"] isKindOfClass:[NSString class]]) {
        NSString *v = [prefs[@"AutonomyMode"] lowercaseString];
        if (OPAutonomyModeValid(v)) {
            return v;
        }
    }
    return @"yolo";
}

// Ask the user via the island's Approve/Deny chips. Returns YES if approved,
// NO on deny or timeout. Called from the model loop before executing a tool
// when AutonomyMode=reviewed. Timeout defaults to 30s.
static volatile int OPConfirmationState = 0; // 0=idle 1=waiting 2=approved 3=denied
static NSString *OPConfirmationRequestPath(void) {
    return [OPStorePath() stringByAppendingPathComponent:@"springboard/confirmation-response.json"];
}

static BOOL OPRequestUserConfirmation(NSString *taskId, NSString *tool,
        NSString *summary, double timeoutSeconds) {
    // Publish request via island.
    OPIslandUpdate(@{
        @"mode": @"needs_review",
        @"subtitle": @"Approve to run",
        @"tool": tool ?: @"",
        @"reply": summary ?: [NSString stringWithFormat:@"Run %@?", tool ?: @"tool"],
        @"task_id": taskId ?: @"",
        @"accent": @"orange"
    });
    // Clear any stale response.
    [[NSFileManager defaultManager] removeItemAtPath:OPConfirmationRequestPath() error:nil];
    OPConfirmationState = 1;
    long long deadline = OPNowMs() + (long long)(timeoutSeconds * 1000);
    while (OPNowMs() < deadline) {
        usleep(200000);
        if (OPTaskCancellationRequested(taskId, NULL)) {
            OPConfirmationState = 3;
            return NO;
        }
        NSDictionary *resp = OPReadJSONFile(OPConfirmationRequestPath());
        if ([resp isKindOfClass:[NSDictionary class]]) {
            NSString *decision = [resp[@"decision"] isKindOfClass:[NSString class]]
                    ? resp[@"decision"] : @"";
            [[NSFileManager defaultManager] removeItemAtPath:OPConfirmationRequestPath() error:nil];
            BOOL approved = [decision isEqualToString:@"approve"];
            OPConfirmationState = approved ? 2 : 3;
            OPRecordTrajectory(taskId, @"user_confirmation", @{
                @"tool": tool ?: @"",
                @"decision": decision ?: @"deny",
                @"summary": summary ?: @""
            });
            return approved;
        }
    }
    OPConfirmationState = 3;
    OPRecordTrajectory(taskId, @"user_confirmation_timeout", @{
        @"tool": tool ?: @"",
        @"summary": summary ?: @""
    });
    return NO;
}

static void OPIslandReset(NSString *mode, NSString *subtitle, NSString *accent) {
    pthread_mutex_lock(&OPIslandMutex);
    OPIslandEnsureState();
    OPIslandState[@"mode"] = mode ?: @"idle";
    OPIslandState[@"title"] = @"OpenPhone";
    OPIslandState[@"subtitle"] = subtitle ?: @"";
    OPIslandState[@"transcript"] = @"";
    OPIslandState[@"tool"] = @"";
    OPIslandState[@"tool_arguments_summary"] = @"";
    OPIslandState[@"step"] = @0;
    OPIslandState[@"max_steps"] = @0;
    OPIslandState[@"task_id"] = @"";
    OPIslandState[@"goal"] = @"";
    OPIslandState[@"accent"] = accent ?: @"cyan";
    OPIslandPublishLocked();
    pthread_mutex_unlock(&OPIslandMutex);
}

static NSDictionary *OPReadJSONFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static NSUInteger OPLimitFromRequest(NSDictionary *request, NSUInteger defaultLimit, NSUInteger maxLimit) {
    id value = request[@"limit"];
    long long limit = (long long)defaultLimit;
    if ([value isKindOfClass:[NSNumber class]]) {
        limit = [value longLongValue];
    } else if ([value isKindOfClass:[NSString class]]) {
        limit = [(NSString *)value longLongValue];
    }
    if (limit < 0) {
        limit = 0;
    }
    if ((NSUInteger)limit > maxLimit) {
        limit = (long long)maxLimit;
    }
    return (NSUInteger)limit;
}

static long long OPLongLongFromRequest(NSDictionary *request, NSString *key,
        long long defaultValue, long long minValue, long long maxValue) {
    id value = request[key];
    long long parsed = defaultValue;
    if ([value isKindOfClass:[NSNumber class]]) {
        parsed = [value longLongValue];
    } else if ([value isKindOfClass:[NSString class]]) {
        parsed = [(NSString *)value longLongValue];
    }
    if (parsed < minValue) {
        parsed = minValue;
    }
    if (parsed > maxValue) {
        parsed = maxValue;
    }
    return parsed;
}

static NSArray<NSDictionary *> *OPReadJSONLines(NSString *path, NSUInteger limit) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return @[];
    }
    NSString *contents = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (contents.length == 0) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *events = [NSMutableArray array];
    NSArray<NSString *> *lines = [contents componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        if (line.length == 0) {
            continue;
        }
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        id object = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
        if ([object isKindOfClass:[NSDictionary class]]) {
            [events addObject:object];
            if (limit > 0 && events.count > limit) {
                [events removeObjectAtIndex:0];
            }
        }
    }
    return events;
}

static NSArray<NSDictionary *> *OPRedactedEvents(NSArray<NSDictionary *> *events) {
    NSMutableArray<NSDictionary *> *redactedEvents = [NSMutableArray array];
    for (NSDictionary *event in events) {
        id redacted = OPRedactedObject(event, 0);
        if ([redacted isKindOfClass:[NSDictionary class]]) {
            [redactedEvents addObject:redacted];
        }
    }
    return redactedEvents;
}

static NSDictionary *OPLastJSONLineDictionary(NSString *path, NSUInteger maxBytes) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        return nil;
    }
    @try {
        unsigned long long fileLength = [handle seekToEndOfFile];
        if (fileLength == 0) {
            [handle closeFile];
            return nil;
        }
        unsigned long long readLength = MIN((unsigned long long)maxBytes, fileLength);
        [handle seekToFileOffset:fileLength - readLength];
        NSData *data = [handle readDataToEndOfFile];
        [handle closeFile];
        NSString *contents = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (contents.length == 0) {
            return nil;
        }
        NSArray<NSString *> *lines = [contents componentsSeparatedByCharactersInSet:
                [NSCharacterSet newlineCharacterSet]];
        for (NSInteger i = (NSInteger)lines.count - 1; i >= 0; i--) {
            NSString *line = [lines[(NSUInteger)i] stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (line.length == 0) {
                continue;
            }
            NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
            id object = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
            if ([object isKindOfClass:[NSDictionary class]]) {
                return object;
            }
        }
    } @catch (NSException *exception) {
        @try {
            [handle closeFile];
        } @catch (NSException *closeException) {
            (void)closeException;
        }
        OPLog(@"read last jsonl failed path=%@ exception=%@", path, exception.name ?: @"NSException");
    }
    return nil;
}

static NSString *OPLastAuditHash(void) {
    NSDictionary *last = OPLastJSONLineDictionary(OPAuditPath(), 256 * 1024);
    NSString *eventHash = [last[@"event_hash"] isKindOfClass:[NSString class]]
            ? last[@"event_hash"] : @"";
    return eventHash ?: @"";
}

static void OPAppendJSONLine(NSString *path, NSDictionary *object) {
    NSData *line = OPJSONData(object ?: @{});
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    @try {
        [handle seekToEndOfFile];
        [handle writeData:line];
        [handle closeFile];
    } @catch (NSException *exception) {
        OPLog(@"append jsonl failed path=%@ exception=%@", path, exception.name);
    }
}

static void OPRecordAudit(NSString *eventType, NSString *taskId, NSString *capability,
        NSString *decision, NSDictionary *input, NSString *detail) {
    @try {
        NSMutableDictionary *event = [NSMutableDictionary dictionary];
        event[@"schema"] = @"openphone.audit_event.v1";
        event[@"event_type"] = eventType ?: @"unknown";
        event[@"timestamp_ms"] = @(OPNowMs());
        event[@"task_id"] = taskId ?: @"";
        event[@"capability"] = capability ?: @"";
        event[@"decision"] = decision ?: @"";
        event[@"input"] = OPRedactedObject(input ?: @{}, 0);
        event[@"detail"] = detail ?: @"";
        event[@"source"] = @"openphone.agentd";
        event[@"previous_hash"] = OPLastAuditHash();
        event[@"event_hash"] = OPSHA256Hex(OPCanonicalJSONData(event));
        OPAppendJSONLine(OPAuditPath(), event);
    } @catch (NSException *exception) {
        OPLog(@"record audit failed event=%@ task_id=%@ exception=%@",
                eventType ?: @"unknown", taskId ?: @"", exception.name ?: @"NSException");
    }
}

static void OPRecordTrajectory(NSString *taskId, NSString *eventName, NSDictionary *payload) {
    if (![taskId isKindOfClass:[NSString class]] || taskId.length == 0) {
        return;
    }
    NSDictionary *event = @{
        @"schema": @"openphone.trajectory_event.v1",
        @"timestamp_ms": @(OPNowMs()),
        @"event": eventName ?: @"unknown",
        @"payload": OPRedactedObject(payload ?: @{}, 0),
        @"source": @"openphone.agentd"
    };
    OPAppendJSONLine(OPTrajectoryPath(taskId), event);
}

static void OPUpdateTask(NSString *taskId, NSString *status, NSDictionary *fields) {
    if (![taskId isKindOfClass:[NSString class]] || taskId.length == 0) {
        return;
    }
    NSMutableDictionary *task = [(OPReadJSONFile(OPTaskPath(taskId)) ?: @{}) mutableCopy];
    task[@"task_id"] = taskId;
    task[@"status"] = status ?: task[@"status"] ?: @"unknown";
    task[@"updated_at"] = @(OPNowMs());
    for (NSString *key in fields) {
        id value = fields[key];
        if (key && value) {
            task[key] = value;
        }
    }
    OPWriteJSONFile(OPTaskPath(taskId), task);
}

static NSString *OPDatabasePath(void) {
    return [[OPStorePath() stringByAppendingPathComponent:@"db"]
            stringByAppendingPathComponent:@"openphone.sqlite"];
}

static NSString *OPJSONString(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object ?: @{}
                                                   options:NSJSONWritingSortedKeys
                                                     error:nil];
    if (!data) {
        return @"{}";
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

static NSDictionary *OPJSONDictionary(NSString *string) {
    if (string.length == 0) {
        return @{};
    }
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        return @{};
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : @{};
}

static NSString *OPSQLiteColumnString(sqlite3_stmt *statement, int column) {
    const unsigned char *text = sqlite3_column_text(statement, column);
    return text ? [NSString stringWithUTF8String:(const char *)text] : @"";
}

static BOOL OPSQLiteExec(sqlite3 *db, NSString *sql, NSString **errorOut) {
    char *error = NULL;
    int rc = sqlite3_exec(db, sql.UTF8String, NULL, NULL, &error);
    if (rc != SQLITE_OK) {
        if (errorOut) {
            *errorOut = error ? [NSString stringWithUTF8String:error] : @"sqlite_exec_failed";
        }
        if (error) {
            sqlite3_free(error);
        }
        return NO;
    }
    return YES;
}

static BOOL OPSQLiteTableExists(sqlite3 *db, NSString *name) {
    sqlite3_stmt *statement = NULL;
    BOOL exists = NO;
    if (sqlite3_prepare_v2(db,
            "SELECT 1 FROM sqlite_master WHERE name = ? LIMIT 1",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, name.UTF8String, -1, SQLITE_TRANSIENT);
        exists = sqlite3_step(statement) == SQLITE_ROW;
    }
    sqlite3_finalize(statement);
    return exists;
}

static BOOL OPSQLiteMigrate(sqlite3 *db, NSString **errorOut) {
    NSArray<NSString *> *statements = @[
        @"PRAGMA journal_mode=WAL",
        @"PRAGMA synchronous=NORMAL",
        @"CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at_ms INTEGER NOT NULL)",
        @"CREATE TABLE IF NOT EXISTS memory (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, type TEXT NOT NULL, subject TEXT NOT NULL, text TEXT NOT NULL, confidence REAL NOT NULL, source TEXT NOT NULL, reason TEXT, metadata_json TEXT)",
        @"CREATE TABLE IF NOT EXISTS context_event (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at_ms INTEGER NOT NULL, type TEXT NOT NULL, source TEXT NOT NULL, task_id TEXT, title TEXT, body TEXT, metadata_json TEXT)",
        @"CREATE TABLE IF NOT EXISTS commitment (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, title TEXT NOT NULL, description TEXT, trigger_type TEXT NOT NULL, trigger_spec_json TEXT, due_at_ms INTEGER NOT NULL DEFAULT 0, expires_at_ms INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL, confidence REAL NOT NULL DEFAULT 1.0, evidence_json TEXT, source TEXT NOT NULL, reason TEXT)",
        @"CREATE TABLE IF NOT EXISTS watcher (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, status TEXT NOT NULL, source TEXT NOT NULL, type TEXT NOT NULL, evaluator TEXT, title TEXT NOT NULL, query TEXT, url TEXT, address TEXT, number TEXT, condition_json TEXT, schedule_json TEXT, delivery_json TEXT, next_run_at_ms INTEGER NOT NULL DEFAULT 0, interval_ms INTEGER NOT NULL DEFAULT 0, recurring INTEGER NOT NULL DEFAULT 0, reason TEXT, metadata_json TEXT)",
        @"CREATE TABLE IF NOT EXISTS agent_job (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, status TEXT NOT NULL, type TEXT NOT NULL, title TEXT NOT NULL, prompt TEXT NOT NULL, schedule_json TEXT, next_run_at_ms INTEGER NOT NULL DEFAULT 0, interval_ms INTEGER NOT NULL DEFAULT 0, session_target TEXT, delivery_json TEXT, notification_text TEXT, payload_json TEXT, reason TEXT, source TEXT NOT NULL, scheduler_enabled INTEGER NOT NULL DEFAULT 0)",
        @"CREATE INDEX IF NOT EXISTS memory_updated_idx ON memory(updated_at_ms DESC)",
        @"CREATE INDEX IF NOT EXISTS memory_type_subject_idx ON memory(type, subject)",
        @"CREATE INDEX IF NOT EXISTS context_event_created_idx ON context_event(created_at_ms DESC)",
        @"CREATE INDEX IF NOT EXISTS context_event_type_idx ON context_event(type)",
        @"CREATE INDEX IF NOT EXISTS commitment_status_due_idx ON commitment(status, due_at_ms)",
        @"CREATE INDEX IF NOT EXISTS commitment_updated_idx ON commitment(updated_at_ms DESC)",
        @"CREATE INDEX IF NOT EXISTS watcher_status_next_run_idx ON watcher(status, next_run_at_ms)",
        @"CREATE INDEX IF NOT EXISTS watcher_updated_idx ON watcher(updated_at_ms DESC)",
        @"CREATE INDEX IF NOT EXISTS agent_job_status_next_run_idx ON agent_job(status, next_run_at_ms)",
        @"CREATE INDEX IF NOT EXISTS agent_job_updated_idx ON agent_job(updated_at_ms DESC)"
    ];
    for (NSString *sql in statements) {
        if (!OPSQLiteExec(db, sql, errorOut)) {
            return NO;
        }
    }

    NSString *ftsError = nil;
    OPSQLiteExec(db,
            @"CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts "
             "USING fts5(memory_id UNINDEXED, text, subject, type)",
            &ftsError);
    ftsError = nil;
    OPSQLiteExec(db,
            @"CREATE VIRTUAL TABLE IF NOT EXISTS context_event_fts "
             "USING fts5(event_id UNINDEXED, title, body, type)",
            &ftsError);
    ftsError = nil;
    OPSQLiteExec(db,
            @"CREATE VIRTUAL TABLE IF NOT EXISTS commitment_fts "
             "USING fts5(commitment_id UNINDEXED, title, description, trigger_type)",
            &ftsError);
    ftsError = nil;
    OPSQLiteExec(db,
            @"CREATE VIRTUAL TABLE IF NOT EXISTS watcher_fts "
             "USING fts5(watcher_id UNINDEXED, title, query, source, type)",
            &ftsError);
    ftsError = nil;
    OPSQLiteExec(db,
            @"CREATE VIRTUAL TABLE IF NOT EXISTS agent_job_fts "
             "USING fts5(job_id UNINDEXED, title, prompt, type)",
            &ftsError);
    ftsError = nil;
    OPSQLiteExec(db,
            @"ALTER TABLE agent_job ADD COLUMN scheduler_enabled INTEGER NOT NULL DEFAULT 0",
            &ftsError);

    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "INSERT OR REPLACE INTO schema_migrations(name, applied_at_ms) VALUES(?, ?)",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, "openphone_store_v1", -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(statement, 2, OPNowMs());
        sqlite3_step(statement);
    }
    sqlite3_finalize(statement);
    statement = NULL;
    if (sqlite3_prepare_v2(db,
            "INSERT OR REPLACE INTO schema_migrations(name, applied_at_ms) VALUES(?, ?)",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, "openphone_store_v2", -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(statement, 2, OPNowMs());
        sqlite3_step(statement);
    }
    sqlite3_finalize(statement);
    statement = NULL;
    if (sqlite3_prepare_v2(db,
            "INSERT OR REPLACE INTO schema_migrations(name, applied_at_ms) VALUES(?, ?)",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, "openphone_store_v3_scheduler_enabled", -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(statement, 2, OPNowMs());
        sqlite3_step(statement);
    }
    sqlite3_finalize(statement);
    return YES;
}

static BOOL OPSQLiteOpen(sqlite3 **dbOut, NSString **errorOut) {
    OPEnsureDirectories();
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(OPDatabasePath().UTF8String, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL);
    if (rc != SQLITE_OK) {
        if (errorOut) {
            *errorOut = db ? [NSString stringWithUTF8String:sqlite3_errmsg(db)] : @"sqlite_open_failed";
        }
        if (db) {
            sqlite3_close(db);
        }
        return NO;
    }
    sqlite3_busy_timeout(db, 5000);
    if (!OPSQLiteMigrate(db, errorOut)) {
        sqlite3_close(db);
        return NO;
    }
    *dbOut = db;
    return YES;
}

static void OPSQLiteBindText(sqlite3_stmt *statement, int index, NSString *value) {
    sqlite3_bind_text(statement, index, (value ?: @"").UTF8String, -1, SQLITE_TRANSIENT);
}

static double OPDoubleFromRequest(NSDictionary *request, NSString *key,
        double defaultValue, double minValue, double maxValue) {
    id value = request[key];
    double parsed = defaultValue;
    if ([value isKindOfClass:[NSNumber class]]) {
        parsed = [value doubleValue];
    } else if ([value isKindOfClass:[NSString class]]) {
        parsed = [(NSString *)value doubleValue];
    }
    if (parsed < minValue) {
        parsed = minValue;
    }
    if (parsed > maxValue) {
        parsed = maxValue;
    }
    return parsed;
}

static NSString *OPStringFromRequest(NSDictionary *request, NSString *key, NSString *defaultValue) {
    id value = request[key];
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    }
    return defaultValue ?: @"";
}

static id OPJSONObjectFromRequest(NSDictionary *request, NSString *key, id defaultValue) {
    id value = request[key];
    if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]]) {
        return OPRedactedObject(value, 0);
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSDictionary *dictionary = OPJSONDictionary(value);
        if (dictionary.count > 0) {
            return OPRedactedObject(dictionary, 0);
        }
    }
    return defaultValue ?: @{};
}

static long long OPRecordIdFromValue(id value) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value longLongValue];
    }
    if (![value isKindOfClass:[NSString class]]) {
        return 0;
    }
    NSString *string = [(NSString *)value stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (string.length == 0) {
        return 0;
    }
    long long direct = [string longLongValue];
    if (direct > 0) {
        return direct;
    }
    NSInteger end = (NSInteger)string.length - 1;
    while (end >= 0) {
        unichar c = [string characterAtIndex:(NSUInteger)end];
        if (c < '0' || c > '9') {
            break;
        }
        end--;
    }
    if (end == (NSInteger)string.length - 1) {
        return 0;
    }
    NSString *suffix = [string substringFromIndex:(NSUInteger)(end + 1)];
    return [suffix longLongValue];
}

static long long OPRecordIdFromRequest(NSDictionary *request, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        long long value = OPRecordIdFromValue(request[key]);
        if (value > 0) {
            return value;
        }
    }
    return 0;
}

static NSString *OPFTSQuery(NSString *query) {
    if (query.length == 0) {
        return @"";
    }
    NSCharacterSet *split = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSArray<NSString *> *rawTokens = [query componentsSeparatedByCharactersInSet:split];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *raw in rawTokens) {
        NSString *token = [raw stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (token.length == 0) {
            continue;
        }
        NSString *escaped = [token stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
        [tokens addObject:[NSString stringWithFormat:@"\"%@\"", escaped]];
    }
    return [tokens componentsJoinedByString:@" OR "];
}

static NSDictionary *OPMemoryFromStatement(sqlite3_stmt *statement) {
    NSString *metadataJSON = OPSQLiteColumnString(statement, 9);
    long long rowId = sqlite3_column_int64(statement, 0);
    return @{
        @"id": @(rowId),
        @"memory_id": [NSString stringWithFormat:@"ios-memory-%lld", rowId],
        @"created_at_ms": @(sqlite3_column_int64(statement, 1)),
        @"updated_at_ms": @(sqlite3_column_int64(statement, 2)),
        @"type": OPSQLiteColumnString(statement, 3),
        @"subject": OPSQLiteColumnString(statement, 4),
        @"text": OPSQLiteColumnString(statement, 5),
        @"confidence": @(sqlite3_column_double(statement, 6)),
        @"source": OPSQLiteColumnString(statement, 7),
        @"reason": OPSQLiteColumnString(statement, 8),
        @"metadata": OPJSONDictionary(metadataJSON)
    };
}

static NSDictionary *OPMemoryReadById(sqlite3 *db, long long memoryId) {
    if (memoryId <= 0) {
        return nil;
    }
    NSDictionary *memory = nil;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "SELECT id, created_at_ms, updated_at_ms, type, subject, text, confidence, source, reason, metadata_json "
            "FROM memory WHERE id = ?",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, memoryId);
        if (sqlite3_step(statement) == SQLITE_ROW) {
            memory = OPMemoryFromStatement(statement);
        }
    }
    sqlite3_finalize(statement);
    return memory;
}

static void OPMemoryDeleteFTS(sqlite3 *db, long long memoryId) {
    if (memoryId <= 0 || !OPSQLiteTableExists(db, @"memory_fts")) {
        return;
    }
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, "DELETE FROM memory_fts WHERE memory_id = ?",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, memoryId);
        sqlite3_step(statement);
    }
    sqlite3_finalize(statement);
}

static void OPMemoryIndexFTS(sqlite3 *db, NSDictionary *memory) {
    if (![memory isKindOfClass:[NSDictionary class]] || !OPSQLiteTableExists(db, @"memory_fts")) {
        return;
    }
    long long memoryId = [memory[@"id"] respondsToSelector:@selector(longLongValue)]
            ? [memory[@"id"] longLongValue] : 0;
    if (memoryId <= 0) {
        return;
    }
    OPMemoryDeleteFTS(db, memoryId);
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "INSERT INTO memory_fts(memory_id, text, subject, type) VALUES(?, ?, ?, ?)",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, memoryId);
        OPSQLiteBindText(statement, 2, memory[@"text"]);
        OPSQLiteBindText(statement, 3, memory[@"subject"]);
        OPSQLiteBindText(statement, 4, memory[@"type"]);
        sqlite3_step(statement);
    }
    sqlite3_finalize(statement);
}

static long long OPRecordContextEvent(NSString *type, NSString *source, NSString *taskId,
        NSString *title, NSString *body, NSDictionary *metadata) {
    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        OPLog(@"context db open failed: %@", error ?: @"unknown");
        return 0;
    }
    long long eventId = 0;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "INSERT INTO context_event(created_at_ms, type, source, task_id, title, body, metadata_json) "
            "VALUES(?, ?, ?, ?, ?, ?, ?)",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, OPNowMs());
        OPSQLiteBindText(statement, 2, type ?: @"event");
        OPSQLiteBindText(statement, 3, source ?: @"openphone.agentd");
        OPSQLiteBindText(statement, 4, taskId ?: @"");
        OPSQLiteBindText(statement, 5, title ?: @"");
        OPSQLiteBindText(statement, 6, body ?: @"");
        OPSQLiteBindText(statement, 7, OPJSONString(metadata ?: @{}));
        if (sqlite3_step(statement) == SQLITE_DONE) {
            eventId = sqlite3_last_insert_rowid(db);
        }
    }
    sqlite3_finalize(statement);

    if (eventId > 0 && OPSQLiteTableExists(db, @"context_event_fts")) {
        sqlite3_stmt *fts = NULL;
        if (sqlite3_prepare_v2(db,
                "INSERT INTO context_event_fts(event_id, title, body, type) VALUES(?, ?, ?, ?)",
                -1, &fts, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(fts, 1, eventId);
            OPSQLiteBindText(fts, 2, title ?: @"");
            OPSQLiteBindText(fts, 3, body ?: @"");
            OPSQLiteBindText(fts, 4, type ?: @"event");
            sqlite3_step(fts);
        }
        sqlite3_finalize(fts);
    }
    sqlite3_close(db);
    return eventId;
}

static NSString *OPExecutablePath(NSArray<NSString *> *candidates) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *candidate in candidates) {
        if ([fileManager isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

static NSDictionary *OPSpawn(NSArray<NSString *> *arguments) {
    if (arguments.count == 0) {
        return @{@"ok": @NO, @"reason": @"missing_command"};
    }
    char **argv = calloc(arguments.count + 1, sizeof(char *));
    if (!argv) {
        return @{@"ok": @NO, @"reason": @"calloc_failed"};
    }
    for (NSUInteger i = 0; i < arguments.count; i++) {
        NSString *argument = [arguments[i] isKindOfClass:[NSString class]] ? arguments[i] : @"";
        argv[i] = strdup(argument.UTF8String ?: "");
        if (!argv[i]) {
            for (NSUInteger j = 0; j < i; j++) {
                free(argv[j]);
            }
            free(argv);
            return @{@"ok": @NO, @"reason": @"strdup_failed"};
        }
    }
    argv[arguments.count] = NULL;

    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
    for (NSUInteger i = 0; i < arguments.count; i++) {
        free(argv[i]);
    }
    free(argv);
    if (spawnResult != 0) {
        return @{
            @"ok": @NO,
            @"reason": @"spawn_failed",
            @"errno": @(spawnResult),
            @"detail": [NSString stringWithUTF8String:strerror(spawnResult)]
        };
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return @{@"ok": @NO, @"reason": @"waitpid_failed", @"errno": @(errno)};
    }
    BOOL exited = WIFEXITED(status);
    int exitCode = exited ? WEXITSTATUS(status) : -1;
    return @{
        @"ok": @(exited && exitCode == 0),
        @"pid": @(pid),
        @"exit_code": @(exitCode),
        @"raw_status": @(status)
    };
}

static NSString *OPSpawnCapture(NSArray<NSString *> *arguments, NSUInteger maxBytes) {
    if (arguments.count == 0) {
        return nil;
    }
    int pipeFds[2];
    if (pipe(pipeFds) != 0) {
        return nil;
    }
    char **argv = calloc(arguments.count + 1, sizeof(char *));
    if (!argv) {
        close(pipeFds[0]);
        close(pipeFds[1]);
        return nil;
    }
    for (NSUInteger i = 0; i < arguments.count; i++) {
        NSString *argument = [arguments[i] isKindOfClass:[NSString class]] ? arguments[i] : @"";
        argv[i] = strdup(argument.UTF8String ?: "");
        if (!argv[i]) {
            for (NSUInteger j = 0; j < i; j++) {
                free(argv[j]);
            }
            free(argv);
            close(pipeFds[0]);
            close(pipeFds[1]);
            return nil;
        }
    }
    argv[arguments.count] = NULL;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipeFds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipeFds[0]);
    posix_spawn_file_actions_addclose(&actions, pipeFds[1]);

    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, argv[0], &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    for (NSUInteger i = 0; i < arguments.count; i++) {
        free(argv[i]);
    }
    free(argv);
    close(pipeFds[1]);

    if (spawnResult != 0) {
        close(pipeFds[0]);
        return nil;
    }

    NSMutableData *data = [NSMutableData data];
    char buffer[4096];
    while (data.length < maxBytes) {
        ssize_t count = read(pipeFds[0], buffer, sizeof(buffer));
        if (count > 0) {
            NSUInteger remaining = maxBytes - data.length;
            [data appendBytes:buffer length:MIN((NSUInteger)count, remaining)];
            continue;
        }
        break;
    }
    close(pipeFds[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString *OPForegroundBundleIdentifier(void) {
    typedef CFStringRef (*OPCopyFrontmostApplicationDisplayIdentifierFunc)(void);
    typedef mach_port_t (*OPSpringBoardServerPortFunc)(void);
    typedef void (*OPFrontmostApplicationDisplayIdentifierFunc)(mach_port_t port, char *result);
    static OPCopyFrontmostApplicationDisplayIdentifierFunc frontmostFunc = NULL;
    static OPSpringBoardServerPortFunc springBoardPortFunc = NULL;
    static OPFrontmostApplicationDisplayIdentifierFunc frontmostCStringFunc = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *frameworks = @[
            @"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            @"/var/jb/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        ];
        for (NSString *framework in frameworks) {
            void *handle = dlopen(framework.UTF8String, RTLD_LAZY);
            if (!handle) {
                continue;
            }
            frontmostFunc = (OPCopyFrontmostApplicationDisplayIdentifierFunc)dlsym(
                    handle, "SBSCopyFrontmostApplicationDisplayIdentifier");
            springBoardPortFunc = (OPSpringBoardServerPortFunc)dlsym(
                    handle, "SBSSpringBoardServerPort");
            frontmostCStringFunc = (OPFrontmostApplicationDisplayIdentifierFunc)dlsym(
                    handle, "SBFrontmostApplicationDisplayIdentifier");
            if (frontmostFunc || (springBoardPortFunc && frontmostCStringFunc)) {
                break;
            }
        }
    });
    if (frontmostFunc) {
        CFStringRef copied = frontmostFunc();
        if (copied) {
            NSString *identifier = CFBridgingRelease(copied);
            if ([identifier isKindOfClass:[NSString class]] && identifier.length > 0) {
                return identifier;
            }
        }
    }
    if (springBoardPortFunc && frontmostCStringFunc) {
        char result[512];
        memset(result, 0, sizeof(result));
        frontmostCStringFunc(springBoardPortFunc(), result);
        if (result[0] != '\0') {
            return [NSString stringWithUTF8String:result];
        }
    }
    return nil;
}

static NSArray<NSDictionary *> *OPRunningApplications(void) {
    NSString *output = OPSpawnCapture(@[@"/bin/ps", @"ax", @"-o", @"pid=", @"-o", @"comm="],
            128 * 1024);
    if (output.length == 0) {
        return @[];
    }
    NSMutableArray<NSDictionary *> *apps = [NSMutableArray array];
    NSArray<NSString *> *lines = [output componentsSeparatedByCharactersInSet:
            [NSCharacterSet newlineCharacterSet]];
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length == 0) {
            continue;
        }
        NSScanner *scanner = [NSScanner scannerWithString:line];
        int pid = 0;
        if (![scanner scanInt:&pid]) {
            continue;
        }
        NSString *path = [[line substringFromIndex:scanner.scanLocation]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSRange appRange = [path rangeOfString:@".app/" options:NSBackwardsSearch];
        if (appRange.location == NSNotFound) {
            continue;
        }
        NSString *appPath = [path substringToIndex:appRange.location + 4];
        NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath] ?: @{};
        NSString *bundleId = [info[@"CFBundleIdentifier"] isKindOfClass:[NSString class]]
                ? info[@"CFBundleIdentifier"] : nil;
        NSString *displayName = [info[@"CFBundleDisplayName"] isKindOfClass:[NSString class]]
                ? info[@"CFBundleDisplayName"] : nil;
        if (displayName.length == 0 && [info[@"CFBundleName"] isKindOfClass:[NSString class]]) {
            displayName = info[@"CFBundleName"];
        }
        if (bundleId.length == 0) {
            bundleId = [[appPath lastPathComponent] stringByDeletingPathExtension];
        }
        [apps addObject:@{
            @"pid": @(pid),
            @"bundle_id": bundleId ?: @"unknown",
            @"display_name": displayName ?: [[appPath lastPathComponent] stringByDeletingPathExtension],
            @"app_path": appPath,
            @"executable_path": path
        }];
    }
    [apps sortUsingDescriptors:@[
        [NSSortDescriptor sortDescriptorWithKey:@"pid" ascending:NO]
    ]];
    return apps;
}

static NSDictionary *OPApplicationInfoForPath(NSString *appPath) {
    NSString *infoPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath] ?: @{};
    NSString *bundleId = [info[@"CFBundleIdentifier"] isKindOfClass:[NSString class]]
            ? info[@"CFBundleIdentifier"] : nil;
    if (bundleId.length == 0) {
        return nil;
    }
    NSString *displayName = [info[@"CFBundleDisplayName"] isKindOfClass:[NSString class]]
            ? info[@"CFBundleDisplayName"] : nil;
    if (displayName.length == 0 && [info[@"CFBundleName"] isKindOfClass:[NSString class]]) {
        displayName = info[@"CFBundleName"];
    }
    NSString *executableName = [info[@"CFBundleExecutable"] isKindOfClass:[NSString class]]
            ? info[@"CFBundleExecutable"] : nil;
    NSMutableDictionary *app = [NSMutableDictionary dictionary];
    app[@"bundle_id"] = bundleId;
    app[@"display_name"] = displayName ?: [appPath.lastPathComponent stringByDeletingPathExtension];
    app[@"app_path"] = appPath;
    if (executableName.length > 0) {
        app[@"executable_path"] = [appPath stringByAppendingPathComponent:executableName];
    }
    NSString *bundleVersion = [info[@"CFBundleShortVersionString"] isKindOfClass:[NSString class]]
            ? info[@"CFBundleShortVersionString"] : nil;
    if (bundleVersion.length > 0) {
        app[@"version"] = bundleVersion;
    }
    return app;
}

static NSArray<NSDictionary *> *OPInstalledApplications(NSUInteger limit) {
    NSArray<NSString *> *roots = @[
        @"/Applications",
        @"/System/Applications",
        @"/System/Library/CoreServices",
        @"/var/jb/Applications",
        @"/var/containers/Bundle/Application"
    ];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableDictionary<NSString *, NSDictionary *> *appsByBundleId = [NSMutableDictionary dictionary];
    for (NSString *root in roots) {
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) {
            continue;
        }
        NSDirectoryEnumerator<NSString *> *enumerator = [fileManager enumeratorAtPath:root];
        for (NSString *relativePath in enumerator) {
            if (![relativePath.pathExtension isEqualToString:@"app"]) {
                continue;
            }
            NSString *appPath = [root stringByAppendingPathComponent:relativePath];
            NSDictionary *app = OPApplicationInfoForPath(appPath);
            NSString *bundleId = app[@"bundle_id"];
            if (bundleId.length > 0 && !appsByBundleId[bundleId]) {
                appsByBundleId[bundleId] = app;
            }
            [enumerator skipDescendants];
            if (limit > 0 && appsByBundleId.count >= limit) {
                break;
            }
        }
        if (limit > 0 && appsByBundleId.count >= limit) {
            break;
        }
    }
    NSMutableArray<NSDictionary *> *apps = [[appsByBundleId allValues] mutableCopy];
    [apps sortUsingDescriptors:@[
        [NSSortDescriptor sortDescriptorWithKey:@"display_name" ascending:YES selector:@selector(localizedCaseInsensitiveCompare:)]
    ]];
    return apps;
}

static NSData *OPLZFSEDecodedData(NSData *compressed) {
    if (compressed.length == 0) {
        return nil;
    }
    const uint8_t *input = compressed.bytes;
    size_t hintedSize = 0;
    if (compressed.length >= 8 && memcmp(input, "bvx2", 4) == 0) {
        hintedSize = (size_t)input[4]
                | ((size_t)input[5] << 8)
                | ((size_t)input[6] << 16)
                | ((size_t)input[7] << 24);
    }
    size_t outputSize = hintedSize > 0 ? hintedSize : MAX((size_t)4096, compressed.length * 8);
    const size_t maxOutputSize = 1024 * 1024;
    for (NSUInteger attempt = 0; attempt < 8 && outputSize <= maxOutputSize; attempt++) {
        NSMutableData *decoded = [NSMutableData dataWithLength:outputSize];
        size_t written = compression_decode_buffer(decoded.mutableBytes,
                decoded.length,
                input,
                compressed.length,
                NULL,
                COMPRESSION_LZFSE);
        if (written > 0 && written <= decoded.length) {
            decoded.length = written;
            return decoded;
        }
        if (hintedSize > 0) {
            break;
        }
        outputSize *= 2;
    }
    return nil;
}

static NSString *OPBundleIdentifierFromSceneIdentifier(NSString *value) {
    if (![value hasPrefix:@"sceneID:"]) {
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
    return identifier;
}

static BOOL OPBundleIdentifierLooksValid(NSString *value) {
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

static NSString *OPSafeFilenameForBundleId(NSString *bundleId) {
    if (![bundleId isKindOfClass:[NSString class]] || bundleId.length == 0) {
        return @"unknown";
    }
    NSMutableString *safe = [NSMutableString string];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    for (NSUInteger index = 0; index < bundleId.length; index++) {
        unichar ch = [bundleId characterAtIndex:index];
        if ([allowed characterIsMember:ch]) {
            [safe appendFormat:@"%C", ch];
        } else {
            [safe appendString:@"_"];
        }
    }
    return safe.length > 0 ? safe : @"unknown";
}

static NSString *OPAppUIStatePath(NSString *bundleId) {
    NSString *filename = [OPSafeFilenameForBundleId(bundleId)
            stringByAppendingPathExtension:@"json"];
    return [OPAppUIPath() stringByAppendingPathComponent:filename];
}

static NSDictionary *OPAppUIIntakeStatus(void) {
    return @{
        @"status": OPAppUIIntakeReady ? @"ready" :
                (OPAppUIIntakeThreadStarted ? @"starting_or_unavailable" : @"not_started"),
        @"provider": @"openphone-agentd.app_ui_intake",
        @"transport": @"tcp_loopback",
        @"host": @"127.0.0.1",
        @"port": @27631,
        @"thread_started": @(OPAppUIIntakeThreadStarted != 0),
        @"listen_ready": @(OPAppUIIntakeReady != 0),
        @"publish_count": @((unsigned long long)OPAppUIIntakePublishCount),
        @"last_publish_ms": @((long long)OPAppUIIntakeLastPublishMs),
        @"last_bundle_id": OPAppUIIntakeLastBundleId ?: @"",
        @"start_error": OPAppUIIntakeStartError ?: @""
    };
}

static NSDictionary *OPAppUIPublish(NSDictionary *request) {
    NSDictionary *state = [request[@"state"] isKindOfClass:[NSDictionary class]]
            ? request[@"state"] : nil;
    if (!state && [request[@"app_ui_state"] isKindOfClass:[NSDictionary class]]) {
        state = request[@"app_ui_state"];
    }
    if (!state && [request[@"schema"] isEqualToString:@"openphone.app_ui_state.v1"]) {
        state = request;
    }
    if (![state isKindOfClass:[NSDictionary class]]) {
        return OPError(@"app_ui_state_missing");
    }
    NSString *bundleId = [state[@"bundle_id"] isKindOfClass:[NSString class]]
            ? state[@"bundle_id"] : @"";
    if (!OPBundleIdentifierLooksValid(bundleId)) {
        return OPError(@"invalid_app_ui_bundle_id");
    }
    NSMutableDictionary *stored = [state mutableCopy];
    stored[@"schema"] = @"openphone.app_ui_state.v1";
    stored[@"status"] = stored[@"status"] ?: @"ok";
    stored[@"provider"] = stored[@"provider"] ?: @"OpenPhoneAppIntrospector.UIKitAccessibility";
    stored[@"bundle_id"] = bundleId;
    if (![stored[@"timestamp_ms"] respondsToSelector:@selector(longLongValue)]) {
        stored[@"timestamp_ms"] = @(OPNowMs());
    }
    stored[@"received_at_ms"] = @(OPNowMs());
    stored[@"received_transport"] = OPStringFromRequest(request, @"transport", @"daemon_command");
    stored[@"storage_owner"] = @"openphone-agentd";
    NSString *path = OPAppUIStatePath(bundleId);
    OPEnsureDirectories();
    BOOL ok = OPWriteProtectedJSONFile(path, stored);
    if (!ok) {
        return OPError(@"app_ui_state_write_failed");
    }
    @synchronized(@"OPAppUIIntakeMetrics") {
        OPAppUIIntakePublishCount++;
        OPAppUIIntakeLastPublishMs = OPNowMs();
        OPAppUIIntakeLastBundleId = [bundleId copy];
    }
    return @{
        @"status": @"ok",
        @"schema": @"openphone.app_ui_publish_result.v1",
        @"bundle_id": bundleId,
        @"path": path,
        @"ui_tree_status": [stored[@"ui_tree"] isKindOfClass:[NSDictionary class]]
                ? (stored[@"ui_tree"][@"status"] ?: @"unknown") : @"missing",
        @"source": @"openphone.agentd.app_ui_intake"
    };
}

static void OPEnsureAppInputRequests(void) {
    @synchronized(@"OPAppInputRequests") {
        if (!OPAppInputRequests) {
            OPAppInputRequests = [NSMutableDictionary dictionary];
        }
    }
}

static NSDictionary *OPAppInputPoll(NSDictionary *request) {
    NSString *bundleId = OPStringFromRequest(request, @"bundle_id", @"");
    NSString *pollScope = OPStringFromRequest(request, @"scope", @"");
    if (!OPBundleIdentifierLooksValid(bundleId)) {
        return OPError(@"invalid_app_input_bundle_id");
    }
    OPEnsureAppInputRequests();
    long long now = OPNowMs();
    @synchronized(@"OPAppInputRequests") {
        for (NSString *requestId in [OPAppInputRequests.allKeys copy]) {
            NSMutableDictionary *entry = OPAppInputRequests[requestId];
            long long expiresAtMs = [entry[@"expires_at_ms"] respondsToSelector:@selector(longLongValue)]
                    ? [entry[@"expires_at_ms"] longLongValue] : 0;
            if (expiresAtMs > 0 && expiresAtMs < now) {
                [OPAppInputRequests removeObjectForKey:requestId];
            }
        }
        for (NSString *requestId in [OPAppInputRequests.allKeys copy]) {
            NSMutableDictionary *entry = OPAppInputRequests[requestId];
            NSString *entryBundleId = [entry[@"bundle_id"] isKindOfClass:[NSString class]]
                    ? entry[@"bundle_id"] : @"";
            NSString *status = [entry[@"status"] isKindOfClass:[NSString class]]
                    ? entry[@"status"] : @"";
            NSDictionary *action = [entry[@"action"] isKindOfClass:[NSDictionary class]]
                    ? entry[@"action"] : @{};
            NSString *preferredScope = [action[@"preferred_input_scope"] isKindOfClass:[NSString class]]
                    ? action[@"preferred_input_scope"] : @"";
            if (preferredScope.length > 0 &&
                    (pollScope.length == 0 || ![preferredScope isEqualToString:pollScope])) {
                continue;
            }
            if ([entryBundleId isEqualToString:bundleId] && [status isEqualToString:@"pending"]) {
                entry[@"delivered_at_ms"] = @(now);
                return @{
                    @"status": @"ok",
                    @"schema": @"openphone.app_input_poll_result.v1",
                    @"provider": @"openphone-agentd.app_input_bridge",
                    @"request": [entry copy],
                    @"source": @"openphone.agentd.app_input"
                };
            }
        }
    }
    return @{
        @"status": @"idle",
        @"schema": @"openphone.app_input_poll_result.v1",
        @"provider": @"openphone-agentd.app_input_bridge",
        @"bundle_id": bundleId,
        @"source": @"openphone.agentd.app_input"
    };
}

static NSDictionary *OPAppInputComplete(NSDictionary *request) {
    NSString *requestId = OPStringFromRequest(request, @"request_id", @"");
    NSString *bundleId = OPStringFromRequest(request, @"bundle_id", @"");
    NSDictionary *response = [request[@"response"] isKindOfClass:[NSDictionary class]]
            ? request[@"response"] : @{};
    if (requestId.length == 0) {
        return OPError(@"missing_app_input_request_id");
    }
    if (!OPBundleIdentifierLooksValid(bundleId)) {
        return OPError(@"invalid_app_input_bundle_id");
    }
    OPEnsureAppInputRequests();
    @synchronized(@"OPAppInputRequests") {
        NSMutableDictionary *entry = OPAppInputRequests[requestId];
        if (![entry isKindOfClass:[NSMutableDictionary class]]) {
            return OPError(@"app_input_request_not_found");
        }
        NSString *entryBundleId = [entry[@"bundle_id"] isKindOfClass:[NSString class]]
                ? entry[@"bundle_id"] : @"";
        if (![entryBundleId isEqualToString:bundleId]) {
            return OPError(@"app_input_bundle_mismatch");
        }
        entry[@"status"] = @"completed";
        entry[@"completed_at_ms"] = @(OPNowMs());
        entry[@"response"] = response ?: @{};
    }
    return @{
        @"status": @"ok",
        @"schema": @"openphone.app_input_complete_result.v1",
        @"provider": @"openphone-agentd.app_input_bridge",
        @"request_id": requestId,
        @"bundle_id": bundleId,
        @"source": @"openphone.agentd.app_input"
    };
}

static NSDictionary *OPAppInputInfo(NSDictionary *action, NSString *bundleId) {
    NSString *actionType = [action[@"type"] isKindOfClass:[NSString class]]
            ? action[@"type"] : @"";
    if (!OPBundleIdentifierLooksValid(bundleId)) {
        return @{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneAppIntrospector.AppInput",
            @"reason": @"invalid_app_input_bundle_id",
            @"action_type": actionType,
            @"bundle_id": bundleId ?: @""
        };
    }
    long long timeoutMs = OPLongLongFromRequest(action, @"input_timeout_ms", 2500, 250, 5000);
    NSString *requestId = [NSString stringWithFormat:@"app-input-%lld-%d", OPNowMs(), getpid()];
    long long now = OPNowMs();
    NSMutableDictionary *entry = [@{
        @"schema": @"openphone.app_input_request.v1",
        @"status": @"pending",
        @"provider": @"openphone-agentd.app_input_bridge",
        @"request_id": requestId,
        @"bundle_id": bundleId,
        @"action": action ?: @{},
        @"created_at_ms": @(now),
        @"expires_at_ms": @(now + timeoutMs),
        @"timeout_ms": @(timeoutMs),
        @"source": @"openphone.agentd.input.perform"
    } mutableCopy];
    OPEnsureAppInputRequests();
    @synchronized(@"OPAppInputRequests") {
        OPAppInputRequests[requestId] = entry;
    }

    long long start = OPNowMs();
    while (OPNowMs() - start <= timeoutMs) {
        NSDictionary *response = nil;
        BOOL completed = NO;
        @synchronized(@"OPAppInputRequests") {
            NSMutableDictionary *current = OPAppInputRequests[requestId];
            NSString *status = [current[@"status"] isKindOfClass:[NSString class]]
                    ? current[@"status"] : @"";
            if ([status isEqualToString:@"completed"]) {
                response = [current[@"response"] isKindOfClass:[NSDictionary class]]
                        ? [current[@"response"] copy] : @{};
                [OPAppInputRequests removeObjectForKey:requestId];
                completed = YES;
            }
        }
        if (completed) {
            NSMutableDictionary *result = [response mutableCopy] ?: [NSMutableDictionary dictionary];
            result[@"provider"] = result[@"provider"] ?: @"OpenPhoneAppIntrospector.AppInput";
            result[@"request_id"] = requestId;
            result[@"bundle_id"] = bundleId;
            result[@"timeout_ms"] = @(timeoutMs);
            result[@"action_type"] = actionType ?: @"";
            result[@"source"] = result[@"source"] ?: @"app_process";
            return result;
        }
        usleep(100000);
    }

    @synchronized(@"OPAppInputRequests") {
        [OPAppInputRequests removeObjectForKey:requestId];
    }
    return @{
        @"status": @"unavailable",
        @"provider": @"OpenPhoneAppIntrospector.AppInput",
        @"reason": @"response_timeout",
        @"request_id": requestId,
        @"bundle_id": bundleId,
        @"action_type": actionType,
        @"timeout_ms": @(timeoutMs)
    };
}

static NSArray<NSString *> *OPBundleIdentifiersFromRecentLayoutData(NSData *data) {
    if (data.length == 0) {
        return @[];
    }
    const uint8_t *bytes = data.bytes;
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSUInteger i = 0;
    while (i < data.length) {
        uint8_t byte = bytes[i];
        if (byte < 32 || byte > 126) {
            i++;
            continue;
        }
        NSUInteger start = i;
        while (i < data.length && bytes[i] >= 32 && bytes[i] <= 126) {
            i++;
        }
        if (i - start < 3) {
            continue;
        }
        NSData *stringData = [NSData dataWithBytes:bytes + start length:i - start];
        NSString *candidate = [[NSString alloc] initWithData:stringData encoding:NSASCIIStringEncoding];
        if (candidate.length == 0) {
            continue;
        }
        NSString *bundleId = [candidate hasPrefix:@"sceneID:"]
                ? OPBundleIdentifierFromSceneIdentifier(candidate) : candidate;
        if (OPBundleIdentifierLooksValid(bundleId) && ![seen containsObject:bundleId]) {
            [seen addObject:bundleId];
            [identifiers addObject:bundleId];
        }
    }
    return identifiers;
}

static NSDictionary<NSString *, NSDictionary *> *OPInstalledAppsByBundleIdentifier(void) {
    NSMutableDictionary<NSString *, NSDictionary *> *appsByBundleId = [NSMutableDictionary dictionary];
    for (NSDictionary *app in OPInstalledApplications(0)) {
        NSString *bundleId = [app[@"bundle_id"] isKindOfClass:[NSString class]]
                ? app[@"bundle_id"] : nil;
        if (bundleId.length > 0) {
            appsByBundleId[bundleId] = app;
        }
    }
    return appsByBundleId;
}

static NSDictionary *OPSpringBoardRecentLayoutInfo(NSUInteger limit) {
    NSString *path = @"/var/mobile/Library/SpringBoard/RecentAppLayouts.pb.lzfse";
    NSData *compressed = [NSData dataWithContentsOfFile:path];
    if (compressed.length == 0) {
        return @{
            @"status": @"unavailable",
            @"provider": @"SpringBoard.RecentAppLayouts",
            @"reason": @"recent_layout_missing",
            @"path": path
        };
    }
    NSData *decoded = OPLZFSEDecodedData(compressed);
    if (decoded.length == 0) {
        return @{
            @"status": @"unavailable",
            @"provider": @"SpringBoard.RecentAppLayouts",
            @"reason": @"lzfse_decode_failed",
            @"path": path,
            @"compressed_bytes": @(compressed.length)
        };
    }

    NSArray<NSString *> *bundleIds = OPBundleIdentifiersFromRecentLayoutData(decoded);
    NSDictionary<NSString *, NSDictionary *> *installedApps = OPInstalledAppsByBundleIdentifier();
    NSMutableArray<NSDictionary *> *apps = [NSMutableArray array];
    NSUInteger count = 0;
    for (NSString *bundleId in bundleIds) {
        NSDictionary *installed = installedApps[bundleId];
        NSMutableDictionary *entry = [@{
            @"bundle_id": bundleId,
            @"rank": @(count),
            @"source": @"SpringBoard.RecentAppLayouts"
        } mutableCopy];
        NSString *displayName = [installed[@"display_name"] isKindOfClass:[NSString class]]
                ? installed[@"display_name"] : nil;
        NSString *appPath = [installed[@"app_path"] isKindOfClass:[NSString class]]
                ? installed[@"app_path"] : nil;
        if (displayName.length > 0) {
            entry[@"display_name"] = displayName;
        }
        if (appPath.length > 0) {
            entry[@"app_path"] = appPath;
        }
        [apps addObject:entry];
        count++;
        if (limit > 0 && count >= limit) {
            break;
        }
    }

    return @{
        @"status": apps.count > 0 ? @"ok" : @"empty",
        @"provider": @"SpringBoard.RecentAppLayouts",
        @"path": path,
        @"compressed_bytes": @(compressed.length),
        @"decoded_bytes": @(decoded.length),
        @"apps": apps,
        @"count": @(apps.count),
        @"first_bundle_id": apps.count > 0 ? apps[0][@"bundle_id"] : @""
    };
}

static NSDictionary *OPSpringBoardPublishedState(void) {
    NSString *path = OPSpringBoardStatePath();
    NSDictionary *state = OPReadJSONFile(path);
    if (!state) {
        return @{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneVolumeTrigger.SpringBoardState",
            @"path": path,
            @"reason": @"state_missing"
        };
    }
    long long now = OPNowMs();
    long long timestamp = 0;
    id timestampValue = state[@"timestamp_ms"];
    if ([timestampValue respondsToSelector:@selector(longLongValue)]) {
        timestamp = [timestampValue longLongValue];
    }
    long long age = timestamp > 0 ? MAX(0, now - timestamp) : 9223372036854775807LL;
    NSMutableDictionary *result = [state mutableCopy];
    result[@"status"] = age <= 30000 ? @"ok" : @"stale";
    result[@"provider"] = result[@"provider"] ?: @"OpenPhoneVolumeTrigger.SpringBoardState";
    result[@"path"] = path;
    result[@"age_ms"] = @(age);
    if (age > 30000) {
        result[@"reason"] = @"state_stale";
    } else {
        NSString *publishedForeground = [result[@"foreground_app"] isKindOfClass:[NSString class]]
                ? result[@"foreground_app"] : @"";
        NSString *servicesForeground = OPForegroundBundleIdentifier();
        if (publishedForeground.length == 0 &&
                OPBundleIdentifierLooksValid(servicesForeground) &&
                ![servicesForeground isEqualToString:@"com.apple.springboard"]) {
            result[@"foreground_app"] = servicesForeground;
            result[@"foreground_source"] = @"agentd_springboardservices_enriched";
            result[@"foreground_enriched"] = @YES;
            result[@"foreground_enrichment_source"] = @"SpringBoardServices";
        }
    }
    return result;
}

static NSDictionary *OPSpringBoardTriggerStatus(void) {
    NSString *path = OPSpringBoardTriggerStatusPath();
    NSDictionary *state = OPReadJSONFile(path);
    if (!state) {
        return @{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneVolumeTrigger.SpringBoardVolumeHooks",
            @"path": path,
            @"reason": @"trigger_status_missing"
        };
    }
    long long now = OPNowMs();
    long long timestamp = 0;
    id timestampValue = state[@"timestamp_ms"];
    if ([timestampValue respondsToSelector:@selector(longLongValue)]) {
        timestamp = [timestampValue longLongValue];
    }
    long long age = timestamp > 0 ? MAX(0, now - timestamp) : 9223372036854775807LL;
    NSMutableDictionary *result = [state mutableCopy];
    NSString *publishedStatus = [result[@"status"] isKindOfClass:[NSString class]]
            ? result[@"status"] : @"unknown";
    result[@"status"] = age <= 30000 ? publishedStatus : @"stale";
    result[@"provider"] = result[@"provider"] ?: @"OpenPhoneVolumeTrigger.SpringBoardVolumeHooks";
    result[@"path"] = path;
    result[@"age_ms"] = @(age);
    if (age > 30000) {
        result[@"reason"] = @"trigger_status_stale";
    }
    return result;
}

static NSDictionary *OPAppUIPublishedState(NSString *foregroundBundleId) {
    NSString *bundleId = [foregroundBundleId isKindOfClass:[NSString class]]
            ? foregroundBundleId : @"";
    NSString *path = OPAppUIStatePath(bundleId);
    if (!OPBundleIdentifierLooksValid(bundleId)) {
        return @{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneAppIntrospector.UIKitAccessibility",
            @"path": path,
            @"reason": @"foreground_bundle_unavailable"
        };
    }
    NSDictionary *state = OPReadJSONFile(path);
    if (!state) {
        return @{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneAppIntrospector.UIKitAccessibility",
            @"bundle_id": bundleId,
            @"path": path,
            @"reason": @"state_missing"
        };
    }
    NSString *publishedBundleId = [state[@"bundle_id"] isKindOfClass:[NSString class]]
            ? state[@"bundle_id"] : @"";
    NSMutableDictionary *result = [state mutableCopy];
    result[@"provider"] = result[@"provider"] ?: @"OpenPhoneAppIntrospector.UIKitAccessibility";
    result[@"path"] = path;
    if (![publishedBundleId isEqualToString:bundleId]) {
        result[@"status"] = @"unavailable";
        result[@"reason"] = @"bundle_mismatch";
        result[@"requested_bundle_id"] = bundleId;
        return result;
    }
    long long now = OPNowMs();
    long long timestamp = 0;
    id timestampValue = state[@"timestamp_ms"];
    if ([timestampValue respondsToSelector:@selector(longLongValue)]) {
        timestamp = [timestampValue longLongValue];
    }
    long long age = timestamp > 0 ? MAX(0, now - timestamp) : 9223372036854775807LL;
    result[@"age_ms"] = @(age);
    long long receivedAt = [state[@"received_at_ms"] respondsToSelector:@selector(longLongValue)]
            ? [state[@"received_at_ms"] longLongValue] : 0;
    NSString *applicationState = [state[@"application_state_name"] isKindOfClass:[NSString class]]
            ? state[@"application_state_name"] : @"unknown";
    NSDictionary *uiTree = [state[@"ui_tree"] isKindOfClass:[NSDictionary class]]
            ? state[@"ui_tree"] : @{};
    if (OPProcessStartMs > 0 && receivedAt > 0 && receivedAt < OPProcessStartMs) {
        // Published by a prior daemon process (before this restart). Even if the
        // timestamp is recent, the UI may have changed while we were down, so a
        // resumed task must force a fresh observation rather than trust it.
        result[@"status"] = @"stale";
        result[@"reason"] = @"state_pre_restart";
    } else if (age > 10000) {
        result[@"status"] = @"stale";
        result[@"reason"] = @"state_stale";
    } else if ([applicationState isEqualToString:@"background"]) {
        result[@"status"] = @"unavailable";
        result[@"reason"] = @"app_background";
    } else if (![uiTree[@"status"] isEqualToString:@"ok"]) {
        result[@"status"] = @"unavailable";
        result[@"reason"] = @"ui_tree_unavailable";
    } else {
        result[@"status"] = @"ok";
    }
    return result;
}

static NSDictionary *OPScreenDisplayInfo(void) {
    typedef CGSize (*OPGSMainScreenPixelSizeFunc)(void);
    typedef CGSize (*OPGSMainScreenPointSizeFunc)(void);
    typedef float (*OPGSMainScreenScaleFactorFunc)(void);
    typedef int (*OPGSMainScreenOrientationFunc)(void);
    typedef CGSize (*OPGSMainScreenSizeFunc)(void);
    static OPGSMainScreenPixelSizeFunc pixelSizeFunc = NULL;
    static OPGSMainScreenPointSizeFunc pointSizeFunc = NULL;
    static OPGSMainScreenScaleFactorFunc scaleFactorFunc = NULL;
    static OPGSMainScreenOrientationFunc orientationFunc = NULL;
    static OPGSMainScreenSizeFunc screenSizeFunc = NULL;
    static BOOL loaded = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *frameworks = @[
            @"/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
            @"/var/jb/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices"
        ];
        for (NSString *framework in frameworks) {
            void *handle = dlopen(framework.UTF8String, RTLD_LAZY);
            if (!handle) {
                continue;
            }
            loaded = YES;
            pixelSizeFunc = (OPGSMainScreenPixelSizeFunc)dlsym(handle, "GSMainScreenPixelSize");
            pointSizeFunc = (OPGSMainScreenPointSizeFunc)dlsym(handle, "GSMainScreenPointSize");
            scaleFactorFunc = (OPGSMainScreenScaleFactorFunc)dlsym(handle, "GSMainScreenScaleFactor");
            orientationFunc = (OPGSMainScreenOrientationFunc)dlsym(handle, "GSMainScreenOrientation");
            screenSizeFunc = (OPGSMainScreenSizeFunc)dlsym(handle, "GSMainScreenSize");
            if (pixelSizeFunc || pointSizeFunc || scaleFactorFunc || orientationFunc || screenSizeFunc) {
                break;
            }
        }
    });
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"status"] = loaded ? @"available" : @"unavailable";
    info[@"provider"] = @"GraphicsServices";
    NSNumber *pixelWidth = nil;
    NSNumber *pixelHeight = nil;
    NSNumber *pointWidth = nil;
    NSNumber *pointHeight = nil;
    if (pixelSizeFunc) {
        CGSize size = pixelSizeFunc();
        pixelWidth = @((double)size.width);
        pixelHeight = @((double)size.height);
        info[@"pixel_width"] = pixelWidth;
        info[@"pixel_height"] = pixelHeight;
    }
    if (pointSizeFunc) {
        CGSize size = pointSizeFunc();
        pointWidth = @((double)size.width);
        pointHeight = @((double)size.height);
        info[@"point_width"] = pointWidth;
        info[@"point_height"] = pointHeight;
    }
    if (screenSizeFunc) {
        CGSize size = screenSizeFunc();
        info[@"screen_width"] = @((double)size.width);
        info[@"screen_height"] = @((double)size.height);
    }
    if (scaleFactorFunc) {
        float scale = scaleFactorFunc();
        if (scale >= 0.5f && scale <= 10.0f) {
            info[@"scale"] = @((double)scale);
        }
    }
    if (!info[@"scale"] && pixelWidth.doubleValue > 0.0 && pointWidth.doubleValue > 0.0) {
        info[@"scale"] = @(pixelWidth.doubleValue / pointWidth.doubleValue);
    }
    if (orientationFunc) {
        int orientation = orientationFunc();
        NSString *name = nil;
        switch (orientation) {
            case 1:
                name = @"portrait";
                break;
            case 2:
                name = @"portrait_upside_down";
                break;
            case 3:
                name = @"landscape_left";
                break;
            case 4:
                name = @"landscape_right";
                break;
            default:
                break;
        }
        if (name) {
            info[@"orientation"] = @(orientation);
            info[@"orientation_name"] = name;
        }
    }
    return info;
}

static NSDictionary *OPScreenLockInfo(void) {
    typedef mach_port_t (*OPSpringBoardServerPortFunc)(void);
    typedef void (*OPSBGetScreenLockStatusFunc)(mach_port_t port, BOOL *lockStatus, BOOL *passcodeEnabled);
    static OPSpringBoardServerPortFunc springBoardPortFunc = NULL;
    static OPSBGetScreenLockStatusFunc lockStatusFunc = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *frameworks = @[
            @"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            @"/var/jb/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        ];
        for (NSString *framework in frameworks) {
            void *handle = dlopen(framework.UTF8String, RTLD_LAZY);
            if (!handle) {
                continue;
            }
            springBoardPortFunc = (OPSpringBoardServerPortFunc)dlsym(handle, "SBSSpringBoardServerPort");
            lockStatusFunc = (OPSBGetScreenLockStatusFunc)dlsym(handle, "SBGetScreenLockStatus");
            if (springBoardPortFunc && lockStatusFunc) {
                break;
            }
        }
    });
    if (!springBoardPortFunc || !lockStatusFunc) {
        return @{
            @"status": @"unavailable",
            @"provider": @"SpringBoardServices",
            @"reason": @"SBGetScreenLockStatus_missing"
        };
    }
    mach_port_t port = springBoardPortFunc();
    if (port == MACH_PORT_NULL) {
        return @{
            @"status": @"unavailable",
            @"provider": @"SpringBoardServices",
            @"reason": @"springboard_port_missing"
        };
    }
    BOOL locked = NO;
    BOOL passcodeEnabled = NO;
    lockStatusFunc(port, &locked, &passcodeEnabled);
    return @{
        @"status": @"available",
        @"provider": @"SpringBoardServices.SBGetScreenLockStatus",
        @"locked": @(locked),
        @"passcode_enabled": @(passcodeEnabled)
    };
}

typedef CFTypeRef OPHIDEventSystemClientRef;
typedef CFTypeRef OPHIDEventRef;
typedef CFTypeRef OPHIDEventQueueRef;
typedef OPHIDEventSystemClientRef (*OPIOHIDEventSystemClientCreateFunc)(CFAllocatorRef allocator);
typedef OPHIDEventSystemClientRef (*OPIOHIDEventSystemClientCreateSimpleClientFunc)(CFAllocatorRef allocator);
typedef void (*OPIOHIDEventSystemClientActivateFunc)(OPHIDEventSystemClientRef client);
typedef void (*OPIOHIDEventSystemClientDispatchEventFunc)(OPHIDEventSystemClientRef client, OPHIDEventRef event);
typedef void (*OPIOHIDEventSystemClientEventCallback)(void *target, void *refcon,
        OPHIDEventQueueRef queue, OPHIDEventRef event);
typedef void (*OPIOHIDEventSystemClientRegisterEventCallbackFunc)(
        OPHIDEventSystemClientRef client, OPIOHIDEventSystemClientEventCallback callback,
        void *target, void *refcon);
typedef void (*OPIOHIDEventSystemClientScheduleWithRunLoopFunc)(
        OPHIDEventSystemClientRef client, CFRunLoopRef runLoop, CFStringRef mode);
typedef uint32_t (*OPIOHIDEventGetTypeFunc)(OPHIDEventRef event);
typedef int (*OPIOHIDEventGetIntegerValueFunc)(OPHIDEventRef event, uint32_t field);
typedef OPHIDEventRef (*OPIOHIDEventCreateDigitizerEventFunc)(CFAllocatorRef allocator,
        uint64_t timestamp, uint32_t type, uint32_t index, uint32_t identity,
        uint32_t eventMask, uint32_t buttonMask, double x, double y, double z,
        double tipPressure, double barrelPressure, Boolean range, Boolean touch,
        uint32_t options);
typedef OPHIDEventRef (*OPIOHIDEventCreateDigitizerFingerEventFunc)(CFAllocatorRef allocator,
        uint64_t timestamp, uint32_t index, uint32_t identity, uint32_t eventMask,
        double x, double y, double z, double tipPressure, double twist,
        Boolean range, Boolean touch, uint32_t options);
typedef OPHIDEventRef (*OPIOHIDEventCreateKeyboardEventFunc)(CFAllocatorRef allocator,
        uint64_t timestamp, uint16_t usagePage, uint16_t usage, Boolean down,
        uint32_t options);
typedef void (*OPIOHIDEventAppendEventFunc)(OPHIDEventRef parent, OPHIDEventRef child);

static const uint32_t OPIOHIDDigitizerTransducerTypeHand = 0x23;
static const uint32_t OPIOHIDDigitizerEventRange = 0x00000001;
static const uint32_t OPIOHIDDigitizerEventTouch = 0x00000002;
static const uint32_t OPIOHIDDigitizerEventPosition = 0x00000004;
static const uint32_t OPIOHIDDigitizerEventIdentity = 0x00000020;
static const uint32_t OPIOHIDDigitizerEventStart = 0x00000100;
static const uint32_t OPIOHIDDigitizerEventStop = 0x00000008;
static const uint32_t OPIOHIDEventOptionIsAbsolute = 0x00000001;
static const uint32_t OPIOHIDEventTypeKeyboard = 3;
static const uint32_t OPIOHIDEventFieldKeyboardUsagePage = (OPIOHIDEventTypeKeyboard << 16);
static const uint32_t OPIOHIDEventFieldKeyboardUsage = (OPIOHIDEventTypeKeyboard << 16) + 1;
static const uint32_t OPIOHIDEventFieldKeyboardDown = (OPIOHIDEventTypeKeyboard << 16) + 2;
static const uint32_t OPIOHIDUsagePageConsumer = 0x0c;
static const uint32_t OPIOHIDUsageConsumerVolumeIncrement = 0xe9;
static const uint32_t OPIOHIDUsageConsumerVolumeDecrement = 0xea;

static BOOL OPHIDLoaded = NO;
static BOOL OPHIDLoadAttempted = NO;
static BOOL OPHIDClientAttempted = NO;
static NSMutableArray<NSString *> *OPHIDMissingSymbols = nil;
static NSMutableArray<NSString *> *OPHIDClientErrors = nil;
static OPHIDEventSystemClientRef OPHIDClient = NULL;
static OPIOHIDEventSystemClientCreateFunc OPHIDCreateClient = NULL;
static OPIOHIDEventSystemClientCreateSimpleClientFunc OPHIDCreateSimpleClient = NULL;
static OPIOHIDEventSystemClientActivateFunc OPHIDActivateClient = NULL;
static OPIOHIDEventSystemClientDispatchEventFunc OPHIDDispatchEvent = NULL;
static OPIOHIDEventSystemClientRegisterEventCallbackFunc OPHIDRegisterEventCallback = NULL;
static OPIOHIDEventSystemClientScheduleWithRunLoopFunc OPHIDScheduleWithRunLoop = NULL;
static OPIOHIDEventGetTypeFunc OPHIDEventGetType = NULL;
static OPIOHIDEventGetIntegerValueFunc OPHIDEventGetIntegerValue = NULL;
static OPIOHIDEventCreateDigitizerEventFunc OPHIDCreateDigitizerEvent = NULL;
static OPIOHIDEventCreateDigitizerFingerEventFunc OPHIDCreateFingerEvent = NULL;
static OPIOHIDEventCreateKeyboardEventFunc OPHIDCreateKeyboardEvent = NULL;
static OPIOHIDEventAppendEventFunc OPHIDAppendEvent = NULL;

static void OPEnsureHIDInputLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        OPHIDLoadAttempted = YES;
        OPHIDMissingSymbols = [NSMutableArray array];
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
            [OPHIDMissingSymbols addObject:@"IOKit.framework"];
            return;
        }
        OPHIDCreateClient = (OPIOHIDEventSystemClientCreateFunc)dlsym(
                handle, "IOHIDEventSystemClientCreate");
        OPHIDCreateSimpleClient = (OPIOHIDEventSystemClientCreateSimpleClientFunc)dlsym(
                handle, "IOHIDEventSystemClientCreateSimpleClient");
        OPHIDActivateClient = (OPIOHIDEventSystemClientActivateFunc)dlsym(
                handle, "IOHIDEventSystemClientActivate");
        OPHIDDispatchEvent = (OPIOHIDEventSystemClientDispatchEventFunc)dlsym(
                handle, "IOHIDEventSystemClientDispatchEvent");
        OPHIDRegisterEventCallback = (OPIOHIDEventSystemClientRegisterEventCallbackFunc)dlsym(
                handle, "IOHIDEventSystemClientRegisterEventCallback");
        OPHIDScheduleWithRunLoop = (OPIOHIDEventSystemClientScheduleWithRunLoopFunc)dlsym(
                handle, "IOHIDEventSystemClientScheduleWithRunLoop");
        OPHIDEventGetType = (OPIOHIDEventGetTypeFunc)dlsym(handle, "IOHIDEventGetType");
        OPHIDEventGetIntegerValue = (OPIOHIDEventGetIntegerValueFunc)dlsym(
                handle, "IOHIDEventGetIntegerValue");
        OPHIDCreateDigitizerEvent = (OPIOHIDEventCreateDigitizerEventFunc)dlsym(
                handle, "IOHIDEventCreateDigitizerEvent");
        OPHIDCreateFingerEvent = (OPIOHIDEventCreateDigitizerFingerEventFunc)dlsym(
                handle, "IOHIDEventCreateDigitizerFingerEvent");
        OPHIDCreateKeyboardEvent = (OPIOHIDEventCreateKeyboardEventFunc)dlsym(
                handle, "IOHIDEventCreateKeyboardEvent");
        OPHIDAppendEvent = (OPIOHIDEventAppendEventFunc)dlsym(handle, "IOHIDEventAppendEvent");

        if (!OPHIDCreateSimpleClient && !OPHIDCreateClient) {
            [OPHIDMissingSymbols addObject:@"IOHIDEventSystemClientCreate"];
        }
        if (!OPHIDDispatchEvent) {
            [OPHIDMissingSymbols addObject:@"IOHIDEventSystemClientDispatchEvent"];
        }
        if (!OPHIDCreateFingerEvent) {
            [OPHIDMissingSymbols addObject:@"IOHIDEventCreateDigitizerFingerEvent"];
        }
        OPHIDLoaded = OPHIDMissingSymbols.count == 0;
    });
}

static BOOL OPEnsureHIDClient(void) {
    OPEnsureHIDInputLoaded();
    if (!OPHIDLoaded) {
        return NO;
    }
    if (OPHIDClient) {
        return YES;
    }
    if (!OPHIDClientErrors) {
        OPHIDClientErrors = [NSMutableArray array];
    }
    OPHIDClientAttempted = YES;
    OPHIDClient = OPHIDCreateSimpleClient
            ? OPHIDCreateSimpleClient(kCFAllocatorDefault)
            : OPHIDCreateClient(kCFAllocatorDefault);
    if (!OPHIDClient) {
        [OPHIDClientErrors addObject:@"IOHIDEventSystemClient"];
        return NO;
    }
    return YES;
}

static NSDictionary *OPHIDInputProviderInfo(void) {
    OPEnsureHIDInputLoaded();
    return @{
        @"available": @(OPHIDLoaded),
        @"provider": @"IOKit.IOHIDEventSystemClient",
        @"attempted": @(OPHIDLoadAttempted),
        @"client_attempted": @(OPHIDClientAttempted),
        @"client_created": @(OPHIDClient != NULL),
        @"keyboard_available": @(OPHIDCreateKeyboardEvent != NULL),
        @"missing": OPHIDMissingSymbols ?: @[],
        @"client_errors": OPHIDClientErrors ?: @[]
    };
}

static BOOL OPHIDCoordinatesAreReasonable(double x, double y) {
    if (!isfinite(x) || !isfinite(y) || x < 0.0 || y < 0.0) {
        return NO;
    }
    NSDictionary *display = OPScreenDisplayInfo();
    double pointWidth = [display[@"point_width"] doubleValue];
    double pointHeight = [display[@"point_height"] doubleValue];
    double pixelWidth = [display[@"pixel_width"] doubleValue];
    double pixelHeight = [display[@"pixel_height"] doubleValue];
    double maxWidth = MAX(pointWidth, pixelWidth);
    double maxHeight = MAX(pointHeight, pixelHeight);
    if (maxWidth <= 0.0 || maxHeight <= 0.0) {
        return YES;
    }
    return x <= maxWidth * 1.1 && y <= maxHeight * 1.1;
}

static NSDictionary *OPDispatchHIDDigitizer(double x, double y, BOOL range, BOOL touch,
        uint32_t eventMask) {
    NSDictionary *provider = OPHIDInputProviderInfo();
    if (![provider[@"available"] boolValue]) {
        return @{
            @"ok": @NO,
            @"reason": @"iohid_provider_unavailable",
            @"provider": provider
        };
    }
    if (!OPEnsureHIDClient()) {
        return @{
            @"ok": @NO,
            @"reason": @"iohid_client_unavailable",
            @"provider": OPHIDInputProviderInfo()
        };
    }
    if (!OPHIDCoordinatesAreReasonable(x, y)) {
        return @{
            @"ok": @NO,
            @"reason": @"coordinates_out_of_range",
            @"x": @(x),
            @"y": @(y),
            @"provider": provider
        };
    }

    uint64_t timestamp = mach_absolute_time();
    OPHIDEventRef finger = OPHIDCreateFingerEvent(kCFAllocatorDefault, timestamp,
            1, 2, eventMask, x, y, 0.0, touch ? 1.0 : 0.0, 0.0,
            range, touch, OPIOHIDEventOptionIsAbsolute);
    if (!finger) {
        return @{
            @"ok": @NO,
            @"reason": @"finger_event_create_failed",
            @"provider": provider
        };
    }

    OPHIDEventRef eventToDispatch = finger;
    OPHIDEventRef hand = NULL;
    if (OPHIDCreateDigitizerEvent && OPHIDAppendEvent) {
        hand = OPHIDCreateDigitizerEvent(kCFAllocatorDefault, timestamp,
                OPIOHIDDigitizerTransducerTypeHand, 0, 1, eventMask, 0,
                x, y, 0.0, touch ? 1.0 : 0.0, 0.0, range, touch,
                OPIOHIDEventOptionIsAbsolute);
        if (hand) {
            OPHIDAppendEvent(hand, finger);
            eventToDispatch = hand;
        }
    }

    OPHIDDispatchEvent(OPHIDClient, eventToDispatch);
    if (hand) {
        CFRelease(hand);
    }
    CFRelease(finger);
    return @{
        @"ok": @YES,
        @"provider": provider[@"provider"] ?: @"IOKit.IOHIDEventSystemClient",
        @"x": @(x),
        @"y": @(y),
        @"range": @(range),
        @"touch": @(touch),
        @"event_mask": @(eventMask)
    };
}

static NSDictionary *OPPerformHIDTap(double x, double y, long holdMs) {
    holdMs = MAX(20, MIN(holdMs, 5000));
    uint32_t downMask = OPIOHIDDigitizerEventRange |
            OPIOHIDDigitizerEventTouch |
            OPIOHIDDigitizerEventPosition |
            OPIOHIDDigitizerEventIdentity |
            OPIOHIDDigitizerEventStart;
    NSDictionary *down = OPDispatchHIDDigitizer(x, y, YES, YES, downMask);
    if (![down[@"ok"] boolValue]) {
        return down;
    }
    usleep((useconds_t)(holdMs * 1000));
    uint32_t upMask = OPIOHIDDigitizerEventRange |
            OPIOHIDDigitizerEventTouch |
            OPIOHIDDigitizerEventPosition |
            OPIOHIDDigitizerEventStop;
    NSDictionary *up = OPDispatchHIDDigitizer(x, y, NO, NO, upMask);
    BOOL ok = [up[@"ok"] boolValue];
    return @{
        @"ok": @(ok),
        @"provider": @"IOKit.IOHIDEventSystemClient",
        @"kind": holdMs >= 500 ? @"long_press" : @"tap",
        @"x": @(x),
        @"y": @(y),
        @"duration_ms": @(holdMs),
        @"down": down,
        @"up": up
    };
}

static NSDictionary *OPPerformHIDSwipe(double startX, double startY, double endX, double endY,
        long durationMs) {
    durationMs = MAX(50, MIN(durationMs, 5000));
    if (!OPHIDCoordinatesAreReasonable(startX, startY) ||
            !OPHIDCoordinatesAreReasonable(endX, endY)) {
        return @{
            @"ok": @NO,
            @"reason": @"coordinates_out_of_range",
            @"start_x": @(startX),
            @"start_y": @(startY),
            @"end_x": @(endX),
            @"end_y": @(endY),
            @"provider": OPHIDInputProviderInfo()
        };
    }
    uint32_t downMask = OPIOHIDDigitizerEventRange |
            OPIOHIDDigitizerEventTouch |
            OPIOHIDDigitizerEventPosition |
            OPIOHIDDigitizerEventIdentity |
            OPIOHIDDigitizerEventStart;
    NSDictionary *down = OPDispatchHIDDigitizer(startX, startY, YES, YES, downMask);
    if (![down[@"ok"] boolValue]) {
        return down;
    }
    NSMutableArray<NSDictionary *> *moves = [NSMutableArray array];
    int steps = 8;
    long stepDelayUs = (durationMs * 1000) / steps;
    for (int step = 1; step < steps; step++) {
        double t = (double)step / (double)steps;
        double x = startX + ((endX - startX) * t);
        double y = startY + ((endY - startY) * t);
        NSDictionary *move = OPDispatchHIDDigitizer(x, y, YES, YES,
                OPIOHIDDigitizerEventPosition);
        [moves addObject:move];
        if (![move[@"ok"] boolValue]) {
            return @{
                @"ok": @NO,
                @"reason": @"move_event_failed",
                @"failed_move": move,
                @"moves": moves,
                @"provider": @"IOKit.IOHIDEventSystemClient"
            };
        }
        usleep((useconds_t)stepDelayUs);
    }
    uint32_t upMask = OPIOHIDDigitizerEventRange |
            OPIOHIDDigitizerEventTouch |
            OPIOHIDDigitizerEventPosition |
            OPIOHIDDigitizerEventStop;
    NSDictionary *up = OPDispatchHIDDigitizer(endX, endY, NO, NO, upMask);
    BOOL ok = [up[@"ok"] boolValue];
    return @{
        @"ok": @(ok),
        @"provider": @"IOKit.IOHIDEventSystemClient",
        @"kind": @"swipe",
        @"start_x": @(startX),
        @"start_y": @(startY),
        @"end_x": @(endX),
        @"end_y": @(endY),
        @"duration_ms": @(durationMs),
        @"steps": @(steps),
        @"down": down,
        @"moves": moves,
        @"up": up
    };
}

static NSDictionary *OPDispatchHIDKeyboardUsage(uint16_t usage, BOOL down) {
    NSDictionary *provider = OPHIDInputProviderInfo();
    if (!OPHIDCreateKeyboardEvent) {
        return @{
            @"ok": @NO,
            @"reason": @"keyboard_event_create_missing",
            @"provider": provider
        };
    }
    if (![provider[@"available"] boolValue]) {
        return @{
            @"ok": @NO,
            @"reason": @"iohid_provider_unavailable",
            @"provider": provider
        };
    }
    if (!OPEnsureHIDClient()) {
        return @{
            @"ok": @NO,
            @"reason": @"iohid_client_unavailable",
            @"provider": OPHIDInputProviderInfo()
        };
    }

    OPHIDEventRef event = OPHIDCreateKeyboardEvent(kCFAllocatorDefault,
            mach_absolute_time(), 0x07, usage, down, 0);
    if (!event) {
        return @{
            @"ok": @NO,
            @"reason": @"keyboard_event_create_failed",
            @"usage": @(usage),
            @"down": @(down),
            @"provider": provider
        };
    }
    OPHIDDispatchEvent(OPHIDClient, event);
    CFRelease(event);
    return @{
        @"ok": @YES,
        @"provider": provider[@"provider"] ?: @"IOKit.IOHIDEventSystemClient",
        @"usage_page": @0x07,
        @"usage": @(usage),
        @"down": @(down)
    };
}

static NSDictionary *OPTapHIDKeyboardUsage(uint16_t usage) {
    NSDictionary *down = OPDispatchHIDKeyboardUsage(usage, YES);
    if (![down[@"ok"] boolValue]) {
        return down;
    }
    usleep(12000);
    NSDictionary *up = OPDispatchHIDKeyboardUsage(usage, NO);
    return @{
        @"ok": @([up[@"ok"] boolValue]),
        @"provider": @"IOKit.IOHIDEventSystemClient",
        @"usage": @(usage),
        @"down": down,
        @"up": up
    };
}

static BOOL OPKeyboardUsageForCharacter(unichar c, uint16_t *usage, BOOL *shift) {
    *shift = NO;
    if (c >= 'a' && c <= 'z') {
        *usage = (uint16_t)(0x04 + (c - 'a'));
        return YES;
    }
    if (c >= 'A' && c <= 'Z') {
        *usage = (uint16_t)(0x04 + (c - 'A'));
        *shift = YES;
        return YES;
    }
    if (c >= '1' && c <= '9') {
        *usage = (uint16_t)(0x1e + (c - '1'));
        return YES;
    }
    if (c == '0') {
        *usage = 0x27;
        return YES;
    }
    switch (c) {
        case '\n':
        case '\r':
            *usage = 0x28;
            return YES;
        case '\t':
            *usage = 0x2b;
            return YES;
        case ' ':
            *usage = 0x2c;
            return YES;
        case '-':
            *usage = 0x2d;
            return YES;
        case '_':
            *usage = 0x2d;
            *shift = YES;
            return YES;
        case '=':
            *usage = 0x2e;
            return YES;
        case '+':
            *usage = 0x2e;
            *shift = YES;
            return YES;
        case '[':
            *usage = 0x2f;
            return YES;
        case '{':
            *usage = 0x2f;
            *shift = YES;
            return YES;
        case ']':
            *usage = 0x30;
            return YES;
        case '}':
            *usage = 0x30;
            *shift = YES;
            return YES;
        case '\\':
            *usage = 0x31;
            return YES;
        case '|':
            *usage = 0x31;
            *shift = YES;
            return YES;
        case ';':
            *usage = 0x33;
            return YES;
        case ':':
            *usage = 0x33;
            *shift = YES;
            return YES;
        case '\'':
            *usage = 0x34;
            return YES;
        case '"':
            *usage = 0x34;
            *shift = YES;
            return YES;
        case '`':
            *usage = 0x35;
            return YES;
        case '~':
            *usage = 0x35;
            *shift = YES;
            return YES;
        case ',':
            *usage = 0x36;
            return YES;
        case '<':
            *usage = 0x36;
            *shift = YES;
            return YES;
        case '.':
            *usage = 0x37;
            return YES;
        case '>':
            *usage = 0x37;
            *shift = YES;
            return YES;
        case '/':
            *usage = 0x38;
            return YES;
        case '?':
            *usage = 0x38;
            *shift = YES;
            return YES;
        case '!':
            *usage = 0x1e;
            *shift = YES;
            return YES;
        case '@':
            *usage = 0x1f;
            *shift = YES;
            return YES;
        case '#':
            *usage = 0x20;
            *shift = YES;
            return YES;
        case '$':
            *usage = 0x21;
            *shift = YES;
            return YES;
        case '%':
            *usage = 0x22;
            *shift = YES;
            return YES;
        case '^':
            *usage = 0x23;
            *shift = YES;
            return YES;
        case '&':
            *usage = 0x24;
            *shift = YES;
            return YES;
        case '*':
            *usage = 0x25;
            *shift = YES;
            return YES;
        case '(':
            *usage = 0x26;
            *shift = YES;
            return YES;
        case ')':
            *usage = 0x27;
            *shift = YES;
            return YES;
        default:
            return NO;
    }
}

static NSDictionary *OPPerformHIDTypeText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
        return @{@"ok": @NO, @"reason": @"missing_text"};
    }
    NSUInteger maxLength = MIN(text.length, (NSUInteger)4096);
    NSUInteger typed = 0;
    NSMutableArray<NSNumber *> *unsupported = [NSMutableArray array];
    for (NSUInteger i = 0; i < maxLength; i++) {
        unichar c = [text characterAtIndex:i];
        uint16_t usage = 0;
        BOOL shift = NO;
        if (!OPKeyboardUsageForCharacter(c, &usage, &shift)) {
            [unsupported addObject:@(c)];
            continue;
        }
        if (shift) {
            NSDictionary *shiftDown = OPDispatchHIDKeyboardUsage(0xe1, YES);
            if (![shiftDown[@"ok"] boolValue]) {
                return shiftDown;
            }
            usleep(6000);
        }
        NSDictionary *key = OPTapHIDKeyboardUsage(usage);
        if (shift) {
            NSDictionary *shiftUp = OPDispatchHIDKeyboardUsage(0xe1, NO);
            if (![shiftUp[@"ok"] boolValue]) {
                return shiftUp;
            }
        }
        if (![key[@"ok"] boolValue]) {
            return key;
        }
        typed += 1;
        usleep(12000);
    }
    return @{
        @"ok": @(unsupported.count == 0 && typed > 0),
        @"provider": @"IOKit.IOHIDEventSystemClient",
        @"kind": @"type_text",
        @"requested_length": @(text.length),
        @"attempted_length": @(maxLength),
        @"typed_characters": @(typed),
        @"unsupported_characters": @(unsupported.count),
        @"truncated": @(text.length > maxLength)
    };
}

typedef struct {
    BOOL loaded;
    BOOL hasWake;
    BOOL hasHome;
    BOOL hasCoordinateInput;
    BOOL hasTextInput;
} OPInputProviderStatus;

static OPInputProviderStatus OPInputStatus(void) {
    typedef void (*OPSBSUndimScreenFunc)(void);
    typedef mach_port_t (*OPSpringBoardServerPortFunc)(void);
    typedef void (*OPGSSendSimpleEventFunc)(int type, mach_port_t port);
    static BOOL loaded = NO;
    static OPSBSUndimScreenFunc undimFunc = NULL;
    static OPSpringBoardServerPortFunc springBoardPortFunc = NULL;
    static OPGSSendSimpleEventFunc sendSimpleEventFunc = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *springBoardFrameworks = @[
            @"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            @"/var/jb/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        ];
        for (NSString *framework in springBoardFrameworks) {
            void *handle = dlopen(framework.UTF8String, RTLD_LAZY);
            if (!handle) {
                continue;
            }
            loaded = YES;
            undimFunc = (OPSBSUndimScreenFunc)dlsym(handle, "SBSUndimScreen");
            springBoardPortFunc = (OPSpringBoardServerPortFunc)dlsym(handle, "SBSSpringBoardServerPort");
            if (undimFunc || springBoardPortFunc) {
                break;
            }
        }

        NSArray<NSString *> *graphicsFrameworks = @[
            @"/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
            @"/var/jb/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices"
        ];
        for (NSString *framework in graphicsFrameworks) {
            void *handle = dlopen(framework.UTF8String, RTLD_LAZY);
            if (!handle) {
                continue;
            }
            loaded = YES;
            sendSimpleEventFunc = (OPGSSendSimpleEventFunc)dlsym(handle, "GSSendSimpleEvent");
            if (sendSimpleEventFunc) {
                break;
            }
        }
    });
    return (OPInputProviderStatus){
        .loaded = loaded,
        .hasWake = undimFunc != NULL,
        .hasHome = springBoardPortFunc != NULL && sendSimpleEventFunc != NULL,
        .hasCoordinateInput = [OPHIDInputProviderInfo()[@"available"] boolValue],
        .hasTextInput = [OPHIDInputProviderInfo()[@"available"] boolValue] &&
                [OPHIDInputProviderInfo()[@"keyboard_available"] boolValue]
    };
}

static NSDictionary *OPWakeScreen(void) {
    typedef void (*OPSBSUndimScreenFunc)(void);
    static OPSBSUndimScreenFunc undimFunc = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *frameworks = @[
            @"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            @"/var/jb/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        ];
        for (NSString *framework in frameworks) {
            void *handle = dlopen(framework.UTF8String, RTLD_LAZY);
            if (!handle) {
                continue;
            }
            undimFunc = (OPSBSUndimScreenFunc)dlsym(handle, "SBSUndimScreen");
            if (undimFunc) {
                break;
            }
        }
    });
    if (!undimFunc) {
        return @{@"ok": @NO, @"reason": @"SBSUndimScreen_missing"};
    }
    undimFunc();
    return @{@"ok": @YES, @"provider": @"SpringBoardServices.SBSUndimScreen"};
}

static NSDictionary *OPPressHome(void) {
    typedef mach_port_t (*OPSpringBoardServerPortFunc)(void);
    typedef void (*OPGSSendSimpleEventFunc)(int type, mach_port_t port);
    static OPSpringBoardServerPortFunc springBoardPortFunc = NULL;
    static OPGSSendSimpleEventFunc sendSimpleEventFunc = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *springBoardFrameworks = @[
            @"/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            @"/var/jb/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices"
        ];
        for (NSString *framework in springBoardFrameworks) {
            void *handle = dlopen(framework.UTF8String, RTLD_LAZY);
            if (!handle) {
                continue;
            }
            springBoardPortFunc = (OPSpringBoardServerPortFunc)dlsym(handle, "SBSSpringBoardServerPort");
            if (springBoardPortFunc) {
                break;
            }
        }

        NSArray<NSString *> *graphicsFrameworks = @[
            @"/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices",
            @"/var/jb/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices"
        ];
        for (NSString *framework in graphicsFrameworks) {
            void *handle = dlopen(framework.UTF8String, RTLD_LAZY);
            if (!handle) {
                continue;
            }
            sendSimpleEventFunc = (OPGSSendSimpleEventFunc)dlsym(handle, "GSSendSimpleEvent");
            if (sendSimpleEventFunc) {
                break;
            }
        }
    });
    if (!springBoardPortFunc) {
        return @{@"ok": @NO, @"reason": @"SBSSpringBoardServerPort_missing"};
    }
    if (!sendSimpleEventFunc) {
        return @{@"ok": @NO, @"reason": @"GSSendSimpleEvent_missing"};
    }
    mach_port_t port = springBoardPortFunc();
    if (port == MACH_PORT_NULL) {
        return @{@"ok": @NO, @"reason": @"springboard_port_missing"};
    }
    sendSimpleEventFunc(1000, port);
    usleep(80000);
    sendSimpleEventFunc(1001, port);
    return @{@"ok": @YES, @"provider": @"GraphicsServices.GSSendSimpleEvent", @"port": @(port)};
}

static NSDictionary *OPUiOpen(NSArray<NSString *> *uiopenArguments) {
    NSString *uiopen = OPExecutablePath(@[
        @"/var/jb/usr/bin/uiopen",
        @"/var/jb/bin/uiopen",
        @"/usr/bin/uiopen"
    ]);
    if (!uiopen) {
        return @{@"ok": @NO, @"reason": @"uiopen_missing"};
    }
    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObject:uiopen];
    [arguments addObjectsFromArray:uiopenArguments];
    return OPSpawn(arguments);
}

static BOOL OPBoolFromRequest(NSDictionary *request, NSString *key, BOOL defaultValue) {
    id value = request[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *lower = [(NSString *)value lowercaseString];
        if ([lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"]
                || [lower isEqualToString:@"1"]) {
            return YES;
        }
        if ([lower isEqualToString:@"false"] || [lower isEqualToString:@"no"]
                || [lower isEqualToString:@"0"]) {
            return NO;
        }
    }
    return defaultValue;
}

static NSDictionary *OPVolumeTriggerPreferences(void) {
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:OPVolumeTriggerPreferencesPath];
    return [preferences isKindOfClass:[NSDictionary class]] ? preferences : @{};
}

static NSString *OPVolumeTriggerGoalFromPreferences(NSDictionary *preferences) {
    NSString *goal = OPStringFromRequest(preferences ?: @{}, @"TriggerGoal",
            OPDefaultHardwareTriggerGoal);
    goal = [goal stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (goal.length == 0 || [goal isEqualToString:OPLegacyHardwareTriggerGoal]) {
        return OPDefaultHardwareTriggerGoal;
    }
    return goal;
}

static long long OPVolumeTriggerWindowMs(NSDictionary *preferences) {
    return OPLongLongFromRequest(preferences ?: @{}, @"WindowMs", 1200, 100, 5000);
}

static long long OPVolumeTriggerCooldownMs(NSDictionary *preferences) {
    return OPLongLongFromRequest(preferences ?: @{}, @"CooldownMs", 10000, 0, 60000);
}

static NSDictionary *OPDefaultModelConfig(void) {
    return @{
        @"schema": @"openphone.model_config.v1",
        @"enabled": @NO,
        @"mode": @"broker",
        @"endpoint_url": @"",
        @"model": @"",
        @"region": @"us-east-1",
        @"timeout_ms": @30000,
        @"max_steps": @5,
        @"max_duration_ms": @120000,
        @"credential_required": @YES,
        @"credential_source": @"external"
    };
}

static BOOL OPModelModeIsOpenAIRealtime(NSString *mode) {
    return [mode isEqualToString:@"openai_realtime"] ||
            [mode isEqualToString:@"openai_realtime2"];
}

static NSString *OPModelDefaultModelForMode(NSString *mode) {
    if ([mode isEqualToString:@"openai_realtime2"]) {
        return OPOpenAIRealtime2Model;
    }
    if ([mode isEqualToString:@"openai_realtime"]) {
        return OPOpenAIRealtimeModel;
    }
    return @"";
}

static NSString *OPModelEffectiveModel(NSDictionary *config) {
    NSString *model = [config[@"model"] isKindOfClass:[NSString class]]
            ? config[@"model"] : @"";
    if (model.length > 0) {
        return model;
    }
    NSString *mode = [config[@"mode"] isKindOfClass:[NSString class]]
            ? config[@"mode"] : @"broker";
    return OPModelDefaultModelForMode(mode);
}

static BOOL OPModelModeHasDefaultEndpoint(NSString *mode) {
    return [mode isEqualToString:@"bedrock_converse"] ||
            OPModelModeIsOpenAIRealtime(mode);
}

static BOOL OPModelModeIsValid(NSString *mode) {
    return [mode isEqualToString:@"broker"] ||
            [mode isEqualToString:@"direct_dev"] ||
            [mode isEqualToString:@"bedrock_converse"] ||
            OPModelModeIsOpenAIRealtime(mode);
}

static NSDictionary *OPModelConfig(void) {
    NSMutableDictionary *config = [OPDefaultModelConfig() mutableCopy];
    NSDictionary *stored = OPReadJSONFile(OPModelConfigPath());
    if ([stored isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in stored) {
            if (!OPSensitiveKey(key) && stored[key]) {
                config[key] = stored[key];
            }
        }
    }
    NSString *mode = [config[@"mode"] isKindOfClass:[NSString class]]
            ? [config[@"mode"] lowercaseString] : @"broker";
    if (!OPModelModeIsValid(mode)) {
        mode = @"broker";
    }
    config[@"mode"] = mode;
    NSString *region = [config[@"region"] isKindOfClass:[NSString class]]
            ? config[@"region"] : @"us-east-1";
    config[@"region"] = region.length > 0 ? region : @"us-east-1";
    long long timeoutMs = OPLongLongFromRequest(config, @"timeout_ms", 30000, 1000, 120000);
    long long maxSteps = OPLongLongFromRequest(config, @"max_steps", 5, 1, 120);
    long long maxDurationMs = OPLongLongFromRequest(config, @"max_duration_ms", 120000, 1000, 3300000);
    config[@"timeout_ms"] = @(timeoutMs);
    config[@"max_steps"] = @(maxSteps);
    config[@"max_duration_ms"] = @(maxDurationMs);
    config[@"model"] = OPModelEffectiveModel(config) ?: @"";
    config[@"enabled"] = @(OPBoolFromRequest(config, @"enabled", NO));
    BOOL credentialRequired = OPBoolFromRequest(config, @"credential_required", YES);
    if (OPModelModeIsOpenAIRealtime(mode)) {
        credentialRequired = YES;
    }
    config[@"credential_required"] = @(credentialRequired);
    return config;
}

static NSDictionary *OPDefaultAgentControlConfig(void) {
    return @{
        @"schema": @"openphone.agent_control.v1",
        @"autonomy_mode": @"yolo",
        @"yolo_enabled": @YES,
        @"hardware_triggers_enabled": @YES,
        @"paused": @NO,
        @"pause_reason": @"",
        @"updated_at_ms": @0,
        @"updated_by": @"default"
    };
}

static NSDictionary *OPAgentControlConfig(void) {
    NSMutableDictionary *config = [OPDefaultAgentControlConfig() mutableCopy];
    NSDictionary *stored = OPReadJSONFile(OPAgentControlPath());
    if ([stored isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in stored) {
            if (!OPSensitiveKey(key) && stored[key]) {
                config[key] = stored[key];
            }
        }
    }
    NSString *mode = [config[@"autonomy_mode"] isKindOfClass:[NSString class]]
            ? [config[@"autonomy_mode"] lowercaseString] : @"yolo";
    if (![mode isEqualToString:@"yolo"] && ![mode isEqualToString:@"reviewed"] &&
            ![mode isEqualToString:@"dry_run"]) {
        mode = @"yolo";
    }
    config[@"schema"] = @"openphone.agent_control.v1";
    config[@"autonomy_mode"] = mode;
    config[@"yolo_enabled"] = @(OPBoolFromRequest(config, @"yolo_enabled", YES));
    config[@"hardware_triggers_enabled"] = @(OPBoolFromRequest(config, @"hardware_triggers_enabled", YES));
    config[@"paused"] = @(OPBoolFromRequest(config, @"paused", NO));
    if (![config[@"pause_reason"] isKindOfClass:[NSString class]]) {
        config[@"pause_reason"] = @"";
    }
    if (![config[@"updated_by"] isKindOfClass:[NSString class]]) {
        config[@"updated_by"] = @"unknown";
    }
    long long updatedAt = [config[@"updated_at_ms"] respondsToSelector:@selector(longLongValue)]
            ? [config[@"updated_at_ms"] longLongValue] : 0;
    config[@"updated_at_ms"] = @(MAX(0, updatedAt));
    return config;
}

static NSDictionary *OPAgentControlSummary(void) {
    NSDictionary *config = OPAgentControlConfig();
    BOOL paused = [config[@"paused"] boolValue];
    BOOL yoloEnabled = [config[@"yolo_enabled"] boolValue];
    BOOL hardwareTriggersEnabled = [config[@"hardware_triggers_enabled"] boolValue];
    NSString *state = paused ? @"paused"
            : ((yoloEnabled && hardwareTriggersEnabled) ? @"running" : @"limited");
    NSString *triggerPolicy = paused ? @"paused"
            : (!hardwareTriggersEnabled ? @"disabled"
            : (!yoloEnabled ? @"manual_only" : @"allow_yolo"));
    return @{
        @"schema": @"openphone.agent_control.v1",
        @"state": state,
        @"autonomy_mode": config[@"autonomy_mode"] ?: @"yolo",
        @"yolo_enabled": @(yoloEnabled),
        @"hardware_triggers_enabled": @(hardwareTriggersEnabled),
        @"paused": @(paused),
        @"pause_reason": config[@"pause_reason"] ?: @"",
        @"trigger_policy": triggerPolicy,
        @"updated_at_ms": config[@"updated_at_ms"] ?: @0,
        @"updated_by": config[@"updated_by"] ?: @"unknown",
        @"config_path": OPAgentControlPath(),
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPModelCredentialStatus(void) {
    const char *envToken = getenv("OPENPHONE_MODEL_BEARER_TOKEN");
    BOOL envPresent = envToken && envToken[0] != '\0';
    BOOL credentialFilePresent = [[NSFileManager defaultManager] fileExistsAtPath:OPModelCredentialPath()];
    return @{
        @"status": (envPresent || credentialFilePresent) ? @"present" : @"missing",
        @"source": envPresent ? @"env" : (credentialFilePresent ? @"credential_file" : @"none"),
        @"env_present": @(envPresent),
        @"credential_file": OPModelCredentialPath(),
        @"credential_file_present": @(credentialFilePresent)
    };
}

static NSString *OPModelCredentialValue(void) {
    const char *envToken = getenv("OPENPHONE_MODEL_BEARER_TOKEN");
    if (envToken && envToken[0] != '\0') {
        return [NSString stringWithUTF8String:envToken] ?: @"";
    }
    NSData *data = [NSData dataWithContentsOfFile:OPModelCredentialPath()];
    if (!data) {
        return @"";
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) {
        return @"";
    }
    NSData *jsonData = [text dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : nil;
    if ([parsed isKindOfClass:[NSDictionary class]]) {
        NSDictionary *object = parsed;
        for (NSString *key in @[@"credential", @"bearer", @"value"]) {
            if ([object[key] isKindOfClass:[NSString class]] && [object[key] length] > 0) {
                return object[key];
            }
        }
        return @"";
    }
    return text;
}

static NSDictionary *OPModelStatusDictionary(void) {
    NSDictionary *config = OPModelConfig();
    NSString *endpoint = [config[@"endpoint_url"] isKindOfClass:[NSString class]]
            ? config[@"endpoint_url"] : @"";
    NSString *model = [config[@"model"] isKindOfClass:[NSString class]]
            ? config[@"model"] : @"";
    NSString *mode = [config[@"mode"] isKindOfClass:[NSString class]]
            ? config[@"mode"] : @"broker";
    NSDictionary *credential = OPModelCredentialStatus();
    BOOL enabled = [config[@"enabled"] boolValue];
    BOOL credentialRequired = [config[@"credential_required"] boolValue];
    BOOL endpointConfigured = OPModelModeHasDefaultEndpoint(mode) ? YES : endpoint.length > 0;
    BOOL configured = OPModelModeHasDefaultEndpoint(mode)
            ? model.length > 0 : (endpoint.length > 0 && model.length > 0);
    BOOL credentialReady = ![credential[@"status"] isEqualToString:@"missing"];
    BOOL ready = enabled && configured && (!credentialRequired || credentialReady);
    return @{
        @"status": ready ? @"ready" : (enabled ? @"configured_incomplete" : @"disabled"),
        @"schema": @"openphone.model_status.v1",
        @"enabled": @(enabled),
        @"mode": mode ?: @"broker",
        @"endpoint_configured": @(endpointConfigured),
        @"endpoint_url_configured": @(endpoint.length > 0),
        @"model_configured": @(model.length > 0),
        @"model": model ?: @"",
        @"region": config[@"region"] ?: @"us-east-1",
        @"timeout_ms": config[@"timeout_ms"] ?: @30000,
        @"max_steps": config[@"max_steps"] ?: @5,
        @"max_duration_ms": config[@"max_duration_ms"] ?: @120000,
        @"screenshot_max_dimension_px": config[@"screenshot_max_dimension_px"] ?: @1024,
        @"screenshot_jpeg_quality_x100": config[@"screenshot_jpeg_quality_x100"] ?: @60,
        @"credential_required": @(credentialRequired),
        @"credential": credential,
        @"config_path": OPModelConfigPath(),
        @"runtime_authority": @"openphone-agentd",
        @"notes": @"Broker/direct/realtime credentials are external only; credential values are never included in status, audit, or trajectory.",
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPModelStatus(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSDictionary *status = OPModelStatusDictionary();
    OPRecordAudit(@"model_status_read", taskId, @"tasks.observe", @"allow_task_scoped",
            @{}, status[@"status"] ?: @"unknown");
    return status;
}

static NSDictionary *OPModelConfigure(NSDictionary *request) {
    for (NSString *key in request) {
        if (OPSensitiveKey(key)) {
            return OPError(@"inline_model_credential_rejected");
        }
    }
    NSString *mode = [OPStringFromRequest(request, @"mode", @"broker") lowercaseString];
    if (!OPModelModeIsValid(mode)) {
        return OPError(@"invalid_model_mode");
    }
    NSString *endpoint = OPStringFromRequest(request, @"endpoint_url", @"");
    NSString *model = OPStringFromRequest(request, @"model", @"");
    NSString *region = OPStringFromRequest(request, @"region", @"us-east-1");
    long long timeoutMs = OPLongLongFromRequest(request, @"timeout_ms", 30000, 1000, 120000);
    if (model.length == 0) {
        model = OPModelDefaultModelForMode(mode);
    }
    long long maxSteps = OPLongLongFromRequest(request, @"max_steps", 5, 1, 120);
    long long maxDurationMs = OPLongLongFromRequest(request, @"max_duration_ms", 120000, 1000, 3300000);
    BOOL credentialRequired = OPBoolFromRequest(request, @"credential_required", YES);
    if (OPModelModeIsOpenAIRealtime(mode)) {
        credentialRequired = YES;
    }
    // Preserve screenshot tuning across model config writes: the screenshot
    // path reads these keys from model config, so a config write that dropped
    // them would silently reset the values.
    NSDictionary *existingModelConfig = OPModelConfig();
    long long screenshotMaxDim = OPLongLongFromRequest(request, @"screenshot_max_dimension_px",
            OPLongLongFromRequest(existingModelConfig, @"screenshot_max_dimension_px", 1024, 0, 4096),
            0, 4096);
    long long screenshotQuality = OPLongLongFromRequest(request, @"screenshot_jpeg_quality_x100",
            OPLongLongFromRequest(existingModelConfig, @"screenshot_jpeg_quality_x100", 60, 1, 100),
            1, 100);
    BOOL defaultEnabled = OPModelModeHasDefaultEndpoint(mode)
            ? model.length > 0 : (endpoint.length > 0 && model.length > 0);
    NSDictionary *config = @{
        @"schema": @"openphone.model_config.v1",
        @"enabled": @(OPBoolFromRequest(request, @"enabled", defaultEnabled)),
        @"mode": mode,
        @"endpoint_url": endpoint ?: @"",
        @"model": model ?: @"",
        @"region": region.length > 0 ? region : @"us-east-1",
        @"timeout_ms": @(timeoutMs),
        @"max_steps": @(maxSteps),
        @"max_duration_ms": @(maxDurationMs),
        @"screenshot_max_dimension_px": @(screenshotMaxDim),
        @"screenshot_jpeg_quality_x100": @(screenshotQuality),
        @"credential_required": @(credentialRequired),
        @"credential_source": @"external",
        @"updated_at_ms": @(OPNowMs())
    };
    BOOL ok = OPWriteProtectedJSONFile(OPModelConfigPath(), config);
    if (!ok) {
        return OPError(@"model_config_write_failed");
    }
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    OPRecordAudit(@"model_configured", taskId, @"tasks.observe", @"allow_yolo",
            OPRedactedObject(request ?: @{}, 0), [NSString stringWithFormat:@"mode:%@", mode]);
    return OPModelStatusDictionary();
}

static NSDictionary *OPJSONDictionaryFromString(NSString *string) {
    if (string.length == 0) {
        return nil;
    }
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static NSString *OPScreenshotHelperPath(void) {
    return OPExecutablePath(@[
        @"/var/jb/usr/local/bin/openphone-screencap-helper",
        @"/usr/local/bin/openphone-screencap-helper"
    ]);
}

static NSDictionary *OPScreenshotHelperStatus(void) {
    NSString *helper = OPScreenshotHelperPath();
    return @{
        @"status": helper ? @"implemented_experimental" : @"not_installed",
        @"provider": @"openphone-screencap-helper",
        @"path": helper ?: @"",
        @"fallback_provider": @"OpenPhoneVolumeTrigger.SpringBoardScreenshot",
        @"fallback_request_path": OPSpringBoardScreenshotRequestPath(),
        @"fallback_response_path": OPSpringBoardScreenshotResponsePath(),
        @"bytes_returned": @"never",
        @"storage": OPScreenshotsPath()
    };
}

static NSDictionary *OPScreenshotProviderSummary(NSDictionary *info) {
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"provider", @"status", @"reason", @"path", @"helper"]) {
        id value = info[key];
        if (value) {
            summary[key] = value;
        }
    }
    id kernReturn = info[@"kern_return"];
    if (kernReturn) {
        summary[@"kern_return"] = kernReturn;
    }
    return summary.count > 0 ? summary : @{};
}

static NSDictionary *OPSpringBoardScreenshotBridgeInfo(void) {
    NSDictionary *state = OPSpringBoardPublishedState();
    if (![state[@"status"] isEqualToString:@"ok"]) {
        return @{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneVolumeTrigger.SpringBoardScreenshot",
            @"reason": state[@"reason"] ?: @"springboard_state_unavailable",
            @"springboard_state_status": state[@"status"] ?: @"unknown"
        };
    }
    NSDictionary *bridge = [state[@"screenshot_bridge"] isKindOfClass:[NSDictionary class]]
            ? state[@"screenshot_bridge"] : @{};
    if (![bridge[@"status"] isEqualToString:@"ready"]) {
        return @{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneVolumeTrigger.SpringBoardScreenshot",
            @"reason": @"springboard_screenshot_bridge_not_ready",
            @"springboard_state_status": state[@"status"] ?: @"unknown",
            @"bridge_status": bridge[@"status"] ?: @"missing"
        };
    }
    NSMutableDictionary *result = [bridge mutableCopy];
    result[@"provider"] = result[@"provider"] ?: @"OpenPhoneVolumeTrigger.SpringBoardScreenshot";
    return result;
}

static NSDictionary *OPSpringBoardScreenshotInfo(NSDictionary *request,
        NSString *path,
        NSDictionary *fallbackFrom) {
    NSDictionary *bridge = OPSpringBoardScreenshotBridgeInfo();
    if (![bridge[@"status"] isEqualToString:@"ready"]) {
        NSMutableDictionary *unavailable = [@{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneVolumeTrigger.SpringBoardScreenshot",
            @"reason": bridge[@"reason"] ?: @"springboard_screenshot_bridge_unavailable",
            @"path": path ?: @"",
            @"bytes_returned": @"never",
            @"storage": OPScreenshotsPath(),
            @"fallback_from": OPScreenshotProviderSummary(fallbackFrom ?: @{})
        } mutableCopy];
        unavailable[@"bridge"] = bridge ?: @{};
        return unavailable;
    }

    NSString *requestId = [NSString stringWithFormat:@"screenshot-%lld-%d", OPNowMs(), getpid()];
    NSString *requestPath = OPSpringBoardScreenshotRequestPath();
    NSString *responsePath = OPSpringBoardScreenshotResponsePath();
    long long timeoutMs = OPLongLongFromRequest(request, @"screenshot_timeout_ms", 1800, 250, 5000);
    NSDictionary *modelConfig = OPModelConfig();
    long long maxDimension = OPLongLongFromRequest(request, @"screenshot_max_dimension_px",
            OPLongLongFromRequest(modelConfig, @"screenshot_max_dimension_px", 1024, 0, 4096),
            0, 4096);
    long long jpegQualityX100 = OPLongLongFromRequest(request, @"screenshot_jpeg_quality_x100",
            OPLongLongFromRequest(modelConfig, @"screenshot_jpeg_quality_x100", 60, 10, 100),
            10, 100);
    NSDictionary *payload = @{
        @"schema": @"openphone.springboard_screenshot_request.v1",
        @"request_id": requestId,
        @"timestamp_ms": @(OPNowMs()),
        @"provider": @"openphone.agentd",
        @"path": path ?: @"",
        @"timeout_ms": @(timeoutMs),
        @"max_dimension_px": @(maxDimension),
        @"jpeg_quality_x100": @(jpegQualityX100),
        @"source": @"openphone.agentd.screen.screenshot"
    };
    if (!OPWriteJSONFile(requestPath, payload)) {
        return @{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneVolumeTrigger.SpringBoardScreenshot",
            @"reason": @"request_write_failed",
            @"path": path ?: @"",
            @"request_path": requestPath,
            @"bytes_returned": @"never",
            @"storage": OPScreenshotsPath(),
            @"fallback_from": OPScreenshotProviderSummary(fallbackFrom ?: @{})
        };
    }
    chmod(requestPath.UTF8String, 0600);

    long long start = OPNowMs();
    while (OPNowMs() - start <= timeoutMs) {
        NSDictionary *response = OPReadJSONFile(responsePath);
        NSString *responseRequestId = [response[@"request_id"] isKindOfClass:[NSString class]]
                ? response[@"request_id"] : @"";
        if ([responseRequestId isEqualToString:requestId]) {
            NSMutableDictionary *result = [response mutableCopy];
            result[@"provider"] = result[@"provider"] ?: @"OpenPhoneVolumeTrigger.SpringBoardScreenshot";
            result[@"path"] = [result[@"path"] isKindOfClass:[NSString class]] ? result[@"path"] : path ?: @"";
            result[@"request_path"] = requestPath;
            result[@"response_path"] = responsePath;
            result[@"bytes_returned"] = @"never";
            result[@"storage"] = OPScreenshotsPath();
            result[@"fallback_from"] = OPScreenshotProviderSummary(fallbackFrom ?: @{});
            if ([result[@"status"] isEqualToString:@"ok"]) {
                NSString *resultPath = [result[@"path"] isKindOfClass:[NSString class]]
                        ? result[@"path"] : @"";
                NSData *png = [NSData dataWithContentsOfFile:resultPath];
                if (png.length == 0) {
                    result[@"status"] = @"unavailable";
                    result[@"reason"] = @"springboard_screenshot_file_missing";
                } else {
                    if (!result[@"bytes"]) {
                        result[@"bytes"] = @(png.length);
                    }
                    if (!result[@"sha256"]) {
                        result[@"sha256"] = OPSHA256Hex(png);
                    }
                }
            }
            return result;
        }
        usleep(100000);
    }

    return @{
        @"status": @"unavailable",
        @"provider": @"OpenPhoneVolumeTrigger.SpringBoardScreenshot",
        @"reason": @"response_timeout",
        @"request_id": requestId,
        @"path": path ?: @"",
        @"request_path": requestPath,
        @"response_path": responsePath,
        @"timeout_ms": @(timeoutMs),
        @"bytes_returned": @"never",
        @"storage": OPScreenshotsPath(),
        @"fallback_from": OPScreenshotProviderSummary(fallbackFrom ?: @{})
    };
}

// Trim the screenshots directory when it grows too large. Kept small so that
// disk-write pressure (jetsam bug_type 145) and simple disk usage stay in check.
static void OPPruneScreenshotsDir(NSUInteger keepCount) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = OPScreenshotsPath();
    NSError *err = nil;
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:dir error:&err];
    if (!files || files.count <= keepCount) {
        return;
    }
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *name in files) {
        NSString *lower = [name lowercaseString];
        if (![lower hasSuffix:@".png"] && ![lower hasSuffix:@".jpg"]
                && ![lower hasSuffix:@".jpeg"]) {
            continue;
        }
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        if (!attrs) {
            continue;
        }
        NSDate *modified = attrs.fileModificationDate ?: attrs.fileCreationDate ?: [NSDate distantPast];
        [entries addObject:@{@"path": path, @"date": modified}];
    }
    if (entries.count <= keepCount) {
        return;
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"date"] compare:a[@"date"]];
    }];
    for (NSUInteger i = keepCount; i < entries.count; i++) {
        [fm removeItemAtPath:entries[i][@"path"] error:nil];
    }
}

static NSDictionary *OPScreenScreenshotInfo(NSDictionary *request) {
    if (!OPBoolFromRequest(request, @"include_screenshot", NO)) {
        return @{
            @"status": @"not_requested",
            @"provider": @"openphone-screencap-helper"
        };
    }

    OPEnsureDirectories();
    OPPruneScreenshotsDir(60);
    // Compress screenshots to cut memory/disk pressure ~4x. Default: JPEG q=0.6,
    // longest edge <= 1024px. Config keys screenshot_max_dimension_px and
    // screenshot_jpeg_quality (0 dimension disables scaling); per-request
    // overrides accepted via the same keys.
    NSDictionary *modelConfig = OPModelConfig();
    long long maxDimension = OPLongLongFromRequest(request, @"screenshot_max_dimension_px",
            OPLongLongFromRequest(modelConfig, @"screenshot_max_dimension_px", 1024, 0, 4096),
            0, 4096);
    double jpegQuality = (double)OPLongLongFromRequest(request, @"screenshot_jpeg_quality_x100",
            OPLongLongFromRequest(modelConfig, @"screenshot_jpeg_quality_x100", 60, 10, 100),
            10, 100) / 100.0;
    NSString *filename = [NSString stringWithFormat:@"screen-%lld-%d.jpg", OPNowMs(), getpid()];
    NSString *path = [OPScreenshotsPath() stringByAppendingPathComponent:filename];
    NSString *helper = OPScreenshotHelperPath();
    NSDictionary *helperResult = helper ? nil : @{
        @"status": @"unavailable",
        @"provider": @"openphone-screencap-helper",
        @"reason": @"helper_not_installed",
        @"path": path
    };

    if (helper) {
        // Ask SpringBoard to hide our island overlay briefly so it doesn't
        // appear in the captured screenshot (which would confuse the model
        // into thinking the app UI is obscured). Give it ~150ms to fade.
        notify_post("com.openphone.island.hide-for-capture");
        usleep(150000);
        NSString *output = OPSpawnCapture(@[helper, path,
                [NSString stringWithFormat:@"%lld", maxDimension],
                [NSString stringWithFormat:@"%.2f", jpegQuality]], 32 * 1024);
        notify_post("com.openphone.island.show-after-capture");
        if (output.length == 0) {
            helperResult = @{
                @"status": @"unavailable",
                @"provider": @"openphone-screencap-helper",
                @"reason": @"helper_failed_or_crashed",
                @"path": path
            };
        } else {
            NSDictionary *parsed = OPJSONDictionaryFromString(output);
            if (!parsed) {
                helperResult = @{
                    @"status": @"unavailable",
                    @"provider": @"openphone-screencap-helper",
                    @"reason": @"helper_json_invalid",
                    @"path": path,
                    @"raw_length": @(output.length)
                };
            } else {
                NSMutableDictionary *result = [parsed mutableCopy];
                if (![result[@"path"] isKindOfClass:[NSString class]]) {
                    result[@"path"] = path;
                }
                result[@"helper"] = helper;
                result[@"bytes_returned"] = @"never";
                if ([result[@"status"] isEqualToString:@"ok"]) {
                    return result;
                }
                helperResult = result;
            }
        }
    }

    if (!helperResult) {
        helperResult = @{
            @"status": @"unavailable",
            @"provider": @"openphone-screencap-helper",
            @"reason": @"helper_unavailable",
            @"path": path
        };
    }
    return OPSpringBoardScreenshotInfo(request, path, helperResult);
}

static NSDictionary *OPSpringBoardInputBridgeInfo(void) {
    NSDictionary *state = OPSpringBoardPublishedState();
    if (![state[@"status"] isEqualToString:@"ok"]) {
        return @{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneVolumeTrigger.SpringBoardInput",
            @"reason": state[@"reason"] ?: @"springboard_state_unavailable",
            @"springboard_state_status": state[@"status"] ?: @"unknown"
        };
    }
    NSDictionary *bridge = [state[@"input_bridge"] isKindOfClass:[NSDictionary class]]
            ? state[@"input_bridge"] : @{};
    if (![bridge[@"status"] isEqualToString:@"ready"]) {
        return @{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneVolumeTrigger.SpringBoardInput",
            @"reason": @"springboard_input_bridge_not_ready",
            @"springboard_state_status": state[@"status"] ?: @"unknown",
            @"bridge_status": bridge[@"status"] ?: @"missing"
        };
    }
    NSMutableDictionary *result = [bridge mutableCopy];
    result[@"provider"] = result[@"provider"] ?: @"OpenPhoneVolumeTrigger.SpringBoardInput";
    return result;
}

static NSDictionary *OPSpringBoardInputInfo(NSDictionary *action) {
    NSDictionary *bridge = OPSpringBoardInputBridgeInfo();
    NSString *actionType = [action[@"type"] isKindOfClass:[NSString class]]
            ? action[@"type"] : @"";
    if (![bridge[@"status"] isEqualToString:@"ready"]) {
        NSMutableDictionary *unavailable = [@{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneVolumeTrigger.SpringBoardInput",
            @"reason": bridge[@"reason"] ?: @"springboard_input_bridge_unavailable",
            @"action_type": actionType,
            @"request_path": OPSpringBoardInputRequestPath(),
            @"response_path": OPSpringBoardInputResponsePath()
        } mutableCopy];
        unavailable[@"bridge"] = bridge ?: @{};
        return unavailable;
    }

    NSString *requestId = [NSString stringWithFormat:@"input-%lld-%d", OPNowMs(), getpid()];
    NSString *requestPath = OPSpringBoardInputRequestPath();
    NSString *responsePath = OPSpringBoardInputResponsePath();
    long long timeoutMs = OPLongLongFromRequest(action, @"input_timeout_ms", 1200, 250, 5000);
    NSDictionary *payload = @{
        @"schema": @"openphone.springboard_input_request.v1",
        @"request_id": requestId,
        @"timestamp_ms": @(OPNowMs()),
        @"provider": @"openphone.agentd",
        @"action": action ?: @{},
        @"timeout_ms": @(timeoutMs),
        @"source": @"openphone.agentd.input.perform"
    };
    if (!OPWriteJSONFile(requestPath, payload)) {
        return @{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneVolumeTrigger.SpringBoardInput",
            @"reason": @"request_write_failed",
            @"request_path": requestPath,
            @"response_path": responsePath,
            @"action_type": actionType
        };
    }
    chmod(requestPath.UTF8String, 0644);

    long long start = OPNowMs();
    while (OPNowMs() - start <= timeoutMs) {
        NSDictionary *response = OPReadJSONFile(responsePath);
        NSString *responseRequestId = [response[@"request_id"] isKindOfClass:[NSString class]]
                ? response[@"request_id"] : @"";
        if ([responseRequestId isEqualToString:requestId]) {
            NSMutableDictionary *result = [response mutableCopy];
            result[@"provider"] = result[@"provider"] ?: @"OpenPhoneVolumeTrigger.SpringBoardInput";
            result[@"request_path"] = requestPath;
            result[@"response_path"] = responsePath;
            result[@"bridge"] = bridge ?: @{};
            [[NSFileManager defaultManager] removeItemAtPath:requestPath error:nil];
            return result;
        }
        usleep(100000);
    }

    [[NSFileManager defaultManager] removeItemAtPath:requestPath error:nil];
    return @{
        @"status": @"unavailable",
        @"provider": @"OpenPhoneVolumeTrigger.SpringBoardInput",
        @"reason": @"response_timeout",
        @"request_id": requestId,
        @"action_type": actionType,
        @"request_path": requestPath,
        @"response_path": responsePath,
        @"timeout_ms": @(timeoutMs),
        @"bridge": bridge ?: @{}
    };
}

static long long OPSQLiteCount(sqlite3 *db, NSString *table) {
    NSString *sql = [NSString stringWithFormat:@"SELECT count(*) FROM %@", table];
    sqlite3_stmt *statement = NULL;
    long long count = 0;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK) {
        if (sqlite3_step(statement) == SQLITE_ROW) {
            count = sqlite3_column_int64(statement, 0);
        }
    }
    sqlite3_finalize(statement);
    return count;
}

static long long OPAgentJobCountForStatus(sqlite3 *db, NSString *status) {
    sqlite3_stmt *statement = NULL;
    long long count = 0;
    if (sqlite3_prepare_v2(db,
            "SELECT count(*) FROM agent_job WHERE status = ?",
            -1, &statement, NULL) == SQLITE_OK) {
        OPSQLiteBindText(statement, 1, status ?: @"");
        if (sqlite3_step(statement) == SQLITE_ROW) {
            count = sqlite3_column_int64(statement, 0);
        }
    }
    sqlite3_finalize(statement);
    return count;
}

static long long OPAgentJobDueCount(sqlite3 *db, long long nowMs) {
    sqlite3_stmt *statement = NULL;
    long long count = 0;
    if (sqlite3_prepare_v2(db,
            "SELECT count(*) FROM agent_job "
            "WHERE scheduler_enabled = 1 AND status = 'queued' "
            "AND (next_run_at_ms = 0 OR next_run_at_ms <= ?)",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, nowMs);
        if (sqlite3_step(statement) == SQLITE_ROW) {
            count = sqlite3_column_int64(statement, 0);
        }
    }
    sqlite3_finalize(statement);
    return count;
}

static long long OPWatcherDueCount(sqlite3 *db, long long nowMs) {
    sqlite3_stmt *statement = NULL;
    long long count = 0;
    if (sqlite3_prepare_v2(db,
            "SELECT count(*) FROM watcher "
            "WHERE status = 'active' AND next_run_at_ms > 0 AND next_run_at_ms <= ? "
            "AND (lower(source) IN ('time', 'timer', 'deadline') "
            "OR lower(type) IN ('time', 'timer', 'deadline'))",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, nowMs);
        if (sqlite3_step(statement) == SQLITE_ROW) {
            count = sqlite3_column_int64(statement, 0);
        }
    }
    sqlite3_finalize(statement);
    return count;
}

static long long OPCommitmentDueCount(sqlite3 *db, long long nowMs) {
    sqlite3_stmt *statement = NULL;
    long long count = 0;
    if (sqlite3_prepare_v2(db,
            "SELECT count(*) FROM commitment "
            "WHERE status = 'active' AND due_at_ms > 0 AND due_at_ms <= ? "
            "AND (expires_at_ms = 0 OR expires_at_ms >= ?)",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, nowMs);
        sqlite3_bind_int64(statement, 2, nowMs);
        if (sqlite3_step(statement) == SQLITE_ROW) {
            count = sqlite3_column_int64(statement, 0);
        }
    }
    sqlite3_finalize(statement);
    return count;
}

static long long OPWatcherStaleRunningCount(sqlite3 *db, long long nowMs, long long staleAfterMs) {
    sqlite3_stmt *statement = NULL;
    long long count = 0;
    long long cutoff = nowMs - staleAfterMs;
    if (sqlite3_prepare_v2(db,
            "SELECT count(*) FROM watcher "
            "WHERE status = 'running' AND updated_at_ms <= ? "
            "AND (lower(source) IN ('time', 'timer', 'deadline') "
            "OR lower(type) IN ('time', 'timer', 'deadline'))",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, cutoff);
        if (sqlite3_step(statement) == SQLITE_ROW) {
            count = sqlite3_column_int64(statement, 0);
        }
    }
    sqlite3_finalize(statement);
    return count;
}

static long long OPAgentJobSchedulerEnabledCount(sqlite3 *db) {
    sqlite3_stmt *statement = NULL;
    long long count = 0;
    if (sqlite3_prepare_v2(db,
            "SELECT count(*) FROM agent_job WHERE scheduler_enabled = 1",
            -1, &statement, NULL) == SQLITE_OK) {
        if (sqlite3_step(statement) == SQLITE_ROW) {
            count = sqlite3_column_int64(statement, 0);
        }
    }
    sqlite3_finalize(statement);
    return count;
}

static long long OPAgentJobStaleRunningCount(sqlite3 *db, long long nowMs, long long staleAfterMs) {
    sqlite3_stmt *statement = NULL;
    long long count = 0;
    long long cutoff = nowMs - staleAfterMs;
    if (sqlite3_prepare_v2(db,
            "SELECT count(*) FROM agent_job "
            "WHERE scheduler_enabled = 1 AND status = 'running' AND updated_at_ms <= ?",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, cutoff);
        if (sqlite3_step(statement) == SQLITE_ROW) {
            count = sqlite3_column_int64(statement, 0);
        }
    }
    sqlite3_finalize(statement);
    return count;
}

static NSDictionary *OPLocalStoresStatus(void) {
    sqlite3 *db = NULL;
    NSString *error = nil;
    NSDictionary *modelStatus = OPModelStatusDictionary();
    if (!OPSQLiteOpen(&db, &error)) {
        return @{
            @"status": @"unavailable",
            @"provider": @"sqlite",
            @"path": OPDatabasePath(),
            @"reason": error ?: @"sqlite_open_failed"
        };
    }
    NSDictionary *result = @{
        @"status": @"ok",
        @"provider": @"sqlite",
        @"path": OPDatabasePath(),
        @"memory": @{
            @"status": @"implemented_partial",
            @"rows": @(OPSQLiteCount(db, @"memory")),
            @"fts": @(OPSQLiteTableExists(db, @"memory_fts"))
        },
        @"context_index": @{
            @"status": @"implemented_partial",
            @"rows": @(OPSQLiteCount(db, @"context_event")),
            @"fts": @(OPSQLiteTableExists(db, @"context_event_fts"))
        },
        @"commitments": @{
            @"status": @"implemented_partial",
            @"rows": @(OPSQLiteCount(db, @"commitment")),
            @"fts": @(OPSQLiteTableExists(db, @"commitment_fts")),
            @"due": @(OPCommitmentDueCount(db, OPNowMs())),
            @"scheduler": OPCommitmentSchedulerStatus()
        },
        @"watchers": @{
            @"status": @"implemented_partial",
            @"rows": @(OPSQLiteCount(db, @"watcher")),
            @"fts": @(OPSQLiteTableExists(db, @"watcher_fts")),
            @"due": @(OPWatcherDueCount(db, OPNowMs())),
            @"stale_running": @(OPWatcherStaleRunningCount(db, OPNowMs(), 300000)),
            @"scheduler": OPWatcherSchedulerStatus()
        },
        @"background_jobs": @{
            @"status": @"implemented_partial",
            @"rows": @(OPSQLiteCount(db, @"agent_job")),
            @"fts": @(OPSQLiteTableExists(db, @"agent_job_fts")),
            @"queued": @(OPAgentJobCountForStatus(db, @"queued")),
            @"running": @(OPAgentJobCountForStatus(db, @"running")),
            @"due": @(OPAgentJobDueCount(db, OPNowMs())),
            @"stale_running": @(OPAgentJobStaleRunningCount(db, OPNowMs(), 300000)),
            @"scheduler_enabled": @(OPAgentJobSchedulerEnabledCount(db)),
            @"scheduler": OPBackgroundJobSchedulerStatus(),
            @"runner": @"deterministic",
            @"model_loop": modelStatus[@"status"] ?: @"disabled"
        }
    };
    sqlite3_close(db);
    return result;
}

static NSDictionary *OPHealth(NSDate *startedAt) {
    NSTimeInterval uptime = [[NSDate date] timeIntervalSinceDate:startedAt];
    struct utsname info;
    memset(&info, 0, sizeof(info));
    uname(&info);

    BOOL rootlessPrefixAvailable = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"];
    NSString *foregroundBundleId = OPForegroundBundleIdentifier() ?: @"unknown";
    NSArray<NSDictionary *> *runningApps = OPRunningApplications();
    OPInputProviderStatus inputStatus = OPInputStatus();
    NSDictionary *displayInfo = OPScreenDisplayInfo();
    NSDictionary *lockInfo = OPScreenLockInfo();
    NSDictionary *screenshotStatus = OPScreenshotHelperStatus();
    NSDictionary *recentLayoutInfo = OPSpringBoardRecentLayoutInfo(8);
    NSDictionary *springBoardState = OPSpringBoardPublishedState();
    NSDictionary *springBoardUITree = [springBoardState[@"ui_tree"] isKindOfClass:[NSDictionary class]]
            ? springBoardState[@"ui_tree"] : @{};
    NSDictionary *springBoardInputBridge = [springBoardState[@"input_bridge"] isKindOfClass:[NSDictionary class]]
            ? springBoardState[@"input_bridge"] : @{};
    NSDictionary *storeStatus = OPLocalStoresStatus();
    NSDictionary *modelStatus = OPModelStatusDictionary();
    NSDictionary *agentControl = OPAgentControlSummary();
    NSString *publishedForeground = [springBoardState[@"foreground_app"] isKindOfClass:[NSString class]]
            ? springBoardState[@"foreground_app"] : @"";
    NSString *screenForeground = foregroundBundleId;
    if ((screenForeground.length == 0 || [screenForeground isEqualToString:@"unknown"]) &&
            [springBoardState[@"status"] isEqualToString:@"ok"] &&
            publishedForeground.length > 0) {
        screenForeground = publishedForeground;
    }
    if (screenForeground.length == 0) {
        screenForeground = @"unknown";
    }
    NSDictionary *appUIState = OPAppUIPublishedState(screenForeground);
    NSDictionary *appUITree = [appUIState[@"ui_tree"] isKindOfClass:[NSDictionary class]]
            ? appUIState[@"ui_tree"] : @{};
    BOOL hasAppUITree = [appUIState[@"status"] isEqualToString:@"ok"] &&
            [appUITree[@"status"] isEqualToString:@"ok"];
    NSDictionary *healthUITree = hasAppUITree ? appUITree : springBoardUITree;
    NSString *healthUITreeScope = hasAppUITree ? @"app_process" :
            (springBoardUITree[@"scope"] ?: @"springboard_only");
    return @{
        @"status": @"ok",
        @"service": @"openphone-agentd",
        @"version": OPAgentVersion,
        @"pid": @(getpid()),
        @"uptime_ms": @((long long)(uptime * 1000.0)),
        @"autonomy_mode": agentControl[@"autonomy_mode"] ?: @"yolo",
        @"agent": agentControl,
        @"default_approved_capabilities": OPFullYoloCapabilities(),
        @"paths": @{
            @"store": OPStorePath(),
            @"socket": OPSocketPath(),
            @"log": OPLogPath()
        },
        @"device": @{
            @"rootless_prefix_available": @(rootlessPrefixAvailable),
            @"rootless_prefix": @"/var/jb",
            @"uname": [NSString stringWithFormat:@"%s %s %s %s %s",
                       info.sysname, info.nodename, info.release, info.version, info.machine]
        },
        @"providers": @{
            @"screen": @{
                @"status": [screenshotStatus[@"status"] isEqualToString:@"implemented_experimental"]
                        ? @"metadata_with_screenshot_helper" : @"metadata_only",
                @"foreground_app": screenForeground,
                @"foreground_source": [screenForeground isEqualToString:publishedForeground]
                        ? @"springboard_state" : @"springboardservices",
                @"display": displayInfo,
                @"lock": lockInfo,
                @"screenshot": screenshotStatus,
                @"springboard_state": @{
                    @"status": springBoardState[@"status"] ?: @"unknown",
                    @"provider": springBoardState[@"provider"] ?: @"OpenPhoneVolumeTrigger.SpringBoardState",
                    @"age_ms": springBoardState[@"age_ms"] ?: @0,
                    @"foreground_app": springBoardState[@"foreground_app"] ?: @"",
                    @"active_scene_count": springBoardState[@"active_scene_count"] ?: @0
                },
                @"app_ui_state": @{
                    @"status": appUIState[@"status"] ?: @"unavailable",
                    @"provider": appUIState[@"provider"] ?: @"OpenPhoneAppIntrospector.UIKitAccessibility",
                    @"bundle_id": appUIState[@"bundle_id"] ?: screenForeground,
                    @"age_ms": appUIState[@"age_ms"] ?: @0,
                    @"application_state_name": appUIState[@"application_state_name"] ?: @"unknown",
                    @"reason": appUIState[@"reason"] ?: @""
                },
                @"app_ui_intake": OPAppUIIntakeStatus(),
                @"recent_layout": @{
                    @"status": recentLayoutInfo[@"status"] ?: @"unknown",
                    @"provider": recentLayoutInfo[@"provider"] ?: @"SpringBoard.RecentAppLayouts",
                    @"count": recentLayoutInfo[@"count"] ?: @0,
                    @"first_bundle_id": recentLayoutInfo[@"first_bundle_id"] ?: @""
                },
                @"ui_tree": @{
                    @"status": healthUITree[@"status"] ?: @"unavailable",
                    @"provider": healthUITree[@"provider"] ?: @"SpringBoard.UIKitAccessibility",
                    @"scope": healthUITreeScope ?: @"springboard_only",
                    @"window_count": healthUITree[@"window_count"] ?: @0,
                    @"element_count": healthUITree[@"element_count"] ?: @0,
                    @"text_count": healthUITree[@"text_count"] ?: @0
                }
            },
            @"input": @{
                @"status": inputStatus.hasHome || inputStatus.hasWake
                        || inputStatus.hasCoordinateInput
                        ? @"implemented_partial" : @"not_implemented",
                @"provider_loaded": @(inputStatus.loaded),
                @"coordinate_provider": OPHIDInputProviderInfo(),
                @"springboard_bridge": @{
                    @"status": springBoardInputBridge[@"status"] ?: @"unavailable",
                    @"provider": springBoardInputBridge[@"provider"] ?: @"OpenPhoneVolumeTrigger.SpringBoardInput",
                    @"request_path": springBoardInputBridge[@"request_path"] ?: OPSpringBoardInputRequestPath(),
                    @"response_path": springBoardInputBridge[@"response_path"] ?: OPSpringBoardInputResponsePath(),
                    @"scope": springBoardInputBridge[@"scope"] ?: @"springboard_windows"
                },
                @"home": inputStatus.hasHome ? @"implemented" : @"not_available",
                @"wake_and_home": (inputStatus.hasWake && inputStatus.hasHome)
                        ? @"implemented" : @"not_available",
                @"tap": inputStatus.hasCoordinateInput ? @"implemented" : @"not_available",
                @"tap_element": inputStatus.hasCoordinateInput
                        ? @"implemented_partial" : @"not_available",
                @"long_press": inputStatus.hasCoordinateInput ? @"implemented" : @"not_available",
                @"swipe": inputStatus.hasCoordinateInput ? @"implemented" : @"not_available",
                @"type_text": inputStatus.hasTextInput ? @"implemented" : @"not_available"
            },
            @"apps": @{
                @"status": @"implemented_partial",
                @"foreground_app": foregroundBundleId,
                @"running_apps_count": @(runningApps.count),
                @"installed_apps": @"implemented",
                @"open_app": @"implemented",
                @"open_url": @"implemented"
            },
            @"notifications": OPNotificationProviderStatus(),
            @"messages": OPMessagesProviderStatus(),
            @"calls": OPCallsProviderStatus(),
            @"triggers": @{
                @"volume_combo": OPVolumeTriggerStatus()
            },
            @"calendar": OPCalendarProviderStatus(),
            @"contacts": OPContactsProviderStatus(),
            @"model": modelStatus,
            @"stores": storeStatus,
            @"memory": storeStatus[@"memory"] ?: @{@"status": @"unknown"},
            @"context_index": storeStatus[@"context_index"] ?: @{@"status": @"unknown"}
        },
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPStartTask(NSDictionary *request) {
    NSString *goal = [request[@"goal"] isKindOfClass:[NSString class]] ? request[@"goal"] : @"";
    NSArray *approved = [request[@"approved_capabilities"] isKindOfClass:[NSArray class]]
            ? request[@"approved_capabilities"] : OPFullYoloCapabilities();
    NSString *taskId = OPTaskId();
    NSDictionary *task = @{
        @"state": @"task.accepted",
        @"task_id": taskId,
        @"goal": goal,
        @"autonomy_mode": @"yolo",
        @"user_visible": @YES,
        @"background_allowed": @NO,
        @"approved_capabilities": approved,
        @"status": @"active",
        @"created_at": @(OPNowMs()),
        @"updated_at": @(OPNowMs()),
        @"owner_pid": @(getpid()),
        @"source": @"openphone.agentd"
    };
    OPWriteJSONFile(OPTaskPath(taskId), task);
    OPRecordAudit(@"task_started", taskId, @"tasks.observe", @"allow_task_scoped", request,
            @"openphone-agentd");
    OPRecordTrajectory(taskId, @"task_started", task);
    return task;
}

static NSDictionary *OPStopTask(NSDictionary *request) {
    NSString *taskId = [request[@"task_id"] isKindOfClass:[NSString class]] ? request[@"task_id"] : @"";
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    if (reason.length == 0) {
        reason = @"stopped";
    }
    NSDictionary *result = @{
        @"state": @"task.stopped",
        @"task_id": taskId,
        @"cancel_requested": @YES,
        @"reason": reason,
        @"source": @"openphone.agentd",
        @"detail": @"stopped"
    };
    OPUpdateTask(taskId, @"stopped", @{
        @"stop_reason": reason,
        @"cancel_reason": reason,
        @"cancel_requested": @YES,
        @"stopped_at": @(OPNowMs())
    });
    OPRecordAudit(@"task_stopped", taskId, @"tasks.observe", @"allow_task_scoped", request,
            @"stopped");
    OPRecordTrajectory(taskId, @"task_stopped", result);
    OPIslandPublishTerminal(taskId, NO, @"Cancelled");
    return result;
}

static BOOL OPTaskCancellationRequested(NSString *taskId, NSString **reasonOut) {
    if (![taskId isKindOfClass:[NSString class]] || taskId.length == 0) {
        return NO;
    }
    NSDictionary *task = OPReadJSONFile(OPTaskPath(taskId));
    if (![task isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSString *status = [task[@"status"] isKindOfClass:[NSString class]] ? task[@"status"] : @"";
    BOOL cancelled = [task[@"cancel_requested"] boolValue] ||
            [status isEqualToString:@"stopped"] ||
            [status isEqualToString:@"cancelled"];
    if (cancelled && reasonOut) {
        NSString *reason = OPStringFromRequest(task, @"cancel_reason",
                OPStringFromRequest(task, @"stop_reason", @"cancelled"));
        *reasonOut = reason.length > 0 ? reason : @"cancelled";
    }
    return cancelled;
}

static NSDictionary *OPFinishTask(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    if (taskId.length == 0) {
        return OPError(@"missing_task_id");
    }
    // Model may name the user-facing message any of: summary, answer, reply,
    // response, message, text. Accept them all.
    NSString *summary = OPStringFromRequest(request, @"summary", @"");
    for (NSString *key in @[@"answer", @"reply", @"response", @"message", @"text"]) {
        if (summary.length > 0) break;
        summary = OPStringFromRequest(request, key, @"");
    }
    if (summary.length == 0) {
        summary = @"Task finished.";
    }
    NSDictionary *result = @{
        @"status": @"ok",
        @"state": @"task.finished",
        @"task_id": taskId,
        @"summary": summary,
        @"source": @"openphone.agentd"
    };
    OPUpdateTask(taskId, @"completed", @{
        @"result": result,
        @"completed_at": @(OPNowMs())
    });
    OPRecordAudit(@"task_finished", taskId, @"tasks.observe", @"allow_task_scoped",
            request, @"finish_task");
    OPRecordTrajectory(taskId, @"task_finished", result);
    OPIslandPublishTerminal(taskId, YES, summary);
    OPRecordAssistantTurn(summary, taskId, YES);
    return result;
}

static NSDictionary *OPFailTask(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    if (taskId.length == 0) {
        return OPError(@"missing_task_id");
    }
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    for (NSString *key in @[@"summary", @"answer", @"reply", @"message", @"text", @"detail"]) {
        if (reason.length > 0) break;
        reason = OPStringFromRequest(request, key, @"");
    }
    if (reason.length == 0) {
        reason = @"Task failed.";
    }
    NSDictionary *result = @{
        @"status": @"ok",
        @"state": @"task.failed",
        @"task_id": taskId,
        @"reason": reason,
        @"source": @"openphone.agentd"
    };
    OPUpdateTask(taskId, @"failed", @{
        @"result": result,
        @"completed_at": @(OPNowMs())
    });
    OPRecordAudit(@"task_failed", taskId, @"tasks.observe", @"failed",
            request, @"fail_task");
    OPRecordTrajectory(taskId, @"task_failed", result);
    OPIslandPublishTerminal(taskId, NO, reason);
    OPRecordAssistantTurn(reason, taskId, NO);
    return result;
}

static NSDictionary *OPGetTask(NSDictionary *request) {
    NSString *taskId = [request[@"task_id"] isKindOfClass:[NSString class]] ? request[@"task_id"] : @"";
    if (taskId.length == 0) {
        return OPError(@"missing_task_id");
    }
    NSDictionary *task = OPReadJSONFile(OPTaskPath(taskId));
    if (!task) {
        return OPError(@"task_not_found");
    }
    return @{
        @"status": @"ok",
        @"task_id": taskId,
        @"task": task,
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPListTasks(NSDictionary *request) {
    NSUInteger limit = OPLimitFromRequest(request, 50, 500);
    NSArray<NSString *> *files = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:OPTasksPath() error:nil] ?: @[];
    NSMutableArray<NSDictionary *> *tasks = [NSMutableArray array];
    for (NSString *file in files) {
        if (![file.pathExtension isEqualToString:@"json"]) {
            continue;
        }
        NSDictionary *task = OPReadJSONFile([OPTasksPath() stringByAppendingPathComponent:file]);
        if (task) {
            [tasks addObject:task];
        }
    }
    [tasks sortUsingDescriptors:@[
        [NSSortDescriptor sortDescriptorWithKey:@"updated_at" ascending:NO]
    ]];
    if (limit > 0 && tasks.count > limit) {
        [tasks removeObjectsInRange:NSMakeRange(limit, tasks.count - limit)];
    }
    return @{
        @"status": @"ok",
        @"tasks": tasks,
        @"count": @(tasks.count),
        @"source": @"openphone.agentd"
    };
}

static NSArray<NSDictionary *> *OPRecentTaskDictionaries(NSUInteger limit) {
    NSArray<NSString *> *files = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:OPTasksPath() error:nil] ?: @[];
    NSMutableArray<NSDictionary *> *tasks = [NSMutableArray array];
    for (NSString *file in files) {
        if (![file.pathExtension isEqualToString:@"json"]) {
            continue;
        }
        NSDictionary *task = OPReadJSONFile([OPTasksPath() stringByAppendingPathComponent:file]);
        if ([task isKindOfClass:[NSDictionary class]]) {
            [tasks addObject:task];
        }
    }
    [tasks sortUsingDescriptors:@[
        [NSSortDescriptor sortDescriptorWithKey:@"updated_at" ascending:NO]
    ]];
    if (limit > 0 && tasks.count > limit) {
        [tasks removeObjectsInRange:NSMakeRange(limit, tasks.count - limit)];
    }
    return tasks;
}

static NSDictionary *OPTaskStatusSummary(NSDictionary *task) {
    if (![task isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSString *goal = [task[@"goal"] isKindOfClass:[NSString class]]
            ? task[@"goal"] : @"";
    if (goal.length > 160) {
        goal = [[goal substringToIndex:160] stringByAppendingString:@"..."];
    }
    NSDictionary *modelLoopCurrent = [task[@"model_loop_current"] isKindOfClass:[NSDictionary class]]
            ? task[@"model_loop_current"] : @{};
    NSDictionary *modelLoopSummary = [task[@"model_loop_summary"] isKindOfClass:[NSDictionary class]]
            ? task[@"model_loop_summary"] : @{};
    id currentStep = modelLoopCurrent[@"step"] ?: modelLoopSummary[@"steps_used"] ?: @0;
    return @{
        @"task_id": task[@"task_id"] ?: @"",
        @"status": task[@"status"] ?: @"unknown",
        @"goal": goal ?: @"",
        @"runner": task[@"runner"] ?: @"",
        @"model_provider": task[@"model_provider"] ?: @"",
        @"created_at": task[@"created_at"] ?: @0,
        @"updated_at": task[@"updated_at"] ?: @0,
        @"completed_at": task[@"completed_at"] ?: @0,
        @"stop_reason": task[@"stop_reason"] ?: modelLoopSummary[@"stop_reason"] ?: @"",
        @"cancel_requested": task[@"cancel_requested"] ?: @NO,
        @"current_step": currentStep ?: @0,
        @"model_loop_status": modelLoopCurrent[@"status"] ?: modelLoopSummary[@"status"] ?: @"",
        @"model_loop_tool": modelLoopCurrent[@"tool"] ?: @"",
        @"steps_used": modelLoopSummary[@"steps_used"] ?: @0,
        @"tool_errors": modelLoopSummary[@"tool_errors"] ?: @0,
        @"unverified_ui_actions": modelLoopSummary[@"unverified_ui_actions"] ?: @0,
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPAgentStatus(NSDictionary *request) {
    NSUInteger limit = OPLimitFromRequest(request, 5, 25);
    NSArray<NSDictionary *> *tasks = OPRecentTaskDictionaries(limit > 0 ? limit : 5);
    NSMutableArray<NSDictionary *> *taskSummaries = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *activeSummaries = [NSMutableArray array];
    for (NSDictionary *task in tasks) {
        NSDictionary *summary = OPTaskStatusSummary(task);
        if (summary.count == 0) {
            continue;
        }
        [taskSummaries addObject:summary];
        NSString *status = [summary[@"status"] isKindOfClass:[NSString class]]
                ? summary[@"status"] : @"";
        if ([status isEqualToString:@"active"]) {
            [activeSummaries addObject:summary];
        }
    }
    NSDictionary *control = OPAgentControlSummary();
    NSDictionary *latestTask = taskSummaries.count > 0 ? taskSummaries[0] : @{};
    NSDictionary *currentTask = activeSummaries.count > 0 ? activeSummaries[0] : @{};
    NSString *agentState = [control[@"paused"] boolValue] ? @"paused"
            : (activeSummaries.count > 0 ? @"running_task" : @"idle");
    NSDictionary *modelStatus = OPModelStatusDictionary();
    NSDictionary *springBoardState = OPSpringBoardPublishedState();
    NSDictionary *status = @{
        @"status": @"ok",
        @"schema": @"openphone.agent_status.v1",
        @"state": agentState,
        @"autonomy_mode": control[@"autonomy_mode"] ?: @"yolo",
        @"control": control,
        @"current_task": currentTask,
        @"latest_task": latestTask,
        @"recent_tasks": taskSummaries,
        @"active_task_count": @(activeSummaries.count),
        @"current_model_loop_step": currentTask[@"current_step"] ?: @0,
        @"current_model_loop_status": currentTask[@"model_loop_status"] ?: @"",
        @"model": modelStatus,
        @"triggers": @{
            @"volume_combo": OPVolumeTriggerStatus(),
            @"last_accepted_at_ms": @(OPHardwareTriggerLastAcceptedMs)
        },
        @"springboard_state": @{
            @"status": springBoardState[@"status"] ?: @"unknown",
            @"age_ms": springBoardState[@"age_ms"] ?: @0,
            @"foreground_app": springBoardState[@"foreground_app"] ?: @"",
            @"foreground_source": springBoardState[@"foreground_source"] ?: @""
        },
        @"user_facing": @{
            @"summary": [control[@"paused"] boolValue]
                    ? @"Agent trigger execution is paused."
                    : (activeSummaries.count > 0 ? @"Agent task is running." : @"Agent is idle."),
            @"last_task_id": latestTask[@"task_id"] ?: @"",
            @"last_stop_reason": latestTask[@"stop_reason"] ?: @""
        },
        @"source": @"openphone.agentd"
    };
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    OPRecordAudit(@"agent_status_read", taskId, @"tasks.observe", @"allow_task_scoped",
            @{@"limit": @(limit)}, agentState);
    return status;
}

static NSDictionary *OPAgentControl(NSDictionary *request) {
    NSString *action = [OPStringFromRequest(request, @"action",
            OPStringFromRequest(request, @"state", @"")) lowercaseString];
    NSMutableDictionary *config = [OPAgentControlConfig() mutableCopy];
    BOOL changed = NO;
    if ([action isEqualToString:@"pause"] || [action isEqualToString:@"paused"] ||
            [action isEqualToString:@"suspend"]) {
        config[@"paused"] = @YES;
        changed = YES;
    } else if ([action isEqualToString:@"resume"] || [action isEqualToString:@"running"] ||
            [action isEqualToString:@"unpause"]) {
        config[@"paused"] = @NO;
        config[@"pause_reason"] = @"";
        changed = YES;
    } else if (action.length > 0 && ![action isEqualToString:@"status"]) {
        return OPError(@"invalid_agent_control_action");
    }
    if (request[@"paused"] != nil) {
        config[@"paused"] = @(OPBoolFromRequest(request, @"paused", [config[@"paused"] boolValue]));
        changed = YES;
    }
    if (request[@"hardware_triggers_enabled"] != nil) {
        config[@"hardware_triggers_enabled"] = @(OPBoolFromRequest(request,
                @"hardware_triggers_enabled", [config[@"hardware_triggers_enabled"] boolValue]));
        changed = YES;
    }
    if (request[@"yolo_enabled"] != nil) {
        config[@"yolo_enabled"] = @(OPBoolFromRequest(request,
                @"yolo_enabled", [config[@"yolo_enabled"] boolValue]));
        changed = YES;
    }
    if ([request[@"autonomy_mode"] isKindOfClass:[NSString class]]) {
        NSString *requestedMode = [request[@"autonomy_mode"] lowercaseString];
        if (!OPAutonomyModeValid(requestedMode)) {
            return OPError(@"invalid_autonomy_mode");
        }
        config[@"autonomy_mode"] = requestedMode;
        changed = YES;
    }
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    if (reason.length > 0 || [config[@"paused"] boolValue]) {
        config[@"pause_reason"] = reason.length > 0 ? reason : (config[@"pause_reason"] ?: @"");
    }
    if (changed) {
        config[@"updated_at_ms"] = @(OPNowMs());
        config[@"updated_by"] = OPStringFromRequest(request, @"source", @"openphone-agentctl");
        config[@"schema"] = @"openphone.agent_control.v1";
        BOOL ok = OPWriteProtectedJSONFile(OPAgentControlPath(), config);
        if (!ok) {
            return OPError(@"agent_control_write_failed");
        }
        OPRecordAudit(@"agent_control_updated", OPStringFromRequest(request, @"task_id", @""),
                @"background.run", [config[@"paused"] boolValue] ? @"paused" : @"allow_yolo",
                OPRedactedObject(request ?: @{}, 0), action.length > 0 ? action : @"updated");
        OPRecordContextEvent(@"agent_control_updated", @"openphone.agentd",
                OPStringFromRequest(request, @"task_id", @""),
                action.length > 0 ? action : @"updated",
                [config[@"paused"] boolValue] ? @"agent paused" : @"agent running",
                OPAgentControlSummary());
    }
    return @{
        @"status": @"ok",
        @"schema": @"openphone.agent_control_result.v1",
        @"changed": @(changed),
        @"control": OPAgentControlSummary(),
        @"source": @"openphone.agentd"
    };
}

static NSArray<NSDictionary *> *OPStaleActiveTaskFiles(NSUInteger limit, long long cutoffMs) {
    NSArray<NSString *> *files = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:OPTasksPath() error:nil] ?: @[];
    NSMutableArray<NSDictionary *> *tasks = [NSMutableArray array];
    for (NSString *file in files) {
        if (![file.pathExtension isEqualToString:@"json"]) {
            continue;
        }
        NSDictionary *task = OPReadJSONFile([OPTasksPath() stringByAppendingPathComponent:file]);
        if (![task isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *status = [task[@"status"] isKindOfClass:[NSString class]]
                ? task[@"status"] : @"";
        if (![status isEqualToString:@"active"]) {
            continue;
        }
        long long updatedAt = [task[@"updated_at"] respondsToSelector:@selector(longLongValue)]
                ? [task[@"updated_at"] longLongValue] : 0;
        long long createdAt = [task[@"created_at"] respondsToSelector:@selector(longLongValue)]
                ? [task[@"created_at"] longLongValue] : 0;
        long long activityAt = updatedAt > 0 ? updatedAt : createdAt;
        if (activityAt > cutoffMs) {
            continue;
        }
        [tasks addObject:task];
    }
    [tasks sortUsingDescriptors:@[
        [NSSortDescriptor sortDescriptorWithKey:@"updated_at" ascending:YES]
    ]];
    if (limit > 0 && tasks.count > limit) {
        [tasks removeObjectsInRange:NSMakeRange(limit, tasks.count - limit)];
    }
    return tasks;
}

static NSDictionary *OPRepairStaleActiveTasks(NSDictionary *request) {
    NSUInteger limit = OPLimitFromRequest(request, 25, 100);
    if (limit == 0) {
        limit = 25;
    }
    long long staleAfterMs = OPLongLongFromRequest(request,
            @"stale_after_ms", 300000, 0, 86400000LL);
    NSString *source = OPStringFromRequest(request, @"source", @"task_repair");
    NSString *repairReason = OPStringFromRequest(request, @"reason",
            @"stale active task repaired after daemon restart");
    NSString *repairTaskId = OPStringFromRequest(request, @"task_id", @"");
    long long now = OPNowMs();
    long long cutoff = now - staleAfterMs;
    NSArray<NSDictionary *> *staleTasks = OPStaleActiveTaskFiles(limit, cutoff);

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSUInteger repairedCount = 0;
    for (NSDictionary *task in staleTasks) {
        NSString *taskId = [task[@"task_id"] isKindOfClass:[NSString class]]
                ? task[@"task_id"] : @"";
        if (taskId.length == 0) {
            continue;
        }
        long long updatedAt = [task[@"updated_at"] respondsToSelector:@selector(longLongValue)]
                ? [task[@"updated_at"] longLongValue] : 0;
        long long createdAt = [task[@"created_at"] respondsToSelector:@selector(longLongValue)]
                ? [task[@"created_at"] longLongValue] : 0;
        long long activityAt = updatedAt > 0 ? updatedAt : createdAt;
        long long ageMs = activityAt > 0 ? MAX(0, now - activityAt) : 0;
        NSString *runner = [task[@"runner"] isKindOfClass:[NSString class]]
                ? task[@"runner"] : @"unknown";
        NSString *stopReason = [source isEqualToString:@"daemon_startup"]
                ? @"stale_active_repaired_after_daemon_restart"
                : @"stale_active_repaired";
        NSDictionary *result = @{
            @"status": @"ok",
            @"state": @"task.failed",
            @"task_id": taskId,
            @"reason": stopReason,
            @"detail": repairReason.length > 0 ? repairReason : stopReason,
            @"source": @"openphone.agentd"
        };
        NSDictionary *repair = @{
            @"status": @"failed",
            @"repair_action": @"failed",
            @"repair_policy": @"fail_stale_active",
            @"previous_status": @"active",
            @"runner": runner.length > 0 ? runner : @"unknown",
            @"stale_after_ms": @(staleAfterMs),
            @"stale_active_age_ms": @(ageMs),
            @"last_activity_at_ms": @(activityAt),
            @"repaired_at_ms": @(now),
            @"repair_source": source.length > 0 ? source : @"task_repair",
            @"daemon_pid": @(getpid())
        };
        NSDictionary *summary = @{
            @"status": @"task.failed",
            @"task_id": taskId,
            @"runner": runner.length > 0 ? runner : @"unknown",
            @"duration_ms": @(ageMs),
            @"stop_reason": stopReason,
            @"last_tool_result": result,
            @"trajectory": OPTrajectoryPath(taskId),
            @"repair": repair,
            @"source": @"openphone.agentd"
        };
        OPUpdateTask(taskId, @"failed", @{
            @"result": result,
            @"completed_at": @(now),
            @"stop_reason": stopReason,
            @"recovery": repair,
            @"model_loop_summary": [runner isEqualToString:@"model"] ? summary : @{}
        });
        OPRecordContextEvent(@"task_repaired", @"openphone.agentd",
                repairTaskId.length > 0 ? repairTaskId : taskId,
                task[@"goal"] ?: taskId, stopReason, repair);
        OPRecordAudit(@"task_repaired", taskId, @"tasks.observe", @"failed",
                @{@"task_id": taskId, @"source": source ?: @"", @"stale_after_ms": @(staleAfterMs)},
                stopReason);
        OPRecordTrajectory(taskId, @"task_repaired", summary);
        if ([runner isEqualToString:@"model"]) {
            OPRecordTrajectory(taskId, @"model_loop_finished", summary);
        } else {
            OPRecordTrajectory(taskId, @"task_failed", summary);
        }
        // Ensure any island in a mid-task state reflects the failure so the
        // pill doesn't stay stuck on "Acting …" after a daemon restart.
        NSString *msg = [source containsString:@"startup"]
                ? @"Daemon restarted mid-task — try again"
                : @"Interrupted — try again";
        OPIslandPublishTerminal(taskId, NO, msg);
        repairedCount++;
        [entries addObject:@{
            @"task_id": taskId,
            @"status": @"failed",
            @"repair_action": @"failed",
            @"runner": runner.length > 0 ? runner : @"unknown",
            @"stale_active_age_ms": @(ageMs),
            @"stop_reason": stopReason
        }];
    }

    return @{
        @"status": @"ok",
        @"repair_policy": @"fail_stale_active",
        @"stale_after_ms": @(staleAfterMs),
        @"cutoff_ms": @(cutoff),
        @"limit": @(limit),
        @"stale_count": @(staleTasks.count),
        @"repaired_count": @(repairedCount),
        @"tasks": entries,
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPGetAudit(NSDictionary *request) {
    NSUInteger limit = OPLimitFromRequest(request, 100, 1000);
    NSArray<NSDictionary *> *events = OPReadJSONLines(OPAuditPath(), limit);
    NSArray<NSDictionary *> *redactedEvents = OPRedactedEvents(events);
    return @{
        @"status": @"ok",
        @"audit_path": OPAuditPath(),
        @"events": redactedEvents,
        @"count": @(redactedEvents.count),
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPGetTrajectory(NSDictionary *request) {
    NSString *taskId = [request[@"task_id"] isKindOfClass:[NSString class]] ? request[@"task_id"] : @"";
    if (taskId.length == 0) {
        return OPError(@"missing_task_id");
    }
    NSUInteger limit = OPLimitFromRequest(request, 200, 2000);
    NSString *path = OPTrajectoryPath(taskId);
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return OPError(@"trajectory_not_found");
    }
    NSArray<NSDictionary *> *events = OPReadJSONLines(path, limit);
    NSArray<NSDictionary *> *redactedEvents = OPRedactedEvents(events);
    return @{
        @"status": @"ok",
        @"task_id": taskId,
        @"trajectory_path": path,
        @"events": redactedEvents,
        @"count": @(redactedEvents.count),
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPMemorySave(NSDictionary *request) {
    NSString *taskId = [request[@"task_id"] isKindOfClass:[NSString class]] ? request[@"task_id"] : @"";
    NSString *text = [request[@"text"] isKindOfClass:[NSString class]] ? request[@"text"] : @"";
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) {
        return OPError(@"missing_memory_text");
    }
    NSString *type = [request[@"type"] isKindOfClass:[NSString class]] ? request[@"type"] : @"fact";
    if (type.length == 0) {
        type = @"fact";
    }
    NSString *subject = [request[@"subject"] isKindOfClass:[NSString class]] ? request[@"subject"] : @"user";
    if (subject.length == 0) {
        subject = @"user";
    }
    NSString *reason = [request[@"reason"] isKindOfClass:[NSString class]] ? request[@"reason"] : @"";
    double confidence = OPDoubleFromRequest(request, @"confidence", 1.0, 0.0, 1.0);
    NSDictionary *metadata = [request[@"metadata"] isKindOfClass:[NSDictionary class]]
            ? OPRedactedObject(request[@"metadata"], 0) : @{};

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }

    long long now = OPNowMs();
    long long memoryId = 0;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "INSERT INTO memory(created_at_ms, updated_at_ms, type, subject, text, confidence, source, reason, metadata_json) "
            "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, now);
        sqlite3_bind_int64(statement, 2, now);
        OPSQLiteBindText(statement, 3, type);
        OPSQLiteBindText(statement, 4, subject);
        OPSQLiteBindText(statement, 5, text);
        sqlite3_bind_double(statement, 6, confidence);
        OPSQLiteBindText(statement, 7, @"openphone.agentd");
        OPSQLiteBindText(statement, 8, reason);
        OPSQLiteBindText(statement, 9, OPJSONString(metadata));
        if (sqlite3_step(statement) == SQLITE_DONE) {
            memoryId = sqlite3_last_insert_rowid(db);
        } else {
            error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
        }
    } else {
        error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    }
    sqlite3_finalize(statement);

    NSDictionary *memory = OPMemoryReadById(db, memoryId);
    if (memory) {
        OPMemoryIndexFTS(db, memory);
    }
    sqlite3_close(db);

    if (memoryId == 0 || !memory) {
        return OPError([NSString stringWithFormat:@"memory_save_failed:%@", error ?: @"unknown"]);
    }

    long long contextId = OPRecordContextEvent(@"memory_saved", @"openphone.agentd", taskId,
            subject, text, @{
                @"memory_id": memory[@"memory_id"] ?: @"",
                @"memory_type": type,
                @"reason": reason ?: @""
            });
    NSMutableDictionary *result = [@{
        @"status": @"ok",
        @"memory": memory,
        @"context_event_id": @(contextId),
        @"db_path": OPDatabasePath(),
        @"source": @"openphone.agentd"
    } mutableCopy];
    OPRecordAudit(@"memory_saved", taskId, @"memory.write", @"allow_yolo",
            request, [NSString stringWithFormat:@"memory_id:%@", memory[@"memory_id"] ?: @""]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"memory_save",
        @"arguments": request ?: @{},
        @"result": result
    });
    return result;
}

static NSDictionary *OPMemoryUpdate(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    long long memoryId = OPRecordIdFromRequest(request, @[@"memory_id", @"id"]);
    if (memoryId <= 0) {
        return OPError(@"missing_memory_id");
    }
    NSString *reason = OPStringFromRequest(request, @"reason", @"");

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    NSDictionary *before = OPMemoryReadById(db, memoryId);
    if (!before) {
        sqlite3_close(db);
        return OPError(@"memory_not_found");
    }

    BOOL hasText = request[@"text"] != nil;
    BOOL hasType = request[@"type"] != nil;
    BOOL hasSubject = request[@"subject"] != nil;
    BOOL hasConfidence = request[@"confidence"] != nil;
    BOOL hasMetadata = request[@"metadata"] != nil;
    if (!hasText && !hasType && !hasSubject && !hasConfidence && !hasMetadata) {
        sqlite3_close(db);
        return OPError(@"missing_memory_update_fields");
    }

    NSString *text = hasText
            ? [OPStringFromRequest(request, @"text", @"") stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]]
            : before[@"text"];
    if (text.length == 0) {
        sqlite3_close(db);
        return OPError(@"missing_memory_text");
    }
    NSString *type = hasType ? OPStringFromRequest(request, @"type", before[@"type"]) : before[@"type"];
    if (type.length == 0) {
        type = @"fact";
    }
    NSString *subject = hasSubject
            ? OPStringFromRequest(request, @"subject", before[@"subject"]) : before[@"subject"];
    if (subject.length == 0) {
        subject = @"user";
    }
    double confidence = hasConfidence
            ? OPDoubleFromRequest(request, @"confidence", [before[@"confidence"] doubleValue], 0.0, 1.0)
            : [before[@"confidence"] doubleValue];
    NSDictionary *metadata = hasMetadata
            ? OPJSONObjectFromRequest(request, @"metadata", @{})
            : (before[@"metadata"] ?: @{});

    long long now = OPNowMs();
    BOOL updated = NO;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "UPDATE memory SET updated_at_ms = ?, type = ?, subject = ?, text = ?, confidence = ?, reason = ?, metadata_json = ? WHERE id = ?",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, now);
        OPSQLiteBindText(statement, 2, type);
        OPSQLiteBindText(statement, 3, subject);
        OPSQLiteBindText(statement, 4, text);
        sqlite3_bind_double(statement, 5, confidence);
        OPSQLiteBindText(statement, 6, reason);
        OPSQLiteBindText(statement, 7, OPJSONString(metadata));
        sqlite3_bind_int64(statement, 8, memoryId);
        updated = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
    } else {
        error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    }
    sqlite3_finalize(statement);

    NSDictionary *memory = updated ? OPMemoryReadById(db, memoryId) : nil;
    if (memory) {
        OPMemoryIndexFTS(db, memory);
    }
    sqlite3_close(db);

    if (!updated || !memory) {
        return OPError([NSString stringWithFormat:@"memory_update_failed:%@", error ?: @"unknown"]);
    }

    long long contextId = OPRecordContextEvent(@"memory_updated", @"openphone.agentd", taskId,
            subject, text, @{
                @"memory_id": memory[@"memory_id"] ?: @"",
                @"reason": reason ?: @""
            });
    NSDictionary *result = @{
        @"status": @"ok",
        @"memory_id": memory[@"memory_id"] ?: @"",
        @"memory": memory,
        @"previous_memory": before,
        @"context_event_id": @(contextId),
        @"db_path": OPDatabasePath(),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"memory_updated", taskId, @"memory.write", @"allow_yolo",
            request, [NSString stringWithFormat:@"memory_id:%@", memory[@"memory_id"] ?: @""]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"memory_update",
        @"arguments": request ?: @{},
        @"result": result
    });
    return result;
}

static NSDictionary *OPMemoryDelete(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    long long memoryId = OPRecordIdFromRequest(request, @[@"memory_id", @"id"]);
    if (memoryId <= 0) {
        return OPError(@"missing_memory_id");
    }
    NSString *reason = OPStringFromRequest(request, @"reason", @"");

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    NSDictionary *before = OPMemoryReadById(db, memoryId);
    if (!before) {
        sqlite3_close(db);
        return OPError(@"memory_not_found");
    }

    BOOL deleted = NO;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, "DELETE FROM memory WHERE id = ?",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, memoryId);
        deleted = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
    } else {
        error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    }
    sqlite3_finalize(statement);
    if (deleted) {
        OPMemoryDeleteFTS(db, memoryId);
    }
    sqlite3_close(db);

    if (!deleted) {
        return OPError([NSString stringWithFormat:@"memory_delete_failed:%@", error ?: @"unknown"]);
    }

    long long contextId = OPRecordContextEvent(@"memory_deleted", @"openphone.agentd", taskId,
            before[@"subject"], before[@"text"], @{
                @"memory_id": before[@"memory_id"] ?: @"",
                @"reason": reason ?: @""
            });
    NSDictionary *result = @{
        @"status": @"ok",
        @"memory_id": before[@"memory_id"] ?: @"",
        @"deleted": @YES,
        @"memory": before,
        @"context_event_id": @(contextId),
        @"db_path": OPDatabasePath(),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"memory_deleted", taskId, @"memory.write", @"allow_yolo",
            request, [NSString stringWithFormat:@"memory_id:%@", before[@"memory_id"] ?: @""]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"memory_delete",
        @"arguments": request ?: @{},
        @"result": result
    });
    return result;
}

static NSDictionary *OPMemoryMerge(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    long long targetId = OPRecordIdFromRequest(request, @[@"target_memory_id", @"target_id", @"memory_id", @"id"]);
    long long sourceId = OPRecordIdFromRequest(request, @[@"source_memory_id", @"source_id", @"merge_memory_id"]);
    if (targetId <= 0 || sourceId <= 0) {
        return OPError(@"missing_memory_merge_ids");
    }
    if (targetId == sourceId) {
        return OPError(@"memory_merge_same_id");
    }
    NSString *reason = OPStringFromRequest(request, @"reason", @"");

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    NSDictionary *target = OPMemoryReadById(db, targetId);
    NSDictionary *source = OPMemoryReadById(db, sourceId);
    if (!target || !source) {
        sqlite3_close(db);
        return OPError(!target ? @"target_memory_not_found" : @"source_memory_not_found");
    }

    BOOL hasText = request[@"text"] != nil;
    NSString *text = hasText
            ? [OPStringFromRequest(request, @"text", @"") stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]]
            : [NSString stringWithFormat:@"%@\n%@", target[@"text"] ?: @"", source[@"text"] ?: @""];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) {
        sqlite3_close(db);
        return OPError(@"missing_memory_text");
    }
    NSString *type = request[@"type"] != nil
            ? OPStringFromRequest(request, @"type", target[@"type"]) : target[@"type"];
    NSString *subject = request[@"subject"] != nil
            ? OPStringFromRequest(request, @"subject", target[@"subject"]) : target[@"subject"];
    double targetConfidence = [target[@"confidence"] doubleValue];
    double sourceConfidence = [source[@"confidence"] doubleValue];
    double confidence = request[@"confidence"] != nil
            ? OPDoubleFromRequest(request, @"confidence", MAX(targetConfidence, sourceConfidence), 0.0, 1.0)
            : MAX(targetConfidence, sourceConfidence);
    NSMutableDictionary *metadata = [(target[@"metadata"] ?: @{}) mutableCopy];
    metadata[@"merged_from"] = source[@"memory_id"] ?: @"";
    metadata[@"merged_from_subject"] = source[@"subject"] ?: @"";
    metadata[@"merged_from_type"] = source[@"type"] ?: @"";
    metadata[@"merged_at_ms"] = @(OPNowMs());
    if (request[@"metadata"] != nil) {
        id patch = OPJSONObjectFromRequest(request, @"metadata", @{});
        if ([patch isKindOfClass:[NSDictionary class]]) {
            [metadata addEntriesFromDictionary:patch];
        }
    }

    long long now = OPNowMs();
    BOOL updated = NO;
    BOOL deleted = NO;
    OPSQLiteExec(db, @"BEGIN IMMEDIATE", &error);
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "UPDATE memory SET updated_at_ms = ?, type = ?, subject = ?, text = ?, confidence = ?, reason = ?, metadata_json = ? WHERE id = ?",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, now);
        OPSQLiteBindText(statement, 2, type);
        OPSQLiteBindText(statement, 3, subject);
        OPSQLiteBindText(statement, 4, text);
        sqlite3_bind_double(statement, 5, confidence);
        OPSQLiteBindText(statement, 6, reason);
        OPSQLiteBindText(statement, 7, OPJSONString(metadata));
        sqlite3_bind_int64(statement, 8, targetId);
        updated = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
    } else {
        error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    }
    sqlite3_finalize(statement);

    if (updated) {
        OPMemoryDeleteFTS(db, sourceId);
        sqlite3_stmt *deleteStatement = NULL;
        if (sqlite3_prepare_v2(db, "DELETE FROM memory WHERE id = ?",
                -1, &deleteStatement, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(deleteStatement, 1, sourceId);
            deleted = sqlite3_step(deleteStatement) == SQLITE_DONE && sqlite3_changes(db) > 0;
        } else {
            error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
        }
        sqlite3_finalize(deleteStatement);
    }

    NSDictionary *memory = updated && deleted ? OPMemoryReadById(db, targetId) : nil;
    if (memory) {
        OPMemoryIndexFTS(db, memory);
        OPSQLiteExec(db, @"COMMIT", &error);
    } else {
        OPSQLiteExec(db, @"ROLLBACK", &error);
    }
    sqlite3_close(db);

    if (!memory) {
        return OPError([NSString stringWithFormat:@"memory_merge_failed:%@", error ?: @"unknown"]);
    }

    long long contextId = OPRecordContextEvent(@"memory_merged", @"openphone.agentd", taskId,
            subject, text, @{
                @"target_memory_id": memory[@"memory_id"] ?: @"",
                @"source_memory_id": source[@"memory_id"] ?: @"",
                @"reason": reason ?: @""
            });
    NSDictionary *result = @{
        @"status": @"ok",
        @"memory_id": memory[@"memory_id"] ?: @"",
        @"memory": memory,
        @"merged_from": source[@"memory_id"] ?: @"",
        @"deleted_memory": source,
        @"context_event_id": @(contextId),
        @"db_path": OPDatabasePath(),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"memory_merged", taskId, @"memory.write", @"allow_yolo",
            request, [NSString stringWithFormat:@"target:%@ source:%@",
                      memory[@"memory_id"] ?: @"", source[@"memory_id"] ?: @""]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"memory_merge",
        @"arguments": request ?: @{},
        @"result": result
    });
    return result;
}

static NSArray<NSDictionary *> *OPMemorySearchRows(sqlite3 *db, NSString *query,
        NSUInteger limit, NSString **providerOut) {
    NSMutableArray<NSDictionary *> *memories = [NSMutableArray array];
    BOOL hasQuery = query.length > 0;
    BOOL ftsFailed = NO;
    if (hasQuery && OPSQLiteTableExists(db, @"memory_fts")) {
        NSString *ftsQuery = OPFTSQuery(query);
        if (ftsQuery.length > 0) {
            sqlite3_stmt *statement = NULL;
            int rc = sqlite3_prepare_v2(db,
                    "SELECT m.id, m.created_at_ms, m.updated_at_ms, m.type, m.subject, m.text, "
                    "m.confidence, m.source, m.reason, m.metadata_json "
                    "FROM memory_fts f JOIN memory m ON f.memory_id = m.id "
                    "WHERE memory_fts MATCH ? ORDER BY bm25(memory_fts) LIMIT ?",
                    -1, &statement, NULL);
            if (rc == SQLITE_OK) {
                OPSQLiteBindText(statement, 1, ftsQuery);
                sqlite3_bind_int64(statement, 2, (sqlite3_int64)limit);
                while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
                    [memories addObject:OPMemoryFromStatement(statement)];
                }
                if (rc != SQLITE_DONE) {
                    ftsFailed = YES;
                    [memories removeAllObjects];
                }
            } else {
                ftsFailed = YES;
            }
            sqlite3_finalize(statement);
            if (!ftsFailed) {
                if (providerOut) {
                    *providerOut = @"sqlite_fts5";
                }
                return memories;
            }
        }
    }

    sqlite3_stmt *statement = NULL;
    NSString *sql = hasQuery
            ? @"SELECT id, created_at_ms, updated_at_ms, type, subject, text, confidence, source, reason, metadata_json "
              "FROM memory WHERE lower(text) LIKE ? OR lower(subject) LIKE ? OR lower(type) LIKE ? "
              "ORDER BY updated_at_ms DESC LIMIT ?"
            : @"SELECT id, created_at_ms, updated_at_ms, type, subject, text, confidence, source, reason, metadata_json "
              "FROM memory ORDER BY updated_at_ms DESC LIMIT ?";
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK) {
        if (hasQuery) {
            NSString *like = [NSString stringWithFormat:@"%%%@%%", query.lowercaseString ?: @""];
            OPSQLiteBindText(statement, 1, like);
            OPSQLiteBindText(statement, 2, like);
            OPSQLiteBindText(statement, 3, like);
            sqlite3_bind_int64(statement, 4, (sqlite3_int64)limit);
        } else {
            sqlite3_bind_int64(statement, 1, (sqlite3_int64)limit);
        }
        while (sqlite3_step(statement) == SQLITE_ROW) {
            [memories addObject:OPMemoryFromStatement(statement)];
        }
    }
    sqlite3_finalize(statement);
    if (providerOut) {
        *providerOut = hasQuery ? @"sqlite_like" : @"sqlite_latest";
    }
    return memories;
}

static NSDictionary *OPMemorySearch(NSDictionary *request) {
    NSString *taskId = [request[@"task_id"] isKindOfClass:[NSString class]] ? request[@"task_id"] : @"";
    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : @"";
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUInteger limit = OPLimitFromRequest(request, 20, 200);
    if (limit == 0) {
        limit = 20;
    }
    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    NSString *provider = nil;
    NSArray<NSDictionary *> *memories = OPMemorySearchRows(db, query, limit, &provider);
    BOOL ftsAvailable = OPSQLiteTableExists(db, @"memory_fts");
    sqlite3_close(db);
    NSDictionary *result = @{
        @"status": @"ok",
        @"query": query ?: @"",
        @"limit": @(limit),
        @"memories": memories,
        @"count": @(memories.count),
        @"provider": provider ?: @"sqlite",
        @"fts_available": @(ftsAvailable),
        @"db_path": OPDatabasePath(),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"memory_searched", taskId, @"memory.read", @"allow_task_scoped",
            request, [NSString stringWithFormat:@"count:%lu", (unsigned long)memories.count]);
    if (!OPBoolFromRequest(request, @"suppress_trajectory", NO)) {
        OPRecordTrajectory(taskId, @"tool_result", @{
            @"tool": @"memory_search",
            @"arguments": request ?: @{},
            @"result": result
        });
    }
    return result;
}

static NSDictionary *OPContextEventFromStatement(sqlite3_stmt *statement) {
    NSString *metadataJSON = OPSQLiteColumnString(statement, 7);
    long long rowId = sqlite3_column_int64(statement, 0);
    return @{
        @"id": @(rowId),
        @"event_id": [NSString stringWithFormat:@"ios-context-%lld", rowId],
        @"created_at_ms": @(sqlite3_column_int64(statement, 1)),
        @"type": OPSQLiteColumnString(statement, 2),
        @"source": OPSQLiteColumnString(statement, 3),
        @"task_id": OPSQLiteColumnString(statement, 4),
        @"title": OPSQLiteColumnString(statement, 5),
        @"body": OPSQLiteColumnString(statement, 6),
        @"metadata": OPJSONDictionary(metadataJSON)
    };
}

static NSDictionary *OPContextSearch(NSDictionary *request) {
    NSString *taskId = [request[@"task_id"] isKindOfClass:[NSString class]] ? request[@"task_id"] : @"";
    NSString *query = [request[@"query"] isKindOfClass:[NSString class]] ? request[@"query"] : @"";
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUInteger limit = OPLimitFromRequest(request, 20, 200);
    if (limit == 0) {
        limit = 20;
    }
    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }

    NSMutableArray<NSDictionary *> *events = [NSMutableArray array];
    NSString *provider = @"sqlite_latest";
    BOOL hasQuery = query.length > 0;
    BOOL ftsFailed = NO;
    if (hasQuery && OPSQLiteTableExists(db, @"context_event_fts")) {
        NSString *ftsQuery = OPFTSQuery(query);
        if (ftsQuery.length > 0) {
            sqlite3_stmt *statement = NULL;
            int rc = sqlite3_prepare_v2(db,
                    "SELECT e.id, e.created_at_ms, e.type, e.source, e.task_id, e.title, e.body, e.metadata_json "
                    "FROM context_event_fts f JOIN context_event e ON f.event_id = e.id "
                    "WHERE context_event_fts MATCH ? ORDER BY bm25(context_event_fts) LIMIT ?",
                    -1, &statement, NULL);
            if (rc == SQLITE_OK) {
                OPSQLiteBindText(statement, 1, ftsQuery);
                sqlite3_bind_int64(statement, 2, (sqlite3_int64)limit);
                while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
                    [events addObject:OPContextEventFromStatement(statement)];
                }
                if (rc != SQLITE_DONE) {
                    [events removeAllObjects];
                    ftsFailed = YES;
                }
            } else {
                ftsFailed = YES;
            }
            sqlite3_finalize(statement);
            if (!ftsFailed) {
                provider = @"sqlite_fts5";
            }
        }
    }
    if (!hasQuery || ftsFailed || ![provider isEqualToString:@"sqlite_fts5"]) {
        [events removeAllObjects];
        sqlite3_stmt *statement = NULL;
        NSString *sql = hasQuery
                ? @"SELECT id, created_at_ms, type, source, task_id, title, body, metadata_json "
                  "FROM context_event WHERE lower(title) LIKE ? OR lower(body) LIKE ? OR lower(type) LIKE ? "
                  "ORDER BY created_at_ms DESC LIMIT ?"
                : @"SELECT id, created_at_ms, type, source, task_id, title, body, metadata_json "
                  "FROM context_event ORDER BY created_at_ms DESC LIMIT ?";
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK) {
            if (hasQuery) {
                NSString *like = [NSString stringWithFormat:@"%%%@%%", query.lowercaseString ?: @""];
                OPSQLiteBindText(statement, 1, like);
                OPSQLiteBindText(statement, 2, like);
                OPSQLiteBindText(statement, 3, like);
                sqlite3_bind_int64(statement, 4, (sqlite3_int64)limit);
                provider = @"sqlite_like";
            } else {
                sqlite3_bind_int64(statement, 1, (sqlite3_int64)limit);
                provider = @"sqlite_latest";
            }
            while (sqlite3_step(statement) == SQLITE_ROW) {
                [events addObject:OPContextEventFromStatement(statement)];
            }
        }
        sqlite3_finalize(statement);
    }
    BOOL ftsAvailable = OPSQLiteTableExists(db, @"context_event_fts");
    sqlite3_close(db);
    NSDictionary *result = @{
        @"status": @"ok",
        @"query": query ?: @"",
        @"limit": @(limit),
        @"events": events,
        @"count": @(events.count),
        @"provider": provider,
        @"fts_available": @(ftsAvailable),
        @"db_path": OPDatabasePath(),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"context_searched", taskId, @"memory.read", @"allow_task_scoped",
            request, [NSString stringWithFormat:@"count:%lu", (unsigned long)events.count]);
    if (!OPBoolFromRequest(request, @"suppress_trajectory", NO)) {
        OPRecordTrajectory(taskId, @"tool_result", @{
            @"tool": @"context_search",
            @"arguments": request ?: @{},
            @"result": result
        });
    }
    return result;
}

static NSDictionary *OPSpringBoardClipboardBridgeInfo(void) {
    NSDictionary *state = OPSpringBoardPublishedState();
    if (![state[@"status"] isEqualToString:@"ok"]) {
        return @{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneVolumeTrigger.SpringBoardClipboard",
            @"reason": state[@"reason"] ?: @"springboard_state_unavailable",
            @"springboard_state_status": state[@"status"] ?: @"unknown"
        };
    }
    NSDictionary *bridge = [state[@"clipboard_bridge"] isKindOfClass:[NSDictionary class]]
            ? state[@"clipboard_bridge"] : @{};
    if (![bridge[@"status"] isEqualToString:@"ready"]) {
        return @{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneVolumeTrigger.SpringBoardClipboard",
            @"reason": @"springboard_clipboard_bridge_not_ready",
            @"springboard_state_status": state[@"status"] ?: @"unknown",
            @"bridge_status": bridge[@"status"] ?: @"missing"
        };
    }
    NSMutableDictionary *result = [bridge mutableCopy];
    result[@"provider"] = result[@"provider"] ?: @"OpenPhoneVolumeTrigger.SpringBoardClipboard";
    return result;
}

static NSDictionary *OPSpringBoardClipboardPerform(NSString *operation,
        NSString *text,
        NSDictionary *request) {
    NSDictionary *bridge = OPSpringBoardClipboardBridgeInfo();
    if (![bridge[@"status"] isEqualToString:@"ready"]) {
        NSMutableDictionary *unavailable = [@{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneVolumeTrigger.SpringBoardClipboard",
            @"reason": bridge[@"reason"] ?: @"springboard_clipboard_bridge_unavailable",
            @"operation": operation ?: @"",
            @"request_path": OPSpringBoardClipboardRequestPath(),
            @"response_path": OPSpringBoardClipboardResponsePath()
        } mutableCopy];
        unavailable[@"bridge"] = bridge ?: @{};
        return unavailable;
    }

    NSString *requestId = [NSString stringWithFormat:@"clipboard-%lld-%d", OPNowMs(), getpid()];
    NSString *requestPath = OPSpringBoardClipboardRequestPath();
    NSString *responsePath = OPSpringBoardClipboardResponsePath();
    long long timeoutMs = OPLongLongFromRequest(request ?: @{}, @"clipboard_timeout_ms", 1200, 250, 5000);
    NSMutableDictionary *payload = [@{
        @"schema": @"openphone.springboard_clipboard_request.v1",
        @"request_id": requestId,
        @"timestamp_ms": @(OPNowMs()),
        @"provider": @"openphone.agentd",
        @"operation": operation ?: @"read",
        @"timeout_ms": @(timeoutMs),
        @"source": @"openphone.agentd.clipboard"
    } mutableCopy];
    if (text) {
        payload[@"text"] = text;
    }
    if (!OPWriteJSONFile(requestPath, payload)) {
        return @{
            @"status": @"unavailable",
            @"provider": @"OpenPhoneVolumeTrigger.SpringBoardClipboard",
            @"reason": @"request_write_failed",
            @"operation": operation ?: @"",
            @"request_path": requestPath,
            @"response_path": responsePath
        };
    }
    chmod(requestPath.UTF8String, 0600);

    long long start = OPNowMs();
    while (OPNowMs() - start <= timeoutMs) {
        NSDictionary *response = OPReadJSONFile(responsePath);
        NSString *responseRequestId = [response[@"request_id"] isKindOfClass:[NSString class]]
                ? response[@"request_id"] : @"";
        if ([responseRequestId isEqualToString:requestId]) {
            NSMutableDictionary *result = [response mutableCopy];
            result[@"provider"] = result[@"provider"] ?: @"OpenPhoneVolumeTrigger.SpringBoardClipboard";
            result[@"operation"] = result[@"operation"] ?: operation ?: @"";
            result[@"request_path"] = requestPath;
            result[@"response_path"] = responsePath;
            result[@"bridge"] = bridge ?: @{};
            [[NSFileManager defaultManager] removeItemAtPath:requestPath error:nil];
            return result;
        }
        usleep(100000);
    }

    [[NSFileManager defaultManager] removeItemAtPath:requestPath error:nil];
    return @{
        @"status": @"unavailable",
        @"provider": @"OpenPhoneVolumeTrigger.SpringBoardClipboard",
        @"reason": @"response_timeout",
        @"operation": operation ?: @"",
        @"request_id": requestId,
        @"request_path": requestPath,
        @"response_path": responsePath,
        @"timeout_ms": @(timeoutMs),
        @"bridge": bridge ?: @{}
    };
}

static NSString *OPClipboardFallbackPath(void) {
    return [OPConfigPath() stringByAppendingPathComponent:@"clipboard-fallback.json"];
}

static NSString *OPClipboardLimitedText(NSString *value, NSUInteger limit, BOOL *truncatedOut) {
    NSString *text = [value isKindOfClass:[NSString class]] ? value : @"";
    if (limit == 0 || text.length <= limit) {
        if (truncatedOut) {
            *truncatedOut = NO;
        }
        return text ?: @"";
    }
    if (truncatedOut) {
        *truncatedOut = YES;
    }
    return [text substringToIndex:limit] ?: @"";
}

static NSString *OPClipboardTextHash(NSString *text) {
    NSData *data = [(text ?: @"") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    return OPSHA256Hex(data);
}

static NSDictionary *OPClipboardSystemRead(NSString **textOut) {
    NSDictionary *bridge = OPSpringBoardClipboardPerform(@"read", nil, @{});
    if ([bridge[@"status"] isEqualToString:@"ok"]) {
        NSString *text = [bridge[@"text"] isKindOfClass:[NSString class]]
                ? bridge[@"text"] : @"";
        if (textOut) {
            *textOut = text ?: @"";
        }
        return @{
            @"provider": bridge[@"provider"] ?: @"OpenPhoneVolumeTrigger.SpringBoardClipboard",
            @"system_clipboard": @YES,
            @"bridge": bridge
        };
    }

    NSDictionary *fallback = OPReadJSONFile(OPClipboardFallbackPath());
    NSString *text = [fallback[@"text"] isKindOfClass:[NSString class]]
            ? fallback[@"text"] : @"";
    if (textOut) {
        *textOut = text ?: @"";
    }
    return @{
        @"provider": @"openphone.clipboard_fallback_file",
        @"system_clipboard": @NO,
        @"fallback_path": OPClipboardFallbackPath(),
        @"bridge": bridge ?: @{}
    };
}

static NSDictionary *OPClipboardSystemWrite(NSString *text) {
    NSDictionary *bridge = OPSpringBoardClipboardPerform(@"write", text ?: @"", @{});
    if ([bridge[@"status"] isEqualToString:@"ok"]) {
        return @{
            @"provider": bridge[@"provider"] ?: @"OpenPhoneVolumeTrigger.SpringBoardClipboard",
            @"system_clipboard": @YES,
            @"bridge": bridge
        };
    }

    NSDictionary *fallback = @{
        @"schema": @"openphone.clipboard_fallback.v1",
        @"updated_at_ms": @(OPNowMs()),
        @"text": text ?: @""
    };
    BOOL wrote = OPWriteJSONFile(OPClipboardFallbackPath(), fallback);
    chmod(OPClipboardFallbackPath().UTF8String, 0600);
    return @{
        @"provider": @"openphone.clipboard_fallback_file",
        @"system_clipboard": @NO,
        @"fallback_path": OPClipboardFallbackPath(),
        @"fallback_write_ok": @(wrote),
        @"bridge": bridge ?: @{}
    };
}

static NSDictionary *OPClipboardTraceSummary(NSDictionary *result) {
    if (![result isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"status", @"tool", @"provider", @"system_clipboard",
            @"text_length", @"text_sha256", @"truncated", @"max_chars",
            @"context_event_id", @"source"]) {
        id value = result[key];
        if (value) {
            summary[key] = value;
        }
    }
    NSString *text = [result[@"text"] isKindOfClass:[NSString class]] ? result[@"text"] : @"";
    if (text.length > 0) {
        BOOL truncated = NO;
        summary[@"text_preview"] = OPClipboardLimitedText(text, 160, &truncated);
        summary[@"text_preview_truncated"] = @(truncated);
    }
    return summary;
}

static NSDictionary *OPClipboardRead(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    NSUInteger maxChars = (NSUInteger)OPLongLongFromRequest(request, @"max_chars",
            (long long)OPLimitFromRequest(request, 4096, 32768), 0, 32768);
    if (maxChars == 0) {
        maxChars = 4096;
    }

    NSString *rawText = @"";
    NSDictionary *provider = OPClipboardSystemRead(&rawText);
    BOOL truncated = NO;
    NSString *text = OPClipboardLimitedText(rawText, maxChars, &truncated);
    NSString *hash = OPClipboardTextHash(rawText);
    long long contextId = OPRecordContextEvent(@"clipboard_read", @"openphone.agentd", taskId,
            @"Clipboard", OPClipboardLimitedText(rawText, 240, NULL), @{
                @"provider": provider[@"provider"] ?: @"unknown",
                @"system_clipboard": provider[@"system_clipboard"] ?: @NO,
                @"text_length": @(rawText.length),
                @"text_sha256": hash ?: @"",
                @"truncated": @(truncated),
                @"reason": reason ?: @""
            });
    NSMutableDictionary *result = [@{
        @"status": @"ok",
        @"tool": @"clipboard_read",
        @"text": text ?: @"",
        @"text_length": @(rawText.length),
        @"text_sha256": hash ?: @"",
        @"truncated": @(truncated),
        @"max_chars": @(maxChars),
        @"provider": provider[@"provider"] ?: @"unknown",
        @"system_clipboard": provider[@"system_clipboard"] ?: @NO,
        @"context_event_id": @(contextId),
        @"source": @"openphone.agentd"
    } mutableCopy];
    if (provider[@"fallback_path"]) {
        result[@"fallback_path"] = provider[@"fallback_path"];
    }
    OPRecordAudit(@"clipboard_read", taskId, @"clipboard.read", @"allow_task_scoped",
            @{
                @"reason": reason ?: @"",
                @"provider": result[@"provider"] ?: @"",
                @"system_clipboard": result[@"system_clipboard"] ?: @NO,
                @"text_length": result[@"text_length"] ?: @0,
                @"text_sha256": result[@"text_sha256"] ?: @"",
                @"truncated": result[@"truncated"] ?: @NO
            },
            [NSString stringWithFormat:@"chars:%@", result[@"text_length"] ?: @0]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"clipboard_read",
        @"arguments": @{
            @"reason": reason ?: @"",
            @"max_chars": @(maxChars)
        },
        @"result": OPClipboardTraceSummary(result)
    });
    return result;
}

static NSDictionary *OPClipboardWrite(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    NSString *text = OPStringFromRequest(request, @"text",
            OPStringFromRequest(request, @"clipboard_text", @""));
    if (text.length == 0 && request[@"text"] == nil && request[@"clipboard_text"] == nil) {
        return OPError(@"missing_clipboard_text");
    }

    NSDictionary *provider = OPClipboardSystemWrite(text ?: @"");
    BOOL wrote = !provider[@"fallback_write_ok"] || [provider[@"fallback_write_ok"] boolValue];
    if (!wrote) {
        return OPError(@"clipboard_write_failed");
    }
    NSString *hash = OPClipboardTextHash(text);
    long long contextId = OPRecordContextEvent(@"clipboard_written", @"openphone.agentd", taskId,
            @"Clipboard", OPClipboardLimitedText(text, 240, NULL), @{
                @"provider": provider[@"provider"] ?: @"unknown",
                @"system_clipboard": provider[@"system_clipboard"] ?: @NO,
                @"text_length": @(text.length),
                @"text_sha256": hash ?: @"",
                @"reason": reason ?: @""
            });
    NSMutableDictionary *result = [@{
        @"status": @"ok",
        @"tool": @"clipboard_write",
        @"text_length": @(text.length),
        @"text_sha256": hash ?: @"",
        @"provider": provider[@"provider"] ?: @"unknown",
        @"system_clipboard": provider[@"system_clipboard"] ?: @NO,
        @"context_event_id": @(contextId),
        @"source": @"openphone.agentd"
    } mutableCopy];
    if (provider[@"fallback_path"]) {
        result[@"fallback_path"] = provider[@"fallback_path"];
    }
    OPRecordAudit(@"clipboard_written", taskId, @"clipboard.write", @"allow_yolo",
            @{
                @"reason": reason ?: @"",
                @"provider": result[@"provider"] ?: @"",
                @"system_clipboard": result[@"system_clipboard"] ?: @NO,
                @"text_length": result[@"text_length"] ?: @0,
                @"text_sha256": result[@"text_sha256"] ?: @""
            },
            [NSString stringWithFormat:@"chars:%@", result[@"text_length"] ?: @0]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"clipboard_write",
        @"arguments": @{
            @"reason": reason ?: @"",
            @"text_length": @(text.length),
            @"text_sha256": hash ?: @""
        },
        @"result": OPClipboardTraceSummary(result)
    });
    return result;
}

static NSString *OPContactsAddressBookPath(void) {
    const char *override = getenv("OPENPHONE_CONTACTS_DB_PATH");
    if (override && override[0] != '\0') {
        return [NSString stringWithUTF8String:override];
    }
    return @"/var/mobile/Library/AddressBook/AddressBook.sqlitedb";
}

static NSDictionary *OPContactsProviderStatus(void) {
    NSString *addressBookPath = OPContactsAddressBookPath();
    BOOL addressBookAvailable = [[NSFileManager defaultManager] fileExistsAtPath:addressBookPath];
    BOOL fixtureAvailable = [[NSFileManager defaultManager] fileExistsAtPath:OPContactsFixturePath()];
    return @{
        @"status": @"implemented_partial",
        @"provider": @"AddressBook.sqlite",
        @"path": addressBookPath ?: @"",
        @"addressbook_available": @(addressBookAvailable),
        @"fixture_provider": @"openphone.contacts_fixture_file",
        @"fixture_path": OPContactsFixturePath(),
        @"fixture_available": @(fixtureAvailable),
        @"access": @"read_only",
        @"retention": @"search results are returned to caller; context/audit store counts and query hashes only"
    };
}

static BOOL OPSQLiteColumnExists(sqlite3 *db, NSString *table, NSString *column) {
    if (!db || table.length == 0 || column.length == 0) {
        return NO;
    }
    sqlite3_stmt *statement = NULL;
    NSString *sql = [NSString stringWithFormat:@"PRAGMA table_info(%@)", table];
    BOOL exists = NO;
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK) {
        while (sqlite3_step(statement) == SQLITE_ROW) {
            NSString *name = OPSQLiteColumnString(statement, 1);
            if ([name caseInsensitiveCompare:column] == NSOrderedSame) {
                exists = YES;
                break;
            }
        }
    }
    sqlite3_finalize(statement);
    return exists;
}

static NSString *OPContactsPersonColumnExpr(sqlite3 *db, NSString *column) {
    if (OPSQLiteColumnExists(db, @"ABPerson", column)) {
        return [NSString stringWithFormat:@"COALESCE(p.%@, '')", column];
    }
    return @"''";
}

static NSArray<NSString *> *OPContactsStringArray(id value, NSUInteger maxItems) {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    if ([value isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)value) {
            if (![item isKindOfClass:[NSString class]]) {
                continue;
            }
            NSString *text = [(NSString *)item stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (text.length == 0 || [items containsObject:text]) {
                continue;
            }
            [items addObject:text];
            if (items.count >= maxItems) {
                break;
            }
        }
    } else if ([value isKindOfClass:[NSString class]]) {
        NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length > 0) {
            [items addObject:text];
        }
    }
    return items;
}

static NSString *OPContactsDisplayName(NSString *first, NSString *middle, NSString *last,
        NSString *organization, NSString *nickname, long long rowId) {
    NSMutableArray<NSString *> *nameParts = [NSMutableArray array];
    for (NSString *part in @[first ?: @"", middle ?: @"", last ?: @""]) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) {
            [nameParts addObject:trimmed];
        }
    }
    NSString *displayName = [nameParts componentsJoinedByString:@" "];
    if (displayName.length == 0) {
        displayName = [organization stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if (displayName.length == 0) {
        displayName = [nickname stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if (displayName.length == 0) {
        displayName = [NSString stringWithFormat:@"Contact %lld", rowId];
    }
    return displayName ?: @"";
}

static BOOL OPContactsValueMatches(NSDictionary *contact, NSString *query) {
    if (query.length == 0) {
        return YES;
    }
    NSString *needle = query.lowercaseString ?: @"";
    NSMutableArray<NSString *> *haystack = [NSMutableArray array];
    for (NSString *key in @[@"display_name", @"given_name", @"middle_name", @"family_name",
            @"organization", @"department", @"job_title", @"nickname"]) {
        id value = contact[key];
        if ([value isKindOfClass:[NSString class]]) {
            [haystack addObject:value];
        }
    }
    for (NSString *key in @[@"phone_numbers", @"emails"]) {
        id value = contact[key];
        if ([value isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)value) {
                if ([item isKindOfClass:[NSString class]]) {
                    [haystack addObject:item];
                }
            }
        }
    }
    for (NSString *value in haystack) {
        if ([value.lowercaseString containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary *OPContactsNormalizedFixtureContact(NSDictionary *contact, NSUInteger index) {
    NSString *displayName = OPStringFromRequest(contact, @"display_name",
            OPStringFromRequest(contact, @"name", @""));
    NSString *givenName = OPStringFromRequest(contact, @"given_name",
            OPStringFromRequest(contact, @"first_name", @""));
    NSString *middleName = OPStringFromRequest(contact, @"middle_name", @"");
    NSString *familyName = OPStringFromRequest(contact, @"family_name",
            OPStringFromRequest(contact, @"last_name", @""));
    NSString *organization = OPStringFromRequest(contact, @"organization", @"");
    NSString *nickname = OPStringFromRequest(contact, @"nickname", @"");
    if (displayName.length == 0) {
        displayName = OPContactsDisplayName(givenName, middleName, familyName,
                organization, nickname, (long long)index + 1);
    }
    return @{
        @"contact_id": OPStringFromRequest(contact, @"contact_id",
                [NSString stringWithFormat:@"fixture-contact-%lu", (unsigned long)index + 1]),
        @"display_name": displayName ?: @"",
        @"given_name": givenName ?: @"",
        @"middle_name": middleName ?: @"",
        @"family_name": familyName ?: @"",
        @"organization": organization ?: @"",
        @"department": OPStringFromRequest(contact, @"department", @""),
        @"job_title": OPStringFromRequest(contact, @"job_title", @""),
        @"nickname": nickname ?: @"",
        @"phone_numbers": OPContactsStringArray(contact[@"phone_numbers"] ?: contact[@"phones"], 8),
        @"emails": OPContactsStringArray(contact[@"emails"] ?: contact[@"email_addresses"], 8),
        @"provider": @"openphone.contacts_fixture_file"
    };
}

static NSArray<NSDictionary *> *OPContactsFixtureSearch(NSString *query, NSUInteger limit) {
    NSDictionary *fixture = OPReadJSONFile(OPContactsFixturePath());
    NSArray *contacts = [fixture[@"contacts"] isKindOfClass:[NSArray class]]
            ? fixture[@"contacts"] : @[];
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    NSUInteger index = 0;
    for (id value in contacts) {
        if (![value isKindOfClass:[NSDictionary class]]) {
            index++;
            continue;
        }
        NSDictionary *contact = OPContactsNormalizedFixtureContact((NSDictionary *)value, index);
        index++;
        if (!OPContactsValueMatches(contact, query)) {
            continue;
        }
        [results addObject:contact];
        if (results.count >= limit) {
            break;
        }
    }
    return results;
}

static BOOL OPContactsLooksLikePhone(NSString *value) {
    NSUInteger digits = 0;
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if (c >= '0' && c <= '9') {
            digits++;
        }
    }
    return digits >= 5;
}

static NSDictionary *OPContactsMultiValues(sqlite3 *db, long long rowId) {
    NSMutableArray<NSString *> *phones = [NSMutableArray array];
    NSMutableArray<NSString *> *emails = [NSMutableArray array];
    if (!OPSQLiteTableExists(db, @"ABMultiValue") ||
            !OPSQLiteColumnExists(db, @"ABMultiValue", @"record_id") ||
            !OPSQLiteColumnExists(db, @"ABMultiValue", @"value")) {
        return @{@"phone_numbers": phones, @"emails": emails};
    }
    NSString *propertyExpr = OPSQLiteColumnExists(db, @"ABMultiValue", @"property")
            ? @"COALESCE(property, 0)" : @"0";
    NSString *orderBy = OPSQLiteColumnExists(db, @"ABMultiValue", @"identifier")
            ? @" ORDER BY identifier" : @"";
    sqlite3_stmt *statement = NULL;
    NSString *sql = [NSString stringWithFormat:
            @"SELECT %@, COALESCE(value, '') FROM ABMultiValue "
             "WHERE record_id = ?%@ LIMIT 32", propertyExpr, orderBy];
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, rowId);
        while (sqlite3_step(statement) == SQLITE_ROW) {
            long long property = sqlite3_column_int64(statement, 0);
            NSString *value = [OPSQLiteColumnString(statement, 1) stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (value.length == 0) {
                continue;
            }
            if ((property == 4 || [value containsString:@"@"]) && ![emails containsObject:value]) {
                [emails addObject:value];
            } else if ((property == 3 || OPContactsLooksLikePhone(value)) &&
                    ![phones containsObject:value]) {
                [phones addObject:value];
            }
            if (phones.count >= 8 && emails.count >= 8) {
                break;
            }
        }
    }
    sqlite3_finalize(statement);
    return @{
        @"phone_numbers": phones.count > 8 ? [phones subarrayWithRange:NSMakeRange(0, 8)] : phones,
        @"emails": emails.count > 8 ? [emails subarrayWithRange:NSMakeRange(0, 8)] : emails
    };
}

static NSArray<NSDictionary *> *OPContactsSystemSearch(NSString *query, NSUInteger limit,
        NSString **errorOut) {
    NSString *path = OPContactsAddressBookPath();
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(path.UTF8String, &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL);
    if (rc != SQLITE_OK) {
        if (errorOut) {
            *errorOut = db ? [NSString stringWithUTF8String:sqlite3_errmsg(db)] : @"sqlite_open_failed";
        }
        if (db) {
            sqlite3_close(db);
        }
        return nil;
    }
    sqlite3_busy_timeout(db, 5000);
    if (!OPSQLiteTableExists(db, @"ABPerson")) {
        if (errorOut) {
            *errorOut = @"abperson_table_missing";
        }
        sqlite3_close(db);
        return nil;
    }

    NSArray<NSString *> *columns = @[@"First", @"Middle", @"Last", @"Organization",
            @"Department", @"JobTitle", @"Nickname"];
    NSMutableArray<NSString *> *selectParts = [NSMutableArray array];
    NSMutableArray<NSString *> *searchParts = [NSMutableArray array];
    for (NSString *column in columns) {
        NSString *expr = OPContactsPersonColumnExpr(db, column);
        [selectParts addObject:expr];
        [searchParts addObject:expr];
    }
    NSString *select = [selectParts componentsJoinedByString:@", "];
    NSString *nameExpr = [searchParts componentsJoinedByString:@" || ' ' || "];
    BOOL hasQuery = query.length > 0;
    BOOL hasMultiValueSearch = OPSQLiteTableExists(db, @"ABMultiValue") &&
            OPSQLiteColumnExists(db, @"ABMultiValue", @"record_id") &&
            OPSQLiteColumnExists(db, @"ABMultiValue", @"value");
    NSString *where = @"";
    if (hasQuery) {
        NSString *multi = hasMultiValueSearch
                ? @" OR EXISTS (SELECT 1 FROM ABMultiValue mv WHERE mv.record_id = p.ROWID AND lower(COALESCE(mv.value, '')) LIKE ?)"
                : @"";
        where = [NSString stringWithFormat:@"WHERE lower(%@) LIKE ?%@", nameExpr, multi];
    }
    NSString *sql = [NSString stringWithFormat:
            @"SELECT p.ROWID, %@ FROM ABPerson p %@ ORDER BY p.ROWID DESC LIMIT ?",
            select, where];
    sqlite3_stmt *statement = NULL;
    NSMutableArray<NSDictionary *> *contacts = [NSMutableArray array];
    rc = sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL);
    if (rc == SQLITE_OK) {
        int bindIndex = 1;
        if (hasQuery) {
            NSString *like = [NSString stringWithFormat:@"%%%@%%", query.lowercaseString ?: @""];
            OPSQLiteBindText(statement, bindIndex++, like);
            if (hasMultiValueSearch) {
                OPSQLiteBindText(statement, bindIndex++, like);
            }
        }
        sqlite3_bind_int64(statement, bindIndex, (sqlite3_int64)limit);
        while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
            long long rowId = sqlite3_column_int64(statement, 0);
            NSString *first = OPSQLiteColumnString(statement, 1);
            NSString *middle = OPSQLiteColumnString(statement, 2);
            NSString *last = OPSQLiteColumnString(statement, 3);
            NSString *organization = OPSQLiteColumnString(statement, 4);
            NSString *department = OPSQLiteColumnString(statement, 5);
            NSString *jobTitle = OPSQLiteColumnString(statement, 6);
            NSString *nickname = OPSQLiteColumnString(statement, 7);
            NSDictionary *multi = OPContactsMultiValues(db, rowId);
            [contacts addObject:@{
                @"contact_id": [NSString stringWithFormat:@"ios-contact-%lld", rowId],
                @"row_id": @(rowId),
                @"display_name": OPContactsDisplayName(first, middle, last,
                        organization, nickname, rowId),
                @"given_name": first ?: @"",
                @"middle_name": middle ?: @"",
                @"family_name": last ?: @"",
                @"organization": organization ?: @"",
                @"department": department ?: @"",
                @"job_title": jobTitle ?: @"",
                @"nickname": nickname ?: @"",
                @"phone_numbers": multi[@"phone_numbers"] ?: @[],
                @"emails": multi[@"emails"] ?: @[],
                @"provider": @"AddressBook.sqlite"
            }];
        }
        if (rc != SQLITE_DONE && errorOut) {
            *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"contacts_query_failed";
        }
    } else if (errorOut) {
        *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"contacts_query_prepare_failed";
    }
    sqlite3_finalize(statement);
    sqlite3_close(db);
    if (rc != SQLITE_DONE && contacts.count == 0 && errorOut && *errorOut) {
        return nil;
    }
    return contacts;
}

static NSArray *OPContactsSummaryContacts(NSArray<NSDictionary *> *contacts, NSUInteger limit) {
    NSMutableArray *summary = [NSMutableArray array];
    for (NSDictionary *contact in contacts) {
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"contact_id", @"display_name", @"organization", @"job_title"]) {
            id value = contact[key];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                item[key] = value;
            }
        }
        NSArray *phones = [contact[@"phone_numbers"] isKindOfClass:[NSArray class]]
                ? contact[@"phone_numbers"] : @[];
        NSArray *emails = [contact[@"emails"] isKindOfClass:[NSArray class]]
                ? contact[@"emails"] : @[];
        if (phones.count > 0) {
            item[@"phone_numbers"] = phones.count > 4 ? [phones subarrayWithRange:NSMakeRange(0, 4)] : phones;
        }
        if (emails.count > 0) {
            item[@"emails"] = emails.count > 4 ? [emails subarrayWithRange:NSMakeRange(0, 4)] : emails;
        }
        if (item.count > 0) {
            [summary addObject:item];
        }
        if (summary.count >= limit) {
            break;
        }
    }
    return summary;
}

static NSDictionary *OPContactsTraceSummary(NSDictionary *result) {
    if (![result isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSArray *contacts = [result[@"contacts"] isKindOfClass:[NSArray class]]
            ? result[@"contacts"] : @[];
    return @{
        @"status": result[@"status"] ?: @"unknown",
        @"tool": @"contacts_search",
        @"provider": result[@"provider"] ?: @"unknown",
        @"query_length": result[@"query_length"] ?: @0,
        @"query_sha256": result[@"query_sha256"] ?: @"",
        @"count": result[@"count"] ?: @0,
        @"limit": result[@"limit"] ?: @0,
        @"contacts": OPContactsSummaryContacts(contacts, 8),
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPContactsSearch(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    NSString *query = OPStringFromRequest(request, @"query",
            OPStringFromRequest(request, @"name", @""));
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL allowEmptyQuery = OPBoolFromRequest(request, @"allow_empty_query", NO);
    if (query.length == 0 && !allowEmptyQuery) {
        return OPError(@"missing_contacts_query");
    }
    NSUInteger limit = OPLimitFromRequest(request, 10, 50);
    if (limit == 0) {
        limit = 10;
    }

    NSString *provider = @"";
    NSString *systemError = nil;
    NSArray<NSDictionary *> *contacts = nil;
    BOOL addressBookAvailable = [[NSFileManager defaultManager] fileExistsAtPath:OPContactsAddressBookPath()];
    if (addressBookAvailable) {
        contacts = OPContactsSystemSearch(query, limit, &systemError);
        if (contacts) {
            provider = @"AddressBook.sqlite";
        }
    }
    if (!contacts) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:OPContactsFixturePath()]) {
            contacts = OPContactsFixtureSearch(query, limit);
            provider = @"openphone.contacts_fixture_file";
        } else {
            NSString *reasonText = addressBookAvailable
                    ? [NSString stringWithFormat:@"contacts_system_query_failed:%@", systemError ?: @"unknown"]
                    : @"contacts_provider_unavailable";
            return OPError(reasonText);
        }
    }

    NSString *queryHash = OPClipboardTextHash(query ?: @"");
    long long contextId = OPRecordContextEvent(@"contacts_searched", @"openphone.agentd", taskId,
            @"Contacts search",
            [NSString stringWithFormat:@"Contacts search returned %lu result(s)",
                    (unsigned long)contacts.count],
            @{
                @"provider": provider ?: @"unknown",
                @"count": @(contacts.count),
                @"limit": @(limit),
                @"query_length": @(query.length),
                @"query_sha256": queryHash ?: @"",
                @"reason": reason ?: @""
            });
    NSDictionary *result = @{
        @"status": @"ok",
        @"tool": @"contacts_search",
        @"query": query ?: @"",
        @"query_length": @(query.length),
        @"query_sha256": queryHash ?: @"",
        @"limit": @(limit),
        @"contacts": contacts ?: @[],
        @"count": @(contacts.count),
        @"provider": provider ?: @"unknown",
        @"addressbook_path": OPContactsAddressBookPath(),
        @"fixture_path": OPContactsFixturePath(),
        @"context_event_id": @(contextId),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"contacts_searched", taskId, @"contacts.read", @"allow_task_scoped",
            @{
                @"reason": reason ?: @"",
                @"provider": provider ?: @"unknown",
                @"limit": @(limit),
                @"query_length": @(query.length),
                @"query_sha256": queryHash ?: @"",
                @"count": @(contacts.count)
            },
            [NSString stringWithFormat:@"count:%lu", (unsigned long)contacts.count]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"contacts_search",
        @"arguments": @{
            @"reason": reason ?: @"",
            @"query_length": @(query.length),
            @"query_sha256": queryHash ?: @"",
            @"limit": @(limit)
        },
        @"result": OPContactsTraceSummary(result)
    });
    return result;
}

static NSArray<NSString *> *OPCalendarDatabasePaths(void) {
    const char *override = getenv("OPENPHONE_CALENDAR_DB_PATH");
    if (override && override[0] != '\0') {
        return @[[NSString stringWithUTF8String:override]];
    }
    return @[
        @"/var/mobile/Library/Calendar/Calendar.sqlitedb",
        @"/private/var/mobile/Library/Calendar/Calendar.sqlitedb"
    ];
}

static NSString *OPCalendarDatabasePath(void) {
    NSArray<NSString *> *paths = OPCalendarDatabasePaths();
    for (NSString *path in paths) {
        if (OPPathExists(path)) {
            return path;
        }
    }
    return paths.count > 0 ? paths[0] : @"/var/mobile/Library/Calendar/Calendar.sqlitedb";
}

static NSDictionary *OPCalendarProviderStatus(void) {
    NSString *calendarPath = OPCalendarDatabasePath();
    BOOL calendarAvailable = OPPathExists(calendarPath);
    BOOL fixtureAvailable = OPPathExists(OPCalendarFixturePath());
    return @{
        @"status": @"implemented_partial",
        @"provider": @"Calendar.sqlitedb",
        @"path": calendarPath ?: @"",
        @"calendar_available": @(calendarAvailable),
        @"fixture_provider": @"openphone.calendar_fixture_file",
        @"fixture_path": OPCalendarFixturePath(),
        @"fixture_available": @(fixtureAvailable),
        @"protected_helper_socket": OPProtectedDataHelperSocketPath(),
        @"protected_helper_available": @(OPPathExists(OPProtectedDataHelperSocketPath())),
        @"protected_helper_manager": @"launchd_sh_wrapper_setuid_helper",
        @"protected_helper_binary": OPProtectedDataHelperBinaryPath() ?: @"",
        @"protected_helper_spawn_pid": @((int)OPProtectedDataHelperPid),
        @"protected_helper_last_spawn_ms": @((long long)OPProtectedDataHelperLastSpawnMs),
        @"protected_helper_last_spawn_error": OPProtectedDataHelperLastSpawnError ?: @"",
        @"access": @"read_only",
        @"retention": @"event summaries are returned to caller; context/audit store counts, query hashes, and time ranges only"
    };
}

static long long OPCalendarLongLongFromValue(id value, long long defaultValue) {
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value longLongValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value longLongValue];
    }
    return defaultValue;
}

static NSString *OPCalendarISO8601FromMs(long long ms) {
    if (ms <= 0) {
        return @"";
    }
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:((NSTimeInterval)ms / 1000.0)];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    return [formatter stringFromDate:date] ?: @"";
}

static long long OPCalendarMsFromSQLiteValue(double value) {
    if (value <= 0.0) {
        return 0;
    }
    if (value > 1000000000000.0) {
        return (long long)value;
    }
    if (value > 1000000000.0) {
        return (long long)(value * 1000.0);
    }
    return (long long)((value + 978307200.0) * 1000.0);
}

static double OPCalendarSQLiteValueFromUnixMs(long long ms) {
    if (ms <= 0) {
        return 0.0;
    }
    return ((double)ms / 1000.0) - 978307200.0;
}

static NSString *OPCalendarFirstExistingColumn(sqlite3 *db, NSString *table, NSArray<NSString *> *columns) {
    for (NSString *column in columns) {
        if (OPSQLiteColumnExists(db, table, column)) {
            return column;
        }
    }
    return @"";
}

static NSString *OPCalendarTextExpr(sqlite3 *db, NSString *table, NSString *alias,
        NSArray<NSString *> *columns) {
    NSString *column = OPCalendarFirstExistingColumn(db, table, columns);
    if (column.length == 0) {
        return @"''";
    }
    return [NSString stringWithFormat:@"COALESCE(%@.%@, '')", alias, column];
}

static NSString *OPCalendarNumberExpr(sqlite3 *db, NSString *table, NSString *alias,
        NSArray<NSString *> *columns) {
    NSString *column = OPCalendarFirstExistingColumn(db, table, columns);
    if (column.length == 0) {
        return @"0";
    }
    return [NSString stringWithFormat:@"COALESCE(%@.%@, 0)", alias, column];
}

static BOOL OPCalendarValueMatches(NSDictionary *event, NSString *query) {
    if (query.length == 0) {
        return YES;
    }
    NSString *needle = query.lowercaseString ?: @"";
    for (NSString *key in @[@"title", @"calendar_title", @"location", @"notes_preview"]) {
        id value = event[key];
        if ([value isKindOfClass:[NSString class]] &&
                [[(NSString *)value lowercaseString] containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary *OPCalendarNormalizedFixtureEvent(NSDictionary *event, NSUInteger index) {
    NSString *title = OPStringFromRequest(event, @"title",
            OPStringFromRequest(event, @"summary", @""));
    if (title.length == 0) {
        title = [NSString stringWithFormat:@"Calendar event %lu", (unsigned long)index + 1];
    }
    NSString *notes = OPStringFromRequest(event, @"notes",
            OPStringFromRequest(event, @"description", @""));
    BOOL notesTruncated = NO;
    NSString *notesPreview = OPClipboardLimitedText(notes, 240, &notesTruncated);
    long long startMs = OPCalendarLongLongFromValue(event[@"start_at_ms"] ?: event[@"start_ms"], 0);
    long long endMs = OPCalendarLongLongFromValue(event[@"end_at_ms"] ?: event[@"end_ms"], 0);
    return @{
        @"event_id": OPStringFromRequest(event, @"event_id",
                [NSString stringWithFormat:@"fixture-calendar-event-%lu", (unsigned long)index + 1]),
        @"title": title ?: @"",
        @"calendar_title": OPStringFromRequest(event, @"calendar_title",
                OPStringFromRequest(event, @"calendar", @"")),
        @"location": OPStringFromRequest(event, @"location", @""),
        @"notes_preview": notesPreview ?: @"",
        @"notes_truncated": @(notesTruncated),
        @"start_at_ms": @(startMs),
        @"start_at": OPCalendarISO8601FromMs(startMs),
        @"end_at_ms": @(endMs),
        @"end_at": OPCalendarISO8601FromMs(endMs),
        @"all_day": @(OPBoolFromRequest(event, @"all_day", NO)),
        @"provider": @"openphone.calendar_fixture_file"
    };
}

static NSArray<NSDictionary *> *OPCalendarFixtureSearch(NSString *query, NSUInteger limit,
        long long startAtMs, long long endAtMs) {
    NSDictionary *fixture = OPReadJSONFile(OPCalendarFixturePath());
    NSArray *events = [fixture[@"events"] isKindOfClass:[NSArray class]]
            ? fixture[@"events"] : @[];
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    NSUInteger index = 0;
    for (id value in events) {
        if (![value isKindOfClass:[NSDictionary class]]) {
            index++;
            continue;
        }
        NSDictionary *event = OPCalendarNormalizedFixtureEvent((NSDictionary *)value, index);
        index++;
        long long eventStart = OPCalendarLongLongFromValue(event[@"start_at_ms"], 0);
        if (startAtMs > 0 && eventStart > 0 && eventStart < startAtMs) {
            continue;
        }
        if (endAtMs > 0 && eventStart > 0 && eventStart > endAtMs) {
            continue;
        }
        if (!OPCalendarValueMatches(event, query)) {
            continue;
        }
        [results addObject:event];
        if (results.count >= limit) {
            break;
        }
    }
    return results;
}

static NSArray<NSDictionary *> *OPCalendarSystemSearchAtPath(NSString *path, NSString *query,
        NSUInteger limit, long long startAtMs, long long endAtMs, NSString **errorOut) {
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(path.UTF8String, &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL);
    if (rc != SQLITE_OK) {
        if (errorOut) {
            *errorOut = db ? [NSString stringWithUTF8String:sqlite3_errmsg(db)] : @"sqlite_open_failed";
        }
        if (db) {
            sqlite3_close(db);
        }
        return nil;
    }
    sqlite3_busy_timeout(db, 5000);
    if (!OPSQLiteTableExists(db, @"CalendarItem")) {
        if (errorOut) {
            *errorOut = @"calendaritem_table_missing";
        }
        sqlite3_close(db);
        return nil;
    }

    NSString *calendarIdColumn = OPCalendarFirstExistingColumn(db, @"CalendarItem",
            @[@"calendar_id", @"calendarID", @"calendar"]);
    NSString *locationIdColumn = OPCalendarFirstExistingColumn(db, @"CalendarItem",
            @[@"location_id", @"locationID", @"structured_location_id"]);
    BOOL hasCalendarJoin = calendarIdColumn.length > 0 && OPSQLiteTableExists(db, @"Calendar");
    BOOL hasLocationJoin = locationIdColumn.length > 0 && OPSQLiteTableExists(db, @"Location");

    NSString *titleExpr = OPCalendarTextExpr(db, @"CalendarItem", @"i",
            @[@"summary", @"title", @"name"]);
    NSString *directLocationExpr = OPCalendarTextExpr(db, @"CalendarItem", @"i",
            @[@"location", @"location_title", @"locationTitle"]);
    NSString *notesExpr = OPCalendarTextExpr(db, @"CalendarItem", @"i",
            @[@"description", @"notes", @"comment"]);
    NSString *startExpr = OPCalendarNumberExpr(db, @"CalendarItem", @"i",
            @[@"start_date", @"startDate", @"start_time", @"startTime"]);
    NSString *endExpr = OPCalendarNumberExpr(db, @"CalendarItem", @"i",
            @[@"end_date", @"endDate", @"end_time", @"endTime"]);
    NSString *allDayExpr = OPCalendarNumberExpr(db, @"CalendarItem", @"i",
            @[@"all_day", @"allDay", @"is_all_day", @"isAllDay"]);
    NSString *calendarTitleExpr = hasCalendarJoin
            ? OPCalendarTextExpr(db, @"Calendar", @"c", @[@"title", @"displayName", @"summary", @"name"])
            : @"''";
    NSString *joinedLocationExpr = hasLocationJoin
            ? OPCalendarTextExpr(db, @"Location", @"l", @[@"title", @"address", @"displayName", @"location"])
            : @"''";
    NSString *locationExpr = [directLocationExpr isEqualToString:@"''"]
            ? joinedLocationExpr
            : [NSString stringWithFormat:@"trim(%@ || ' ' || %@)", directLocationExpr, joinedLocationExpr];

    NSMutableString *from = [NSMutableString stringWithString:@"FROM CalendarItem i"];
    if (hasCalendarJoin) {
        [from appendFormat:@" LEFT JOIN Calendar c ON c.ROWID = i.%@", calendarIdColumn];
    }
    if (hasLocationJoin) {
        [from appendFormat:@" LEFT JOIN Location l ON l.ROWID = i.%@", locationIdColumn];
    }

    NSMutableArray<NSString *> *whereParts = [NSMutableArray array];
    BOOL hasQuery = query.length > 0;
    if (hasQuery) {
        [whereParts addObject:[NSString stringWithFormat:
                @"lower(%@ || ' ' || %@ || ' ' || %@ || ' ' || %@) LIKE ?",
                titleExpr, locationExpr, notesExpr, calendarTitleExpr]];
    }
    if (startAtMs > 0 && ![startExpr isEqualToString:@"0"]) {
        [whereParts addObject:[NSString stringWithFormat:@"%@ >= ?", startExpr]];
    }
    if (endAtMs > 0 && ![startExpr isEqualToString:@"0"]) {
        [whereParts addObject:[NSString stringWithFormat:@"%@ <= ?", startExpr]];
    }
    NSString *where = whereParts.count > 0
            ? [NSString stringWithFormat:@"WHERE %@", [whereParts componentsJoinedByString:@" AND "]]
            : @"";
    NSString *orderBy = [startExpr isEqualToString:@"0"] ? @"i.ROWID DESC" : [NSString stringWithFormat:@"%@ ASC", startExpr];
    NSString *sql = [NSString stringWithFormat:
            @"SELECT i.ROWID, %@, %@, %@, %@, %@, %@, %@ "
             "%@ %@ ORDER BY %@ LIMIT ?",
            titleExpr, locationExpr, notesExpr, startExpr, endExpr, allDayExpr,
            calendarTitleExpr, from, where, orderBy];

    sqlite3_stmt *statement = NULL;
    NSMutableArray<NSDictionary *> *events = [NSMutableArray array];
    rc = sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL);
    if (rc == SQLITE_OK) {
        int bindIndex = 1;
        if (hasQuery) {
            NSString *like = [NSString stringWithFormat:@"%%%@%%", query.lowercaseString ?: @""];
            OPSQLiteBindText(statement, bindIndex++, like);
        }
        if (startAtMs > 0 && ![startExpr isEqualToString:@"0"]) {
            sqlite3_bind_double(statement, bindIndex++, OPCalendarSQLiteValueFromUnixMs(startAtMs));
        }
        if (endAtMs > 0 && ![startExpr isEqualToString:@"0"]) {
            sqlite3_bind_double(statement, bindIndex++, OPCalendarSQLiteValueFromUnixMs(endAtMs));
        }
        sqlite3_bind_int64(statement, bindIndex, (sqlite3_int64)limit);
        while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
            long long rowId = sqlite3_column_int64(statement, 0);
            NSString *title = OPSQLiteColumnString(statement, 1);
            NSString *location = OPSQLiteColumnString(statement, 2);
            NSString *notes = OPSQLiteColumnString(statement, 3);
            long long startMs = OPCalendarMsFromSQLiteValue(sqlite3_column_double(statement, 4));
            long long endMs = OPCalendarMsFromSQLiteValue(sqlite3_column_double(statement, 5));
            BOOL allDay = sqlite3_column_int64(statement, 6) != 0;
            NSString *calendarTitle = OPSQLiteColumnString(statement, 7);
            BOOL notesTruncated = NO;
            NSString *notesPreview = OPClipboardLimitedText(notes, 240, &notesTruncated);
            [events addObject:@{
                @"event_id": [NSString stringWithFormat:@"ios-calendar-event-%lld", rowId],
                @"row_id": @(rowId),
                @"title": title ?: @"",
                @"calendar_title": calendarTitle ?: @"",
                @"location": location ?: @"",
                @"notes_preview": notesPreview ?: @"",
                @"notes_truncated": @(notesTruncated),
                @"start_at_ms": @(startMs),
                @"start_at": OPCalendarISO8601FromMs(startMs),
                @"end_at_ms": @(endMs),
                @"end_at": OPCalendarISO8601FromMs(endMs),
                @"all_day": @(allDay),
                @"provider": @"Calendar.sqlitedb"
            }];
        }
        if (rc != SQLITE_DONE && errorOut) {
            *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"calendar_query_failed";
        }
    } else if (errorOut) {
        *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"calendar_query_prepare_failed";
    }
    sqlite3_finalize(statement);
    sqlite3_close(db);
    if (rc != SQLITE_DONE && events.count == 0 && errorOut && *errorOut) {
        return nil;
    }
    return events;
}

static NSArray<NSDictionary *> *OPCalendarSystemSearch(NSString *query, NSUInteger limit,
        long long startAtMs, long long endAtMs, NSString **errorOut) {
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    for (NSString *path in OPCalendarDatabasePaths()) {
        NSString *pathError = nil;
        NSArray<NSDictionary *> *events = OPCalendarSystemSearchAtPath(path, query, limit,
                startAtMs, endAtMs, &pathError);
        if (events) {
            return events;
        }
        if (pathError.length > 0) {
            [errors addObject:[NSString stringWithFormat:@"%@:%@", path.lastPathComponent ?: @"calendar", pathError]];
        }
    }
    if (errorOut) {
        *errorOut = errors.count > 0 ? [errors componentsJoinedByString:@";"] : @"calendar_query_failed";
    }
    return nil;
}

static NSArray *OPCalendarSummaryEvents(NSArray<NSDictionary *> *events, NSUInteger limit) {
    NSMutableArray *summary = [NSMutableArray array];
    for (NSDictionary *event in events) {
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"event_id", @"title", @"calendar_title", @"location",
                @"start_at_ms", @"start_at", @"end_at_ms", @"end_at", @"all_day"]) {
            id value = event[key];
            if (value) {
                item[key] = value;
            }
        }
        NSString *notesPreview = [event[@"notes_preview"] isKindOfClass:[NSString class]]
                ? event[@"notes_preview"] : @"";
        if (notesPreview.length > 0) {
            item[@"notes_preview"] = notesPreview;
            item[@"notes_truncated"] = event[@"notes_truncated"] ?: @NO;
        }
        if (item.count > 0) {
            [summary addObject:item];
        }
        if (summary.count >= limit) {
            break;
        }
    }
    return summary;
}

static NSDictionary *OPCalendarTraceSummary(NSDictionary *result) {
    if (![result isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSArray *events = [result[@"events"] isKindOfClass:[NSArray class]]
            ? result[@"events"] : @[];
    return @{
        @"status": result[@"status"] ?: @"unknown",
        @"tool": @"calendar_search",
        @"provider": result[@"provider"] ?: @"unknown",
        @"query_length": result[@"query_length"] ?: @0,
        @"query_sha256": result[@"query_sha256"] ?: @"",
        @"start_at_ms": result[@"start_at_ms"] ?: @0,
        @"end_at_ms": result[@"end_at_ms"] ?: @0,
        @"count": result[@"count"] ?: @0,
        @"limit": result[@"limit"] ?: @0,
        @"events": OPCalendarSummaryEvents(events, 8),
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPCalendarSearch(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    NSString *query = OPStringFromRequest(request, @"query",
            OPStringFromRequest(request, @"title", @""));
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    long long startAtMs = OPCalendarLongLongFromValue(request[@"start_at_ms"] ?: request[@"start_ms"], 0);
    long long endAtMs = OPCalendarLongLongFromValue(request[@"end_at_ms"] ?: request[@"end_ms"], 0);
    BOOL allowEmptyQuery = OPBoolFromRequest(request, @"allow_empty_query", NO);
    if (query.length == 0 && startAtMs <= 0 && endAtMs <= 0 && !allowEmptyQuery) {
        return OPError(@"missing_calendar_query_or_range");
    }
    NSUInteger limit = OPLimitFromRequest(request, 10, 50);
    if (limit == 0) {
        limit = 10;
    }

    NSString *provider = @"";
    NSString *systemError = nil;
    NSArray<NSDictionary *> *events = nil;
    BOOL calendarAvailable = OPPathExists(OPCalendarDatabasePath());
    events = OPCalendarSystemSearch(query, limit, startAtMs, endAtMs, &systemError);
    if (events) {
        provider = @"Calendar.sqlitedb";
    }
    if (!events && !OPProtectedDataHelperRole()) {
        NSMutableDictionary *helperRequest = [request mutableCopy] ?: [NSMutableDictionary dictionary];
        helperRequest[@"command"] = @"calendar_search";
        helperRequest[@"task_id"] = @"";
        NSDictionary *helperResult = OPProtectedDataHelperRequest(helperRequest);
        if ([helperResult[@"status"] isEqualToString:@"ok"] &&
                [helperResult[@"events"] isKindOfClass:[NSArray class]]) {
            events = helperResult[@"events"];
            provider = [helperResult[@"provider"] isKindOfClass:[NSString class]]
                    ? helperResult[@"provider"] : @"Calendar.sqlitedb";
        } else if ([helperResult[@"reason"] isKindOfClass:[NSString class]]) {
            systemError = systemError.length > 0
                    ? [NSString stringWithFormat:@"%@;protected_helper:%@", systemError, helperResult[@"reason"]]
                    : [NSString stringWithFormat:@"protected_helper:%@", helperResult[@"reason"]];
        }
    }
    if (!events) {
        if (OPPathExists(OPCalendarFixturePath())) {
            events = OPCalendarFixtureSearch(query, limit, startAtMs, endAtMs);
            provider = @"openphone.calendar_fixture_file";
        } else {
            NSString *reasonText = (calendarAvailable || systemError.length > 0)
                    ? [NSString stringWithFormat:@"calendar_system_query_failed:%@", systemError ?: @"unknown"]
                    : @"calendar_provider_unavailable";
            return OPError(reasonText);
        }
    }

    NSString *queryHash = OPClipboardTextHash(query ?: @"");
    long long contextId = OPRecordContextEvent(@"calendar_searched", @"openphone.agentd", taskId,
            @"Calendar search",
            [NSString stringWithFormat:@"Calendar search returned %lu event(s)",
                    (unsigned long)events.count],
            @{
                @"provider": provider ?: @"unknown",
                @"count": @(events.count),
                @"limit": @(limit),
                @"query_length": @(query.length),
                @"query_sha256": queryHash ?: @"",
                @"start_at_ms": @(startAtMs),
                @"end_at_ms": @(endAtMs),
                @"reason": reason ?: @""
            });
    NSDictionary *result = @{
        @"status": @"ok",
        @"tool": @"calendar_search",
        @"query": query ?: @"",
        @"query_length": @(query.length),
        @"query_sha256": queryHash ?: @"",
        @"start_at_ms": @(startAtMs),
        @"start_at": OPCalendarISO8601FromMs(startAtMs),
        @"end_at_ms": @(endAtMs),
        @"end_at": OPCalendarISO8601FromMs(endAtMs),
        @"limit": @(limit),
        @"events": events ?: @[],
        @"count": @(events.count),
        @"provider": provider ?: @"unknown",
        @"calendar_path": OPCalendarDatabasePath(),
        @"fixture_path": OPCalendarFixturePath(),
        @"context_event_id": @(contextId),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"calendar_searched", taskId, @"calendar.read", @"allow_task_scoped",
            @{
                @"reason": reason ?: @"",
                @"provider": provider ?: @"unknown",
                @"limit": @(limit),
                @"query_length": @(query.length),
                @"query_sha256": queryHash ?: @"",
                @"start_at_ms": @(startAtMs),
                @"end_at_ms": @(endAtMs),
                @"count": @(events.count)
            },
            [NSString stringWithFormat:@"count:%lu", (unsigned long)events.count]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"calendar_search",
        @"arguments": @{
            @"reason": reason ?: @"",
            @"query_length": @(query.length),
            @"query_sha256": queryHash ?: @"",
            @"start_at_ms": @(startAtMs),
            @"end_at_ms": @(endAtMs),
            @"limit": @(limit)
        },
        @"result": OPCalendarTraceSummary(result)
    });
    return result;
}

static NSArray<NSString *> *OPCallsDatabasePaths(void) {
    const char *override = getenv("OPENPHONE_CALLS_DB_PATH");
    if (override && override[0] != '\0') {
        return @[[NSString stringWithUTF8String:override]];
    }
    return @[
        @"/var/mobile/Library/CallHistoryDB/CallHistory.storedata",
        @"/private/var/mobile/Library/CallHistoryDB/CallHistory.storedata"
    ];
}

static NSString *OPCallsDatabasePath(void) {
    NSArray<NSString *> *paths = OPCallsDatabasePaths();
    for (NSString *path in paths) {
        if (OPPathExists(path)) {
            return path;
        }
    }
    return paths.count > 0 ? paths[0] : @"/var/mobile/Library/CallHistoryDB/CallHistory.storedata";
}

static NSDictionary *OPCallsProviderStatus(void) {
    NSString *callsPath = OPCallsDatabasePath();
    BOOL callHistoryAvailable = OPPathExists(callsPath);
    BOOL fixtureAvailable = OPPathExists(OPCallsFixturePath());
    return @{
        @"status": @"implemented_partial",
        @"provider": @"CallHistory.storedata",
        @"path": callsPath ?: @"",
        @"call_history_available": @(callHistoryAvailable),
        @"fixture_provider": @"openphone.calls_fixture_file",
        @"fixture_path": OPCallsFixturePath(),
        @"fixture_available": @(fixtureAvailable),
        @"protected_helper_socket": OPProtectedDataHelperSocketPath(),
        @"protected_helper_available": @(OPPathExists(OPProtectedDataHelperSocketPath())),
        @"protected_helper_manager": @"launchd_sh_wrapper_setuid_helper",
        @"protected_helper_binary": OPProtectedDataHelperBinaryPath() ?: @"",
        @"protected_helper_spawn_pid": @((int)OPProtectedDataHelperPid),
        @"protected_helper_last_spawn_ms": @((long long)OPProtectedDataHelperLastSpawnMs),
        @"protected_helper_last_spawn_error": OPProtectedDataHelperLastSpawnError ?: @"",
        @"access": @"read_only",
        @"retention": @"call summaries are returned to caller; context/audit store counts, query hashes, and time ranges only"
    };
}

static NSString *OPCallsTableName(sqlite3 *db) {
    for (NSString *table in @[@"ZCALLRECORD", @"CallRecord", @"call_history", @"calls"]) {
        if (OPSQLiteTableExists(db, table)) {
            return table;
        }
    }
    return @"";
}

static NSString *OPCallsTextExpr(sqlite3 *db, NSString *table, NSString *alias,
        NSArray<NSString *> *columns) {
    NSString *column = OPCalendarFirstExistingColumn(db, table, columns);
    if (column.length == 0) {
        return @"''";
    }
    return [NSString stringWithFormat:@"COALESCE(%@.%@, '')", alias, column];
}

static NSString *OPCallsNumberExpr(sqlite3 *db, NSString *table, NSString *alias,
        NSArray<NSString *> *columns) {
    NSString *column = OPCalendarFirstExistingColumn(db, table, columns);
    if (column.length == 0) {
        return @"0";
    }
    return [NSString stringWithFormat:@"COALESCE(%@.%@, 0)", alias, column];
}

static NSString *OPCallsDirectionFromOriginated(long long originated) {
    if (originated == 1) {
        return @"outgoing";
    }
    if (originated == 0) {
        return @"incoming";
    }
    return @"unknown";
}

static BOOL OPCallsValueMatches(NSDictionary *call, NSString *query) {
    if (query.length == 0) {
        return YES;
    }
    NSString *needle = query.lowercaseString ?: @"";
    for (NSString *key in @[@"address", @"display_name", @"service", @"direction", @"call_type"]) {
        id value = call[key];
        if ([value isKindOfClass:[NSString class]] &&
                [[(NSString *)value lowercaseString] containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary *OPCallsNormalizedFixtureCall(NSDictionary *call, NSUInteger index) {
    long long startMs = OPCalendarLongLongFromValue(call[@"start_at_ms"] ?: call[@"start_ms"], 0);
    long long durationSeconds = OPCalendarLongLongFromValue(
            call[@"duration_seconds"] ?: call[@"duration"], 0);
    NSString *direction = OPStringFromRequest(call, @"direction", @"unknown");
    if (direction.length == 0) {
        direction = @"unknown";
    }
    return @{
        @"call_id": OPStringFromRequest(call, @"call_id",
                [NSString stringWithFormat:@"fixture-call-%lu", (unsigned long)index + 1]),
        @"address": OPStringFromRequest(call, @"address",
                OPStringFromRequest(call, @"phone_number", @"")),
        @"display_name": OPStringFromRequest(call, @"display_name",
                OPStringFromRequest(call, @"name", @"")),
        @"service": OPStringFromRequest(call, @"service", @""),
        @"direction": direction ?: @"unknown",
        @"answered": @(OPBoolFromRequest(call, @"answered", YES)),
        @"duration_seconds": @(durationSeconds),
        @"start_at_ms": @(startMs),
        @"start_at": OPCalendarISO8601FromMs(startMs),
        @"call_type": OPStringFromRequest(call, @"call_type", @""),
        @"provider": @"openphone.calls_fixture_file"
    };
}

static NSArray<NSDictionary *> *OPCallsFixtureSearch(NSString *query, NSUInteger limit,
        long long startAtMs, long long endAtMs) {
    NSDictionary *fixture = OPReadJSONFile(OPCallsFixturePath());
    NSArray *calls = [fixture[@"calls"] isKindOfClass:[NSArray class]]
            ? fixture[@"calls"] : @[];
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    NSUInteger index = 0;
    for (id value in calls) {
        if (![value isKindOfClass:[NSDictionary class]]) {
            index++;
            continue;
        }
        NSDictionary *call = OPCallsNormalizedFixtureCall((NSDictionary *)value, index);
        index++;
        long long callStart = OPCalendarLongLongFromValue(call[@"start_at_ms"], 0);
        if (startAtMs > 0 && callStart > 0 && callStart < startAtMs) {
            continue;
        }
        if (endAtMs > 0 && callStart > 0 && callStart > endAtMs) {
            continue;
        }
        if (!OPCallsValueMatches(call, query)) {
            continue;
        }
        [results addObject:call];
        if (results.count >= limit) {
            break;
        }
    }
    return results;
}

static NSArray<NSDictionary *> *OPCallsSystemSearchAtPath(NSString *path, NSString *query,
        NSUInteger limit, long long startAtMs, long long endAtMs, NSString **errorOut) {
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(path.UTF8String, &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL);
    if (rc != SQLITE_OK) {
        if (errorOut) {
            *errorOut = db ? [NSString stringWithUTF8String:sqlite3_errmsg(db)] : @"sqlite_open_failed";
        }
        if (db) {
            sqlite3_close(db);
        }
        return nil;
    }
    sqlite3_busy_timeout(db, 5000);
    NSString *table = OPCallsTableName(db);
    if (table.length == 0) {
        if (errorOut) {
            *errorOut = @"call_table_missing";
        }
        sqlite3_close(db);
        return nil;
    }

    NSString *addressExpr = OPCallsTextExpr(db, table, @"c",
            @[@"ZADDRESS", @"address", @"phone_number", @"number", @"sender"]);
    NSString *displayNameExpr = OPCallsTextExpr(db, table, @"c",
            @[@"ZNAME", @"ZDISPLAYNAME", @"display_name", @"name", @"caller_name"]);
    NSString *serviceExpr = OPCallsTextExpr(db, table, @"c",
            @[@"ZSERVICE_PROVIDER", @"ZSERVICE", @"service", @"provider"]);
    NSString *startExpr = OPCallsNumberExpr(db, table, @"c",
            @[@"ZDATE", @"date", @"timestamp", @"start_date", @"start_time"]);
    NSString *durationExpr = OPCallsNumberExpr(db, table, @"c",
            @[@"ZDURATION", @"duration", @"duration_seconds"]);
    NSString *originatedExpr = OPCallsNumberExpr(db, table, @"c",
            @[@"ZORIGINATED", @"originated", @"outgoing", @"is_outgoing"]);
    NSString *answeredExpr = OPCallsNumberExpr(db, table, @"c",
            @[@"ZANSWERED", @"answered", @"is_answered"]);
    NSString *callTypeExpr = OPCallsTextExpr(db, table, @"c",
            @[@"ZCALLTYPE", @"call_type", @"type"]);

    NSMutableArray<NSString *> *whereParts = [NSMutableArray array];
    BOOL hasQuery = query.length > 0;
    if (hasQuery) {
        [whereParts addObject:[NSString stringWithFormat:
                @"lower(%@ || ' ' || %@ || ' ' || %@ || ' ' || %@) LIKE ?",
                addressExpr, displayNameExpr, serviceExpr, callTypeExpr]];
    }
    if (startAtMs > 0 && ![startExpr isEqualToString:@"0"]) {
        [whereParts addObject:[NSString stringWithFormat:@"%@ >= ?", startExpr]];
    }
    if (endAtMs > 0 && ![startExpr isEqualToString:@"0"]) {
        [whereParts addObject:[NSString stringWithFormat:@"%@ <= ?", startExpr]];
    }
    NSString *where = whereParts.count > 0
            ? [NSString stringWithFormat:@"WHERE %@", [whereParts componentsJoinedByString:@" AND "]]
            : @"";
    NSString *orderBy = [startExpr isEqualToString:@"0"] ? @"c.ROWID DESC" : [NSString stringWithFormat:@"%@ DESC", startExpr];
    NSString *sql = [NSString stringWithFormat:
            @"SELECT c.ROWID, %@, %@, %@, %@, %@, %@, %@, %@ "
             "FROM %@ c %@ ORDER BY %@ LIMIT ?",
            addressExpr, displayNameExpr, serviceExpr, startExpr, durationExpr,
            originatedExpr, answeredExpr, callTypeExpr, table, where, orderBy];

    sqlite3_stmt *statement = NULL;
    NSMutableArray<NSDictionary *> *calls = [NSMutableArray array];
    rc = sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL);
    if (rc == SQLITE_OK) {
        int bindIndex = 1;
        if (hasQuery) {
            NSString *like = [NSString stringWithFormat:@"%%%@%%", query.lowercaseString ?: @""];
            OPSQLiteBindText(statement, bindIndex++, like);
        }
        if (startAtMs > 0 && ![startExpr isEqualToString:@"0"]) {
            sqlite3_bind_double(statement, bindIndex++, OPCalendarSQLiteValueFromUnixMs(startAtMs));
        }
        if (endAtMs > 0 && ![startExpr isEqualToString:@"0"]) {
            sqlite3_bind_double(statement, bindIndex++, OPCalendarSQLiteValueFromUnixMs(endAtMs));
        }
        sqlite3_bind_int64(statement, bindIndex, (sqlite3_int64)limit);
        while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
            long long rowId = sqlite3_column_int64(statement, 0);
            NSString *address = OPSQLiteColumnString(statement, 1);
            NSString *displayName = OPSQLiteColumnString(statement, 2);
            NSString *service = OPSQLiteColumnString(statement, 3);
            long long startMs = OPCalendarMsFromSQLiteValue(sqlite3_column_double(statement, 4));
            long long durationSeconds = sqlite3_column_int64(statement, 5);
            long long originated = sqlite3_column_int64(statement, 6);
            BOOL answered = sqlite3_column_int64(statement, 7) != 0;
            NSString *callType = OPSQLiteColumnString(statement, 8);
            [calls addObject:@{
                @"call_id": [NSString stringWithFormat:@"ios-call-%lld", rowId],
                @"row_id": @(rowId),
                @"address": address ?: @"",
                @"display_name": displayName ?: @"",
                @"service": service ?: @"",
                @"direction": OPCallsDirectionFromOriginated(originated),
                @"answered": @(answered),
                @"duration_seconds": @(durationSeconds),
                @"start_at_ms": @(startMs),
                @"start_at": OPCalendarISO8601FromMs(startMs),
                @"call_type": callType ?: @"",
                @"provider": @"CallHistory.storedata"
            }];
        }
        if (rc != SQLITE_DONE && errorOut) {
            *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"calls_query_failed";
        }
    } else if (errorOut) {
        *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"calls_query_prepare_failed";
    }
    sqlite3_finalize(statement);
    sqlite3_close(db);
    if (rc != SQLITE_DONE && calls.count == 0 && errorOut && *errorOut) {
        return nil;
    }
    return calls;
}

static NSArray<NSDictionary *> *OPCallsSystemSearch(NSString *query, NSUInteger limit,
        long long startAtMs, long long endAtMs, NSString **errorOut) {
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    for (NSString *path in OPCallsDatabasePaths()) {
        NSString *pathError = nil;
        NSArray<NSDictionary *> *calls = OPCallsSystemSearchAtPath(path, query, limit,
                startAtMs, endAtMs, &pathError);
        if (calls) {
            return calls;
        }
        if (pathError.length > 0) {
            [errors addObject:[NSString stringWithFormat:@"%@:%@", path.lastPathComponent ?: @"calls", pathError]];
        }
    }
    if (errorOut) {
        *errorOut = errors.count > 0 ? [errors componentsJoinedByString:@";"] : @"calls_query_failed";
    }
    return nil;
}

static NSArray *OPCallsSummaryCalls(NSArray<NSDictionary *> *calls, NSUInteger limit) {
    NSMutableArray *summary = [NSMutableArray array];
    for (NSDictionary *call in calls) {
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"call_id", @"address", @"display_name", @"service", @"direction",
                @"answered", @"duration_seconds", @"start_at_ms", @"start_at", @"call_type"]) {
            id value = call[key];
            if (value) {
                item[key] = value;
            }
        }
        if (item.count > 0) {
            [summary addObject:item];
        }
        if (summary.count >= limit) {
            break;
        }
    }
    return summary;
}

static NSDictionary *OPCallsTraceSummary(NSDictionary *result) {
    if (![result isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSArray *calls = [result[@"calls"] isKindOfClass:[NSArray class]]
            ? result[@"calls"] : @[];
    return @{
        @"status": result[@"status"] ?: @"unknown",
        @"tool": @"calls_search",
        @"provider": result[@"provider"] ?: @"unknown",
        @"query_length": result[@"query_length"] ?: @0,
        @"query_sha256": result[@"query_sha256"] ?: @"",
        @"start_at_ms": result[@"start_at_ms"] ?: @0,
        @"end_at_ms": result[@"end_at_ms"] ?: @0,
        @"count": result[@"count"] ?: @0,
        @"limit": result[@"limit"] ?: @0,
        @"calls": OPCallsSummaryCalls(calls, 8),
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPCallsSearch(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    NSString *query = OPStringFromRequest(request, @"query",
            OPStringFromRequest(request, @"phone_number",
                    OPStringFromRequest(request, @"address", @"")));
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    long long startAtMs = OPCalendarLongLongFromValue(request[@"start_at_ms"] ?: request[@"start_ms"], 0);
    long long endAtMs = OPCalendarLongLongFromValue(request[@"end_at_ms"] ?: request[@"end_ms"], 0);
    BOOL allowEmptyQuery = OPBoolFromRequest(request, @"allow_empty_query", NO);
    if (query.length == 0 && startAtMs <= 0 && endAtMs <= 0 && !allowEmptyQuery) {
        return OPError(@"missing_calls_query_or_range");
    }
    NSUInteger limit = OPLimitFromRequest(request, 10, 50);
    if (limit == 0) {
        limit = 10;
    }

    NSString *provider = @"";
    NSString *systemError = nil;
    NSArray<NSDictionary *> *calls = nil;
    BOOL callHistoryAvailable = OPPathExists(OPCallsDatabasePath());
    calls = OPCallsSystemSearch(query, limit, startAtMs, endAtMs, &systemError);
    if (calls) {
        provider = @"CallHistory.storedata";
    }
    if (!calls && !OPProtectedDataHelperRole()) {
        NSMutableDictionary *helperRequest = [request mutableCopy] ?: [NSMutableDictionary dictionary];
        helperRequest[@"command"] = @"calls_search";
        helperRequest[@"task_id"] = @"";
        NSDictionary *helperResult = OPProtectedDataHelperRequest(helperRequest);
        if ([helperResult[@"status"] isEqualToString:@"ok"] &&
                [helperResult[@"calls"] isKindOfClass:[NSArray class]]) {
            calls = helperResult[@"calls"];
            provider = [helperResult[@"provider"] isKindOfClass:[NSString class]]
                    ? helperResult[@"provider"] : @"CallHistory.storedata";
        } else if ([helperResult[@"reason"] isKindOfClass:[NSString class]]) {
            systemError = systemError.length > 0
                    ? [NSString stringWithFormat:@"%@;protected_helper:%@", systemError, helperResult[@"reason"]]
                    : [NSString stringWithFormat:@"protected_helper:%@", helperResult[@"reason"]];
        }
    }
    if (!calls) {
        if (OPPathExists(OPCallsFixturePath())) {
            calls = OPCallsFixtureSearch(query, limit, startAtMs, endAtMs);
            provider = @"openphone.calls_fixture_file";
        } else {
            NSString *reasonText = (callHistoryAvailable || systemError.length > 0)
                    ? [NSString stringWithFormat:@"calls_system_query_failed:%@", systemError ?: @"unknown"]
                    : @"calls_provider_unavailable";
            return OPError(reasonText);
        }
    }

    NSString *queryHash = OPClipboardTextHash(query ?: @"");
    long long contextId = OPRecordContextEvent(@"calls_searched", @"openphone.agentd", taskId,
            @"Calls search",
            [NSString stringWithFormat:@"Calls search returned %lu call(s)",
                    (unsigned long)calls.count],
            @{
                @"provider": provider ?: @"unknown",
                @"count": @(calls.count),
                @"limit": @(limit),
                @"query_length": @(query.length),
                @"query_sha256": queryHash ?: @"",
                @"start_at_ms": @(startAtMs),
                @"end_at_ms": @(endAtMs),
                @"reason": reason ?: @""
            });
    NSDictionary *result = @{
        @"status": @"ok",
        @"tool": @"calls_search",
        @"query": query ?: @"",
        @"query_length": @(query.length),
        @"query_sha256": queryHash ?: @"",
        @"start_at_ms": @(startAtMs),
        @"start_at": OPCalendarISO8601FromMs(startAtMs),
        @"end_at_ms": @(endAtMs),
        @"end_at": OPCalendarISO8601FromMs(endAtMs),
        @"limit": @(limit),
        @"calls": calls ?: @[],
        @"count": @(calls.count),
        @"provider": provider ?: @"unknown",
        @"calls_path": OPCallsDatabasePath(),
        @"fixture_path": OPCallsFixturePath(),
        @"context_event_id": @(contextId),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"calls_searched", taskId, @"calls.read", @"allow_task_scoped",
            @{
                @"reason": reason ?: @"",
                @"provider": provider ?: @"unknown",
                @"limit": @(limit),
                @"query_length": @(query.length),
                @"query_sha256": queryHash ?: @"",
                @"start_at_ms": @(startAtMs),
                @"end_at_ms": @(endAtMs),
                @"count": @(calls.count)
            },
            [NSString stringWithFormat:@"count:%lu", (unsigned long)calls.count]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"calls_search",
        @"arguments": @{
            @"reason": reason ?: @"",
            @"query_length": @(query.length),
            @"query_sha256": queryHash ?: @"",
            @"start_at_ms": @(startAtMs),
            @"end_at_ms": @(endAtMs),
            @"limit": @(limit)
        },
        @"result": OPCallsTraceSummary(result)
    });
    return result;
}

static NSArray<NSString *> *OPMessagesDatabasePaths(void) {
    const char *override = getenv("OPENPHONE_MESSAGES_DB_PATH");
    if (override && override[0] != '\0') {
        return @[[NSString stringWithUTF8String:override]];
    }
    return @[
        @"/var/mobile/Library/SMS/sms.db",
        @"/private/var/mobile/Library/SMS/sms.db"
    ];
}

static NSString *OPMessagesDatabasePath(void) {
    NSArray<NSString *> *paths = OPMessagesDatabasePaths();
    for (NSString *path in paths) {
        if (OPPathExists(path)) {
            return path;
        }
    }
    return paths.count > 0 ? paths[0] : @"/var/mobile/Library/SMS/sms.db";
}

static NSDictionary *OPMessagesProviderStatus(void) {
    NSString *messagesPath = OPMessagesDatabasePath();
    BOOL smsAvailable = OPPathExists(messagesPath);
    BOOL fixtureAvailable = OPPathExists(OPMessagesFixturePath());
    return @{
        @"status": @"implemented_partial",
        @"provider": @"SMS.sqlite",
        @"path": messagesPath ?: @"",
        @"sms_available": @(smsAvailable),
        @"fixture_provider": @"openphone.messages_fixture_file",
        @"fixture_path": OPMessagesFixturePath(),
        @"fixture_available": @(fixtureAvailable),
        @"protected_helper_socket": OPProtectedDataHelperSocketPath(),
        @"protected_helper_available": @(OPPathExists(OPProtectedDataHelperSocketPath())),
        @"protected_helper_manager": @"launchd_sh_wrapper_setuid_helper",
        @"protected_helper_binary": OPProtectedDataHelperBinaryPath() ?: @"",
        @"protected_helper_spawn_pid": @((int)OPProtectedDataHelperPid),
        @"protected_helper_last_spawn_ms": @((long long)OPProtectedDataHelperLastSpawnMs),
        @"protected_helper_last_spawn_error": OPProtectedDataHelperLastSpawnError ?: @"",
        @"access": @"read_only",
        @"retention": @"bounded message previews are returned to caller; context/audit store counts, query hashes, and time ranges only"
    };
}

static NSString *OPMessagesTextExpr(sqlite3 *db, NSString *table, NSString *alias,
        NSArray<NSString *> *columns) {
    NSString *column = OPCalendarFirstExistingColumn(db, table, columns);
    if (column.length == 0) {
        return @"''";
    }
    return [NSString stringWithFormat:@"COALESCE(%@.%@, '')", alias, column];
}

static NSString *OPMessagesNumberExpr(sqlite3 *db, NSString *table, NSString *alias,
        NSArray<NSString *> *columns) {
    NSString *column = OPCalendarFirstExistingColumn(db, table, columns);
    if (column.length == 0) {
        return @"0";
    }
    return [NSString stringWithFormat:@"COALESCE(%@.%@, 0)", alias, column];
}

static NSString *OPMessagesDirectionFromIsFromMe(long long isFromMe) {
    if (isFromMe == 1) {
        return @"outgoing";
    }
    if (isFromMe == 0) {
        return @"incoming";
    }
    return @"unknown";
}

static long long OPMessagesMsFromSQLiteValue(double value) {
    if (value <= 0.0) {
        return 0;
    }
    if (value > 100000000000000000.0) {
        return (long long)(value / 1000000.0) + 978307200000LL;
    }
    if (value > 1000000000000.0) {
        return (long long)value;
    }
    if (value > 1000000000.0) {
        return (long long)(value * 1000.0);
    }
    return (long long)((value + 978307200.0) * 1000.0);
}

static NSDictionary *OPMessagesPreviewFields(NSString *text, NSString *prefix, NSUInteger maxChars) {
    NSString *value = text ?: @"";
    BOOL truncated = NO;
    NSString *preview = OPClipboardLimitedText(value, maxChars, &truncated);
    NSString *hash = value.length > 0 ? OPClipboardTextHash(value) : @"";
    return @{
        [NSString stringWithFormat:@"%@_preview", prefix]: preview ?: @"",
        [NSString stringWithFormat:@"%@_truncated", prefix]: @(truncated),
        [NSString stringWithFormat:@"%@_length", prefix]: @(value.length),
        [NSString stringWithFormat:@"%@_sha256", prefix]: hash ?: @""
    };
}

static BOOL OPMessagesValueMatches(NSDictionary *message, NSString *query) {
    if (query.length == 0) {
        return YES;
    }
    NSString *needle = query.lowercaseString ?: @"";
    for (NSString *key in @[@"handle", @"service", @"direction", @"text_preview", @"subject_preview"]) {
        id value = message[key];
        if ([value isKindOfClass:[NSString class]] &&
                [[(NSString *)value lowercaseString] containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary *OPMessagesNormalizedFixtureMessage(NSDictionary *message, NSUInteger index) {
    NSString *text = OPStringFromRequest(message, @"text",
            OPStringFromRequest(message, @"body", OPStringFromRequest(message, @"text_preview", @"")));
    NSString *subject = OPStringFromRequest(message, @"subject",
            OPStringFromRequest(message, @"subject_preview", @""));
    long long sentAtMs = OPCalendarLongLongFromValue(message[@"sent_at_ms"] ?: message[@"date_ms"], 0);
    NSString *direction = OPStringFromRequest(message, @"direction",
            OPBoolFromRequest(message, @"is_from_me", NO) ? @"outgoing" : @"incoming");
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:@{
        @"message_id": OPStringFromRequest(message, @"message_id",
                [NSString stringWithFormat:@"fixture-message-%lu", (unsigned long)index + 1]),
        @"guid": OPStringFromRequest(message, @"guid", @""),
        @"handle": OPStringFromRequest(message, @"handle",
                OPStringFromRequest(message, @"address", @"")),
        @"service": OPStringFromRequest(message, @"service", @""),
        @"direction": direction.length > 0 ? direction : @"unknown",
        @"sent_at_ms": @(sentAtMs),
        @"sent_at": OPCalendarISO8601FromMs(sentAtMs),
        @"read": @(OPBoolFromRequest(message, @"read", NO)),
        @"delivered": @(OPBoolFromRequest(message, @"delivered", NO)),
        @"provider": @"openphone.messages_fixture_file"
    }];
    [result addEntriesFromDictionary:OPMessagesPreviewFields(text, @"text", 500)];
    [result addEntriesFromDictionary:OPMessagesPreviewFields(subject, @"subject", 240)];
    return result;
}

static NSArray<NSDictionary *> *OPMessagesFixtureSearch(NSString *query, NSUInteger limit,
        long long startAtMs, long long endAtMs) {
    NSDictionary *fixture = OPReadJSONFile(OPMessagesFixturePath());
    NSArray *messages = [fixture[@"messages"] isKindOfClass:[NSArray class]]
            ? fixture[@"messages"] : @[];
    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    NSUInteger index = 0;
    for (id value in messages) {
        if (![value isKindOfClass:[NSDictionary class]]) {
            index++;
            continue;
        }
        NSDictionary *message = OPMessagesNormalizedFixtureMessage((NSDictionary *)value, index);
        index++;
        long long sentAtMs = OPCalendarLongLongFromValue(message[@"sent_at_ms"], 0);
        if (startAtMs > 0 && sentAtMs > 0 && sentAtMs < startAtMs) {
            continue;
        }
        if (endAtMs > 0 && sentAtMs > 0 && sentAtMs > endAtMs) {
            continue;
        }
        if (!OPMessagesValueMatches(message, query)) {
            continue;
        }
        [results addObject:message];
        if (results.count >= limit) {
            break;
        }
    }
    return results;
}

static NSArray<NSDictionary *> *OPMessagesSystemSearchAtPath(NSString *path, NSString *query,
        NSUInteger limit, long long startAtMs, long long endAtMs, NSString **errorOut) {
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(path.UTF8String, &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL);
    if (rc != SQLITE_OK) {
        if (errorOut) {
            *errorOut = db ? [NSString stringWithUTF8String:sqlite3_errmsg(db)] : @"sqlite_open_failed";
        }
        if (db) {
            sqlite3_close(db);
        }
        return nil;
    }
    sqlite3_busy_timeout(db, 5000);
    if (!OPSQLiteTableExists(db, @"message")) {
        if (errorOut) {
            *errorOut = @"message_table_missing";
        }
        sqlite3_close(db);
        return nil;
    }

    BOOL hasHandleJoin = OPSQLiteTableExists(db, @"handle") &&
            OPSQLiteColumnExists(db, @"message", @"handle_id");
    NSString *guidExpr = OPMessagesTextExpr(db, @"message", @"m", @[@"guid"]);
    NSString *textExpr = OPMessagesTextExpr(db, @"message", @"m", @[@"text"]);
    NSString *subjectExpr = OPMessagesTextExpr(db, @"message", @"m", @[@"subject"]);
    NSString *serviceExpr = OPMessagesTextExpr(db, @"message", @"m", @[@"service"]);
    NSString *dateExpr = OPMessagesNumberExpr(db, @"message", @"m", @[@"date"]);
    NSString *isFromMeExpr = OPMessagesNumberExpr(db, @"message", @"m", @[@"is_from_me"]);
    NSString *readExpr = OPMessagesNumberExpr(db, @"message", @"m", @[@"date_read", @"read"]);
    NSString *deliveredExpr = OPMessagesNumberExpr(db, @"message", @"m", @[@"date_delivered", @"delivered"]);
    NSString *handleExpr = hasHandleJoin
            ? OPMessagesTextExpr(db, @"handle", @"h", @[@"id", @"uncanonicalized_id"])
            : OPMessagesTextExpr(db, @"message", @"m", @[@"handle", @"cache_roomnames", @"address"]);

    NSMutableString *from = [NSMutableString stringWithString:@"FROM message m"];
    if (hasHandleJoin) {
        [from appendString:@" LEFT JOIN handle h ON h.ROWID = m.handle_id"];
    }
    NSMutableArray<NSString *> *whereParts = [NSMutableArray array];
    BOOL hasQuery = query.length > 0;
    if (hasQuery) {
        [whereParts addObject:[NSString stringWithFormat:
                @"lower(%@ || ' ' || %@ || ' ' || %@ || ' ' || %@) LIKE ?",
                textExpr, subjectExpr, handleExpr, serviceExpr]];
    }
    NSString *where = whereParts.count > 0
            ? [NSString stringWithFormat:@"WHERE %@", [whereParts componentsJoinedByString:@" AND "]]
            : @"";
    NSString *orderBy = [dateExpr isEqualToString:@"0"] ? @"m.ROWID DESC" : [NSString stringWithFormat:@"%@ DESC", dateExpr];
    NSUInteger fetchLimit = MIN(MAX(limit * 8, (NSUInteger)50), (NSUInteger)250);
    NSString *sql = [NSString stringWithFormat:
            @"SELECT m.ROWID, %@, %@, %@, %@, %@, %@, %@, %@, %@ "
             "%@ %@ ORDER BY %@ LIMIT ?",
            guidExpr, textExpr, subjectExpr, handleExpr, serviceExpr, dateExpr,
            isFromMeExpr, readExpr, deliveredExpr, from, where, orderBy];

    sqlite3_stmt *statement = NULL;
    NSMutableArray<NSDictionary *> *messages = [NSMutableArray array];
    rc = sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL);
    if (rc == SQLITE_OK) {
        int bindIndex = 1;
        if (hasQuery) {
            NSString *like = [NSString stringWithFormat:@"%%%@%%", query.lowercaseString ?: @""];
            OPSQLiteBindText(statement, bindIndex++, like);
        }
        sqlite3_bind_int64(statement, bindIndex, (sqlite3_int64)fetchLimit);
        while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
            long long rowId = sqlite3_column_int64(statement, 0);
            NSString *guid = OPSQLiteColumnString(statement, 1);
            NSString *text = OPSQLiteColumnString(statement, 2);
            NSString *subject = OPSQLiteColumnString(statement, 3);
            NSString *handle = OPSQLiteColumnString(statement, 4);
            NSString *service = OPSQLiteColumnString(statement, 5);
            long long sentAtMs = OPMessagesMsFromSQLiteValue(sqlite3_column_double(statement, 6));
            if (startAtMs > 0 && sentAtMs > 0 && sentAtMs < startAtMs) {
                continue;
            }
            if (endAtMs > 0 && sentAtMs > 0 && sentAtMs > endAtMs) {
                continue;
            }
            long long isFromMe = sqlite3_column_int64(statement, 7);
            BOOL read = sqlite3_column_int64(statement, 8) > 0;
            BOOL delivered = sqlite3_column_int64(statement, 9) > 0;
            NSMutableDictionary *message = [NSMutableDictionary dictionaryWithDictionary:@{
                @"message_id": [NSString stringWithFormat:@"ios-message-%lld", rowId],
                @"row_id": @(rowId),
                @"guid": guid ?: @"",
                @"handle": handle ?: @"",
                @"service": service ?: @"",
                @"direction": OPMessagesDirectionFromIsFromMe(isFromMe),
                @"sent_at_ms": @(sentAtMs),
                @"sent_at": OPCalendarISO8601FromMs(sentAtMs),
                @"read": @(read),
                @"delivered": @(delivered),
                @"provider": @"SMS.sqlite"
            }];
            [message addEntriesFromDictionary:OPMessagesPreviewFields(text, @"text", 500)];
            [message addEntriesFromDictionary:OPMessagesPreviewFields(subject, @"subject", 240)];
            [messages addObject:message];
            if (messages.count >= limit) {
                break;
            }
        }
        if (rc != SQLITE_DONE && errorOut) {
            *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"messages_query_failed";
        }
    } else if (errorOut) {
        *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"messages_query_prepare_failed";
    }
    sqlite3_finalize(statement);
    sqlite3_close(db);
    if (rc != SQLITE_DONE && messages.count == 0 && errorOut && *errorOut) {
        return nil;
    }
    return messages;
}

static NSArray<NSDictionary *> *OPMessagesSystemSearch(NSString *query, NSUInteger limit,
        long long startAtMs, long long endAtMs, NSString **errorOut) {
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    for (NSString *path in OPMessagesDatabasePaths()) {
        NSString *pathError = nil;
        NSArray<NSDictionary *> *messages = OPMessagesSystemSearchAtPath(path, query, limit,
                startAtMs, endAtMs, &pathError);
        if (messages) {
            return messages;
        }
        if (pathError.length > 0) {
            [errors addObject:[NSString stringWithFormat:@"%@:%@", path.lastPathComponent ?: @"messages", pathError]];
        }
    }
    if (errorOut) {
        *errorOut = errors.count > 0 ? [errors componentsJoinedByString:@";"] : @"messages_query_failed";
    }
    return nil;
}

static NSArray *OPMessagesSummaryMessages(NSArray<NSDictionary *> *messages, NSUInteger limit,
        BOOL includeText) {
    NSMutableArray *summary = [NSMutableArray array];
    for (NSDictionary *message in messages) {
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"message_id", @"handle", @"service", @"direction",
                @"sent_at_ms", @"sent_at", @"read", @"delivered"]) {
            id value = message[key];
            if (value) {
                item[key] = value;
            }
        }
        if (includeText) {
            for (NSString *key in @[@"text_preview", @"text_truncated", @"text_length",
                    @"subject_preview", @"subject_truncated", @"subject_length"]) {
                id value = message[key];
                if (value) {
                    item[key] = value;
                }
            }
        } else {
            for (NSString *key in @[@"text_length", @"text_sha256", @"subject_length", @"subject_sha256"]) {
                id value = message[key];
                if (value) {
                    item[key] = value;
                }
            }
        }
        if (item.count > 0) {
            [summary addObject:item];
        }
        if (summary.count >= limit) {
            break;
        }
    }
    return summary;
}

static NSDictionary *OPMessagesTraceSummary(NSDictionary *result) {
    if (![result isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSArray *messages = [result[@"messages"] isKindOfClass:[NSArray class]]
            ? result[@"messages"] : @[];
    return @{
        @"status": result[@"status"] ?: @"unknown",
        @"tool": @"messages_search",
        @"provider": result[@"provider"] ?: @"unknown",
        @"query_length": result[@"query_length"] ?: @0,
        @"query_sha256": result[@"query_sha256"] ?: @"",
        @"start_at_ms": result[@"start_at_ms"] ?: @0,
        @"end_at_ms": result[@"end_at_ms"] ?: @0,
        @"count": result[@"count"] ?: @0,
        @"limit": result[@"limit"] ?: @0,
        @"messages": OPMessagesSummaryMessages(messages, 8, NO),
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPMessagesSearch(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    NSString *query = OPStringFromRequest(request, @"query",
            OPStringFromRequest(request, @"text",
                    OPStringFromRequest(request, @"handle", @"")));
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    long long startAtMs = OPCalendarLongLongFromValue(request[@"start_at_ms"] ?: request[@"start_ms"], 0);
    long long endAtMs = OPCalendarLongLongFromValue(request[@"end_at_ms"] ?: request[@"end_ms"], 0);
    BOOL allowEmptyQuery = OPBoolFromRequest(request, @"allow_empty_query", NO);
    if (query.length == 0 && startAtMs <= 0 && endAtMs <= 0 && !allowEmptyQuery) {
        return OPError(@"missing_messages_query_or_range");
    }
    NSUInteger limit = OPLimitFromRequest(request, 10, 50);
    if (limit == 0) {
        limit = 10;
    }

    NSString *provider = @"";
    NSString *systemError = nil;
    NSArray<NSDictionary *> *messages = nil;
    BOOL smsAvailable = OPPathExists(OPMessagesDatabasePath());
    messages = OPMessagesSystemSearch(query, limit, startAtMs, endAtMs, &systemError);
    if (messages) {
        provider = @"SMS.sqlite";
    }
    if (!messages && !OPProtectedDataHelperRole()) {
        NSMutableDictionary *helperRequest = [request mutableCopy] ?: [NSMutableDictionary dictionary];
        helperRequest[@"command"] = @"messages_search";
        helperRequest[@"task_id"] = @"";
        NSDictionary *helperResult = OPProtectedDataHelperRequest(helperRequest);
        if ([helperResult[@"status"] isEqualToString:@"ok"] &&
                [helperResult[@"messages"] isKindOfClass:[NSArray class]]) {
            messages = helperResult[@"messages"];
            provider = [helperResult[@"provider"] isKindOfClass:[NSString class]]
                    ? helperResult[@"provider"] : @"SMS.sqlite";
        } else if ([helperResult[@"reason"] isKindOfClass:[NSString class]]) {
            systemError = systemError.length > 0
                    ? [NSString stringWithFormat:@"%@;protected_helper:%@", systemError, helperResult[@"reason"]]
                    : [NSString stringWithFormat:@"protected_helper:%@", helperResult[@"reason"]];
        }
    }
    if (!messages) {
        if (OPPathExists(OPMessagesFixturePath())) {
            messages = OPMessagesFixtureSearch(query, limit, startAtMs, endAtMs);
            provider = @"openphone.messages_fixture_file";
        } else {
            NSString *reasonText = (smsAvailable || systemError.length > 0)
                    ? [NSString stringWithFormat:@"messages_system_query_failed:%@", systemError ?: @"unknown"]
                    : @"messages_provider_unavailable";
            return OPError(reasonText);
        }
    }

    NSString *queryHash = OPClipboardTextHash(query ?: @"");
    long long contextId = OPRecordContextEvent(@"messages_searched", @"openphone.agentd", taskId,
            @"Messages search",
            [NSString stringWithFormat:@"Messages search returned %lu message(s)",
                    (unsigned long)messages.count],
            @{
                @"provider": provider ?: @"unknown",
                @"count": @(messages.count),
                @"limit": @(limit),
                @"query_length": @(query.length),
                @"query_sha256": queryHash ?: @"",
                @"start_at_ms": @(startAtMs),
                @"end_at_ms": @(endAtMs),
                @"reason": reason ?: @""
            });
    NSDictionary *result = @{
        @"status": @"ok",
        @"tool": @"messages_search",
        @"query": query ?: @"",
        @"query_length": @(query.length),
        @"query_sha256": queryHash ?: @"",
        @"start_at_ms": @(startAtMs),
        @"start_at": OPCalendarISO8601FromMs(startAtMs),
        @"end_at_ms": @(endAtMs),
        @"end_at": OPCalendarISO8601FromMs(endAtMs),
        @"limit": @(limit),
        @"messages": messages ?: @[],
        @"count": @(messages.count),
        @"provider": provider ?: @"unknown",
        @"messages_path": OPMessagesDatabasePath(),
        @"fixture_path": OPMessagesFixturePath(),
        @"context_event_id": @(contextId),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"messages_searched", taskId, @"messages.read", @"allow_task_scoped",
            @{
                @"reason": reason ?: @"",
                @"provider": provider ?: @"unknown",
                @"limit": @(limit),
                @"query_length": @(query.length),
                @"query_sha256": queryHash ?: @"",
                @"start_at_ms": @(startAtMs),
                @"end_at_ms": @(endAtMs),
                @"count": @(messages.count)
            },
            [NSString stringWithFormat:@"count:%lu", (unsigned long)messages.count]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"messages_search",
        @"arguments": @{
            @"reason": reason ?: @"",
            @"query_length": @(query.length),
            @"query_sha256": queryHash ?: @"",
            @"start_at_ms": @(startAtMs),
            @"end_at_ms": @(endAtMs),
            @"limit": @(limit)
        },
        @"result": OPMessagesTraceSummary(result)
    });
    return result;
}

static NSDictionary *OPCommitmentFromStatement(sqlite3_stmt *statement) {
    NSString *triggerSpecJSON = OPSQLiteColumnString(statement, 6);
    NSString *evidenceJSON = OPSQLiteColumnString(statement, 11);
    long long rowId = sqlite3_column_int64(statement, 0);
    return @{
        @"id": @(rowId),
        @"commitment_id": [NSString stringWithFormat:@"ios-commitment-%lld", rowId],
        @"created_at_ms": @(sqlite3_column_int64(statement, 1)),
        @"updated_at_ms": @(sqlite3_column_int64(statement, 2)),
        @"title": OPSQLiteColumnString(statement, 3),
        @"description": OPSQLiteColumnString(statement, 4),
        @"trigger_type": OPSQLiteColumnString(statement, 5),
        @"trigger_spec": OPJSONDictionary(triggerSpecJSON),
        @"due_at_ms": @(sqlite3_column_int64(statement, 7)),
        @"due_at": @(sqlite3_column_int64(statement, 7)),
        @"expires_at_ms": @(sqlite3_column_int64(statement, 8)),
        @"expires_at": @(sqlite3_column_int64(statement, 8)),
        @"status": OPSQLiteColumnString(statement, 9),
        @"confidence": @(sqlite3_column_double(statement, 10)),
        @"evidence": OPJSONDictionary(evidenceJSON),
        @"source": OPSQLiteColumnString(statement, 12),
        @"reason": OPSQLiteColumnString(statement, 13)
    };
}

static BOOL OPWatcherSourceIsLocalTimer(NSString *source, NSString *type) {
    NSString *sourceLower = [source isKindOfClass:[NSString class]] ? source.lowercaseString : @"";
    NSString *typeLower = [type isKindOfClass:[NSString class]] ? type.lowercaseString : @"";
    NSSet<NSString *> *timerTypes = [NSSet setWithObjects:@"time", @"timer", @"deadline", nil];
    return [timerTypes containsObject:sourceLower] || [timerTypes containsObject:typeLower];
}

static BOOL OPWatcherFiresLocally(NSString *source, NSString *type, long long nextRunAtMs) {
    return nextRunAtMs > 0 && OPWatcherSourceIsLocalTimer(source, type);
}

static NSDictionary *OPWatcherFromStatement(sqlite3_stmt *statement) {
    NSString *conditionJSON = OPSQLiteColumnString(statement, 12);
    NSString *scheduleJSON = OPSQLiteColumnString(statement, 13);
    NSString *deliveryJSON = OPSQLiteColumnString(statement, 14);
    NSString *metadataJSON = OPSQLiteColumnString(statement, 19);
    long long rowId = sqlite3_column_int64(statement, 0);
    NSString *source = OPSQLiteColumnString(statement, 4);
    NSString *type = OPSQLiteColumnString(statement, 5);
    long long nextRunAtMs = sqlite3_column_int64(statement, 15);
    BOOL firesLocally = OPWatcherFiresLocally(source, type, nextRunAtMs);
    return @{
        @"id": @(rowId),
        @"watcher_id": [NSString stringWithFormat:@"ios-watcher-%lld", rowId],
        @"created_at_ms": @(sqlite3_column_int64(statement, 1)),
        @"updated_at_ms": @(sqlite3_column_int64(statement, 2)),
        @"status": OPSQLiteColumnString(statement, 3),
        @"source": source,
        @"type": type,
        @"evaluator": OPSQLiteColumnString(statement, 6),
        @"title": OPSQLiteColumnString(statement, 7),
        @"query": OPSQLiteColumnString(statement, 8),
        @"url": OPSQLiteColumnString(statement, 9),
        @"address": OPSQLiteColumnString(statement, 10),
        @"number": OPSQLiteColumnString(statement, 11),
        @"condition": OPJSONDictionary(conditionJSON),
        @"schedule": OPJSONDictionary(scheduleJSON),
        @"delivery": OPJSONDictionary(deliveryJSON),
        @"next_run_at_ms": @(nextRunAtMs),
        @"interval_ms": @(sqlite3_column_int64(statement, 16)),
        @"recurring": @(sqlite3_column_int64(statement, 17) != 0),
        @"reason": OPSQLiteColumnString(statement, 18),
        @"metadata": OPJSONDictionary(metadataJSON),
        @"scheduler_status": firesLocally ? OPWatcherSchedulerStatus() : @"not_started",
        @"fires_locally": @(firesLocally)
    };
}

static NSDictionary *OPAgentJobFromStatement(sqlite3_stmt *statement) {
    NSString *scheduleJSON = OPSQLiteColumnString(statement, 7);
    NSString *deliveryJSON = OPSQLiteColumnString(statement, 11);
    NSString *payloadJSON = OPSQLiteColumnString(statement, 13);
    long long rowId = sqlite3_column_int64(statement, 0);
    BOOL schedulerEnabled = sqlite3_column_int64(statement, 16) != 0;
    return @{
        @"id": @(rowId),
        @"job_id": [NSString stringWithFormat:@"ios-job-%lld", rowId],
        @"created_at_ms": @(sqlite3_column_int64(statement, 1)),
        @"updated_at_ms": @(sqlite3_column_int64(statement, 2)),
        @"status": OPSQLiteColumnString(statement, 3),
        @"type": OPSQLiteColumnString(statement, 4),
        @"title": OPSQLiteColumnString(statement, 5),
        @"prompt": OPSQLiteColumnString(statement, 6),
        @"schedule": OPJSONDictionary(scheduleJSON),
        @"next_run_at_ms": @(sqlite3_column_int64(statement, 8)),
        @"interval_ms": @(sqlite3_column_int64(statement, 9)),
        @"session_target": OPSQLiteColumnString(statement, 10),
        @"delivery": OPJSONDictionary(deliveryJSON),
        @"notification_text": OPSQLiteColumnString(statement, 12),
        @"payload": OPJSONDictionary(payloadJSON),
        @"reason": OPSQLiteColumnString(statement, 14),
        @"source": OPSQLiteColumnString(statement, 15),
        @"scheduler_enabled": @(schedulerEnabled),
        @"scheduler_status": OPBackgroundJobSchedulerStatus(),
        @"runner": @"deterministic",
        @"runs_locally": @(schedulerEnabled),
        @"model_loop_status": @"not_started"
    };
}

static NSDictionary *OPCommitmentRead(sqlite3 *db, long long commitmentId) {
    sqlite3_stmt *read = NULL;
    NSDictionary *commitment = nil;
    if (sqlite3_prepare_v2(db,
            "SELECT id, created_at_ms, updated_at_ms, title, description, trigger_type, "
            "trigger_spec_json, due_at_ms, expires_at_ms, status, confidence, evidence_json, source, reason "
            "FROM commitment WHERE id = ?",
            -1, &read, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(read, 1, commitmentId);
        if (sqlite3_step(read) == SQLITE_ROW) {
            commitment = OPCommitmentFromStatement(read);
        }
    }
    sqlite3_finalize(read);
    return commitment;
}

static NSDictionary *OPWatcherRead(sqlite3 *db, long long watcherId) {
    sqlite3_stmt *read = NULL;
    NSDictionary *watcher = nil;
    if (sqlite3_prepare_v2(db,
            "SELECT id, created_at_ms, updated_at_ms, status, source, type, evaluator, title, "
            "query, url, address, number, condition_json, schedule_json, delivery_json, "
            "next_run_at_ms, interval_ms, recurring, reason, metadata_json "
            "FROM watcher WHERE id = ?",
            -1, &read, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(read, 1, watcherId);
        if (sqlite3_step(read) == SQLITE_ROW) {
            watcher = OPWatcherFromStatement(read);
        }
    }
    sqlite3_finalize(read);
    return watcher;
}

static NSDictionary *OPAgentJobRead(sqlite3 *db, long long jobId) {
    sqlite3_stmt *read = NULL;
    NSDictionary *job = nil;
    if (sqlite3_prepare_v2(db,
            "SELECT id, created_at_ms, updated_at_ms, status, type, title, prompt, schedule_json, "
            "next_run_at_ms, interval_ms, session_target, delivery_json, notification_text, "
            "payload_json, reason, source, scheduler_enabled FROM agent_job WHERE id = ?",
            -1, &read, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(read, 1, jobId);
        if (sqlite3_step(read) == SQLITE_ROW) {
            job = OPAgentJobFromStatement(read);
        }
    }
    sqlite3_finalize(read);
    return job;
}

static NSDictionary *OPCommitmentCreate(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *title = [OPStringFromRequest(request, @"title", @"") stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (title.length == 0) {
        return OPError(@"missing_commitment_title");
    }
    NSString *description = OPStringFromRequest(request, @"description", @"");
    long long dueAt = OPLongLongFromRequest(request, @"due_at_ms", 0, 0, 4102444800000LL);
    if (dueAt == 0) {
        dueAt = OPLongLongFromRequest(request, @"due_at", 0, 0, 4102444800000LL);
    }
    long long expiresAt = OPLongLongFromRequest(request, @"expires_at_ms", 0, 0, 4102444800000LL);
    if (expiresAt == 0) {
        expiresAt = OPLongLongFromRequest(request, @"expires_at", 0, 0, 4102444800000LL);
    }
    NSString *triggerType = OPStringFromRequest(request, @"trigger_type", dueAt > 0 ? @"time" : @"manual");
    if (triggerType.length == 0) {
        triggerType = dueAt > 0 ? @"time" : @"manual";
    }
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    double confidence = OPDoubleFromRequest(request, @"confidence", 1.0, 0.0, 1.0);
    id triggerSpec = OPJSONObjectFromRequest(request, @"trigger_spec", @{});
    id evidence = OPJSONObjectFromRequest(request, @"evidence", OPJSONObjectFromRequest(request, @"metadata", @{}));
    NSString *source = OPStringFromRequest(request, @"source", @"openphone.agentd");
    if (source.length == 0) {
        source = @"openphone.agentd";
    }

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }

    long long now = OPNowMs();
    long long commitmentId = 0;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "INSERT INTO commitment(created_at_ms, updated_at_ms, title, description, trigger_type, "
            "trigger_spec_json, due_at_ms, expires_at_ms, status, confidence, evidence_json, source, reason) "
            "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, now);
        sqlite3_bind_int64(statement, 2, now);
        OPSQLiteBindText(statement, 3, title);
        OPSQLiteBindText(statement, 4, description);
        OPSQLiteBindText(statement, 5, triggerType);
        OPSQLiteBindText(statement, 6, OPJSONString(triggerSpec));
        sqlite3_bind_int64(statement, 7, dueAt);
        sqlite3_bind_int64(statement, 8, expiresAt);
        OPSQLiteBindText(statement, 9, @"active");
        sqlite3_bind_double(statement, 10, confidence);
        OPSQLiteBindText(statement, 11, OPJSONString(evidence));
        OPSQLiteBindText(statement, 12, source);
        OPSQLiteBindText(statement, 13, reason);
        if (sqlite3_step(statement) == SQLITE_DONE) {
            commitmentId = sqlite3_last_insert_rowid(db);
        } else {
            error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
        }
    } else {
        error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    }
    sqlite3_finalize(statement);

    if (commitmentId > 0 && OPSQLiteTableExists(db, @"commitment_fts")) {
        sqlite3_stmt *fts = NULL;
        if (sqlite3_prepare_v2(db,
                "INSERT INTO commitment_fts(commitment_id, title, description, trigger_type) "
                "VALUES(?, ?, ?, ?)",
                -1, &fts, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(fts, 1, commitmentId);
            OPSQLiteBindText(fts, 2, title);
            OPSQLiteBindText(fts, 3, description);
            OPSQLiteBindText(fts, 4, triggerType);
            sqlite3_step(fts);
        }
        sqlite3_finalize(fts);
    }
    NSDictionary *commitment = commitmentId > 0 ? OPCommitmentRead(db, commitmentId) : nil;
    sqlite3_close(db);
    if (commitmentId == 0 || !commitment) {
        return OPError([NSString stringWithFormat:@"commitment_create_failed:%@", error ?: @"unknown"]);
    }

    OPRecordContextEvent(@"commitment_created", @"openphone.agentd", taskId,
            title, description.length > 0 ? description : title, @{
                @"commitment_id": commitment[@"commitment_id"] ?: @"",
                @"due_at_ms": @(dueAt),
                @"trigger_type": triggerType
            });
    NSDictionary *result = @{
        @"status": @"ok",
        @"commitment_id": commitment[@"id"] ?: @(commitmentId),
        @"commitment": commitment,
        @"db_path": OPDatabasePath(),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"commitment_created", taskId, @"commitments.write", @"allow_yolo",
            request, [NSString stringWithFormat:@"commitment_id:%@", commitment[@"commitment_id"] ?: @""]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"commitment_create",
        @"arguments": request ?: @{},
        @"result": result
    });
    return result;
}

static NSDictionary *OPCommitmentSearch(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *query = [OPStringFromRequest(request, @"query", @"") stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUInteger limit = OPLimitFromRequest(request, 20, 200);
    if (limit == 0) {
        limit = 20;
    }
    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }

    NSMutableArray<NSDictionary *> *commitments = [NSMutableArray array];
    NSString *provider = @"sqlite_latest";
    BOOL hasQuery = query.length > 0;
    BOOL ftsFailed = NO;
    if (hasQuery && OPSQLiteTableExists(db, @"commitment_fts")) {
        NSString *ftsQuery = OPFTSQuery(query);
        if (ftsQuery.length > 0) {
            sqlite3_stmt *statement = NULL;
            int rc = sqlite3_prepare_v2(db,
                    "SELECT c.id, c.created_at_ms, c.updated_at_ms, c.title, c.description, "
                    "c.trigger_type, c.trigger_spec_json, c.due_at_ms, c.expires_at_ms, c.status, "
                    "c.confidence, c.evidence_json, c.source, c.reason "
                    "FROM commitment_fts f JOIN commitment c ON f.commitment_id = c.id "
                    "WHERE commitment_fts MATCH ? ORDER BY bm25(commitment_fts) LIMIT ?",
                    -1, &statement, NULL);
            if (rc == SQLITE_OK) {
                OPSQLiteBindText(statement, 1, ftsQuery);
                sqlite3_bind_int64(statement, 2, (sqlite3_int64)limit);
                while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
                    [commitments addObject:OPCommitmentFromStatement(statement)];
                }
                if (rc != SQLITE_DONE) {
                    [commitments removeAllObjects];
                    ftsFailed = YES;
                }
            } else {
                ftsFailed = YES;
            }
            sqlite3_finalize(statement);
            if (!ftsFailed) {
                provider = @"sqlite_fts5";
            }
        }
    }
    if (!hasQuery || ftsFailed || ![provider isEqualToString:@"sqlite_fts5"]) {
        [commitments removeAllObjects];
        sqlite3_stmt *statement = NULL;
        NSString *sql = hasQuery
                ? @"SELECT id, created_at_ms, updated_at_ms, title, description, trigger_type, "
                  "trigger_spec_json, due_at_ms, expires_at_ms, status, confidence, evidence_json, source, reason "
                  "FROM commitment WHERE lower(title) LIKE ? OR lower(description) LIKE ? OR lower(trigger_type) LIKE ? "
                  "ORDER BY updated_at_ms DESC LIMIT ?"
                : @"SELECT id, created_at_ms, updated_at_ms, title, description, trigger_type, "
                  "trigger_spec_json, due_at_ms, expires_at_ms, status, confidence, evidence_json, source, reason "
                  "FROM commitment ORDER BY updated_at_ms DESC LIMIT ?";
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK) {
            if (hasQuery) {
                NSString *like = [NSString stringWithFormat:@"%%%@%%", query.lowercaseString ?: @""];
                OPSQLiteBindText(statement, 1, like);
                OPSQLiteBindText(statement, 2, like);
                OPSQLiteBindText(statement, 3, like);
                sqlite3_bind_int64(statement, 4, (sqlite3_int64)limit);
                provider = @"sqlite_like";
            } else {
                sqlite3_bind_int64(statement, 1, (sqlite3_int64)limit);
                provider = @"sqlite_latest";
            }
            while (sqlite3_step(statement) == SQLITE_ROW) {
                [commitments addObject:OPCommitmentFromStatement(statement)];
            }
        }
        sqlite3_finalize(statement);
    }
    BOOL ftsAvailable = OPSQLiteTableExists(db, @"commitment_fts");
    sqlite3_close(db);
    NSDictionary *result = @{
        @"status": @"ok",
        @"query": query ?: @"",
        @"limit": @(limit),
        @"commitments": commitments,
        @"count": @(commitments.count),
        @"provider": provider,
        @"fts_available": @(ftsAvailable),
        @"db_path": OPDatabasePath(),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"commitments_searched", taskId, @"commitments.read", @"allow_task_scoped",
            request, [NSString stringWithFormat:@"count:%lu", (unsigned long)commitments.count]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"commitment_search",
        @"arguments": request ?: @{},
        @"result": result
    });
    return result;
}

static NSDictionary *OPCommitmentUpdateStatus(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    long long commitmentId = OPRecordIdFromRequest(request, @[@"commitment_id", @"id"]);
    if (commitmentId <= 0) {
        return OPError(@"missing_commitment_id");
    }
    NSString *status = [OPStringFromRequest(request, @"status", @"") lowercaseString];
    status = [status stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (status.length == 0) {
        return OPError(@"missing_commitment_status");
    }
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    sqlite3_stmt *statement = NULL;
    BOOL updated = NO;
    if (sqlite3_prepare_v2(db,
            "UPDATE commitment SET status = ?, updated_at_ms = ?, reason = ? WHERE id = ?",
            -1, &statement, NULL) == SQLITE_OK) {
        OPSQLiteBindText(statement, 1, status);
        sqlite3_bind_int64(statement, 2, OPNowMs());
        OPSQLiteBindText(statement, 3, reason);
        sqlite3_bind_int64(statement, 4, commitmentId);
        updated = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
    } else {
        error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    }
    sqlite3_finalize(statement);
    NSDictionary *commitment = updated ? OPCommitmentRead(db, commitmentId) : nil;
    sqlite3_close(db);
    if (!updated || !commitment) {
        return OPError([NSString stringWithFormat:@"commitment_update_failed:%@", error ?: @"not_found"]);
    }
    OPRecordContextEvent(@"commitment_status_updated", @"openphone.agentd", taskId,
            commitment[@"title"] ?: @"", status, @{
                @"commitment_id": commitment[@"commitment_id"] ?: @"",
                @"status": status,
                @"reason": reason ?: @""
            });
    NSDictionary *result = @{
        @"status": @"ok",
        @"commitment_id": commitment[@"id"] ?: @(commitmentId),
        @"commitment": commitment,
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"commitment_status_updated", taskId, @"commitments.write", @"allow_yolo",
            request, [NSString stringWithFormat:@"commitment_id:%lld status:%@", commitmentId, status]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"commitment_update_status",
        @"arguments": request ?: @{},
        @"result": result
    });
    return result;
}

static id OPDictionaryNumberValue(NSDictionary *dictionary, NSString *key) {
    id value = dictionary[key];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static NSDictionary *OPWatcherCreate(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *title = [OPStringFromRequest(request, @"title", @"") stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (title.length == 0) {
        return OPError(@"missing_watcher_title");
    }
    NSString *source = OPStringFromRequest(request, @"source", @"");
    NSString *type = OPStringFromRequest(request, @"type", @"");
    if (source.length == 0 && type.length > 0) {
        source = type;
    }
    if (source.length == 0) {
        source = @"time";
    }
    if (type.length == 0) {
        type = source;
    }
    NSString *evaluator = OPStringFromRequest(request, @"evaluator", @"");
    if (evaluator.length == 0) {
        evaluator = [source isEqualToString:@"web"] ? @"hash_change" : @"event_match";
    }
    NSString *query = OPStringFromRequest(request, @"query", @"");
    NSString *url = OPStringFromRequest(request, @"url", @"");
    NSString *address = OPStringFromRequest(request, @"address", @"");
    NSString *number = OPStringFromRequest(request, @"number", @"");
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    long long nextRunAt = OPLongLongFromRequest(request, @"next_run_at", 0, 0, 4102444800000LL);
    long long deadlineAt = OPLongLongFromRequest(request, @"deadline_at", 0, 0, 4102444800000LL);
    if (nextRunAt == 0 && deadlineAt > 0) {
        nextRunAt = deadlineAt;
    }
    long long intervalMs = OPLongLongFromRequest(request, @"interval_ms", 0, 0, 31536000000LL);
    BOOL recurring = OPBoolFromRequest(request, @"recurring", intervalMs > 0);

    NSMutableDictionary *condition = [OPJSONObjectFromRequest(request, @"condition", @{}) mutableCopy];
    if (!condition) {
        condition = [NSMutableDictionary dictionary];
    }
    if (query.length > 0) {
        condition[@"query"] = query;
    }
    if (url.length > 0) {
        condition[@"url"] = url;
    }
    if (address.length > 0) {
        condition[@"address"] = address;
    }
    if (number.length > 0) {
        condition[@"number"] = number;
    }
    if (deadlineAt > 0) {
        condition[@"deadline_at"] = @(deadlineAt);
    }
    NSString *notifyOn = OPStringFromRequest(request, @"notify_on", @"");
    if (notifyOn.length > 0) {
        condition[@"notify_on"] = notifyOn;
    }
    NSString *direction = OPStringFromRequest(request, @"direction", @"");
    if (direction.length > 0) {
        condition[@"direction"] = direction;
    }
    if (OPBoolFromRequest(request, @"match_any", NO)) {
        condition[@"match_any"] = @YES;
    }
    long long threadId = OPLongLongFromRequest(request, @"thread_id", 0, 0, 9223372036854775807LL);
    if (threadId > 0) {
        condition[@"thread_id"] = @(threadId);
    }
    NSString *smsBody = OPStringFromRequest(request, @"sms_body", @"");
    if (smsBody.length > 0) {
        condition[@"sms_body"] = smsBody;
    }

    NSMutableDictionary *schedule = [OPJSONObjectFromRequest(request, @"schedule", @{}) mutableCopy];
    if (!schedule) {
        schedule = [NSMutableDictionary dictionary];
    }
    if (nextRunAt > 0) {
        schedule[@"next_run_at"] = @(nextRunAt);
    } else {
        id scheduledNext = OPDictionaryNumberValue(schedule, @"next_run_at");
        if (scheduledNext) {
            nextRunAt = [scheduledNext longLongValue];
        }
    }
    if (intervalMs > 0) {
        schedule[@"interval_ms"] = @(intervalMs);
    } else {
        id scheduledInterval = OPDictionaryNumberValue(schedule, @"interval_ms");
        if (scheduledInterval) {
            intervalMs = [scheduledInterval longLongValue];
        }
    }
    if (recurring) {
        schedule[@"recurring"] = @YES;
    }

    NSMutableDictionary *delivery = [OPJSONObjectFromRequest(request, @"delivery", @{}) mutableCopy];
    if (!delivery) {
        delivery = [NSMutableDictionary dictionary];
    }
    NSString *tool = OPStringFromRequest(request, @"tool", @"");
    NSString *prompt = OPStringFromRequest(request, @"prompt", @"");
    id arguments = OPJSONObjectFromRequest(request, @"arguments", nil);
    if (tool.length > 0) {
        delivery[@"tool"] = tool;
    }
    if (prompt.length > 0) {
        delivery[@"prompt"] = prompt;
        if (![delivery[@"mode"] isKindOfClass:[NSString class]]) {
            delivery[@"mode"] = @"background_job";
        }
    }
    if (arguments) {
        delivery[@"arguments"] = arguments;
    }
    if (delivery.count == 0) {
        delivery[@"mode"] = @"notification";
    }
    BOOL firesLocally = OPWatcherFiresLocally(source, type, nextRunAt);
    NSDictionary *metadata = @{
        @"scheduler_status": firesLocally ? OPWatcherSchedulerStatus() : @"not_started",
        @"fires_locally": @(firesLocally)
    };

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    long long now = OPNowMs();
    long long watcherId = 0;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "INSERT INTO watcher(created_at_ms, updated_at_ms, status, source, type, evaluator, title, query, url, "
            "address, number, condition_json, schedule_json, delivery_json, next_run_at_ms, interval_ms, "
            "recurring, reason, metadata_json) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, now);
        sqlite3_bind_int64(statement, 2, now);
        OPSQLiteBindText(statement, 3, @"active");
        OPSQLiteBindText(statement, 4, source);
        OPSQLiteBindText(statement, 5, type);
        OPSQLiteBindText(statement, 6, evaluator);
        OPSQLiteBindText(statement, 7, title);
        OPSQLiteBindText(statement, 8, query);
        OPSQLiteBindText(statement, 9, url);
        OPSQLiteBindText(statement, 10, address);
        OPSQLiteBindText(statement, 11, number);
        OPSQLiteBindText(statement, 12, OPJSONString(condition));
        OPSQLiteBindText(statement, 13, OPJSONString(schedule));
        OPSQLiteBindText(statement, 14, OPJSONString(delivery));
        sqlite3_bind_int64(statement, 15, nextRunAt);
        sqlite3_bind_int64(statement, 16, intervalMs);
        sqlite3_bind_int64(statement, 17, recurring ? 1 : 0);
        OPSQLiteBindText(statement, 18, reason);
        OPSQLiteBindText(statement, 19, OPJSONString(metadata));
        if (sqlite3_step(statement) == SQLITE_DONE) {
            watcherId = sqlite3_last_insert_rowid(db);
        } else {
            error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
        }
    } else {
        error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    }
    sqlite3_finalize(statement);
    if (watcherId > 0 && OPSQLiteTableExists(db, @"watcher_fts")) {
        sqlite3_stmt *fts = NULL;
        if (sqlite3_prepare_v2(db,
                "INSERT INTO watcher_fts(watcher_id, title, query, source, type) VALUES(?, ?, ?, ?, ?)",
                -1, &fts, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(fts, 1, watcherId);
            OPSQLiteBindText(fts, 2, title);
            OPSQLiteBindText(fts, 3, query);
            OPSQLiteBindText(fts, 4, source);
            OPSQLiteBindText(fts, 5, type);
            sqlite3_step(fts);
        }
        sqlite3_finalize(fts);
    }
    NSDictionary *watcher = watcherId > 0 ? OPWatcherRead(db, watcherId) : nil;
    sqlite3_close(db);
    if (watcherId == 0 || !watcher) {
        return OPError([NSString stringWithFormat:@"watcher_create_failed:%@", error ?: @"unknown"]);
    }
    OPRecordContextEvent(@"watcher_created", @"openphone.agentd", taskId,
            title, query.length > 0 ? query : source, @{
                @"watcher_id": watcher[@"watcher_id"] ?: @"",
                @"source": source,
                @"type": type,
                @"scheduler_status": metadata[@"scheduler_status"] ?: @"not_started"
            });
    NSDictionary *result = @{
        @"status": @"ok",
        @"watcher_id": watcher[@"id"] ?: @(watcherId),
        @"watcher": watcher,
        @"scheduler_status": metadata[@"scheduler_status"] ?: @"not_started",
        @"fires_locally": @(firesLocally),
        @"db_path": OPDatabasePath(),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"watcher_created", taskId, @"watchers.write", @"allow_yolo",
            request, [NSString stringWithFormat:@"watcher_id:%@", watcher[@"watcher_id"] ?: @""]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"watcher_create",
        @"arguments": request ?: @{},
        @"result": result
    });
    return result;
}

static NSArray<NSDictionary *> *OPWatcherListRows(sqlite3 *db, NSString *query,
        NSUInteger limit, NSString **providerOut) {
    NSMutableArray<NSDictionary *> *watchers = [NSMutableArray array];
    BOOL hasQuery = query.length > 0;
    BOOL ftsFailed = NO;
    if (hasQuery && OPSQLiteTableExists(db, @"watcher_fts")) {
        NSString *ftsQuery = OPFTSQuery(query);
        if (ftsQuery.length > 0) {
            sqlite3_stmt *statement = NULL;
            int rc = sqlite3_prepare_v2(db,
                    "SELECT w.id, w.created_at_ms, w.updated_at_ms, w.status, w.source, w.type, "
                    "w.evaluator, w.title, w.query, w.url, w.address, w.number, w.condition_json, "
                    "w.schedule_json, w.delivery_json, w.next_run_at_ms, w.interval_ms, w.recurring, "
                    "w.reason, w.metadata_json FROM watcher_fts f JOIN watcher w ON f.watcher_id = w.id "
                    "WHERE watcher_fts MATCH ? ORDER BY bm25(watcher_fts) LIMIT ?",
                    -1, &statement, NULL);
            if (rc == SQLITE_OK) {
                OPSQLiteBindText(statement, 1, ftsQuery);
                sqlite3_bind_int64(statement, 2, (sqlite3_int64)limit);
                while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
                    [watchers addObject:OPWatcherFromStatement(statement)];
                }
                if (rc != SQLITE_DONE) {
                    [watchers removeAllObjects];
                    ftsFailed = YES;
                }
            } else {
                ftsFailed = YES;
            }
            sqlite3_finalize(statement);
            if (!ftsFailed) {
                if (providerOut) {
                    *providerOut = @"sqlite_fts5";
                }
                return watchers;
            }
        }
    }

    sqlite3_stmt *statement = NULL;
    NSString *sql = hasQuery
            ? @"SELECT id, created_at_ms, updated_at_ms, status, source, type, evaluator, title, query, url, "
              "address, number, condition_json, schedule_json, delivery_json, next_run_at_ms, interval_ms, "
              "recurring, reason, metadata_json FROM watcher WHERE lower(title) LIKE ? OR lower(query) LIKE ? "
              "OR lower(source) LIKE ? OR lower(type) LIKE ? ORDER BY updated_at_ms DESC LIMIT ?"
            : @"SELECT id, created_at_ms, updated_at_ms, status, source, type, evaluator, title, query, url, "
              "address, number, condition_json, schedule_json, delivery_json, next_run_at_ms, interval_ms, "
              "recurring, reason, metadata_json FROM watcher ORDER BY updated_at_ms DESC LIMIT ?";
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK) {
        if (hasQuery) {
            NSString *like = [NSString stringWithFormat:@"%%%@%%", query.lowercaseString ?: @""];
            OPSQLiteBindText(statement, 1, like);
            OPSQLiteBindText(statement, 2, like);
            OPSQLiteBindText(statement, 3, like);
            OPSQLiteBindText(statement, 4, like);
            sqlite3_bind_int64(statement, 5, (sqlite3_int64)limit);
        } else {
            sqlite3_bind_int64(statement, 1, (sqlite3_int64)limit);
        }
        while (sqlite3_step(statement) == SQLITE_ROW) {
            [watchers addObject:OPWatcherFromStatement(statement)];
        }
    }
    sqlite3_finalize(statement);
    if (providerOut) {
        *providerOut = hasQuery ? @"sqlite_like" : @"sqlite_latest";
    }
    return watchers;
}

static NSDictionary *OPWatcherList(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *query = [OPStringFromRequest(request, @"query", @"") stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUInteger limit = OPLimitFromRequest(request, 20, 200);
    if (limit == 0) {
        limit = 20;
    }
    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    NSString *provider = nil;
    NSArray<NSDictionary *> *watchers = OPWatcherListRows(db, query, limit, &provider);
    BOOL ftsAvailable = OPSQLiteTableExists(db, @"watcher_fts");
    sqlite3_close(db);
    NSDictionary *result = @{
        @"status": @"ok",
        @"query": query ?: @"",
        @"limit": @(limit),
        @"watchers": watchers,
        @"count": @(watchers.count),
        @"provider": provider ?: @"sqlite",
        @"fts_available": @(ftsAvailable),
        @"scheduler_status": OPWatcherSchedulerStatus(),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"watchers_listed", taskId, @"watchers.read", @"allow_task_scoped",
            request, [NSString stringWithFormat:@"count:%lu", (unsigned long)watchers.count]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"watcher_list",
        @"arguments": request ?: @{},
        @"result": result
    });
    return result;
}

static NSDictionary *OPWatcherStop(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    long long watcherId = OPRecordIdFromRequest(request, @[@"watcher_id", @"id"]);
    BOOL stopAll = OPBoolFromRequest(request, @"all", NO) ||
            [OPStringFromRequest(request, @"scope", @"") isEqualToString:@"all"];
    NSString *query = [OPStringFromRequest(request, @"query", @"") stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (watcherId <= 0 && !stopAll && query.length == 0) {
        return OPError(@"missing_watcher_target");
    }
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
    sqlite3_stmt *select = NULL;
    NSString *sql = nil;
    if (watcherId > 0) {
        sql = @"SELECT id FROM watcher WHERE id = ? AND status != 'stopped'";
    } else if (stopAll) {
        sql = @"SELECT id FROM watcher WHERE status != 'stopped'";
    } else {
        sql = @"SELECT id FROM watcher WHERE status != 'stopped' AND "
              "(lower(title) LIKE ? OR lower(query) LIKE ? OR lower(source) LIKE ? OR lower(type) LIKE ?)";
    }
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &select, NULL) == SQLITE_OK) {
        if (watcherId > 0) {
            sqlite3_bind_int64(select, 1, watcherId);
        } else if (!stopAll) {
            NSString *like = [NSString stringWithFormat:@"%%%@%%", query.lowercaseString ?: @""];
            OPSQLiteBindText(select, 1, like);
            OPSQLiteBindText(select, 2, like);
            OPSQLiteBindText(select, 3, like);
            OPSQLiteBindText(select, 4, like);
        }
        while (sqlite3_step(select) == SQLITE_ROW) {
            [ids addObject:@(sqlite3_column_int64(select, 0))];
        }
    } else {
        error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    }
    sqlite3_finalize(select);

    NSMutableArray<NSDictionary *> *stopped = [NSMutableArray array];
    for (NSNumber *recordId in ids) {
        sqlite3_stmt *update = NULL;
        if (sqlite3_prepare_v2(db,
                "UPDATE watcher SET status = 'stopped', updated_at_ms = ?, reason = ? WHERE id = ?",
                -1, &update, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(update, 1, OPNowMs());
            OPSQLiteBindText(update, 2, reason);
            sqlite3_bind_int64(update, 3, [recordId longLongValue]);
            sqlite3_step(update);
        }
        sqlite3_finalize(update);
        NSDictionary *watcher = OPWatcherRead(db, [recordId longLongValue]);
        if (watcher) {
            [stopped addObject:watcher];
        }
    }
    sqlite3_close(db);
    NSDictionary *result = @{
        @"status": @"ok",
        @"stopped_count": @(stopped.count),
        @"watchers": stopped,
        @"scheduler_status": OPWatcherSchedulerStatus(),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"watchers_stopped", taskId, @"watchers.write", @"allow_yolo",
            request, [NSString stringWithFormat:@"count:%lu error:%@", (unsigned long)stopped.count, error ?: @""]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"watcher_stop",
        @"arguments": request ?: @{},
        @"result": result
    });
    return result;
}

static NSDictionary *OPBackgroundJobCreate(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *title = [OPStringFromRequest(request, @"title", @"") stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *prompt = [OPStringFromRequest(request, @"prompt", @"") stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (title.length == 0) {
        return OPError(@"missing_background_job_title");
    }
    if (prompt.length == 0) {
        return OPError(@"missing_background_job_prompt");
    }
    NSString *type = OPStringFromRequest(request, @"type", @"agent_turn");
    if (type.length == 0) {
        type = @"agent_turn";
    }
    id schedule = OPJSONObjectFromRequest(request, @"schedule", @{});
    long long nextRunAt = OPLongLongFromRequest(request, @"next_run_at", 0, 0, 4102444800000LL);
    if (nextRunAt == 0) {
        nextRunAt = OPLongLongFromRequest(request, @"run_at", 0, 0, 4102444800000LL);
    }
    long long intervalMs = OPLongLongFromRequest(request, @"interval_ms", 0, 0, 31536000000LL);
    NSMutableDictionary *scheduleDict = [[schedule mutableCopy] ?: [NSMutableDictionary dictionary] mutableCopy];
    scheduleDict[@"scheduler_status"] = OPBackgroundJobSchedulerStatus();
    scheduleDict[@"scheduler_enabled"] = @YES;
    if (nextRunAt > 0) {
        scheduleDict[@"next_run_at"] = @(nextRunAt);
    } else {
        id scheduledNext = OPDictionaryNumberValue(scheduleDict, @"next_run_at");
        if (scheduledNext) {
            nextRunAt = [scheduledNext longLongValue];
        }
    }
    if (intervalMs > 0) {
        scheduleDict[@"interval_ms"] = @(intervalMs);
    } else {
        id scheduledInterval = OPDictionaryNumberValue(scheduleDict, @"interval_ms");
        if (scheduledInterval) {
            intervalMs = [scheduledInterval longLongValue];
        }
    }
    BOOL recurring = OPBoolFromRequest(request, @"recurring",
            intervalMs > 0 && ![scheduleDict[@"recurring"] isEqual:@NO]);
    scheduleDict[@"recurring"] = @(recurring);
    NSString *sessionTarget = OPStringFromRequest(request, @"session_target", @"main");
    if (sessionTarget.length == 0) {
        sessionTarget = @"main";
    }
    id delivery = OPJSONObjectFromRequest(request, @"delivery", @{@"mode": @"notification"});
    NSString *notificationText = OPStringFromRequest(request, @"notification_text", @"");
    id payload = OPJSONObjectFromRequest(request, @"payload", @{});
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    NSString *source = OPStringFromRequest(request, @"source", @"openphone.agentd");
    if (source.length == 0) {
        source = @"openphone.agentd";
    }

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    long long now = OPNowMs();
    long long jobId = 0;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "INSERT INTO agent_job(created_at_ms, updated_at_ms, status, type, title, prompt, schedule_json, "
            "next_run_at_ms, interval_ms, session_target, delivery_json, notification_text, payload_json, "
            "reason, source, scheduler_enabled) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, now);
        sqlite3_bind_int64(statement, 2, now);
        OPSQLiteBindText(statement, 3, @"queued");
        OPSQLiteBindText(statement, 4, type);
        OPSQLiteBindText(statement, 5, title);
        OPSQLiteBindText(statement, 6, prompt);
        OPSQLiteBindText(statement, 7, OPJSONString(scheduleDict));
        sqlite3_bind_int64(statement, 8, nextRunAt);
        sqlite3_bind_int64(statement, 9, intervalMs);
        OPSQLiteBindText(statement, 10, sessionTarget);
        OPSQLiteBindText(statement, 11, OPJSONString(delivery));
        OPSQLiteBindText(statement, 12, notificationText);
        OPSQLiteBindText(statement, 13, OPJSONString(payload));
        OPSQLiteBindText(statement, 14, reason);
        OPSQLiteBindText(statement, 15, source);
        sqlite3_bind_int64(statement, 16, 1);
        if (sqlite3_step(statement) == SQLITE_DONE) {
            jobId = sqlite3_last_insert_rowid(db);
        } else {
            error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
        }
    } else {
        error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    }
    sqlite3_finalize(statement);
    if (jobId > 0 && OPSQLiteTableExists(db, @"agent_job_fts")) {
        sqlite3_stmt *fts = NULL;
        if (sqlite3_prepare_v2(db,
                "INSERT INTO agent_job_fts(job_id, title, prompt, type) VALUES(?, ?, ?, ?)",
                -1, &fts, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(fts, 1, jobId);
            OPSQLiteBindText(fts, 2, title);
            OPSQLiteBindText(fts, 3, prompt);
            OPSQLiteBindText(fts, 4, type);
            sqlite3_step(fts);
        }
        sqlite3_finalize(fts);
    }
    NSDictionary *job = jobId > 0 ? OPAgentJobRead(db, jobId) : nil;
    sqlite3_close(db);
    if (jobId == 0 || !job) {
        return OPError([NSString stringWithFormat:@"background_job_create_failed:%@", error ?: @"unknown"]);
    }
    OPRecordContextEvent(@"background_job_created", @"openphone.agentd", taskId,
            title, prompt, @{
                @"job_id": job[@"job_id"] ?: @"",
                @"type": type,
                @"scheduler_status": OPBackgroundJobSchedulerStatus()
            });
    NSDictionary *result = @{
        @"status": @"ok",
        @"job_id": job[@"id"] ?: @(jobId),
        @"job": job,
        @"scheduler_status": OPBackgroundJobSchedulerStatus(),
        @"runner": @"deterministic",
        @"runs_locally": @YES,
        @"model_loop_status": @"not_started",
        @"db_path": OPDatabasePath(),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"background_job_created", taskId, @"background.run", @"allow_yolo",
            request, [NSString stringWithFormat:@"job_id:%@", job[@"job_id"] ?: @""]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"background_job_create",
        @"arguments": request ?: @{},
        @"result": result
    });
    return result;
}

static NSArray<NSDictionary *> *OPBackgroundJobListRows(sqlite3 *db, NSString *query,
        NSUInteger limit, NSString **providerOut) {
    NSMutableArray<NSDictionary *> *jobs = [NSMutableArray array];
    BOOL hasQuery = query.length > 0;
    BOOL ftsFailed = NO;
    if (hasQuery && OPSQLiteTableExists(db, @"agent_job_fts")) {
        NSString *ftsQuery = OPFTSQuery(query);
        if (ftsQuery.length > 0) {
            sqlite3_stmt *statement = NULL;
            int rc = sqlite3_prepare_v2(db,
                    "SELECT j.id, j.created_at_ms, j.updated_at_ms, j.status, j.type, j.title, j.prompt, "
                    "j.schedule_json, j.next_run_at_ms, j.interval_ms, j.session_target, j.delivery_json, "
                    "j.notification_text, j.payload_json, j.reason, j.source, j.scheduler_enabled "
                    "FROM agent_job_fts f JOIN agent_job j ON f.job_id = j.id "
                    "WHERE agent_job_fts MATCH ? ORDER BY bm25(agent_job_fts) LIMIT ?",
                    -1, &statement, NULL);
            if (rc == SQLITE_OK) {
                OPSQLiteBindText(statement, 1, ftsQuery);
                sqlite3_bind_int64(statement, 2, (sqlite3_int64)limit);
                while ((rc = sqlite3_step(statement)) == SQLITE_ROW) {
                    [jobs addObject:OPAgentJobFromStatement(statement)];
                }
                if (rc != SQLITE_DONE) {
                    [jobs removeAllObjects];
                    ftsFailed = YES;
                }
            } else {
                ftsFailed = YES;
            }
            sqlite3_finalize(statement);
            if (!ftsFailed) {
                if (providerOut) {
                    *providerOut = @"sqlite_fts5";
                }
                return jobs;
            }
        }
    }

    sqlite3_stmt *statement = NULL;
    NSString *sql = hasQuery
            ? @"SELECT id, created_at_ms, updated_at_ms, status, type, title, prompt, schedule_json, "
              "next_run_at_ms, interval_ms, session_target, delivery_json, notification_text, payload_json, "
              "reason, source, scheduler_enabled FROM agent_job WHERE lower(title) LIKE ? OR lower(prompt) LIKE ? OR lower(type) LIKE ? "
              "ORDER BY updated_at_ms DESC LIMIT ?"
            : @"SELECT id, created_at_ms, updated_at_ms, status, type, title, prompt, schedule_json, "
              "next_run_at_ms, interval_ms, session_target, delivery_json, notification_text, payload_json, "
              "reason, source, scheduler_enabled FROM agent_job ORDER BY updated_at_ms DESC LIMIT ?";
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK) {
        if (hasQuery) {
            NSString *like = [NSString stringWithFormat:@"%%%@%%", query.lowercaseString ?: @""];
            OPSQLiteBindText(statement, 1, like);
            OPSQLiteBindText(statement, 2, like);
            OPSQLiteBindText(statement, 3, like);
            sqlite3_bind_int64(statement, 4, (sqlite3_int64)limit);
        } else {
            sqlite3_bind_int64(statement, 1, (sqlite3_int64)limit);
        }
        while (sqlite3_step(statement) == SQLITE_ROW) {
            [jobs addObject:OPAgentJobFromStatement(statement)];
        }
    }
    sqlite3_finalize(statement);
    if (providerOut) {
        *providerOut = hasQuery ? @"sqlite_like" : @"sqlite_latest";
    }
    return jobs;
}

static NSDictionary *OPBackgroundJobList(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *query = [OPStringFromRequest(request, @"query", @"") stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSUInteger limit = OPLimitFromRequest(request, 20, 200);
    if (limit == 0) {
        limit = 20;
    }
    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    NSString *provider = nil;
    NSArray<NSDictionary *> *jobs = OPBackgroundJobListRows(db, query, limit, &provider);
    BOOL ftsAvailable = OPSQLiteTableExists(db, @"agent_job_fts");
    sqlite3_close(db);
    NSDictionary *result = @{
        @"status": @"ok",
        @"query": query ?: @"",
        @"limit": @(limit),
        @"jobs": jobs,
        @"count": @(jobs.count),
        @"provider": provider ?: @"sqlite",
        @"fts_available": @(ftsAvailable),
        @"scheduler_status": OPBackgroundJobSchedulerStatus(),
        @"runner": @"deterministic",
        @"model_loop_status": @"not_started",
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"background_jobs_listed", taskId, @"tasks.observe", @"allow_task_scoped",
            request, [NSString stringWithFormat:@"count:%lu", (unsigned long)jobs.count]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"background_job_list",
        @"arguments": request ?: @{},
        @"result": result
    });
    return result;
}

static NSDictionary *OPBackgroundJobStop(NSDictionary *request) {
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    long long jobId = OPRecordIdFromRequest(request, @[@"job_id", @"id"]);
    if (jobId <= 0) {
        return OPError(@"missing_background_job_id");
    }
    NSString *reason = OPStringFromRequest(request, @"reason", @"");
    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    sqlite3_stmt *statement = NULL;
    BOOL updated = NO;
    if (sqlite3_prepare_v2(db,
            "UPDATE agent_job SET status = 'stopped', updated_at_ms = ?, reason = ? WHERE id = ?",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, OPNowMs());
        OPSQLiteBindText(statement, 2, reason);
        sqlite3_bind_int64(statement, 3, jobId);
        updated = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
    } else {
        error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    }
    sqlite3_finalize(statement);
    NSDictionary *job = updated ? OPAgentJobRead(db, jobId) : nil;
    sqlite3_close(db);
    if (!updated || !job) {
        return OPError([NSString stringWithFormat:@"background_job_stop_failed:%@", error ?: @"not_found"]);
    }
    NSDictionary *result = @{
        @"status": @"ok",
        @"stopped_count": @1,
        @"job_id": job[@"id"] ?: @(jobId),
        @"job": job,
        @"scheduler_status": OPBackgroundJobSchedulerStatus(),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"background_job_stopped", taskId, @"background.run", @"allow_yolo",
            request, [NSString stringWithFormat:@"job_id:%lld", jobId]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"background_job_stop",
        @"arguments": request ?: @{},
        @"result": result
    });
    return result;
}

static NSArray<NSDictionary *> *OPCommitmentDueRows(sqlite3 *db, NSUInteger limit, long long nowMs) {
    NSMutableArray<NSDictionary *> *commitments = [NSMutableArray array];
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "SELECT id, created_at_ms, updated_at_ms, title, description, trigger_type, "
            "trigger_spec_json, due_at_ms, expires_at_ms, status, confidence, evidence_json, source, reason "
            "FROM commitment "
            "WHERE status = 'active' AND due_at_ms > 0 AND due_at_ms <= ? "
            "AND (expires_at_ms = 0 OR expires_at_ms >= ?) "
            "ORDER BY due_at_ms ASC LIMIT ?",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, nowMs);
        sqlite3_bind_int64(statement, 2, nowMs);
        sqlite3_bind_int64(statement, 3, (sqlite3_int64)limit);
        while (sqlite3_step(statement) == SQLITE_ROW) {
            [commitments addObject:OPCommitmentFromStatement(statement)];
        }
    }
    sqlite3_finalize(statement);
    return commitments;
}

static NSString *OPCommitmentPrompt(NSDictionary *commitment) {
    NSDictionary *triggerSpec = [commitment[@"trigger_spec"] isKindOfClass:[NSDictionary class]]
            ? commitment[@"trigger_spec"] : @{};
    for (NSString *key in @[@"prompt", @"goal"]) {
        NSString *value = [triggerSpec[key] isKindOfClass:[NSString class]]
                ? [triggerSpec[key] stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
        if (value.length > 0) {
            return value;
        }
    }
    NSString *title = [commitment[@"title"] isKindOfClass:[NSString class]]
            ? commitment[@"title"] : @"OpenPhone commitment";
    NSString *description = [commitment[@"description"] isKindOfClass:[NSString class]]
            ? [commitment[@"description"] stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    if (description.length > 0) {
        return [NSString stringWithFormat:
                @"Handle due OpenPhone commitment '%@'. Description: %@. Use the current phone context. If no safe phone action is clear, finish with a concise status.",
                title, description];
    }
    return [NSString stringWithFormat:
            @"Handle due OpenPhone commitment '%@' using the current phone context. If no safe phone action is clear, finish with a concise status.",
            title];
}

static NSDictionary *OPCommitmentClaimDue(NSDictionary *commitment, long long claimedAtMs,
        NSString *source, NSString **errorOut) {
    long long commitmentId = [commitment[@"id"] longLongValue];
    if (commitmentId <= 0) {
        if (errorOut) {
            *errorOut = @"missing_commitment_id";
        }
        return nil;
    }
    NSDictionary *existingEvidence = [commitment[@"evidence"] isKindOfClass:[NSDictionary class]]
            ? commitment[@"evidence"] : @{};
    NSMutableDictionary *evidence = [existingEvidence mutableCopy];
    NSDictionary *existingScheduler = [evidence[@"scheduler"] isKindOfClass:[NSDictionary class]]
            ? evidence[@"scheduler"] : @{};
    NSMutableDictionary *scheduler = [existingScheduler mutableCopy];
    long long attemptCount = [scheduler[@"trigger_attempt_count"] respondsToSelector:@selector(longLongValue)]
            ? [scheduler[@"trigger_attempt_count"] longLongValue] + 1 : 1;
    scheduler[@"scheduler_status"] = OPCommitmentSchedulerStatus();
    scheduler[@"last_claimed_at_ms"] = @(claimedAtMs);
    scheduler[@"last_trigger_status"] = @"running";
    scheduler[@"last_trigger_source"] = source ?: @"commitment_scheduler";
    scheduler[@"trigger_attempt_count"] = @(attemptCount);
    evidence[@"scheduler"] = scheduler;

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"];
        }
        return nil;
    }
    sqlite3_stmt *statement = NULL;
    BOOL updated = NO;
    if (sqlite3_prepare_v2(db,
            "UPDATE commitment SET status = 'running', updated_at_ms = ?, evidence_json = ? "
            "WHERE id = ? AND status = 'active' AND due_at_ms > 0 AND due_at_ms <= ? "
            "AND (expires_at_ms = 0 OR expires_at_ms >= ?)",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, claimedAtMs);
        OPSQLiteBindText(statement, 2, OPJSONString(evidence));
        sqlite3_bind_int64(statement, 3, commitmentId);
        sqlite3_bind_int64(statement, 4, claimedAtMs);
        sqlite3_bind_int64(statement, 5, claimedAtMs);
        updated = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
        if (!updated && errorOut) {
            *errorOut = @"commitment_claim_missed_active_due_row";
        }
    } else if (errorOut) {
        *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"commitment_claim_prepare_failed";
    }
    sqlite3_finalize(statement);
    NSDictionary *claimedCommitment = updated ? OPCommitmentRead(db, commitmentId) : nil;
    sqlite3_close(db);
    return claimedCommitment;
}

static NSDictionary *OPCommitmentUpdateAfterTrigger(NSDictionary *commitment,
        NSString *jobPublicId, long long triggeredAtMs, NSString *source, NSString **errorOut) {
    long long commitmentId = [commitment[@"id"] longLongValue];
    if (commitmentId <= 0) {
        if (errorOut) {
            *errorOut = @"missing_commitment_id";
        }
        return nil;
    }
    NSDictionary *existingEvidence = [commitment[@"evidence"] isKindOfClass:[NSDictionary class]]
            ? commitment[@"evidence"] : @{};
    NSMutableDictionary *evidence = [existingEvidence mutableCopy];
    NSDictionary *existingScheduler = [evidence[@"scheduler"] isKindOfClass:[NSDictionary class]]
            ? evidence[@"scheduler"] : @{};
    NSMutableDictionary *scheduler = [existingScheduler mutableCopy];
    long long triggerCount = [scheduler[@"trigger_count"] respondsToSelector:@selector(longLongValue)]
            ? [scheduler[@"trigger_count"] longLongValue] + 1 : 1;
    scheduler[@"scheduler_status"] = OPCommitmentSchedulerStatus();
    scheduler[@"last_trigger_status"] = @"background_job_queued";
    scheduler[@"last_triggered_at_ms"] = @(triggeredAtMs);
    scheduler[@"last_job_id"] = jobPublicId ?: @"";
    scheduler[@"trigger_count"] = @(triggerCount);
    scheduler[@"source"] = source ?: @"commitment_scheduler";
    evidence[@"scheduler"] = scheduler;

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"];
        }
        return nil;
    }
    sqlite3_stmt *statement = NULL;
    BOOL updated = NO;
    if (sqlite3_prepare_v2(db,
            "UPDATE commitment SET status = 'triggered', updated_at_ms = ?, evidence_json = ?, "
            "reason = ? WHERE id = ? AND status IN ('active', 'running')",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, triggeredAtMs);
        OPSQLiteBindText(statement, 2, OPJSONString(evidence));
        OPSQLiteBindText(statement, 3, [NSString stringWithFormat:@"commitment triggered:%@",
                source ?: @"commitment_scheduler"]);
        sqlite3_bind_int64(statement, 4, commitmentId);
        updated = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
        if (!updated && errorOut) {
            *errorOut = @"commitment_update_missed_running_row";
        }
    } else if (errorOut) {
        *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"commitment_update_prepare_failed";
    }
    sqlite3_finalize(statement);
    NSDictionary *updatedCommitment = updated ? OPCommitmentRead(db, commitmentId) : nil;
    sqlite3_close(db);
    return updatedCommitment;
}

static NSDictionary *OPCommitmentRequeueAfterTriggerFailure(NSDictionary *commitment,
        NSString *failureReason, long long failedAtMs, NSString *source, NSString **errorOut) {
    long long commitmentId = [commitment[@"id"] longLongValue];
    if (commitmentId <= 0) {
        if (errorOut) {
            *errorOut = @"missing_commitment_id";
        }
        return nil;
    }
    NSDictionary *existingEvidence = [commitment[@"evidence"] isKindOfClass:[NSDictionary class]]
            ? commitment[@"evidence"] : @{};
    NSMutableDictionary *evidence = [existingEvidence mutableCopy];
    NSDictionary *existingScheduler = [evidence[@"scheduler"] isKindOfClass:[NSDictionary class]]
            ? evidence[@"scheduler"] : @{};
    NSMutableDictionary *scheduler = [existingScheduler mutableCopy];
    long long failureCount = [scheduler[@"trigger_failure_count"] respondsToSelector:@selector(longLongValue)]
            ? [scheduler[@"trigger_failure_count"] longLongValue] + 1 : 1;
    scheduler[@"scheduler_status"] = OPCommitmentSchedulerStatus();
    scheduler[@"last_trigger_status"] = @"background_job_create_failed";
    scheduler[@"last_trigger_error"] = failureReason ?: @"background_job_create_failed";
    scheduler[@"trigger_failure_count"] = @(failureCount);
    scheduler[@"last_failed_at_ms"] = @(failedAtMs);
    scheduler[@"source"] = source ?: @"commitment_scheduler";
    evidence[@"scheduler"] = scheduler;

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"];
        }
        return nil;
    }
    sqlite3_stmt *statement = NULL;
    BOOL updated = NO;
    if (sqlite3_prepare_v2(db,
            "UPDATE commitment SET status = 'active', updated_at_ms = ?, evidence_json = ?, "
            "reason = ? WHERE id = ? AND status = 'running'",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, failedAtMs);
        OPSQLiteBindText(statement, 2, OPJSONString(evidence));
        OPSQLiteBindText(statement, 3, [NSString stringWithFormat:@"commitment trigger failed:%@",
                failureReason ?: @"background_job_create_failed"]);
        sqlite3_bind_int64(statement, 4, commitmentId);
        updated = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
        if (!updated && errorOut) {
            *errorOut = @"commitment_failure_requeue_missed_running_row";
        }
    } else if (errorOut) {
        *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"commitment_failure_requeue_prepare_failed";
    }
    sqlite3_finalize(statement);
    NSDictionary *updatedCommitment = updated ? OPCommitmentRead(db, commitmentId) : nil;
    sqlite3_close(db);
    return updatedCommitment;
}

static NSDictionary *OPCommitmentMaterializeDue(NSUInteger limit, long long nowMs,
        NSString *taskId, NSString *source, NSDictionary *requestDelivery) {
    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    NSArray<NSDictionary *> *dueCommitments = OPCommitmentDueRows(db, limit, nowMs);
    sqlite3_close(db);

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSUInteger triggeredCount = 0;
    NSUInteger jobCount = 0;
    for (NSDictionary *commitment in dueCommitments) {
        NSString *commitmentPublicId = [commitment[@"commitment_id"] isKindOfClass:[NSString class]]
                ? commitment[@"commitment_id"] : [NSString stringWithFormat:@"ios-commitment-%lld",
                        [commitment[@"id"] longLongValue]];
        NSString *title = [commitment[@"title"] isKindOfClass:[NSString class]]
                ? commitment[@"title"] : commitmentPublicId;
        NSDictionary *triggerSpec = [commitment[@"trigger_spec"] isKindOfClass:[NSDictionary class]]
                ? commitment[@"trigger_spec"] : @{};
        NSDictionary *delivery = [triggerSpec[@"delivery"] isKindOfClass:[NSDictionary class]]
                ? triggerSpec[@"delivery"]
                : ([requestDelivery isKindOfClass:[NSDictionary class]] ? requestDelivery : @{@"mode": @"notification"});
        NSDictionary *event = @{
            @"type": @"time",
            @"commitment_id": commitmentPublicId,
            @"commitment_row_id": commitment[@"id"] ?: @0,
            @"title": title ?: commitmentPublicId,
            @"trigger_type": commitment[@"trigger_type"] ?: @"time",
            @"triggered_at_ms": @(nowMs),
            @"due_at_ms": commitment[@"due_at_ms"] ?: @0
        };
        NSString *claimError = nil;
        NSDictionary *claimedCommitment = OPCommitmentClaimDue(commitment, nowMs,
                source ?: @"commitment_scheduler", &claimError);
        if (!claimedCommitment) {
            [entries addObject:@{
                @"commitment_id": commitmentPublicId,
                @"status": @"skipped",
                @"reason": claimError ?: @"commitment_claim_failed",
                @"event": event
            }];
            continue;
        }

        NSString *prompt = OPCommitmentPrompt(claimedCommitment);
        NSMutableDictionary *payload = [@{
            @"source": source ?: @"commitment_scheduler",
            @"commitment_id": commitmentPublicId,
            @"commitment_row_id": claimedCommitment[@"id"] ?: @0,
            @"event": event,
            @"trigger_spec": triggerSpec,
            @"delivery": delivery
        } mutableCopy];
        NSMutableDictionary *jobRequest = [@{
            @"command": @"background_job_create",
            @"task_id": taskId ?: @"",
            @"title": [NSString stringWithFormat:@"Commitment due: %@", title ?: commitmentPublicId],
            @"prompt": prompt,
            @"type": @"commitment_due",
            @"next_run_at": @(nowMs),
            @"source": @"commitment_scheduler",
            @"reason": [NSString stringWithFormat:@"commitment due:%@", commitmentPublicId],
            @"payload": payload,
            @"delivery": delivery
        } mutableCopy];
        NSString *notificationText = [delivery[@"notification_text"] isKindOfClass:[NSString class]]
                ? delivery[@"notification_text"] : @"";
        if (notificationText.length > 0) {
            jobRequest[@"notification_text"] = notificationText;
        }

        NSDictionary *jobResult = OPBackgroundJobCreate(jobRequest);
        NSMutableDictionary *entry = [@{
            @"commitment_id": commitmentPublicId,
            @"status": @"failed",
            @"event": event
        } mutableCopy];
        if ([jobResult[@"status"] isEqualToString:@"ok"]) {
            triggeredCount++;
            jobCount++;
            NSDictionary *job = [jobResult[@"job"] isKindOfClass:[NSDictionary class]]
                    ? jobResult[@"job"] : @{};
            NSString *jobPublicId = [job[@"job_id"] isKindOfClass:[NSString class]]
                    ? job[@"job_id"] : @"";
            NSString *updateError = nil;
            NSDictionary *updatedCommitment = OPCommitmentUpdateAfterTrigger(claimedCommitment,
                    jobPublicId, nowMs, source ?: @"commitment_scheduler", &updateError);
            entry[@"status"] = @"background_job_queued";
            entry[@"job_id"] = jobPublicId;
            entry[@"job"] = job;
            if (updatedCommitment) {
                entry[@"commitment"] = updatedCommitment;
            }
            if (updateError) {
                entry[@"update_error"] = updateError;
            }
            OPRecordContextEvent(@"commitment_triggered", @"openphone.agentd", taskId,
                    title ?: commitmentPublicId, prompt, @{
                        @"commitment_id": commitmentPublicId,
                        @"job_id": jobPublicId ?: @"",
                        @"scheduler_status": OPCommitmentSchedulerStatus(),
                        @"source": source ?: @"commitment_scheduler"
                    });
            OPRecordAudit(@"commitment_triggered", taskId, @"commitments.write", @"allow_yolo",
                    jobRequest, [NSString stringWithFormat:@"commitment_id:%@ job_id:%@",
                    commitmentPublicId, jobPublicId ?: @""]);
        } else {
            NSString *failureReason = [jobResult[@"reason"] isKindOfClass:[NSString class]]
                    ? jobResult[@"reason"] : @"background_job_create_failed";
            entry[@"reason"] = failureReason;
            entry[@"job_result"] = jobResult ?: @{};
            NSString *failureUpdateError = nil;
            NSDictionary *requeuedCommitment = OPCommitmentRequeueAfterTriggerFailure(claimedCommitment,
                    failureReason, nowMs, source ?: @"commitment_scheduler", &failureUpdateError);
            if (requeuedCommitment) {
                entry[@"commitment"] = requeuedCommitment;
            }
            if (failureUpdateError) {
                entry[@"update_error"] = failureUpdateError;
            }
        }
        [entries addObject:entry];
    }

    return @{
        @"status": @"ok",
        @"scheduler_status": OPCommitmentSchedulerStatus(),
        @"source": @"openphone.agentd",
        @"limit": @(limit),
        @"due_count": @(dueCommitments.count),
        @"triggered_count": @(triggeredCount),
        @"job_count": @(jobCount),
        @"commitments": entries
    };
}

static pthread_mutex_t OPBackgroundJobSchedulerMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_t OPBackgroundJobSchedulerThread;
static volatile int OPBackgroundJobSchedulerThreadStarted = 0;
static const int OPBackgroundJobSchedulerStartupDelaySeconds = 15;

static NSArray<NSDictionary *> *OPBackgroundJobDueRows(sqlite3 *db, NSUInteger limit,
        long long nowMs, long long targetJobId) {
    NSMutableArray<NSDictionary *> *jobs = [NSMutableArray array];
    sqlite3_stmt *statement = NULL;
    NSString *sql = targetJobId > 0
            ? @"SELECT id, created_at_ms, updated_at_ms, status, type, title, prompt, schedule_json, "
              "next_run_at_ms, interval_ms, session_target, delivery_json, notification_text, payload_json, "
              "reason, source, scheduler_enabled FROM agent_job "
              "WHERE id = ? AND scheduler_enabled = 1 AND status = 'queued' "
              "AND (next_run_at_ms = 0 OR next_run_at_ms <= ?) LIMIT 1"
            : @"SELECT id, created_at_ms, updated_at_ms, status, type, title, prompt, schedule_json, "
              "next_run_at_ms, interval_ms, session_target, delivery_json, notification_text, payload_json, "
              "reason, source, scheduler_enabled FROM agent_job "
              "WHERE scheduler_enabled = 1 AND status = 'queued' AND (next_run_at_ms = 0 OR next_run_at_ms <= ?) "
              "ORDER BY CASE WHEN next_run_at_ms = 0 THEN created_at_ms ELSE next_run_at_ms END ASC "
              "LIMIT ?";
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK) {
        if (targetJobId > 0) {
            sqlite3_bind_int64(statement, 1, targetJobId);
            sqlite3_bind_int64(statement, 2, nowMs);
        } else {
            sqlite3_bind_int64(statement, 1, nowMs);
            sqlite3_bind_int64(statement, 2, (sqlite3_int64)limit);
        }
        while (sqlite3_step(statement) == SQLITE_ROW) {
            [jobs addObject:OPAgentJobFromStatement(statement)];
        }
    }
    sqlite3_finalize(statement);
    return jobs;
}

static BOOL OPBackgroundJobClaim(long long jobId, NSString **errorOut) {
    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"];
        }
        return NO;
    }
    sqlite3_stmt *statement = NULL;
    BOOL claimed = NO;
    if (sqlite3_prepare_v2(db,
            "UPDATE agent_job SET status = 'running', updated_at_ms = ? "
            "WHERE id = ? AND status = 'queued' AND scheduler_enabled = 1",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, OPNowMs());
        sqlite3_bind_int64(statement, 2, jobId);
        claimed = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
        if (!claimed && errorOut) {
            *errorOut = @"not_queued";
        }
    } else if (errorOut) {
        *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"claim_prepare_failed";
    }
    sqlite3_finalize(statement);
    sqlite3_close(db);
    return claimed;
}

static long long OPBackgroundJobRetryBackoffMs(long long failureCount) {
    long long backoffMs = 30000;
    long long shifts = failureCount > 1 ? MIN(failureCount - 1, 6) : 0;
    for (long long i = 0; i < shifts; i++) {
        backoffMs *= 2;
    }
    return MIN(backoffMs, 3600000);
}

static NSDictionary *OPBackgroundJobFinish(NSDictionary *job, NSDictionary *runResult,
        NSString **errorOut) {
    long long jobId = [job[@"id"] longLongValue];
    if (jobId <= 0) {
        if (errorOut) {
            *errorOut = @"missing_job_id";
        }
        return nil;
    }
    BOOL taskFinished = [runResult[@"status"] isEqualToString:@"task.finished"];
    long long intervalMs = [job[@"interval_ms"] isKindOfClass:[NSNumber class]]
            ? [job[@"interval_ms"] longLongValue] : 0;
    NSDictionary *schedule = [job[@"schedule"] isKindOfClass:[NSDictionary class]]
            ? job[@"schedule"] : @{};
    BOOL recurring = intervalMs > 0 &&
            (![schedule[@"recurring"] respondsToSelector:@selector(boolValue)] ||
            [schedule[@"recurring"] boolValue]);
    long long now = OPNowMs();
    NSDictionary *existingPayload = [job[@"payload"] isKindOfClass:[NSDictionary class]]
            ? job[@"payload"] : @{};
    NSDictionary *existingScheduler = [existingPayload[@"scheduler"] isKindOfClass:[NSDictionary class]]
            ? existingPayload[@"scheduler"] : @{};
    long long previousFailureCount = [existingScheduler[@"failure_count"] respondsToSelector:@selector(longLongValue)]
            ? [existingScheduler[@"failure_count"] longLongValue] : 0;
    long long failureCount = taskFinished ? 0 : previousFailureCount + 1;
    long long retryBackoffMs = (!taskFinished && recurring)
            ? OPBackgroundJobRetryBackoffMs(failureCount) : 0;
    NSString *runPolicy = recurring
            ? (taskFinished ? @"recurring_interval" : @"recurring_failure_backoff")
            : @"terminal";
    NSString *finalStatus = recurring ? @"queued" : (taskFinished ? @"completed" : @"failed");
    long long nextRunAt = recurring
            ? (now + (taskFinished ? intervalMs : retryBackoffMs)) : 0;
    NSString *runner = [runResult[@"runner"] isKindOfClass:[NSString class]]
            ? runResult[@"runner"] : @"auto";
    NSString *modelLoopStatus = [runResult[@"model_loop_status"] isKindOfClass:[NSString class]]
            ? runResult[@"model_loop_status"]
            : ([runner isEqualToString:@"model"] ? (taskFinished ? @"finished" : @"failed") : @"not_started");

    NSMutableDictionary *payload = [existingPayload mutableCopy];
    payload[@"scheduler"] = @{
        @"status": OPBackgroundJobSchedulerStatus(),
        @"runner": runner ?: @"auto",
        @"model_loop_status": modelLoopStatus ?: @"unknown",
        @"last_run_at_ms": @(now),
        @"last_status": runResult[@"status"] ?: @"unknown",
        @"last_task_id": runResult[@"task_id"] ?: @"",
        @"last_stop_reason": runResult[@"stop_reason"] ?: @"",
        @"recurring": @(recurring),
        @"interval_ms": @(intervalMs),
        @"next_run_at_ms": @(nextRunAt),
        @"run_policy": runPolicy,
        @"failure_count": @(failureCount),
        @"retry_backoff_ms": @(retryBackoffMs)
    };
    payload[@"last_run_task"] = runResult ?: @{};

    NSMutableDictionary *updatedSchedule = [schedule mutableCopy];
    updatedSchedule[@"scheduler_status"] = OPBackgroundJobSchedulerStatus();
    updatedSchedule[@"scheduler_enabled"] = @YES;
    updatedSchedule[@"last_run_at_ms"] = @(now);
    updatedSchedule[@"last_status"] = runResult[@"status"] ?: @"unknown";
    updatedSchedule[@"last_stop_reason"] = runResult[@"stop_reason"] ?: @"";
    updatedSchedule[@"run_policy"] = runPolicy;
    updatedSchedule[@"recurring"] = @(recurring);
    updatedSchedule[@"interval_ms"] = @(intervalMs);
    updatedSchedule[@"next_run_at"] = @(nextRunAt);
    updatedSchedule[@"failure_count"] = @(failureCount);
    updatedSchedule[@"retry_backoff_ms"] = @(retryBackoffMs);

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"];
        }
        return nil;
    }
    sqlite3_stmt *statement = NULL;
    BOOL updated = NO;
    if (sqlite3_prepare_v2(db,
            "UPDATE agent_job SET status = ?, updated_at_ms = ?, next_run_at_ms = ?, "
            "schedule_json = ?, payload_json = ? "
            "WHERE id = ? AND status = 'running'",
            -1, &statement, NULL) == SQLITE_OK) {
        OPSQLiteBindText(statement, 1, finalStatus);
        sqlite3_bind_int64(statement, 2, now);
        sqlite3_bind_int64(statement, 3, nextRunAt);
        OPSQLiteBindText(statement, 4, OPJSONString(updatedSchedule));
        OPSQLiteBindText(statement, 5, OPJSONString(payload));
        sqlite3_bind_int64(statement, 6, jobId);
        updated = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
        if (!updated && errorOut) {
            *errorOut = @"finish_update_missed_running_row";
        }
    } else if (errorOut) {
        *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"finish_prepare_failed";
    }
    sqlite3_finalize(statement);
    NSDictionary *updatedJob = updated ? OPAgentJobRead(db, jobId) : nil;
    sqlite3_close(db);
    return updatedJob;
}

static NSArray<NSDictionary *> *OPBackgroundJobStaleRunningRows(sqlite3 *db,
        NSUInteger limit, long long cutoffMs) {
    NSMutableArray<NSDictionary *> *jobs = [NSMutableArray array];
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "SELECT id, created_at_ms, updated_at_ms, status, type, title, prompt, schedule_json, "
            "next_run_at_ms, interval_ms, session_target, delivery_json, notification_text, payload_json, "
            "reason, source, scheduler_enabled FROM agent_job "
            "WHERE scheduler_enabled = 1 AND status = 'running' AND updated_at_ms <= ? "
            "ORDER BY updated_at_ms ASC LIMIT ?",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, cutoffMs);
        sqlite3_bind_int64(statement, 2, (sqlite3_int64)limit);
        while (sqlite3_step(statement) == SQLITE_ROW) {
            [jobs addObject:OPAgentJobFromStatement(statement)];
        }
    }
    sqlite3_finalize(statement);
    return jobs;
}

static NSDictionary *OPBackgroundJobRepairStuckInternal(NSUInteger limit,
        long long staleAfterMs, NSString *taskId, NSString *source) {
    if (limit == 0) {
        limit = 1;
    }
    long long now = OPNowMs();
    long long cutoff = now - staleAfterMs;
    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    NSArray<NSDictionary *> *staleJobs = OPBackgroundJobStaleRunningRows(db, limit, cutoff);

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSUInteger repairedCount = 0;
    for (NSDictionary *job in staleJobs) {
        long long jobId = [job[@"id"] longLongValue];
        NSString *jobPublicId = [job[@"job_id"] isKindOfClass:[NSString class]]
                ? job[@"job_id"] : [NSString stringWithFormat:@"ios-job-%lld", jobId];
        long long updatedAt = [job[@"updated_at_ms"] respondsToSelector:@selector(longLongValue)]
                ? [job[@"updated_at_ms"] longLongValue] : 0;
        long long ageMs = updatedAt > 0 ? MAX(0, now - updatedAt) : 0;

        NSDictionary *existingPayload = [job[@"payload"] isKindOfClass:[NSDictionary class]]
                ? job[@"payload"] : @{};
        NSMutableDictionary *payload = [existingPayload mutableCopy];
        NSDictionary *existingRepair = [payload[@"stuck_repair"] isKindOfClass:[NSDictionary class]]
                ? payload[@"stuck_repair"] : @{};
        long long repairCount = [existingRepair[@"repair_count"] respondsToSelector:@selector(longLongValue)]
                ? [existingRepair[@"repair_count"] longLongValue] + 1 : 1;
        payload[@"stuck_repair"] = @{
            @"status": @"requeued",
            @"repair_action": @"requeued",
            @"repair_count": @(repairCount),
            @"last_repair_at_ms": @(now),
            @"stale_after_ms": @(staleAfterMs),
            @"stale_running_age_ms": @(ageMs),
            @"previous_status": @"running",
            @"source": source ?: @"background_job_repair"
        };

        NSDictionary *existingSchedule = [job[@"schedule"] isKindOfClass:[NSDictionary class]]
                ? job[@"schedule"] : @{};
        NSMutableDictionary *schedule = [existingSchedule mutableCopy];
        schedule[@"last_repair_at_ms"] = @(now);
        schedule[@"stuck_repair_count"] = @(repairCount);
        schedule[@"scheduler_status"] = OPBackgroundJobSchedulerStatus();
        schedule[@"next_run_at"] = @(now);

        sqlite3_stmt *update = NULL;
        BOOL updated = NO;
        if (sqlite3_prepare_v2(db,
                "UPDATE agent_job SET status = 'queued', updated_at_ms = ?, next_run_at_ms = ?, "
                "schedule_json = ?, payload_json = ?, reason = ? "
                "WHERE id = ? AND status = 'running' AND scheduler_enabled = 1",
                -1, &update, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(update, 1, now);
            sqlite3_bind_int64(update, 2, now);
            OPSQLiteBindText(update, 3, OPJSONString(schedule));
            OPSQLiteBindText(update, 4, OPJSONString(payload));
            OPSQLiteBindText(update, 5, [NSString stringWithFormat:@"stuck repair:%@",
                    source ?: @"background_job_repair"]);
            sqlite3_bind_int64(update, 6, jobId);
            updated = sqlite3_step(update) == SQLITE_DONE && sqlite3_changes(db) > 0;
        }
        sqlite3_finalize(update);

        NSDictionary *updatedJob = updated ? OPAgentJobRead(db, jobId) : nil;
        NSMutableDictionary *entry = [@{
            @"job_id": jobPublicId,
            @"status": updated ? @"requeued" : @"skipped",
            @"repair_action": updated ? @"requeued" : @"not_repaired",
            @"stale_running_age_ms": @(ageMs)
        } mutableCopy];
        if (updatedJob) {
            entry[@"job"] = updatedJob;
        }
        if (updated) {
            repairedCount++;
            OPRecordContextEvent(@"background_job_repaired", @"openphone.agentd", taskId,
                    job[@"title"] ?: jobPublicId, @"stale running job requeued", @{
                        @"job_id": jobPublicId,
                        @"repair_action": @"requeued",
                        @"stale_running_age_ms": @(ageMs),
                        @"source": source ?: @"background_job_repair"
                    });
            OPRecordAudit(@"background_job_repaired", taskId, @"background.run",
                    @"allow_yolo", @{@"job_id": jobPublicId, @"source": source ?: @""},
                    [NSString stringWithFormat:@"job_id:%@ action:requeued", jobPublicId]);
        }
        [entries addObject:entry];
    }
    sqlite3_close(db);

    return @{
        @"status": @"ok",
        @"scheduler_status": OPBackgroundJobSchedulerStatus(),
        @"repair_policy": @"requeue_stale_running",
        @"stale_after_ms": @(staleAfterMs),
        @"cutoff_ms": @(cutoff),
        @"limit": @(limit),
        @"stale_count": @(staleJobs.count),
        @"repaired_count": @(repairedCount),
        @"jobs": entries,
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPBackgroundJobRepairStuck(NSDictionary *request) {
    if (pthread_mutex_trylock(&OPBackgroundJobSchedulerMutex) != 0) {
        return @{
            @"status": @"ok",
            @"scheduler_status": OPBackgroundJobSchedulerStatus(),
            @"busy": @YES,
            @"repaired_count": @0,
            @"source": @"openphone.agentd"
        };
    }
    @try {
        NSUInteger limit = OPLimitFromRequest(request, 5, 25);
        if (limit == 0) {
            limit = 5;
        }
        long long staleAfterMs = OPLongLongFromRequest(request,
                @"stale_after_ms", 300000, 1000, 86400000LL);
        NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
        NSString *source = OPStringFromRequest(request, @"source", @"background_job_repair");
        return OPBackgroundJobRepairStuckInternal(limit, staleAfterMs, taskId, source);
    } @finally {
        pthread_mutex_unlock(&OPBackgroundJobSchedulerMutex);
    }
}

static NSDictionary *OPBackgroundJobDebugMarkRunning(NSDictionary *request) {
    if (!OPBoolFromRequest(request, @"validation", NO)) {
        return OPError(@"validation_required");
    }
    long long jobId = OPRecordIdFromRequest(request, @[@"job_id", @"id"]);
    if (jobId <= 0) {
        return OPError(@"missing_background_job_id");
    }
    long long ageMs = OPLongLongFromRequest(request, @"age_ms", 600000, 1000, 86400000LL);
    long long now = OPNowMs();
    long long updatedAt = now - ageMs;
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *source = OPStringFromRequest(request, @"source", @"validation_stuck_fixture");

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    NSDictionary *job = OPAgentJobRead(db, jobId);
    if (!job) {
        sqlite3_close(db);
        return OPError(@"background_job_not_found");
    }
    NSDictionary *existingPayload = [job[@"payload"] isKindOfClass:[NSDictionary class]]
            ? job[@"payload"] : @{};
    NSMutableDictionary *payload = [existingPayload mutableCopy];
    payload[@"validation_stuck_fixture"] = @{
        @"status": @"marked_running",
        @"marked_at_ms": @(now),
        @"updated_at_ms": @(updatedAt),
        @"age_ms": @(ageMs),
        @"source": source ?: @"validation_stuck_fixture"
    };

    sqlite3_stmt *statement = NULL;
    BOOL updated = NO;
    if (sqlite3_prepare_v2(db,
            "UPDATE agent_job SET status = 'running', updated_at_ms = ?, payload_json = ?, "
            "reason = ? WHERE id = ? AND scheduler_enabled = 1",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, updatedAt);
        OPSQLiteBindText(statement, 2, OPJSONString(payload));
        OPSQLiteBindText(statement, 3, [NSString stringWithFormat:@"validation stuck fixture:%@",
                source ?: @"validation"]);
        sqlite3_bind_int64(statement, 4, jobId);
        updated = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
    } else {
        error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    }
    sqlite3_finalize(statement);
    NSDictionary *updatedJob = updated ? OPAgentJobRead(db, jobId) : nil;
    sqlite3_close(db);
    if (!updated || !updatedJob) {
        return OPError([NSString stringWithFormat:@"background_job_debug_mark_running_failed:%@",
                error ?: @"not_updated"]);
    }

    NSDictionary *result = @{
        @"status": @"ok",
        @"job_id": updatedJob[@"id"] ?: @(jobId),
        @"job": updatedJob,
        @"age_ms": @(ageMs),
        @"updated_at_ms": @(updatedAt),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"background_job_debug_marked_running", taskId, @"background.run",
            @"allow_yolo", request, [NSString stringWithFormat:@"job_id:%lld age_ms:%lld",
            jobId, ageMs]);
    return result;
}

static long long OPWatcherRetryBackoffMs(long long failureCount) {
    long long backoffMs = 30000;
    long long shifts = failureCount > 1 ? MIN(failureCount - 1, 6) : 0;
    for (long long i = 0; i < shifts; i++) {
        backoffMs *= 2;
    }
    return MIN(backoffMs, 3600000);
}

static NSDictionary *OPWatcherClaimForFire(NSDictionary *watcher, long long claimedAtMs,
        NSString *source, NSString **errorOut) {
    long long watcherId = [watcher[@"id"] longLongValue];
    if (watcherId <= 0) {
        if (errorOut) {
            *errorOut = @"missing_watcher_id";
        }
        return nil;
    }
    NSDictionary *existingSchedule = [watcher[@"schedule"] isKindOfClass:[NSDictionary class]]
            ? watcher[@"schedule"] : @{};
    NSMutableDictionary *schedule = [existingSchedule mutableCopy];
    long long fireAttemptCount = [schedule[@"fire_attempt_count"] respondsToSelector:@selector(longLongValue)]
            ? [schedule[@"fire_attempt_count"] longLongValue] + 1 : 1;
    schedule[@"last_claimed_at_ms"] = @(claimedAtMs);
    schedule[@"fire_attempt_count"] = @(fireAttemptCount);
    schedule[@"scheduler_status"] = OPWatcherSchedulerStatus();

    NSDictionary *existingMetadata = [watcher[@"metadata"] isKindOfClass:[NSDictionary class]]
            ? watcher[@"metadata"] : @{};
    NSMutableDictionary *metadata = [existingMetadata mutableCopy];
    metadata[@"scheduler_status"] = OPWatcherSchedulerStatus();
    metadata[@"fires_locally"] = @YES;
    metadata[@"last_claimed_at_ms"] = @(claimedAtMs);
    metadata[@"last_fire_status"] = @"running";
    metadata[@"fire_attempt_count"] = @(fireAttemptCount);
    metadata[@"source"] = source ?: @"watcher_scheduler";

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"];
        }
        return nil;
    }
    sqlite3_stmt *statement = NULL;
    BOOL updated = NO;
    if (sqlite3_prepare_v2(db,
            "UPDATE watcher SET status = 'running', updated_at_ms = ?, schedule_json = ?, "
            "metadata_json = ? WHERE id = ? AND status = 'active'",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, claimedAtMs);
        OPSQLiteBindText(statement, 2, OPJSONString(schedule));
        OPSQLiteBindText(statement, 3, OPJSONString(metadata));
        sqlite3_bind_int64(statement, 4, watcherId);
        updated = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
        if (!updated && errorOut) {
            *errorOut = @"watcher_claim_missed_active_row";
        }
    } else if (errorOut) {
        *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"watcher_claim_prepare_failed";
    }
    sqlite3_finalize(statement);
    NSDictionary *claimedWatcher = updated ? OPWatcherRead(db, watcherId) : nil;
    sqlite3_close(db);
    return claimedWatcher;
}

static NSDictionary *OPWatcherRequeueAfterFireFailure(NSDictionary *watcher, NSString *failureReason,
        long long failedAtMs, NSString *source, NSString **errorOut) {
    long long watcherId = [watcher[@"id"] longLongValue];
    if (watcherId <= 0) {
        if (errorOut) {
            *errorOut = @"missing_watcher_id";
        }
        return nil;
    }
    NSDictionary *existingMetadata = [watcher[@"metadata"] isKindOfClass:[NSDictionary class]]
            ? watcher[@"metadata"] : @{};
    NSMutableDictionary *metadata = [existingMetadata mutableCopy];
    long long failureCount = [metadata[@"fire_failure_count"] respondsToSelector:@selector(longLongValue)]
            ? [metadata[@"fire_failure_count"] longLongValue] + 1 : 1;
    long long backoffMs = OPWatcherRetryBackoffMs(failureCount);
    long long nextRunAt = failedAtMs + backoffMs;
    metadata[@"scheduler_status"] = OPWatcherSchedulerStatus();
    metadata[@"fires_locally"] = @YES;
    metadata[@"last_fire_status"] = @"background_job_create_failed";
    metadata[@"last_fire_error"] = failureReason ?: @"background_job_create_failed";
    metadata[@"fire_failure_count"] = @(failureCount);
    metadata[@"retry_backoff_ms"] = @(backoffMs);
    metadata[@"next_run_at_ms"] = @(nextRunAt);
    metadata[@"source"] = source ?: @"watcher_scheduler";

    NSDictionary *existingSchedule = [watcher[@"schedule"] isKindOfClass:[NSDictionary class]]
            ? watcher[@"schedule"] : @{};
    NSMutableDictionary *schedule = [existingSchedule mutableCopy];
    schedule[@"last_fire_status"] = @"background_job_create_failed";
    schedule[@"last_fire_error"] = failureReason ?: @"background_job_create_failed";
    schedule[@"fire_failure_count"] = @(failureCount);
    schedule[@"retry_backoff_ms"] = @(backoffMs);
    schedule[@"next_run_at"] = @(nextRunAt);
    schedule[@"scheduler_status"] = OPWatcherSchedulerStatus();

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"];
        }
        return nil;
    }
    sqlite3_stmt *statement = NULL;
    BOOL updated = NO;
    if (sqlite3_prepare_v2(db,
            "UPDATE watcher SET status = 'active', updated_at_ms = ?, schedule_json = ?, "
            "next_run_at_ms = ?, metadata_json = ? WHERE id = ? AND status = 'running'",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, failedAtMs);
        OPSQLiteBindText(statement, 2, OPJSONString(schedule));
        sqlite3_bind_int64(statement, 3, nextRunAt);
        OPSQLiteBindText(statement, 4, OPJSONString(metadata));
        sqlite3_bind_int64(statement, 5, watcherId);
        updated = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
        if (!updated && errorOut) {
            *errorOut = @"watcher_failure_requeue_missed_running_row";
        }
    } else if (errorOut) {
        *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"watcher_failure_requeue_prepare_failed";
    }
    sqlite3_finalize(statement);
    NSDictionary *updatedWatcher = updated ? OPWatcherRead(db, watcherId) : nil;
    sqlite3_close(db);
    return updatedWatcher;
}

static NSArray<NSDictionary *> *OPWatcherStaleRunningRows(sqlite3 *db,
        NSUInteger limit, long long cutoffMs) {
    NSMutableArray<NSDictionary *> *watchers = [NSMutableArray array];
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "SELECT id, created_at_ms, updated_at_ms, status, source, type, evaluator, title, "
            "query, url, address, number, condition_json, schedule_json, delivery_json, "
            "next_run_at_ms, interval_ms, recurring, reason, metadata_json "
            "FROM watcher "
            "WHERE status = 'running' AND updated_at_ms <= ? "
            "AND (lower(source) IN ('time', 'timer', 'deadline') "
            "OR lower(type) IN ('time', 'timer', 'deadline')) "
            "ORDER BY updated_at_ms ASC LIMIT ?",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, cutoffMs);
        sqlite3_bind_int64(statement, 2, (sqlite3_int64)limit);
        while (sqlite3_step(statement) == SQLITE_ROW) {
            [watchers addObject:OPWatcherFromStatement(statement)];
        }
    }
    sqlite3_finalize(statement);
    return watchers;
}

static NSDictionary *OPWatcherRepairStuckInternal(NSUInteger limit,
        long long staleAfterMs, NSString *taskId, NSString *source) {
    if (limit == 0) {
        limit = 1;
    }
    long long now = OPNowMs();
    long long cutoff = now - staleAfterMs;
    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    NSArray<NSDictionary *> *staleWatchers = OPWatcherStaleRunningRows(db, limit, cutoff);

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSUInteger repairedCount = 0;
    for (NSDictionary *watcher in staleWatchers) {
        long long watcherId = [watcher[@"id"] longLongValue];
        NSString *watcherPublicId = [watcher[@"watcher_id"] isKindOfClass:[NSString class]]
                ? watcher[@"watcher_id"] : [NSString stringWithFormat:@"ios-watcher-%lld", watcherId];
        long long updatedAt = [watcher[@"updated_at_ms"] respondsToSelector:@selector(longLongValue)]
                ? [watcher[@"updated_at_ms"] longLongValue] : 0;
        long long ageMs = updatedAt > 0 ? MAX(0, now - updatedAt) : 0;

        NSDictionary *existingMetadata = [watcher[@"metadata"] isKindOfClass:[NSDictionary class]]
                ? watcher[@"metadata"] : @{};
        NSMutableDictionary *metadata = [existingMetadata mutableCopy];
        NSDictionary *existingRepair = [metadata[@"stuck_repair"] isKindOfClass:[NSDictionary class]]
                ? metadata[@"stuck_repair"] : @{};
        long long repairCount = [existingRepair[@"repair_count"] respondsToSelector:@selector(longLongValue)]
                ? [existingRepair[@"repair_count"] longLongValue] + 1 : 1;
        metadata[@"scheduler_status"] = OPWatcherSchedulerStatus();
        metadata[@"fires_locally"] = @YES;
        metadata[@"last_fire_status"] = @"requeued_stale_running";
        metadata[@"next_run_at_ms"] = @(now);
        metadata[@"stuck_repair"] = @{
            @"status": @"requeued",
            @"repair_action": @"requeued",
            @"repair_count": @(repairCount),
            @"last_repair_at_ms": @(now),
            @"stale_after_ms": @(staleAfterMs),
            @"stale_running_age_ms": @(ageMs),
            @"previous_status": @"running",
            @"source": source ?: @"watcher_repair"
        };

        NSDictionary *existingSchedule = [watcher[@"schedule"] isKindOfClass:[NSDictionary class]]
                ? watcher[@"schedule"] : @{};
        NSMutableDictionary *schedule = [existingSchedule mutableCopy];
        schedule[@"last_repair_at_ms"] = @(now);
        schedule[@"stuck_repair_count"] = @(repairCount);
        schedule[@"scheduler_status"] = OPWatcherSchedulerStatus();
        schedule[@"next_run_at"] = @(now);

        sqlite3_stmt *update = NULL;
        BOOL updated = NO;
        if (sqlite3_prepare_v2(db,
                "UPDATE watcher SET status = 'active', updated_at_ms = ?, next_run_at_ms = ?, "
                "schedule_json = ?, metadata_json = ?, reason = ? "
                "WHERE id = ? AND status = 'running'",
                -1, &update, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(update, 1, now);
            sqlite3_bind_int64(update, 2, now);
            OPSQLiteBindText(update, 3, OPJSONString(schedule));
            OPSQLiteBindText(update, 4, OPJSONString(metadata));
            OPSQLiteBindText(update, 5, [NSString stringWithFormat:@"stuck repair:%@",
                    source ?: @"watcher_repair"]);
            sqlite3_bind_int64(update, 6, watcherId);
            updated = sqlite3_step(update) == SQLITE_DONE && sqlite3_changes(db) > 0;
        }
        sqlite3_finalize(update);

        NSDictionary *updatedWatcher = updated ? OPWatcherRead(db, watcherId) : nil;
        NSMutableDictionary *entry = [@{
            @"watcher_id": watcherPublicId,
            @"status": updated ? @"requeued" : @"skipped",
            @"repair_action": updated ? @"requeued" : @"not_repaired",
            @"stale_running_age_ms": @(ageMs)
        } mutableCopy];
        if (updatedWatcher) {
            entry[@"watcher"] = updatedWatcher;
        }
        if (updated) {
            repairedCount++;
            OPRecordContextEvent(@"watcher_repaired", @"openphone.agentd", taskId,
                    watcher[@"title"] ?: watcherPublicId, @"stale running watcher requeued", @{
                        @"watcher_id": watcherPublicId,
                        @"repair_action": @"requeued",
                        @"stale_running_age_ms": @(ageMs),
                        @"source": source ?: @"watcher_repair"
                    });
            OPRecordAudit(@"watcher_repaired", taskId, @"watchers.write",
                    @"allow_yolo", @{@"watcher_id": watcherPublicId, @"source": source ?: @""},
                    [NSString stringWithFormat:@"watcher_id:%@ action:requeued", watcherPublicId]);
        }
        [entries addObject:entry];
    }
    sqlite3_close(db);

    return @{
        @"status": @"ok",
        @"scheduler_status": OPWatcherSchedulerStatus(),
        @"repair_policy": @"requeue_stale_running",
        @"stale_after_ms": @(staleAfterMs),
        @"cutoff_ms": @(cutoff),
        @"limit": @(limit),
        @"stale_count": @(staleWatchers.count),
        @"repaired_count": @(repairedCount),
        @"watchers": entries,
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPWatcherRepairStuck(NSDictionary *request) {
    NSUInteger limit = OPLimitFromRequest(request, 5, 25);
    if (limit == 0) {
        limit = 5;
    }
    long long staleAfterMs = OPLongLongFromRequest(request,
            @"stale_after_ms", 300000, 1000, 86400000LL);
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *source = OPStringFromRequest(request, @"source", @"watcher_repair");
    return OPWatcherRepairStuckInternal(limit, staleAfterMs, taskId, source);
}

static NSDictionary *OPWatcherDebugMarkRunning(NSDictionary *request) {
    if (!OPBoolFromRequest(request, @"validation", NO)) {
        return OPError(@"validation_required");
    }
    long long watcherId = OPRecordIdFromRequest(request, @[@"watcher_id", @"id"]);
    if (watcherId <= 0) {
        return OPError(@"missing_watcher_id");
    }
    long long ageMs = OPLongLongFromRequest(request, @"age_ms", 600000, 1000, 86400000LL);
    long long now = OPNowMs();
    long long updatedAt = now - ageMs;
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
    NSString *source = OPStringFromRequest(request, @"source", @"validation_watcher_stuck_fixture");

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    NSDictionary *watcher = OPWatcherRead(db, watcherId);
    if (!watcher) {
        sqlite3_close(db);
        return OPError(@"watcher_not_found");
    }
    NSDictionary *existingMetadata = [watcher[@"metadata"] isKindOfClass:[NSDictionary class]]
            ? watcher[@"metadata"] : @{};
    NSMutableDictionary *metadata = [existingMetadata mutableCopy];
    metadata[@"validation_stuck_fixture"] = @{
        @"status": @"marked_running",
        @"marked_at_ms": @(now),
        @"updated_at_ms": @(updatedAt),
        @"age_ms": @(ageMs),
        @"source": source ?: @"validation_watcher_stuck_fixture"
    };
    metadata[@"scheduler_status"] = OPWatcherSchedulerStatus();
    metadata[@"fires_locally"] = @YES;
    metadata[@"last_fire_status"] = @"running";

    sqlite3_stmt *statement = NULL;
    BOOL updated = NO;
    if (sqlite3_prepare_v2(db,
            "UPDATE watcher SET status = 'running', updated_at_ms = ?, metadata_json = ?, "
            "reason = ? WHERE id = ?",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, updatedAt);
        OPSQLiteBindText(statement, 2, OPJSONString(metadata));
        OPSQLiteBindText(statement, 3, [NSString stringWithFormat:@"validation stuck fixture:%@",
                source ?: @"validation"]);
        sqlite3_bind_int64(statement, 4, watcherId);
        updated = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
    } else {
        error = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
    }
    sqlite3_finalize(statement);
    NSDictionary *updatedWatcher = updated ? OPWatcherRead(db, watcherId) : nil;
    sqlite3_close(db);
    if (!updated || !updatedWatcher) {
        return OPError([NSString stringWithFormat:@"watcher_debug_mark_running_failed:%@",
                error ?: @"not_updated"]);
    }

    NSDictionary *result = @{
        @"status": @"ok",
        @"watcher_id": updatedWatcher[@"id"] ?: @(watcherId),
        @"watcher": updatedWatcher,
        @"age_ms": @(ageMs),
        @"updated_at_ms": @(updatedAt),
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"watcher_debug_marked_running", taskId, @"watchers.write",
            @"allow_yolo", request, [NSString stringWithFormat:@"watcher_id:%lld age_ms:%lld",
            watcherId, ageMs]);
    return result;
}

static NSArray<NSDictionary *> *OPWatcherDueRows(sqlite3 *db, NSUInteger limit, long long nowMs) {
    NSMutableArray<NSDictionary *> *watchers = [NSMutableArray array];
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "SELECT id, created_at_ms, updated_at_ms, status, source, type, evaluator, title, "
            "query, url, address, number, condition_json, schedule_json, delivery_json, "
            "next_run_at_ms, interval_ms, recurring, reason, metadata_json "
            "FROM watcher "
            "WHERE status = 'active' AND next_run_at_ms > 0 AND next_run_at_ms <= ? "
            "AND (lower(source) IN ('time', 'timer', 'deadline') "
            "OR lower(type) IN ('time', 'timer', 'deadline')) "
            "ORDER BY next_run_at_ms ASC LIMIT ?",
            -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(statement, 1, nowMs);
        sqlite3_bind_int64(statement, 2, (sqlite3_int64)limit);
        while (sqlite3_step(statement) == SQLITE_ROW) {
            [watchers addObject:OPWatcherFromStatement(statement)];
        }
    }
    sqlite3_finalize(statement);
    return watchers;
}

static NSString *OPWatcherPrompt(NSDictionary *watcher) {
    NSDictionary *delivery = [watcher[@"delivery"] isKindOfClass:[NSDictionary class]]
            ? watcher[@"delivery"] : @{};
    NSString *prompt = [delivery[@"prompt"] isKindOfClass:[NSString class]]
            ? [delivery[@"prompt"] stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    if (prompt.length > 0) {
        return prompt;
    }
    NSString *query = [watcher[@"query"] isKindOfClass:[NSString class]]
            ? [watcher[@"query"] stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    NSString *title = [watcher[@"title"] isKindOfClass:[NSString class]]
            ? watcher[@"title"] : @"OpenPhone watcher";
    if (query.length > 0) {
        return [NSString stringWithFormat:@"Handle fired OpenPhone watcher '%@': %@",
                title, query];
    }
    return [NSString stringWithFormat:@"Handle fired OpenPhone watcher '%@' using the current phone context.",
            title];
}

static NSDictionary *OPWatcherUpdateAfterFire(NSDictionary *watcher, NSString *jobPublicId,
        long long firedAtMs, NSString **errorOut) {
    long long watcherId = [watcher[@"id"] longLongValue];
    if (watcherId <= 0) {
        if (errorOut) {
            *errorOut = @"missing_watcher_id";
        }
        return nil;
    }
    long long intervalMs = [watcher[@"interval_ms"] respondsToSelector:@selector(longLongValue)]
            ? [watcher[@"interval_ms"] longLongValue] : 0;
    BOOL recurring = intervalMs > 0 &&
            [watcher[@"recurring"] respondsToSelector:@selector(boolValue)] &&
            [watcher[@"recurring"] boolValue];
    long long nextRunAt = recurring ? (firedAtMs + intervalMs) : 0;
    NSString *finalStatus = recurring ? @"active" : @"fired";

    NSDictionary *existingSchedule = [watcher[@"schedule"] isKindOfClass:[NSDictionary class]]
            ? watcher[@"schedule"] : @{};
    NSMutableDictionary *schedule = [existingSchedule mutableCopy];
    schedule[@"last_fired_at_ms"] = @(firedAtMs);
    schedule[@"last_job_id"] = jobPublicId ?: @"";
    schedule[@"next_run_at"] = @(nextRunAt);
    schedule[@"scheduler_status"] = OPWatcherSchedulerStatus();
    if (recurring) {
        schedule[@"recurring"] = @YES;
        schedule[@"interval_ms"] = @(intervalMs);
    }

    NSDictionary *existingMetadata = [watcher[@"metadata"] isKindOfClass:[NSDictionary class]]
            ? watcher[@"metadata"] : @{};
    NSMutableDictionary *metadata = [existingMetadata mutableCopy];
    metadata[@"scheduler_status"] = OPWatcherSchedulerStatus();
    metadata[@"fires_locally"] = @YES;
    metadata[@"last_fired_at_ms"] = @(firedAtMs);
    metadata[@"last_job_id"] = jobPublicId ?: @"";
    metadata[@"last_fire_status"] = @"background_job_queued";
    metadata[@"recurring"] = @(recurring);
    metadata[@"next_run_at_ms"] = @(nextRunAt);

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"];
        }
        return nil;
    }
    sqlite3_stmt *statement = NULL;
    BOOL updated = NO;
    if (sqlite3_prepare_v2(db,
            "UPDATE watcher SET status = ?, updated_at_ms = ?, schedule_json = ?, "
            "next_run_at_ms = ?, metadata_json = ? WHERE id = ? "
            "AND status IN ('active', 'running')",
            -1, &statement, NULL) == SQLITE_OK) {
        OPSQLiteBindText(statement, 1, finalStatus);
        sqlite3_bind_int64(statement, 2, firedAtMs);
        OPSQLiteBindText(statement, 3, OPJSONString(schedule));
        sqlite3_bind_int64(statement, 4, nextRunAt);
        OPSQLiteBindText(statement, 5, OPJSONString(metadata));
        sqlite3_bind_int64(statement, 6, watcherId);
        updated = sqlite3_step(statement) == SQLITE_DONE && sqlite3_changes(db) > 0;
        if (!updated && errorOut) {
            *errorOut = @"watcher_update_missed_active_row";
        }
    } else if (errorOut) {
        *errorOut = [NSString stringWithUTF8String:sqlite3_errmsg(db)] ?: @"watcher_update_prepare_failed";
    }
    sqlite3_finalize(statement);
    NSDictionary *updatedWatcher = updated ? OPWatcherRead(db, watcherId) : nil;
    sqlite3_close(db);
    return updatedWatcher;
}

static NSDictionary *OPWatcherMaterializeDue(NSUInteger limit, long long nowMs,
        NSString *taskId, NSString *source) {
    NSDictionary *repairResult = OPWatcherRepairStuckInternal(limit, 300000, taskId,
            source ?: @"watcher_scheduler");
    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    NSArray<NSDictionary *> *dueWatchers = OPWatcherDueRows(db, limit, nowMs);
    sqlite3_close(db);

    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSUInteger firedCount = 0;
    NSUInteger jobCount = 0;
    for (NSDictionary *watcher in dueWatchers) {
        NSString *watcherPublicId = [watcher[@"watcher_id"] isKindOfClass:[NSString class]]
                ? watcher[@"watcher_id"] : [NSString stringWithFormat:@"ios-watcher-%lld",
                        [watcher[@"id"] longLongValue]];
        NSString *title = [watcher[@"title"] isKindOfClass:[NSString class]]
                ? watcher[@"title"] : watcherPublicId;
        NSDictionary *delivery = [watcher[@"delivery"] isKindOfClass:[NSDictionary class]]
                ? watcher[@"delivery"] : @{};
        NSDictionary *event = @{
            @"type": @"timer",
            @"watcher_id": watcherPublicId,
            @"watcher_row_id": watcher[@"id"] ?: @0,
            @"title": title ?: watcherPublicId,
            @"fired_at_ms": @(nowMs),
            @"scheduled_at_ms": watcher[@"next_run_at_ms"] ?: @0
        };
        NSString *claimError = nil;
        NSDictionary *claimedWatcher = OPWatcherClaimForFire(watcher, nowMs,
                source ?: @"watcher_scheduler", &claimError);
        if (!claimedWatcher) {
            NSMutableDictionary *claimEntry = [@{
                @"watcher_id": watcherPublicId,
                @"status": @"skipped",
                @"reason": claimError ?: @"watcher_claim_failed",
                @"event": event
            } mutableCopy];
            [entries addObject:claimEntry];
            continue;
        }
        NSDictionary *materializedWatcher = claimedWatcher;
        NSMutableDictionary *payload = [@{
            @"source": @"watcher_scheduler",
            @"watcher_id": watcherPublicId,
            @"watcher_row_id": materializedWatcher[@"id"] ?: @0,
            @"event": event,
            @"delivery": delivery
        } mutableCopy];
        NSString *prompt = OPWatcherPrompt(materializedWatcher);
        NSMutableDictionary *jobRequest = [@{
            @"command": @"background_job_create",
            @"task_id": taskId ?: @"",
            @"title": [NSString stringWithFormat:@"Watcher fired: %@", title ?: watcherPublicId],
            @"prompt": prompt,
            @"type": @"watcher_fire",
            @"next_run_at": @(nowMs),
            @"source": @"watcher_scheduler",
            @"reason": [NSString stringWithFormat:@"timer watcher fired:%@", watcherPublicId],
            @"payload": payload,
            @"delivery": delivery
        } mutableCopy];
        NSString *notificationText = [delivery[@"notification_text"] isKindOfClass:[NSString class]]
                ? delivery[@"notification_text"] : @"";
        if (notificationText.length > 0) {
            jobRequest[@"notification_text"] = notificationText;
        }

        NSDictionary *jobResult = OPBackgroundJobCreate(jobRequest);
        NSMutableDictionary *entry = [@{
            @"watcher_id": watcherPublicId,
            @"status": @"failed",
            @"event": event
        } mutableCopy];
        if ([jobResult[@"status"] isEqualToString:@"ok"]) {
            firedCount++;
            jobCount++;
            NSDictionary *job = [jobResult[@"job"] isKindOfClass:[NSDictionary class]]
                    ? jobResult[@"job"] : @{};
            NSString *jobPublicId = [job[@"job_id"] isKindOfClass:[NSString class]]
                    ? job[@"job_id"] : @"";
            NSString *updateError = nil;
            NSDictionary *updatedWatcher = OPWatcherUpdateAfterFire(materializedWatcher, jobPublicId, nowMs, &updateError);
            entry[@"status"] = @"background_job_queued";
            entry[@"job_id"] = jobPublicId;
            entry[@"job"] = job;
            if (updatedWatcher) {
                entry[@"watcher"] = updatedWatcher;
            }
            if (updateError) {
                entry[@"update_error"] = updateError;
            }
            OPRecordContextEvent(@"watcher_fired", @"openphone.agentd", taskId,
                    title ?: watcherPublicId, prompt, @{
                        @"watcher_id": watcherPublicId,
                        @"job_id": jobPublicId ?: @"",
                        @"scheduler_status": OPWatcherSchedulerStatus(),
                        @"source": source ?: @"watcher_scheduler"
                    });
            OPRecordAudit(@"watcher_fired", taskId, @"watchers.write", @"allow_yolo",
                    jobRequest, [NSString stringWithFormat:@"watcher_id:%@ job_id:%@",
                    watcherPublicId, jobPublicId ?: @""]);
        } else {
            NSString *failureReason = [jobResult[@"reason"] isKindOfClass:[NSString class]]
                    ? jobResult[@"reason"] : @"background_job_create_failed";
            entry[@"reason"] = failureReason;
            entry[@"job_result"] = jobResult ?: @{};
            NSString *failureUpdateError = nil;
            NSDictionary *requeuedWatcher = OPWatcherRequeueAfterFireFailure(materializedWatcher,
                    failureReason, nowMs, source ?: @"watcher_scheduler", &failureUpdateError);
            entry[@"retry_backoff"] = @"exponential";
            if (requeuedWatcher) {
                entry[@"watcher"] = requeuedWatcher;
            }
            if (failureUpdateError) {
                entry[@"update_error"] = failureUpdateError;
            }
        }
        [entries addObject:entry];
    }

    return @{
        @"status": @"ok",
        @"scheduler_status": OPWatcherSchedulerStatus(),
        @"stuck_repair_count": repairResult[@"repaired_count"] ?: @0,
        @"stuck_repair_result": repairResult ?: @{},
        @"source": @"openphone.agentd",
        @"limit": @(limit),
        @"due_count": @(dueWatchers.count),
        @"fired_count": @(firedCount),
        @"job_count": @(jobCount),
        @"watchers": entries
    };
}

// ---------------------------------------------------------------------------
// Notification provider. The OpenPhoneVolumeTrigger tweak (injected into
// SpringBoard) hooks NCNotificationDispatcher and posts each incoming banner
// to the daemon via the `notification_ingest` command. The daemon keeps a
// bounded, redacted rolling log and fires any active `notification`-source
// watchers whose condition matches, turning the assistant reactive.
// ---------------------------------------------------------------------------

static const NSUInteger OPNotificationLogMax = 100;

static NSString *OPNotificationBoundedText(NSString *text, NSUInteger maxLen) {
    if (![text isKindOfClass:[NSString class]]) {
        return @"";
    }
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length <= maxLen) {
        return trimmed;
    }
    return [[trimmed substringToIndex:maxLen] stringByAppendingString:@"…"];
}

static NSDictionary *OPNotificationProviderStatus(void) {
    NSDictionary *log = OPReadJSONFile(OPNotificationLogPath());
    NSArray *items = [log[@"notifications"] isKindOfClass:[NSArray class]]
            ? log[@"notifications"] : @[];
    return @{
        @"status": @"implemented",
        @"provider": @"OpenPhoneVolumeTrigger.NCNotificationDispatcher",
        @"transport": @"unix_socket",
        @"log_path": OPNotificationLogPath(),
        @"stored_count": @(items.count),
        @"ingest_count": @((long long)OPNotificationIngestCount),
        @"last_ingest_ms": @((long long)OPNotificationLastIngestMs),
        @"last_bundle_id": OPNotificationLastBundleId ?: @"",
        @"watcher_source": @"notification",
        @"retention": @"bounded title/body previews only, newest 100 kept; no attachments or full payloads"
    };
}

// Active notification-source watchers whose condition matches the notification
// fire a background job. A watcher matches when its bundle_id condition (if any)
// equals the notification bundle and its query/keyword (if any) appears in the
// notification title or body (case-insensitive). Empty conditions match all.
static NSDictionary *OPNotificationFireWatchers(NSDictionary *notification) {
    NSString *bundleId = [notification[@"bundle_id"] isKindOfClass:[NSString class]]
            ? notification[@"bundle_id"] : @"";
    NSString *haystack = [[NSString stringWithFormat:@"%@ %@ %@",
            notification[@"title"] ?: @"", notification[@"subtitle"] ?: @"",
            notification[@"body"] ?: @""] lowercaseString];
    long long nowMs = OPNowMs();

    sqlite3 *db = NULL;
    NSString *error = nil;
    if (!OPSQLiteOpen(&db, &error)) {
        return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
    }
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db,
            "SELECT id, created_at_ms, updated_at_ms, status, source, type, evaluator, title, "
            "query, url, address, number, condition_json, schedule_json, delivery_json, "
            "next_run_at_ms, interval_ms, recurring, reason, metadata_json "
            "FROM watcher WHERE status = 'active' AND lower(source) = 'notification'",
            -1, &statement, NULL) == SQLITE_OK) {
        while (sqlite3_step(statement) == SQLITE_ROW) {
            [candidates addObject:OPWatcherFromStatement(statement)];
        }
    }
    sqlite3_finalize(statement);
    sqlite3_close(db);

    NSMutableArray<NSDictionary *> *fired = [NSMutableArray array];
    NSUInteger firedCount = 0;
    for (NSDictionary *watcher in candidates) {
        NSDictionary *condition = [watcher[@"condition"] isKindOfClass:[NSDictionary class]]
                ? watcher[@"condition"] : @{};
        NSString *wantBundle = [condition[@"bundle_id"] isKindOfClass:[NSString class]]
                ? condition[@"bundle_id"] : ([watcher[@"address"] isKindOfClass:[NSString class]]
                        ? watcher[@"address"] : @"");
        if (wantBundle.length > 0 && ![wantBundle isEqualToString:bundleId]) {
            continue;
        }
        NSString *keyword = [condition[@"query"] isKindOfClass:[NSString class]]
                ? condition[@"query"] : ([watcher[@"query"] isKindOfClass:[NSString class]]
                        ? watcher[@"query"] : @"");
        keyword = [keyword stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (keyword.length > 0 &&
                [haystack rangeOfString:keyword.lowercaseString].location == NSNotFound) {
            continue;
        }
        NSString *watcherPublicId = [watcher[@"watcher_id"] isKindOfClass:[NSString class]]
                ? watcher[@"watcher_id"] : [NSString stringWithFormat:@"ios-watcher-%lld",
                        [watcher[@"id"] longLongValue]];
        NSString *title = [watcher[@"title"] isKindOfClass:[NSString class]]
                ? watcher[@"title"] : watcherPublicId;
        NSString *claimError = nil;
        NSDictionary *claimedWatcher = OPWatcherClaimForFire(watcher, nowMs,
                @"notification_provider", &claimError);
        if (!claimedWatcher) {
            [fired addObject:@{@"watcher_id": watcherPublicId, @"status": @"skipped",
                    @"reason": claimError ?: @"watcher_claim_failed"}];
            continue;
        }
        NSDictionary *delivery = [claimedWatcher[@"delivery"] isKindOfClass:[NSDictionary class]]
                ? claimedWatcher[@"delivery"] : @{};
        NSDictionary *event = @{
            @"type": @"notification",
            @"watcher_id": watcherPublicId,
            @"watcher_row_id": claimedWatcher[@"id"] ?: @0,
            @"fired_at_ms": @(nowMs),
            @"notification": notification
        };
        NSString *prompt = OPWatcherPrompt(claimedWatcher);
        NSString *notificationSummary = [NSString stringWithFormat:
                @"Notification from %@: %@ %@", bundleId,
                notification[@"title"] ?: @"", notification[@"body"] ?: @""];
        NSMutableDictionary *jobRequest = [@{
            @"command": @"background_job_create",
            @"title": [NSString stringWithFormat:@"Notification watcher fired: %@", title],
            @"prompt": [NSString stringWithFormat:@"%@\n\nTriggering notification: %@",
                    prompt, notificationSummary],
            @"type": @"watcher_fire",
            @"next_run_at": @(nowMs),
            @"source": @"notification_provider",
            @"reason": [NSString stringWithFormat:@"notification watcher fired:%@", watcherPublicId],
            @"payload": @{@"source": @"notification_provider", @"watcher_id": watcherPublicId,
                    @"event": event, @"delivery": delivery},
            @"delivery": delivery
        } mutableCopy];
        NSDictionary *jobResult = OPBackgroundJobCreate(jobRequest);
        if ([jobResult[@"status"] isEqualToString:@"ok"]) {
            firedCount++;
            NSDictionary *job = [jobResult[@"job"] isKindOfClass:[NSDictionary class]]
                    ? jobResult[@"job"] : @{};
            NSString *jobPublicId = [job[@"job_id"] isKindOfClass:[NSString class]]
                    ? job[@"job_id"] : @"";
            NSString *updateError = nil;
            OPWatcherUpdateAfterFire(claimedWatcher, jobPublicId, nowMs, &updateError);
            OPRecordAudit(@"watcher_fired", @"", @"watchers.write", @"allow_yolo",
                    jobRequest, [NSString stringWithFormat:@"watcher_id:%@ job_id:%@ source:notification",
                    watcherPublicId, jobPublicId ?: @""]);
            [fired addObject:@{@"watcher_id": watcherPublicId,
                    @"status": @"background_job_queued", @"job_id": jobPublicId}];
        } else {
            NSString *failureReason = [jobResult[@"reason"] isKindOfClass:[NSString class]]
                    ? jobResult[@"reason"] : @"background_job_create_failed";
            NSString *failureUpdateError = nil;
            OPWatcherRequeueAfterFireFailure(claimedWatcher, failureReason, nowMs,
                    @"notification_provider", &failureUpdateError);
            [fired addObject:@{@"watcher_id": watcherPublicId, @"status": @"failed",
                    @"reason": failureReason}];
        }
    }
    return @{
        @"status": @"ok",
        @"candidate_count": @(candidates.count),
        @"fired_count": @(firedCount),
        @"watchers": fired
    };
}

static NSDictionary *OPNotificationIngest(NSDictionary *request) {
    NSString *bundleId = OPStringFromRequest(request, @"bundle_id", @"");
    if (!OPBundleIdentifierLooksValid(bundleId)) {
        return OPError(@"invalid_notification_bundle_id");
    }
    long long nowMs = OPNowMs();
    NSDictionary *record = @{
        @"schema": @"openphone.notification.v1",
        @"bundle_id": bundleId,
        @"title": OPNotificationBoundedText(OPStringFromRequest(request, @"title", @""), 200),
        @"subtitle": OPNotificationBoundedText(OPStringFromRequest(request, @"subtitle", @""), 200),
        @"body": OPNotificationBoundedText(OPStringFromRequest(request, @"body", @""), 1000),
        @"notification_id": OPNotificationBoundedText(OPStringFromRequest(request, @"notification_id", @""), 200),
        @"thread_id": OPNotificationBoundedText(OPStringFromRequest(request, @"thread_id", @""), 200),
        @"received_at_ms": @(nowMs),
        @"source": @"OpenPhoneVolumeTrigger.NCNotificationDispatcher"
    };

    OPEnsureDirectories();
    NSDictionary *existing = OPReadJSONFile(OPNotificationLogPath());
    NSArray *prior = [existing[@"notifications"] isKindOfClass:[NSArray class]]
            ? existing[@"notifications"] : @[];
    NSMutableArray *items = [prior mutableCopy];
    [items addObject:record];
    while (items.count > OPNotificationLogMax) {
        [items removeObjectAtIndex:0];
    }
    OPWriteJSONFile(OPNotificationLogPath(), @{
        @"schema": @"openphone.notification_log.v1",
        @"updated_at_ms": @(nowMs),
        @"notifications": items,
        @"source": @"openphone.agentd"
    });
    chmod(OPNotificationLogPath().UTF8String, 0644);

    @synchronized(@"OPNotificationMetrics") {
        OPNotificationIngestCount++;
        OPNotificationLastIngestMs = nowMs;
        OPNotificationLastBundleId = [bundleId copy];
    }
    OPRecordContextEvent(@"notification_received", @"openphone.agentd", @"",
            record[@"title"], record[@"body"], @{
                @"bundle_id": bundleId,
                @"source": @"notification_provider"
            });

    NSDictionary *fireResult = OPNotificationFireWatchers(record);
    return @{
        @"status": @"ok",
        @"schema": @"openphone.notification_ingest_result.v1",
        @"bundle_id": bundleId,
        @"stored_count": @(items.count),
        @"watcher_fire": fireResult ?: @{},
        @"source": @"openphone.agentd.notification_provider"
    };
}

static NSDictionary *OPNotificationList(NSDictionary *request) {
    long long limit = OPLongLongFromRequest(request, @"limit", 20, 1, OPNotificationLogMax);
    NSString *bundleFilter = OPStringFromRequest(request, @"bundle_id", @"");
    NSDictionary *log = OPReadJSONFile(OPNotificationLogPath());
    NSArray *items = [log[@"notifications"] isKindOfClass:[NSArray class]]
            ? log[@"notifications"] : @[];
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *item in [items reverseObjectEnumerator]) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        if (bundleFilter.length > 0 &&
                ![item[@"bundle_id"] isEqualToString:bundleFilter]) {
            continue;
        }
        [filtered addObject:item];
        if ((long long)filtered.count >= limit) break;
    }
    return @{
        @"status": @"ok",
        @"schema": @"openphone.notification_list.v1",
        @"count": @(filtered.count),
        @"total_stored": @(items.count),
        @"notifications": filtered,
        @"provider_status": OPNotificationProviderStatus(),
        @"source": @"openphone.agentd"
    };
}

// Promote durable voice turns from the persisted chat history into the memory
// store so a follow-up voice turn days later can reference them. The in-memory
// OPRecentVoiceTurns ring buffer only survives the process; chat-history.json
// survives restarts and is the source of truth here. A watermark file tracks
// the last-promoted turn timestamp so each turn is saved at most once.
static NSDictionary *OPPromoteVoiceTurnsToMemory(NSDictionary *request) {
    long long minChars = OPLongLongFromRequest(request, @"min_chars", 12, 1, 4000);
    long long maxPromote = OPLongLongFromRequest(request, @"max_promote", 10, 1, 100);
    NSString *taskId = OPStringFromRequest(request, @"task_id", @"");

    NSString *historyPath = [[OPStorePath() stringByAppendingPathComponent:@"springboard"]
            stringByAppendingPathComponent:@"chat-history.json"];
    NSDictionary *history = OPReadJSONFile(historyPath);
    NSArray *turns = [history[@"turns"] isKindOfClass:[NSArray class]] ? history[@"turns"] : @[];

    NSDictionary *watermark = OPReadJSONFile(OPVoiceMemoryWatermarkPath());
    long long lastPromotedMs = [watermark[@"last_promoted_at_ms"] respondsToSelector:@selector(longLongValue)]
            ? [watermark[@"last_promoted_at_ms"] longLongValue] : 0;

    long long highestSeenMs = lastPromotedMs;
    long long promoted = 0;
    NSMutableArray<NSDictionary *> *saved = [NSMutableArray array];
    for (NSDictionary *turn in turns) {
        if (![turn isKindOfClass:[NSDictionary class]]) continue;
        long long atMs = [turn[@"at_ms"] respondsToSelector:@selector(longLongValue)]
                ? [turn[@"at_ms"] longLongValue] : 0;
        if (atMs <= lastPromotedMs) continue;
        if (atMs > highestSeenMs) highestSeenMs = atMs;
        NSString *role = [turn[@"role"] isKindOfClass:[NSString class]] ? turn[@"role"] : @"";
        if (![role isEqualToString:@"user"]) continue;
        NSString *text = [turn[@"text"] isKindOfClass:[NSString class]] ? turn[@"text"] : @"";
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ((long long)text.length < minChars) continue;
        if (promoted >= maxPromote) break;
        NSString *turnTaskId = [turn[@"task_id"] isKindOfClass:[NSString class]]
                ? turn[@"task_id"] : @"";
        NSDictionary *saveResult = OPMemorySave(@{
            @"text": text,
            @"type": @"voice_turn",
            @"subject": @"user",
            @"confidence": @0.7,
            @"reason": @"auto-promoted from voice chat history",
            @"task_id": turnTaskId,
            @"metadata": @{
                @"origin": @"voice_turn_auto_promote",
                @"turn_at_ms": @(atMs)
            }
        });
        if ([saveResult[@"status"] isEqualToString:@"ok"]) {
            promoted += 1;
            [saved addObject:@{
                @"turn_at_ms": @(atMs),
                @"memory_id": saveResult[@"memory"][@"memory_id"] ?: @""
            }];
        }
    }

    if (highestSeenMs > lastPromotedMs) {
        OPWriteJSONFile(OPVoiceMemoryWatermarkPath(), @{
            @"last_promoted_at_ms": @(highestSeenMs),
            @"updated_at_ms": @(OPNowMs()),
            @"promoted_count": @(promoted),
            @"source": @"openphone.agentd"
        });
        chmod(OPVoiceMemoryWatermarkPath().UTF8String, 0644);
    }
    if (promoted > 0) {
        OPRecordAudit(@"voice_turns_promoted_to_memory", taskId, @"memory.write",
                @"allow_yolo", request, [NSString stringWithFormat:@"promoted:%lld", promoted]);
    }
    return @{
        @"status": @"ok",
        @"promoted_count": @(promoted),
        @"turns_scanned": @(turns.count),
        @"last_promoted_at_ms": @(highestSeenMs),
        @"saved": saved,
        @"source": @"openphone.agentd"
    };
}

// Unattended background jobs run without a human watching the Approve/Deny
// island, so by default they may only observe and navigate, never commit
// irreversible or externally-visible mutations. Every state-changing action
// on iOS routes through the UI (tap/type_text/swipe/long_press) which all map
// to the "input.perform" capability; mutating provider tools map to their own
// write/send/delete/place capabilities. The read/navigate-only grant below
// omits all of those, so OPModelExecuteDecision denies mutations with
// "capability_not_approved". A job opts back into full state-changing power
// only by carrying an explicit grant (payload.background_state_changing = true
// or payload.autonomy = "yolo"), mirroring the Android "explicit policy grant"
// model (IOS_PLAN.md Phase 10, Option B).
static NSArray<NSString *> *OPBackgroundReadOnlyCapabilities(void) {
    return @[
        @"screen.read.visible",
        @"screen.capture",
        @"apps.read",
        @"apps.launch",
        @"tasks.observe",
        @"memory.read",
        @"memory.write",
        @"commitments.read",
        @"watchers.read",
        @"notifications.read",
        @"clipboard.read",
        @"contacts.read",
        @"calendar.read",
        @"messages.read",
        @"calls.read",
        @"settings.read",
        @"files.read.scoped",
        @"background.run",
        @"network.use"
    ];
}

static BOOL OPBackgroundJobHasStateChangingGrant(NSDictionary *job) {
    if (![job isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSDictionary *payload = [job[@"payload"] isKindOfClass:[NSDictionary class]]
            ? job[@"payload"] : @{};
    if ([payload[@"background_state_changing"] isEqual:@YES]) {
        return YES;
    }
    NSString *autonomy = [payload[@"autonomy"] isKindOfClass:[NSString class]]
            ? [payload[@"autonomy"] lowercaseString] : @"";
    if ([autonomy isEqualToString:@"yolo"] || [autonomy isEqualToString:@"full"]) {
        return YES;
    }
    return NO;
}

// Resolve the capability grant a background job runs under. Returns the
// read/navigate-only set unless the job carries an explicit state-changing
// grant, in which case it gets full YOLO capabilities. policyOut (optional)
// receives a short label for audit/trajectory.
static NSArray<NSString *> *OPBackgroundJobRunCapabilities(NSDictionary *job,
        NSString **policyOut) {
    if (OPBackgroundJobHasStateChangingGrant(job)) {
        if (policyOut) {
            *policyOut = @"explicit_state_changing_grant";
        }
        return OPFullYoloCapabilities();
    }
    if (policyOut) {
        *policyOut = @"read_navigate_only";
    }
    return OPBackgroundReadOnlyCapabilities();
}

static NSDictionary *OPBackgroundJobRunDue(NSDictionary *request) {
    if (pthread_mutex_trylock(&OPBackgroundJobSchedulerMutex) != 0) {
        return @{
            @"status": @"ok",
            @"scheduler_status": OPBackgroundJobSchedulerStatus(),
            @"commitment_scheduler_status": OPCommitmentSchedulerStatus(),
            @"watcher_scheduler_status": OPWatcherSchedulerStatus(),
            @"busy": @YES,
            @"ran_count": @0,
            @"source": @"openphone.agentd"
        };
    }

    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    NSUInteger claimedCount = 0;
    NSUInteger skippedCount = 0;
    NSString *error = nil;
    @try {
        NSUInteger limit = OPLimitFromRequest(request, 1, 10);
        if (limit == 0) {
            limit = 1;
        }
        long long maxSteps = OPLongLongFromRequest(request, @"max_steps", 1, 1, 5);
        long long maxDurationMs = OPLongLongFromRequest(request, @"max_duration_ms", 15000, 1000, 120000);
        NSString *source = OPStringFromRequest(request, @"source", @"background_job_scheduler");
        NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
        long long targetJobId = OPRecordIdFromRequest(request, @[@"job_id", @"id"]);
        BOOL repairStuck = OPBoolFromRequest(request, @"repair_stuck", targetJobId <= 0);
        BOOL materializeCommitments = OPBoolFromRequest(request, @"materialize_commitments", targetJobId <= 0);
        BOOL materializeWatchers = OPBoolFromRequest(request, @"materialize_watchers", targetJobId <= 0);
        BOOL runJobs = OPBoolFromRequest(request, @"run_jobs", YES);
        long long staleAfterMs = OPLongLongFromRequest(request,
                @"stale_after_ms", 300000, 1000, 86400000LL);
        NSDictionary *repairResult = repairStuck
                ? OPBackgroundJobRepairStuckInternal(limit, staleAfterMs, taskId, source)
                : @{@"status": @"skipped", @"reason": @"repair_stuck_disabled", @"repaired_count": @0};
        id deliveryRequest = OPJSONObjectFromRequest(request, @"delivery", nil);
        NSDictionary *commitmentResult = materializeCommitments
                ? OPCommitmentMaterializeDue(limit, OPNowMs(), taskId, source,
                    [deliveryRequest isKindOfClass:[NSDictionary class]] ? deliveryRequest : nil)
                : @{@"status": @"skipped", @"reason": @"materialize_commitments_disabled",
                    @"triggered_count": @0, @"job_count": @0};
        NSDictionary *watcherResult = materializeWatchers
                ? OPWatcherMaterializeDue(limit, OPNowMs(), taskId, source)
                : @{@"status": @"skipped", @"reason": @"materialize_watchers_disabled",
                    @"fired_count": @0, @"job_count": @0};
        if (!runJobs) {
            return @{
                @"status": @"ok",
                @"scheduler_status": OPBackgroundJobSchedulerStatus(),
                @"commitment_scheduler_status": OPCommitmentSchedulerStatus(),
                @"watcher_scheduler_status": OPWatcherSchedulerStatus(),
                @"stuck_repair_count": repairResult[@"repaired_count"] ?: @0,
                @"stuck_repair_result": repairResult ?: @{},
                @"commitment_triggered_count": commitmentResult[@"triggered_count"] ?: @0,
                @"commitment_jobs_created": commitmentResult[@"job_count"] ?: @0,
                @"commitment_result": commitmentResult ?: @{},
                @"watcher_fire_count": watcherResult[@"fired_count"] ?: @0,
                @"watcher_jobs_created": watcherResult[@"job_count"] ?: @0,
                @"watcher_result": watcherResult ?: @{},
                @"runner": @"deterministic",
                @"model_loop_status": @"not_started",
                @"run_jobs": @NO,
                @"run_policy": @"repair_and_materialize_only",
                @"target_job_id": @(targetJobId),
                @"limit": @(limit),
                @"claimed_count": @0,
                @"skipped_count": @0,
                @"ran_count": @0,
                @"jobs": @[],
                @"source": @"openphone.agentd"
            };
        }

        sqlite3 *db = NULL;
        if (!OPSQLiteOpen(&db, &error)) {
            return OPError([NSString stringWithFormat:@"sqlite_open_failed:%@", error ?: @"unknown"]);
        }
        NSArray<NSDictionary *> *jobs = OPBackgroundJobDueRows(db, limit, OPNowMs(), targetJobId);
        sqlite3_close(db);

        for (NSDictionary *job in jobs) {
            long long jobId = [job[@"id"] longLongValue];
            NSString *jobPublicId = [job[@"job_id"] isKindOfClass:[NSString class]]
                    ? job[@"job_id"] : [NSString stringWithFormat:@"ios-job-%lld", jobId];
            NSString *claimError = nil;
            if (!OPBackgroundJobClaim(jobId, &claimError)) {
                skippedCount++;
                [results addObject:@{
                    @"job_id": jobPublicId,
                    @"status": @"skipped",
                    @"reason": claimError ?: @"claim_failed"
                }];
                continue;
            }
            claimedCount++;

            NSString *prompt = [job[@"prompt"] isKindOfClass:[NSString class]] ? job[@"prompt"] : @"";
            if (prompt.length == 0) {
                prompt = [job[@"title"] isKindOfClass:[NSString class]] ? job[@"title"] : @"background job";
            }
            NSString *runPolicy = nil;
            NSArray<NSString *> *runCapabilities = OPBackgroundJobRunCapabilities(job, &runPolicy);
            NSDictionary *runRequest = @{
                @"mode": OPStringFromRequest(request, @"mode", @"auto"),
                @"goal": prompt,
                @"reason": [NSString stringWithFormat:@"background job scheduler:%@", jobPublicId],
                @"max_steps": @(maxSteps),
                @"max_duration_ms": @(maxDurationMs),
                @"include_screenshot": @(![source isEqualToString:@"background_job_scheduler"]),
                @"background_job_id": jobPublicId,
                @"background_job_row_id": @(jobId),
                @"approved_capabilities": runCapabilities,
                @"background_capability_policy": runPolicy ?: @"read_navigate_only",
                @"source": source ?: @"background_job_scheduler"
            };
            OPRecordContextEvent(@"background_job_started", @"openphone.agentd", taskId,
                    job[@"title"] ?: jobPublicId, prompt, @{
                        @"job_id": jobPublicId,
                        @"runner": runRequest[@"mode"] ?: @"auto",
                        @"model_loop_status": @"auto",
                        @"capability_policy": runPolicy ?: @"read_navigate_only"
                    });
            OPRecordAudit(@"background_job_started", taskId, @"background.run",
                    [runPolicy isEqualToString:@"explicit_state_changing_grant"]
                            ? @"allow_yolo" : @"allow_read_navigate_only",
                    runRequest, [NSString stringWithFormat:@"job_id:%@ policy:%@",
                            jobPublicId, runPolicy ?: @"read_navigate_only"]);

            NSDictionary *runResult = nil;
            @try {
                runResult = OPRunTask(runRequest);
            } @catch (NSException *exception) {
                OPLog(@"background job run exception job_id=%@ exception=%@ reason=%@",
                        jobPublicId ?: @"", exception.name ?: @"NSException",
                        exception.reason ?: @"");
                runResult = @{
                    @"status": @"task.failed",
                    @"runner": @"deterministic",
                    @"task_id": @"",
                    @"stop_reason": @"exception",
                    @"exception_name": exception.name ?: @"NSException",
                    @"exception_reason": exception.reason ?: @"",
                    @"source": @"openphone.agentd"
                };
            }
            BOOL taskFinished = [runResult[@"status"] isEqualToString:@"task.finished"];
            NSString *runner = [runResult[@"runner"] isKindOfClass:[NSString class]]
                    ? runResult[@"runner"] : @"auto";
            NSString *modelLoopStatus = [runner isEqualToString:@"model"] ? @"finished" : @"not_started";
            NSString *finishError = nil;
            NSDictionary *updatedJob = OPBackgroundJobFinish(job, runResult, &finishError);
            NSString *jobStatus = taskFinished ? @"completed" : @"failed";
            if ([updatedJob[@"status"] isEqualToString:@"queued"]) {
                jobStatus = @"queued";
            } else if ([updatedJob[@"status"] isKindOfClass:[NSString class]]) {
                jobStatus = updatedJob[@"status"];
            }
            NSMutableDictionary *entry = [@{
                @"job_id": jobPublicId,
                @"status": jobStatus ?: @"unknown",
                @"run_task": runResult ?: @{},
                @"runner": runner ?: @"auto",
                @"model_loop_status": modelLoopStatus ?: @"unknown"
            } mutableCopy];
            if (updatedJob) {
                entry[@"job"] = updatedJob;
            }
            if (finishError) {
                entry[@"finish_error"] = finishError;
            }
            [results addObject:entry];

            OPRecordContextEvent(taskFinished ? @"background_job_completed" : @"background_job_failed",
                    @"openphone.agentd", runResult[@"task_id"] ?: taskId,
                    job[@"title"] ?: jobPublicId, runResult[@"stop_reason"] ?: jobStatus, @{
                        @"job_id": jobPublicId,
                        @"status": jobStatus ?: @"unknown",
                        @"task_id": runResult[@"task_id"] ?: @""
                    });
            OPRecordAudit(taskFinished ? @"background_job_completed" : @"background_job_failed",
                    runResult[@"task_id"] ?: taskId, @"background.run",
                    taskFinished ? @"allow_task_scoped" : @"failed",
                    runRequest, [NSString stringWithFormat:@"job_id:%@ status:%@", jobPublicId, jobStatus]);
        }

        NSString *aggregateRunner = @"auto";
        NSString *aggregateModelLoopStatus = @"auto";
        if (results.count > 0) {
            NSDictionary *firstResult = results[0];
            aggregateRunner = [firstResult[@"runner"] isKindOfClass:[NSString class]]
                    ? firstResult[@"runner"] : aggregateRunner;
            aggregateModelLoopStatus = [firstResult[@"model_loop_status"] isKindOfClass:[NSString class]]
                    ? firstResult[@"model_loop_status"] : aggregateModelLoopStatus;
        }
        NSDictionary *result = @{
            @"status": @"ok",
            @"scheduler_status": OPBackgroundJobSchedulerStatus(),
            @"commitment_scheduler_status": OPCommitmentSchedulerStatus(),
            @"watcher_scheduler_status": OPWatcherSchedulerStatus(),
            @"stuck_repair_count": repairResult[@"repaired_count"] ?: @0,
            @"stuck_repair_result": repairResult ?: @{},
            @"commitment_triggered_count": commitmentResult[@"triggered_count"] ?: @0,
            @"commitment_jobs_created": commitmentResult[@"job_count"] ?: @0,
            @"commitment_result": commitmentResult ?: @{},
            @"watcher_fire_count": watcherResult[@"fired_count"] ?: @0,
            @"watcher_jobs_created": watcherResult[@"job_count"] ?: @0,
            @"watcher_result": watcherResult ?: @{},
            @"runner": aggregateRunner ?: @"auto",
            @"model_loop_status": aggregateModelLoopStatus ?: @"auto",
            @"target_job_id": @(targetJobId),
            @"limit": @(limit),
            @"claimed_count": @(claimedCount),
            @"skipped_count": @(skippedCount),
            @"ran_count": @(results.count - skippedCount),
            @"jobs": results,
            @"source": @"openphone.agentd"
        };
        if (results.count > 0) {
            OPRecordAudit(@"background_job_scheduler_tick", taskId, @"background.run",
                    @"allow_task_scoped", request, [NSString stringWithFormat:@"ran:%lu skipped:%lu",
                    (unsigned long)(results.count - skippedCount), (unsigned long)skippedCount]);
        }
        return result;
    } @finally {
        pthread_mutex_unlock(&OPBackgroundJobSchedulerMutex);
    }
}

static void *OPBackgroundJobSchedulerMain(void *context) {
    (void)context;
    OPLog(@"background job scheduler startup delay seconds=%d",
            OPBackgroundJobSchedulerStartupDelaySeconds);
    for (int i = 0; i < OPBackgroundJobSchedulerStartupDelaySeconds && OPRunning; i++) {
        sleep(1);
    }
    long long lastVoicePromoteMs = 0;
    while (OPRunning) {
        @autoreleasepool {
            NSDictionary *result = OPBackgroundJobRunDue(@{
                @"command": @"background_job_run_due",
                @"limit": @1,
                @"max_steps": @1,
                @"max_duration_ms": @15000,
                @"run_jobs": @NO,
                @"source": @"background_job_scheduler",
                @"reason": @"periodic background job scheduler repair/materialization tick"
            });
            // Promote durable voice turns into memory on a slow cadence (~60s)
            // so follow-up voice turns days later can reference them.
            long long nowMs = OPNowMs();
            if (nowMs - lastVoicePromoteMs >= 60000) {
                lastVoicePromoteMs = nowMs;
                NSDictionary *promote = OPPromoteVoiceTurnsToMemory(@{
                    @"source": @"background_job_scheduler"
                });
                long long promoted = [promote[@"promoted_count"] respondsToSelector:@selector(longLongValue)]
                        ? [promote[@"promoted_count"] longLongValue] : 0;
                if (promoted > 0) {
                    OPLog(@"voice turns promoted to memory count=%lld", promoted);
                }
            }
            long long ran = [result[@"ran_count"] respondsToSelector:@selector(longLongValue)]
                    ? [result[@"ran_count"] longLongValue] : 0;
            long long repaired = [result[@"stuck_repair_count"] respondsToSelector:@selector(longLongValue)]
                    ? [result[@"stuck_repair_count"] longLongValue] : 0;
            long long fired = [result[@"watcher_fire_count"] respondsToSelector:@selector(longLongValue)]
                    ? [result[@"watcher_fire_count"] longLongValue] : 0;
            long long triggered = [result[@"commitment_triggered_count"] respondsToSelector:@selector(longLongValue)]
                    ? [result[@"commitment_triggered_count"] longLongValue] : 0;
            if (ran > 0) {
                OPLog(@"background job scheduler ran_count=%lld", ran);
            } else if (repaired > 0 || fired > 0 || triggered > 0) {
                OPLog(@"background job scheduler recovery repaired=%lld commitment_triggered_count=%lld watcher_fire_count=%lld",
                        repaired, triggered, fired);
            }
        }
        for (int i = 0; i < 5 && OPRunning; i++) {
            sleep(1);
        }
    }
    return NULL;
}

static void OPStartBackgroundJobScheduler(void) {
    if (OPBackgroundJobSchedulerThreadStarted) {
        return;
    }
    int rc = pthread_create(&OPBackgroundJobSchedulerThread, NULL,
            OPBackgroundJobSchedulerMain, NULL);
    if (rc == 0) {
        OPBackgroundJobSchedulerThreadStarted = 1;
        pthread_detach(OPBackgroundJobSchedulerThread);
        OPLog(@"background job scheduler started status=%@", OPBackgroundJobSchedulerStatus());
    } else {
        OPLog(@"background job scheduler start failed: %s", strerror(rc));
    }
}

static NSDictionary *OPListApps(NSDictionary *request) {
    NSUInteger limit = OPLimitFromRequest(request, 200, 2000);
    NSString *taskId = [request[@"task_id"] isKindOfClass:[NSString class]] ? request[@"task_id"] : @"";
    NSString *query = [request[@"query"] isKindOfClass:[NSString class]]
            ? [request[@"query"] lowercaseString] : @"";
    NSArray<NSDictionary *> *allApps = OPInstalledApplications(query.length > 0 ? 0 : limit);
    NSMutableArray<NSDictionary *> *apps = [NSMutableArray array];
    for (NSDictionary *app in allApps) {
        if (query.length > 0) {
            NSString *bundleId = [app[@"bundle_id"] isKindOfClass:[NSString class]]
                    ? [app[@"bundle_id"] lowercaseString] : @"";
            NSString *displayName = [app[@"display_name"] isKindOfClass:[NSString class]]
                    ? [app[@"display_name"] lowercaseString] : @"";
            if (![bundleId containsString:query] && ![displayName containsString:query]) {
                continue;
            }
        }
        [apps addObject:app];
        if (limit > 0 && apps.count >= limit) {
            break;
        }
    }
    NSDictionary *result = @{
        @"status": @"ok",
        @"apps": apps,
        @"count": @(apps.count),
        @"query": query ?: @"",
        @"source": @"openphone.agentd"
    };
    OPRecordAudit(@"apps_listed", taskId, @"apps.read", @"allow_task_scoped",
            request, [NSString stringWithFormat:@"count:%lu", (unsigned long)apps.count]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"list_apps",
        @"arguments": request ?: @{},
        @"result": result
    });
    return result;
}

static NSDictionary *OPGetScreen(NSDictionary *request) {
    NSString *taskId = [request[@"task_id"] isKindOfClass:[NSString class]] ? request[@"task_id"] : @"";
    NSString *foregroundBundleId = OPForegroundBundleIdentifier();
    NSString *foregroundSource = foregroundBundleId.length > 0 ? @"springboardservices" : @"unavailable";
    NSArray<NSDictionary *> *runningApps = OPRunningApplications();
    NSMutableDictionary *displayInfo = [OPScreenDisplayInfo() mutableCopy];
    NSDictionary *lockInfo = OPScreenLockInfo();
    NSDictionary *springBoardState = OPSpringBoardPublishedState();
    NSDictionary *recentLayoutInfo = OPSpringBoardRecentLayoutInfo(20);
    NSDictionary *screenshotInfo = OPScreenScreenshotInfo(request ?: @{});
    BOOL isLocked = [lockInfo[@"locked"] boolValue];
    BOOL hasFreshSpringBoardState = [springBoardState[@"status"] isEqualToString:@"ok"];
    NSDictionary *springBoardUITree = [springBoardState[@"ui_tree"] isKindOfClass:[NSDictionary class]]
            ? springBoardState[@"ui_tree"] : @{};
    BOOL hasSpringBoardUITree = hasFreshSpringBoardState &&
            [springBoardUITree[@"status"] isEqualToString:@"ok"];
    NSString *springBoardForeground = [springBoardState[@"foreground_app"] isKindOfClass:[NSString class]]
            ? springBoardState[@"foreground_app"] : @"";
    BOOL foregroundDisagreesWithSpringBoardState = NO;
    if (hasFreshSpringBoardState && springBoardForeground.length > 0) {
        if (foregroundBundleId.length == 0 ||
                [foregroundBundleId isEqualToString:@"unknown"] ||
                [foregroundBundleId isEqualToString:springBoardForeground]) {
            foregroundBundleId = springBoardForeground;
            foregroundSource = @"springboard_state";
        } else {
            foregroundDisagreesWithSpringBoardState = YES;
        }
    }
    NSDictionary *springBoardDisplay = [springBoardState[@"display"] isKindOfClass:[NSDictionary class]]
            ? springBoardState[@"display"] : @{};
    if (hasFreshSpringBoardState && !displayInfo[@"orientation_name"] &&
            [springBoardDisplay[@"orientation_name"] isKindOfClass:[NSString class]]) {
        displayInfo[@"orientation_name"] = springBoardDisplay[@"orientation_name"];
        displayInfo[@"orientation"] = springBoardDisplay[@"orientation"] ?: @0;
        displayInfo[@"orientation_provider"] = @"OpenPhoneVolumeTrigger.SpringBoardState";
    }
    NSString *recentFirstBundleId = [recentLayoutInfo[@"first_bundle_id"] isKindOfClass:[NSString class]]
            ? recentLayoutInfo[@"first_bundle_id"] : @"";
    if (foregroundBundleId.length == 0 && !isLocked && recentFirstBundleId.length > 0) {
        foregroundBundleId = recentFirstBundleId;
        foregroundSource = @"springboard_recent_layout_inferred";
    }
    if (foregroundBundleId.length == 0) {
        foregroundBundleId = @"unknown";
    }
    NSDictionary *appUIState = OPAppUIPublishedState(foregroundBundleId);
    NSDictionary *appUITree = [appUIState[@"ui_tree"] isKindOfClass:[NSDictionary class]]
            ? appUIState[@"ui_tree"] : @{};
    BOOL hasAppUITree = !isLocked &&
            [appUIState[@"status"] isEqualToString:@"ok"] &&
            [appUITree[@"status"] isEqualToString:@"ok"];
    NSDictionary *selectedUITree = hasAppUITree ? appUITree : springBoardUITree;
    BOOL hasSelectedUITree = hasAppUITree || hasSpringBoardUITree;
    NSArray *visibleText = hasSelectedUITree &&
            [selectedUITree[@"visible_text"] isKindOfClass:[NSArray class]]
            ? selectedUITree[@"visible_text"] : @[];
    NSArray *interactiveElements = hasSelectedUITree &&
            [selectedUITree[@"interactive_elements"] isKindOfClass:[NSArray class]]
            ? selectedUITree[@"interactive_elements"] : @[];
    NSArray *windows = hasSelectedUITree &&
            [selectedUITree[@"windows"] isKindOfClass:[NSArray class]]
            ? selectedUITree[@"windows"] : @[];
    NSString *uiTreeSource = hasAppUITree ? @"app_process" :
            (hasSpringBoardUITree ? @"springboard_state" : @"unavailable");
    BOOL screenshotOK = [screenshotInfo[@"status"] isEqualToString:@"ok"];
    NSMutableArray<NSString *> *riskFlags = [NSMutableArray array];
    if (hasAppUITree) {
        [riskFlags addObject:@"ui_tree_app_process"];
        if (interactiveElements.count == 0) {
            [riskFlags addObject:@"interactive_elements_empty"];
        }
        if (visibleText.count == 0) {
            [riskFlags addObject:@"visible_text_empty"];
        }
    } else if (hasSpringBoardUITree) {
        [riskFlags addObject:@"ui_tree_springboard_only"];
        if (interactiveElements.count == 0) {
            [riskFlags addObject:@"interactive_elements_empty"];
        }
        if (visibleText.count == 0) {
            [riskFlags addObject:@"visible_text_empty"];
        }
    } else {
        [riskFlags addObject:@"ui_tree_unavailable"];
    }
    if (!isLocked && OPBundleIdentifierLooksValid(foregroundBundleId) && !hasAppUITree) {
        NSString *appUIStatus = [appUIState[@"status"] isKindOfClass:[NSString class]]
                ? appUIState[@"status"] : @"unavailable";
        NSString *appUIReason = [appUIState[@"reason"] isKindOfClass:[NSString class]]
                ? appUIState[@"reason"] : @"";
        if ([appUIStatus isEqualToString:@"stale"]) {
            [riskFlags addObject:@"app_ui_state_stale"];
        } else if (appUIReason.length > 0) {
            [riskFlags addObject:[NSString stringWithFormat:@"app_ui_%@", appUIReason]];
        } else {
            [riskFlags addObject:@"app_ui_unavailable"];
        }
    }
    if ([foregroundSource isEqualToString:@"unavailable"]) {
        [riskFlags addObject:@"foreground_app_unavailable"];
    } else if ([foregroundSource isEqualToString:@"springboard_recent_layout_inferred"]) {
        [riskFlags addObject:@"foreground_app_inferred"];
    }
    if (foregroundDisagreesWithSpringBoardState) {
        [riskFlags addObject:@"foreground_app_springboard_state_disagreement"];
    }
    if ([springBoardState[@"status"] isEqualToString:@"stale"]) {
        [riskFlags addObject:@"springboard_state_stale"];
    } else if ([springBoardState[@"status"] isEqualToString:@"unavailable"]) {
        [riskFlags addObject:@"springboard_state_unavailable"];
    }
    if (!screenshotOK) {
        [riskFlags addObject:@"screen_metadata_only"];
        NSString *screenshotStatus = [screenshotInfo[@"status"] isKindOfClass:[NSString class]]
                ? screenshotInfo[@"status"] : @"unknown";
        NSString *screenshotReason = [screenshotInfo[@"reason"] isKindOfClass:[NSString class]]
                ? screenshotInfo[@"reason"] : @"";
        if ([screenshotReason isEqualToString:@"helper_not_installed"]) {
            [riskFlags addObject:@"screenshot_provider_missing"];
        } else if ([screenshotStatus isEqualToString:@"not_requested"]) {
            [riskFlags addObject:@"screenshot_not_requested"];
        } else {
            [riskFlags addObject:@"screenshot_unavailable"];
        }
    }
    if (isLocked) {
        [riskFlags insertObject:@"device_locked" atIndex:0];
    }
    NSString *captureMode = screenshotOK ? @"screenshot_file" : @"metadata_only";
    NSString *source = screenshotOK ? @"openphone.agentd.screen.screenshot"
            : @"openphone.agentd.screen.metadata";
    NSString *state = nil;
    if (isLocked) {
        state = screenshotOK ? @"screen.locked.screenshot" : @"screen.locked.metadata_only";
    } else if (screenshotOK) {
        state = @"screen.observed.screenshot";
    } else {
        state = [foregroundBundleId isEqualToString:@"unknown"]
                ? @"screen.metadata_only" : @"screen.observed.metadata_only";
    }
    NSDictionary *result = @{
        @"status": @"ok",
        @"state": state,
        @"task_id": taskId,
        @"timestamp_ms": @(OPNowMs()),
        @"capture_mode": captureMode,
        @"source": source,
        @"screenshot": screenshotInfo,
        @"context": @{
            @"foreground_app": foregroundBundleId,
            @"foreground_package": foregroundBundleId,
            @"foreground_source": foregroundSource,
            @"springboard_state": springBoardState,
            @"app_ui_state": appUIState,
            @"last_known_foreground_candidate": recentFirstBundleId ?: @"",
            @"recent_apps": recentLayoutInfo[@"apps"] ?: @[],
            @"recent_apps_source": recentLayoutInfo[@"provider"] ?: @"SpringBoard.RecentAppLayouts",
            @"recent_apps_status": recentLayoutInfo[@"status"] ?: @"unknown",
            @"running_apps": runningApps,
            @"display": displayInfo,
            @"lock": lockInfo,
            @"screenshot": screenshotInfo,
            @"ui_tree": selectedUITree.count > 0 ? selectedUITree : @{
                @"status": @"unavailable",
                @"provider": @"SpringBoard.UIKitAccessibility",
                @"reason": @"screen_missing_ui_tree"
            },
            @"ui_tree_source": uiTreeSource,
            @"visible_text": visibleText,
            @"interactive_elements": interactiveElements,
            @"windows": windows,
            @"notifications": @[],
            @"risk_flags": riskFlags,
            @"source": source
        },
        @"request": request ?: @{}
    };
    NSString *auditDetail = screenshotOK ? @"screenshot_ok" : @"metadata_only";
    if (!screenshotOK) {
        NSString *status = [screenshotInfo[@"status"] isKindOfClass:[NSString class]]
                ? screenshotInfo[@"status"] : @"unknown";
        NSString *reason = [screenshotInfo[@"reason"] isKindOfClass:[NSString class]]
                ? screenshotInfo[@"reason"] : @"";
        auditDetail = reason.length > 0
                ? [NSString stringWithFormat:@"screenshot_%@:%@", status, reason]
                : [NSString stringWithFormat:@"screenshot_%@", status];
    }
    OPRecordAudit(@"screen_capture", taskId, @"screen.read.visible", @"allow_task_scoped",
            request, auditDetail);
    NSDictionary *trajectoryPayload = OPBoolFromRequest(request, @"compact_trajectory", NO)
            ? OPModelScreenTraceSummary(result) : result;
    OPRecordTrajectory(taskId, @"screen_observed", trajectoryPayload);
    return result;
}

static BOOL OPDoubleForKey(NSDictionary *dictionary, NSString *key, double *outValue) {
    id value = dictionary[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        *outValue = [value doubleValue];
        return YES;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *string = value;
        if (string.length == 0) {
            return NO;
        }
        *outValue = [string doubleValue];
        return YES;
    }
    return NO;
}

static BOOL OPCenterFromBoundsObject(id boundsObject, double *outX, double *outY) {
    if ([boundsObject isKindOfClass:[NSDictionary class]]) {
        NSDictionary *bounds = boundsObject;
        double x = 0.0;
        double y = 0.0;
        double width = 0.0;
        double height = 0.0;
        if (OPDoubleForKey(bounds, @"x", &x) &&
                OPDoubleForKey(bounds, @"y", &y) &&
                OPDoubleForKey(bounds, @"width", &width) &&
                OPDoubleForKey(bounds, @"height", &height)) {
            *outX = x + (width / 2.0);
            *outY = y + (height / 2.0);
            return YES;
        }
        if (OPDoubleForKey(bounds, @"left", &x) &&
                OPDoubleForKey(bounds, @"top", &y) &&
                OPDoubleForKey(bounds, @"right", &width) &&
                OPDoubleForKey(bounds, @"bottom", &height)) {
            *outX = x + ((width - x) / 2.0);
            *outY = y + ((height - y) / 2.0);
            return YES;
        }
    }
    if ([boundsObject isKindOfClass:[NSArray class]]) {
        NSArray *bounds = boundsObject;
        if (bounds.count >= 4) {
            double x = [bounds[0] doubleValue];
            double y = [bounds[1] doubleValue];
            double width = [bounds[2] doubleValue];
            double height = [bounds[3] doubleValue];
            *outX = x + (width / 2.0);
            *outY = y + (height / 2.0);
            return YES;
        }
    }
    return NO;
}

static NSDictionary *OPInteractiveElementFromScreen(NSDictionary *screen, NSString *elementId) {
    if (![elementId isKindOfClass:[NSString class]] || elementId.length == 0) {
        return nil;
    }
    NSDictionary *context = [screen[@"context"] isKindOfClass:[NSDictionary class]]
            ? screen[@"context"] : @{};
    NSMutableArray *candidateArrays = [NSMutableArray array];
    if ([context[@"interactive_elements"] isKindOfClass:[NSArray class]]) {
        [candidateArrays addObject:context[@"interactive_elements"]];
    }
    NSDictionary *uiTree = [context[@"ui_tree"] isKindOfClass:[NSDictionary class]]
            ? context[@"ui_tree"] : @{};
    if ([uiTree[@"interactive_elements"] isKindOfClass:[NSArray class]]) {
        [candidateArrays addObject:uiTree[@"interactive_elements"]];
    }

    for (NSArray *elements in candidateArrays) {
        for (id object in elements) {
            if (![object isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSDictionary *element = object;
            NSString *identifier = [element[@"id"] isKindOfClass:[NSString class]]
                    ? element[@"id"] : @"";
            NSString *viewIdentifier = [element[@"view_id"] isKindOfClass:[NSString class]]
                    ? element[@"view_id"] : @"";
            if ([identifier isEqualToString:elementId] ||
                    (viewIdentifier.length > 0 && [viewIdentifier isEqualToString:elementId])) {
                return element;
            }
        }
    }
    return nil;
}

static NSDictionary *OPResolvedElementSummary(NSDictionary *element) {
    if (![element isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"id", @"view_id", @"kind", @"label", @"bounds", @"enabled",
            @"focused", @"sensitive", @"risk_hint", @"scope", @"input_scope",
            @"source_bundle_id", @"dom_index", @"tag", @"input_type"]) {
        id value = element[key];
        if (value) {
            summary[key] = value;
        }
    }
    return summary;
}

static NSString *OPInputActionType(NSDictionary *result, NSString *fallback) {
    NSString *actionType = [result[@"action_type"] isKindOfClass:[NSString class]]
            ? result[@"action_type"] : @"";
    return actionType.length > 0 ? actionType : (fallback ?: @"");
}

static NSString *OPInputProviderScope(NSDictionary *result, NSString *provider) {
    NSString *scope = [result[@"scope"] isKindOfClass:[NSString class]]
            ? result[@"scope"] : @"";
    if (scope.length > 0) {
        return scope;
    }
    NSDictionary *bridge = [result[@"bridge"] isKindOfClass:[NSDictionary class]]
            ? result[@"bridge"] : @{};
    scope = [bridge[@"scope"] isKindOfClass:[NSString class]]
            ? bridge[@"scope"] : @"";
    if (scope.length > 0) {
        return scope;
    }
    if ([provider containsString:@"OpenPhoneVolumeTrigger.SpringBoardInput"]) {
        return @"springboard_windows";
    }
    if ([provider containsString:@"OpenPhoneAppIntrospector.AppInput"] ||
            [provider containsString:@"OpenPhoneAppIntrospector.WebContentInput"]) {
        if ([provider containsString:@"OpenPhoneAppIntrospector.WebContentInput"]) {
            return @"web_content_process";
        }
        return @"app_process";
    }
    if ([provider containsString:@"IOHIDEventSystemClient"]) {
        return @"daemon_hid";
    }
    if ([provider containsString:@"SpringBoardServices"] ||
            [provider containsString:@"GraphicsServices"]) {
        return @"springboard_services";
    }
    return @"unknown";
}

static BOOL OPInputPasscodeVisible(NSDictionary *result) {
    if ([result[@"passcode_visible"] respondsToSelector:@selector(boolValue)] &&
            [result[@"passcode_visible"] boolValue]) {
        return YES;
    }
    NSDictionary *fallback = [result[@"lockscreen_fallback"] isKindOfClass:[NSDictionary class]]
            ? result[@"lockscreen_fallback"] : @{};
    NSArray *attempts = [fallback[@"attempts"] isKindOfClass:[NSArray class]]
            ? fallback[@"attempts"] : @[];
    for (id object in attempts) {
        if (![object isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *attempt = object;
        if ([attempt[@"passcode_visible"] respondsToSelector:@selector(boolValue)] &&
                [attempt[@"passcode_visible"] boolValue]) {
            return YES;
        }
    }
    return NO;
}

static BOOL OPInputUnlockVerified(NSDictionary *result) {
    NSDictionary *unlock = [result[@"lockscreen_unlock"] isKindOfClass:[NSDictionary class]]
            ? result[@"lockscreen_unlock"] : @{};
    if (![unlock[@"status"] isEqualToString:@"ok"]) {
        return NO;
    }
    if ([unlock[@"locked_after_attempt"] respondsToSelector:@selector(boolValue)]) {
        return ![unlock[@"locked_after_attempt"] boolValue];
    }
    return NO;
}

static NSDictionary *OPInputAttemptVerification(NSDictionary *result, NSString *actionType) {
    NSString *provider = [result[@"provider"] isKindOfClass:[NSString class]]
            ? result[@"provider"] : @"";
    NSString *status = [result[@"status"] isKindOfClass:[NSString class]]
            ? result[@"status"] : @"";
    if (status.length == 0 && [result[@"ok"] respondsToSelector:@selector(boolValue)]) {
        status = [result[@"ok"] boolValue] ? @"ok" : @"unavailable";
    }
    NSString *reason = [result[@"reason"] isKindOfClass:[NSString class]]
            ? result[@"reason"] : @"";
    if (![status isEqualToString:@"ok"]) {
        return @{
            @"status": @"failed",
            @"source": @"provider_status",
            @"reason": reason.length > 0 ? reason : (status.length > 0 ? status : @"not_attempted")
        };
    }
    if ([actionType isEqualToString:@"show_passcode"] && OPInputPasscodeVisible(result)) {
        return @{
            @"status": @"verified",
            @"source": @"springboard_passcode_visible",
            @"reason": @"passcode_visible_after_invocation"
        };
    }
    if ([actionType isEqualToString:@"unlock_with_passcode"] && OPInputUnlockVerified(result)) {
        return @{
            @"status": @"verified",
            @"source": @"springboard_lock_state",
            @"reason": @"unlocked_after_invocation"
        };
    }
    if ([provider containsString:@"IOHIDEventSystemClient"]) {
        return @{
            @"status": @"unverified",
            @"source": @"iohid_dispatch",
            @"reason": @"dispatch_only_no_visible_verification"
        };
    }
    if ([provider containsString:@"OpenPhoneAppIntrospector.AppInput"] ||
            [provider containsString:@"OpenPhoneAppIntrospector.WebContentInput"]) {
        NSString *activationMethod = [result[@"activation_method"] isKindOfClass:[NSString class]]
                ? result[@"activation_method"] : @"";
        long long textLength = [result[@"text_length"] respondsToSelector:@selector(longLongValue)]
                ? [result[@"text_length"] longLongValue] : 0;
        long long beforeTextLength = [result[@"before_text_length"] respondsToSelector:@selector(longLongValue)]
                ? [result[@"before_text_length"] longLongValue] : -1;
        long long afterTextLength = [result[@"after_text_length"] respondsToSelector:@selector(longLongValue)]
                ? [result[@"after_text_length"] longLongValue] : -1;
        if ([actionType isEqualToString:@"type_text"] &&
                [activationMethod isEqualToString:@"text_input_insert"] &&
                textLength > 0 &&
                beforeTextLength >= 0 &&
                afterTextLength > beforeTextLength) {
            return @{
                @"status": @"verified",
                @"source": @"app_process_text_state",
                @"reason": @"text_length_changed_after_insert"
            };
        }
        if ([actionType isEqualToString:@"type_text"] &&
                [activationMethod isEqualToString:@"webkit_dom_text_input"] &&
                textLength > 0 &&
                beforeTextLength >= 0 &&
                afterTextLength > beforeTextLength) {
            return @{
                @"status": @"verified",
                @"source": @"web_content_dom_state",
                @"reason": @"dom_text_length_changed_after_insert"
            };
        }
        return @{
            @"status": @"unverified",
            @"source": @"app_process_activation",
            @"reason": @"app_process_activation_without_visible_verification"
        };
    }
    if ([result[@"activation_method"] isKindOfClass:[NSString class]]) {
        return @{
            @"status": @"unverified",
            @"source": @"springboard_activation",
            @"reason": @"activation_without_visible_verification"
        };
    }
    return @{
        @"status": @"unverified",
        @"source": @"provider_dispatch",
        @"reason": @"no_visible_verification"
    };
}

static NSDictionary *OPInputAttemptSummaryForAction(NSDictionary *result, NSString *fallbackActionType) {
    if (![result isKindOfClass:[NSDictionary class]]) {
        return @{
            @"provider": @"none",
            @"scope": @"none",
            @"action_type": fallbackActionType ?: @"",
            @"status": @"not_attempted",
            @"verification": @{
                @"status": @"failed",
                @"source": @"none",
                @"reason": @"no_provider_result"
            }
        };
    }
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    NSString *status = [result[@"status"] isKindOfClass:[NSString class]]
            ? result[@"status"] : nil;
    if (!status && [result[@"ok"] respondsToSelector:@selector(boolValue)]) {
        status = [result[@"ok"] boolValue] ? @"ok" : @"unavailable";
    }
    NSString *provider = [result[@"provider"] isKindOfClass:[NSString class]]
            ? result[@"provider"] : @"unknown";
    NSString *actionType = OPInputActionType(result, fallbackActionType);
    summary[@"provider"] = provider;
    summary[@"scope"] = OPInputProviderScope(result, provider);
    summary[@"action_type"] = actionType ?: @"";
    if (status.length > 0) {
        summary[@"status"] = status;
    }
    for (NSString *key in @[@"reason", @"request_id", @"kind", @"strategy",
            @"activation_method", @"activated_class", @"target_class", @"preferred_input_scope",
            @"dom_index", @"tag", @"input_type", @"attempts",
            @"diagnostics", @"text_length", @"before_text_length", @"after_text_length"]) {
        id value = result[key];
        if (value) {
            summary[key] = value;
        }
    }
    NSMutableDictionary *dispatchMetadata = [NSMutableDictionary dictionary];
    for (NSString *key in @[
            @"x", @"y", @"start_x", @"start_y", @"end_x", @"end_y",
            @"duration_ms", @"timeout_ms", @"usage", @"usage_page"]) {
        id value = result[key];
        if (value) {
            dispatchMetadata[key] = value;
        }
    }
    if (dispatchMetadata.count > 0) {
        summary[@"dispatch_metadata"] = dispatchMetadata;
    } else if ([result[@"dispatch_metadata"] isKindOfClass:[NSDictionary class]]) {
        summary[@"dispatch_metadata"] = result[@"dispatch_metadata"];
    }
    summary[@"verification"] = OPInputAttemptVerification(result, actionType);
    return summary;
}

static NSArray<NSDictionary *> *OPInputProviderAttemptsForResult(NSDictionary *result,
        NSString *actionType) {
    if (![result isKindOfClass:[NSDictionary class]]) {
        return @[OPInputAttemptSummaryForAction(nil, actionType)];
    }
    NSArray *existing = [result[@"provider_attempts"] isKindOfClass:[NSArray class]]
            ? result[@"provider_attempts"] : nil;
    if (existing.count > 0) {
        NSMutableArray<NSDictionary *> *attempts = [NSMutableArray array];
        for (id object in existing) {
            if ([object isKindOfClass:[NSDictionary class]]) {
                [attempts addObject:OPInputAttemptSummaryForAction(object, actionType)];
            }
        }
        if (attempts.count > 0) {
            return attempts;
        }
    }
    NSDictionary *providerResult = [result[@"provider_result"] isKindOfClass:[NSDictionary class]]
            ? result[@"provider_result"] : nil;
    if (providerResult) {
        NSDictionary *wake = [providerResult[@"wake"] isKindOfClass:[NSDictionary class]]
                ? providerResult[@"wake"] : nil;
        NSDictionary *home = [providerResult[@"home"] isKindOfClass:[NSDictionary class]]
                ? providerResult[@"home"] : nil;
        if (wake || home) {
            NSMutableArray<NSDictionary *> *attempts = [NSMutableArray array];
            if (wake) {
                [attempts addObject:OPInputAttemptSummaryForAction(wake, actionType ?: @"wake_and_home")];
            }
            if (home) {
                [attempts addObject:OPInputAttemptSummaryForAction(home, actionType ?: @"wake_and_home")];
            }
            return attempts;
        }
        return @[OPInputAttemptSummaryForAction(providerResult, actionType)];
    }
    return @[OPInputAttemptSummaryForAction(nil, actionType)];
}

static NSDictionary *OPInputResultVerification(NSArray<NSDictionary *> *attempts,
        NSDictionary *result) {
    for (NSDictionary *attempt in attempts) {
        NSDictionary *verification = [attempt[@"verification"] isKindOfClass:[NSDictionary class]]
                ? attempt[@"verification"] : @{};
        if ([verification[@"status"] isEqualToString:@"verified"]) {
            return @{
                @"status": @"verified",
                @"source": verification[@"source"] ?: @"provider_attempt",
                @"reason": verification[@"reason"] ?: @"visible_state_verified"
            };
        }
    }
    NSString *state = [result[@"state"] isKindOfClass:[NSString class]]
            ? result[@"state"] : @"";
    if ([state isEqualToString:@"action.executed"]) {
        return @{
            @"status": @"unverified",
            @"source": @"provider_attempts",
            @"reason": @"dispatch_without_visible_state_change"
        };
    }
    return @{
        @"status": @"failed",
        @"source": @"provider_attempts",
        @"reason": result[@"detail"] ?: @"input_failed"
    };
}

static NSDictionary *OPFinalizeInputResult(NSDictionary *result, NSString *actionType) {
    if (![result isKindOfClass:[NSDictionary class]]) {
        return result ?: @{};
    }
    NSMutableDictionary *finalResult = [result mutableCopy];
    NSArray<NSDictionary *> *attempts = OPInputProviderAttemptsForResult(finalResult, actionType);
    NSDictionary *verification = OPInputResultVerification(attempts, finalResult);
    finalResult[@"provider_attempts"] = attempts ?: @[];
    finalResult[@"verification"] = verification;
    NSString *state = [finalResult[@"state"] isKindOfClass:[NSString class]]
            ? finalResult[@"state"] : @"";
    if ([verification[@"status"] isEqualToString:@"verified"]) {
        finalResult[@"user_facing_status"] = @"verified";
    } else if ([state isEqualToString:@"action.executed"]) {
        finalResult[@"user_facing_status"] = @"dispatch_unverified";
    } else {
        finalResult[@"user_facing_status"] = @"failed";
    }
    return finalResult;
}

static BOOL OPPointFromAction(NSDictionary *action, double *outX, double *outY) {
    if (OPDoubleForKey(action, @"x", outX) && OPDoubleForKey(action, @"y", outY)) {
        return YES;
    }
    id centerObject = action[@"center"];
    if ([centerObject isKindOfClass:[NSDictionary class]]) {
        NSDictionary *center = centerObject;
        if (OPDoubleForKey(center, @"x", outX) && OPDoubleForKey(center, @"y", outY)) {
            return YES;
        }
    }
    if (OPCenterFromBoundsObject(action[@"bounds"], outX, outY)) {
        return YES;
    }
    id elementObject = action[@"element"];
    if ([elementObject isKindOfClass:[NSDictionary class]]) {
        NSDictionary *element = elementObject;
        if (OPDoubleForKey(element, @"x", outX) && OPDoubleForKey(element, @"y", outY)) {
            return YES;
        }
        if (OPCenterFromBoundsObject(element[@"bounds"], outX, outY)) {
            return YES;
        }
    }
    return NO;
}

static NSDictionary *OPActionForRecording(NSDictionary *action) {
    if (![action isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSString *type = [action[@"type"] isKindOfClass:[NSString class]] ? action[@"type"] : @"";
    NSMutableDictionary *recorded = [NSMutableDictionary dictionary];
    for (id key in action) {
        NSString *keyString = [key isKindOfClass:[NSString class]]
                ? key : [key description];
        if (OPSensitiveKey(keyString)) {
            recorded[OPRedactedKeyName(keyString)] = @"<redacted>";
        } else {
            recorded[keyString] = OPRedactedObject(action[key], 1);
        }
    }
    if ([type isEqualToString:@"type_text"]) {
        NSString *text = [action[@"text"] isKindOfClass:[NSString class]] ? action[@"text"] : @"";
        recorded[@"text"] = [NSString stringWithFormat:@"<redacted:text:%lu>",
                             (unsigned long)text.length];
    }
    return recorded;
}

static NSDictionary *OPExecuteAction(NSDictionary *request) {
    NSDictionary *action = [request[@"action"] isKindOfClass:[NSDictionary class]]
            ? request[@"action"] : request;
    NSString *type = [action[@"type"] isKindOfClass:[NSString class]] ? action[@"type"] : @"";
    NSString *taskId = [request[@"task_id"] isKindOfClass:[NSString class]] ? request[@"task_id"] : @"";
    NSDictionary *recordedRequest = request;
    NSDictionary *result = nil;
    NSString *capability = @"unknown";
    if ([type isEqualToString:@"wait"]) {
        capability = @"tasks.observe";
        NSNumber *durationNumber = [action[@"duration_ms"] isKindOfClass:[NSNumber class]]
                ? action[@"duration_ms"] : @1000;
        long durationMs = MAX(0, MIN(durationNumber.longValue, 30000));
        usleep((useconds_t)(durationMs * 1000));
        result = @{
            @"state": @"action.executed",
            @"task_id": taskId,
            @"capability": capability,
            @"detail": [NSString stringWithFormat:@"wait:%ldms", durationMs],
            @"source": @"openphone.agentd"
        };
    } else if ([type isEqualToString:@"open_url"]) {
        capability = @"network.use";
        NSString *url = [action[@"url"] isKindOfClass:[NSString class]] ? action[@"url"] : @"";
        if (url.length == 0) {
            result = @{
                @"state": @"action.denied.missing_argument",
                @"task_id": taskId,
                @"capability": capability,
                @"detail": @"missing_url",
                @"source": @"openphone.agentd"
            };
        } else {
            NSDictionary *spawn = OPUiOpen(@[@"--url", url]);
            result = @{
                @"state": [spawn[@"ok"] boolValue] ? @"action.executed" : @"action.denied.input_failed",
                @"task_id": taskId,
                @"capability": capability,
                @"detail": @"open_url",
                @"provider_result": spawn,
                @"source": @"openphone.agentd"
            };
        }
    } else if ([type isEqualToString:@"open_app"]) {
        capability = @"apps.launch";
        NSDictionary *target = [action[@"target"] isKindOfClass:[NSDictionary class]]
                ? action[@"target"] : @{};
        NSString *bundleId = [action[@"bundle_id"] isKindOfClass:[NSString class]]
                ? action[@"bundle_id"] : nil;
        if (bundleId.length == 0 && [target[@"package"] isKindOfClass:[NSString class]]) {
            bundleId = target[@"package"];
        }
        if (bundleId.length == 0 && [target[@"bundle_id"] isKindOfClass:[NSString class]]) {
            bundleId = target[@"bundle_id"];
        }
        if (bundleId.length == 0) {
            result = @{
                @"state": @"action.denied.missing_argument",
                @"task_id": taskId,
                @"capability": capability,
                @"detail": @"missing_bundle_id",
                @"source": @"openphone.agentd"
            };
        } else {
            NSDictionary *spawn = OPUiOpen(@[@"--bundleid", bundleId]);
            result = @{
                @"state": [spawn[@"ok"] boolValue] ? @"action.executed" : @"action.denied.input_failed",
                @"task_id": taskId,
                @"capability": capability,
                @"detail": [NSString stringWithFormat:@"open_app:%@", bundleId],
                @"provider_result": spawn,
                @"source": @"openphone.agentd"
            };
        }
    } else if ([type isEqualToString:@"home"]) {
        capability = @"input.perform";
        NSDictionary *home = OPPressHome();
        result = @{
            @"state": [home[@"ok"] boolValue] ? @"action.executed" : @"action.denied.input_failed",
            @"task_id": taskId,
            @"capability": capability,
            @"detail": @"home",
            @"provider_result": home,
            @"source": @"openphone.agentd"
        };
    } else if ([type isEqualToString:@"wake_and_home"]) {
        capability = @"input.perform";
        NSDictionary *wake = OPWakeScreen();
        NSDictionary *home = OPPressHome();
        BOOL ok = [wake[@"ok"] boolValue] && [home[@"ok"] boolValue];
        result = @{
            @"state": ok ? @"action.executed" : @"action.denied.input_failed",
            @"task_id": taskId,
            @"capability": capability,
            @"detail": @"wake_and_home",
            @"provider_result": @{
                @"wake": wake,
                @"home": home
            },
            @"source": @"openphone.agentd"
        };
    } else if ([type isEqualToString:@"show_passcode"]) {
        capability = @"input.perform";
        NSMutableDictionary *bridgeAction = [action mutableCopy] ?: [NSMutableDictionary dictionary];
        bridgeAction[@"type"] = @"show_passcode";
        NSDictionary *springBoardInput = OPSpringBoardInputInfo(bridgeAction);
        BOOL springBoardOK = [springBoardInput[@"status"] isEqualToString:@"ok"];
        result = @{
            @"state": springBoardOK ? @"action.executed" : @"action.denied.input_failed",
            @"task_id": taskId,
            @"capability": capability,
            @"detail": @"show_passcode",
            @"provider_result": springBoardInput ?: @{},
            @"provider_attempts": @[OPInputAttemptSummaryForAction(springBoardInput, type)],
            @"source": @"openphone.agentd"
        };
    } else if ([type isEqualToString:@"unlock_with_passcode"]) {
        capability = @"input.perform";
        NSString *passcode = [action[@"passcode"] isKindOfClass:[NSString class]]
                ? action[@"passcode"] : @"";
        if (passcode.length == 0) {
            result = @{
                @"state": @"action.denied.missing_argument",
                @"task_id": taskId,
                @"capability": capability,
                @"detail": @"missing_passcode",
                @"source": @"openphone.agentd"
            };
        } else {
            NSMutableDictionary *bridgeAction = [action mutableCopy] ?: [NSMutableDictionary dictionary];
            bridgeAction[@"type"] = @"unlock_with_passcode";
            if (![bridgeAction[@"input_timeout_ms"] respondsToSelector:@selector(longLongValue)]) {
                bridgeAction[@"input_timeout_ms"] = @3000;
            }
            NSDictionary *springBoardInput = OPSpringBoardInputInfo(bridgeAction);
            BOOL springBoardOK = [springBoardInput[@"status"] isEqualToString:@"ok"];
            result = @{
                @"state": springBoardOK ? @"action.executed" : @"action.denied.input_failed",
                @"task_id": taskId,
                @"capability": capability,
                @"detail": @"unlock_with_passcode",
                @"provider_result": springBoardInput ?: @{},
                @"provider_attempts": @[OPInputAttemptSummaryForAction(springBoardInput, type)],
                @"source": @"openphone.agentd"
            };
        }
    } else if ([type isEqualToString:@"tap"] || [type isEqualToString:@"tap_element"]) {
        capability = @"input.perform";
        double x = 0.0;
        double y = 0.0;
        BOOL hasPoint = OPPointFromAction(action, &x, &y);
        NSDictionary *resolvedElement = nil;
        NSDictionary *resolutionScreen = nil;
        NSDictionary *appInput = nil;
        NSString *elementId = [action[@"element_id"] isKindOfClass:[NSString class]]
                ? action[@"element_id"] : @"";
        NSString *coordinateSource = hasPoint ? @"action_coordinates" : @"";
        if (!hasPoint && [type isEqualToString:@"tap_element"] && elementId.length > 0) {
            resolutionScreen = OPGetScreen(@{
                @"command": @"get_screen",
                @"task_id": taskId ?: @"",
                @"include_screenshot": @NO,
                @"compact_trajectory": @YES,
                @"reason": @"tap_element_resolve"
            });
            resolvedElement = OPInteractiveElementFromScreen(resolutionScreen, elementId);
            if (resolvedElement) {
                id enabledValue = resolvedElement[@"enabled"];
                BOOL enabled = ![enabledValue respondsToSelector:@selector(boolValue)] ||
                        [enabledValue boolValue];
                if (!enabled) {
                    result = @{
                        @"state": @"action.denied.element_disabled",
                        @"task_id": taskId,
                        @"capability": capability,
                        @"detail": [NSString stringWithFormat:@"element_disabled:%@", elementId],
                        @"target": OPResolvedElementSummary(resolvedElement),
                        @"source": @"openphone.agentd"
                    };
                } else if (OPCenterFromBoundsObject(resolvedElement[@"bounds"], &x, &y)) {
                    hasPoint = YES;
                    coordinateSource = @"ui_tree.bounds_center";
                } else {
                    result = @{
                        @"state": @"action.denied.missing_coordinates",
                        @"task_id": taskId,
                        @"capability": capability,
                        @"detail": [NSString stringWithFormat:@"element_missing_bounds:%@", elementId],
                        @"target": OPResolvedElementSummary(resolvedElement),
                        @"source": @"openphone.agentd"
                    };
                }
            } else {
                hasPoint = NO;
            }
        }
        if (!result && resolvedElement) {
            NSString *scope = [resolvedElement[@"scope"] isKindOfClass:[NSString class]]
                    ? resolvedElement[@"scope"] : @"";
            NSString *inputScope = [resolvedElement[@"input_scope"] isKindOfClass:[NSString class]]
                    ? resolvedElement[@"input_scope"] : scope;
            NSString *riskHint = [resolvedElement[@"risk_hint"] isKindOfClass:[NSString class]]
                    ? resolvedElement[@"risk_hint"] : @"";
            if ([scope isEqualToString:@"app_process"] ||
                    [scope isEqualToString:@"web_content_process"] ||
                    [riskHint isEqualToString:@"app_process"] ||
                    [riskHint isEqualToString:@"web_content_process"]) {
                NSString *bundleId = [resolvedElement[@"source_bundle_id"] isKindOfClass:[NSString class]]
                        ? resolvedElement[@"source_bundle_id"] : @"";
                if (bundleId.length == 0) {
                    NSDictionary *context = [resolutionScreen[@"context"] isKindOfClass:[NSDictionary class]]
                            ? resolutionScreen[@"context"] : @{};
                    bundleId = [context[@"foreground_app"] isKindOfClass:[NSString class]]
                            ? context[@"foreground_app"] : @"";
                }
                NSMutableDictionary *appAction = [action mutableCopy] ?: [NSMutableDictionary dictionary];
                appAction[@"type"] = type;
                if (elementId.length > 0) {
                    appAction[@"element_id"] = elementId;
                }
                appAction[@"x"] = @(x);
                appAction[@"y"] = @(y);
                appAction[@"duration_ms"] = [type isEqualToString:@"long_press"] ? @700 : @80;
                appAction[@"target"] = OPResolvedElementSummary(resolvedElement);
                if (inputScope.length > 0) {
                    appAction[@"preferred_input_scope"] = inputScope;
                }
                appInput = OPAppInputInfo(appAction, bundleId);
                BOOL appInputOK = [appInput[@"status"] isEqualToString:@"ok"];
                if (appInputOK) {
                    NSMutableDictionary *mutableResult = [@{
                        @"state": @"action.executed",
                        @"task_id": taskId,
                        @"capability": capability,
                        @"detail": [NSString stringWithFormat:@"%@:%@:app_process", type, elementId],
                        @"provider_result": appInput ?: @{},
                        @"provider_attempts": @[OPInputAttemptSummaryForAction(appInput, type)],
                        @"source": @"openphone.agentd"
                    } mutableCopy];
                    if (coordinateSource.length > 0) {
                        mutableResult[@"coordinate_source"] = coordinateSource;
                    }
                    mutableResult[@"target"] = OPResolvedElementSummary(resolvedElement);
                    result = mutableResult;
                }
            }
        }
        if (!hasPoint && !result && [type isEqualToString:@"tap_element"] && elementId.length > 0) {
            NSMutableDictionary *bridgeAction = [action mutableCopy] ?: [NSMutableDictionary dictionary];
            bridgeAction[@"type"] = @"tap_element";
            bridgeAction[@"element_id"] = elementId;
            NSDictionary *springBoardInput = OPSpringBoardInputInfo(bridgeAction);
            BOOL springBoardOK = [springBoardInput[@"status"] isEqualToString:@"ok"];
            result = @{
                @"state": springBoardOK ? @"action.executed" : @"action.denied.element_not_found",
                @"task_id": taskId,
                @"capability": capability,
                @"detail": springBoardOK
                        ? [NSString stringWithFormat:@"tap_element:%@:springboard_bridge", elementId]
                        : [NSString stringWithFormat:@"element_not_found:%@", elementId],
                @"provider_result": springBoardInput ?: @{},
                @"provider_attempts": @[OPInputAttemptSummaryForAction(springBoardInput, type)],
                @"source": @"openphone.agentd"
            };
        }
        if (!hasPoint && !result) {
            NSString *detail = [type isEqualToString:@"tap_element"]
                    ? @"missing_element_coordinates" : @"missing_coordinates";
            result = @{
                @"state": @"action.denied.missing_coordinates",
                @"task_id": taskId,
                @"capability": capability,
                @"detail": detail,
                @"source": @"openphone.agentd"
            };
        } else if (!result) {
            NSMutableDictionary *bridgeAction = [action mutableCopy] ?: [NSMutableDictionary dictionary];
            bridgeAction[@"type"] = type;
            bridgeAction[@"x"] = @(x);
            bridgeAction[@"y"] = @(y);
            bridgeAction[@"duration_ms"] = @80;
            NSDictionary *springBoardInput = OPSpringBoardInputInfo(bridgeAction);
            BOOL springBoardOK = [springBoardInput[@"status"] isEqualToString:@"ok"];
            NSDictionary *tap = springBoardOK ? nil : OPPerformHIDTap(x, y, 80);
            BOOL ok = springBoardOK || [tap[@"ok"] boolValue];
            NSMutableDictionary *mutableResult = [@{
                @"state": ok ? @"action.executed" : @"action.denied.input_failed",
                @"task_id": taskId,
                @"capability": capability,
                @"detail": elementId.length > 0
                        ? [NSString stringWithFormat:@"%@:%@:%0.1f,%0.1f", type, elementId, x, y]
                        : [NSString stringWithFormat:@"%@:%0.1f,%0.1f", type, x, y],
                @"provider_result": springBoardOK ? springBoardInput : (tap ?: @{}),
                @"source": @"openphone.agentd"
            } mutableCopy];
            NSMutableArray *providerAttempts = [NSMutableArray array];
            if (appInput) {
                [providerAttempts addObject:OPInputAttemptSummaryForAction(appInput, type)];
            }
            [providerAttempts addObject:OPInputAttemptSummaryForAction(springBoardInput, type)];
            if (!springBoardOK && tap) {
                [providerAttempts addObject:OPInputAttemptSummaryForAction(tap, type)];
                mutableResult[@"springboard_provider_result"] = springBoardInput ?: @{};
            }
            mutableResult[@"provider_attempts"] = providerAttempts;
            if (coordinateSource.length > 0) {
                mutableResult[@"coordinate_source"] = coordinateSource;
            }
            if (resolvedElement) {
                mutableResult[@"target"] = OPResolvedElementSummary(resolvedElement);
            }
            result = mutableResult;
        }
    } else if ([type isEqualToString:@"long_press"]) {
        capability = @"input.perform";
        double x = 0.0;
        double y = 0.0;
        if (!OPPointFromAction(action, &x, &y)) {
            result = @{
                @"state": @"action.denied.missing_coordinates",
                @"task_id": taskId,
                @"capability": capability,
                @"detail": @"missing_coordinates",
                @"source": @"openphone.agentd"
            };
        } else {
            long durationMs = OPLongLongFromRequest(action, @"duration_ms", 700, 100, 5000);
            NSMutableDictionary *bridgeAction = [action mutableCopy] ?: [NSMutableDictionary dictionary];
            bridgeAction[@"type"] = @"long_press";
            bridgeAction[@"x"] = @(x);
            bridgeAction[@"y"] = @(y);
            bridgeAction[@"duration_ms"] = @(durationMs);
            NSDictionary *springBoardInput = OPSpringBoardInputInfo(bridgeAction);
            BOOL springBoardOK = [springBoardInput[@"status"] isEqualToString:@"ok"];
            NSDictionary *press = springBoardOK ? nil : OPPerformHIDTap(x, y, durationMs);
            BOOL ok = springBoardOK || [press[@"ok"] boolValue];
            NSMutableDictionary *mutableResult = [@{
                @"state": ok ? @"action.executed" : @"action.denied.input_failed",
                @"task_id": taskId,
                @"capability": capability,
                @"detail": [NSString stringWithFormat:@"long_press:%0.1f,%0.1f:%ldms",
                             x, y, durationMs],
                @"provider_result": springBoardOK ? springBoardInput : (press ?: @{}),
                @"source": @"openphone.agentd"
            } mutableCopy];
            NSMutableArray *providerAttempts = [NSMutableArray array];
            [providerAttempts addObject:OPInputAttemptSummaryForAction(springBoardInput, type)];
            if (!springBoardOK && press) {
                [providerAttempts addObject:OPInputAttemptSummaryForAction(press, type)];
                mutableResult[@"springboard_provider_result"] = springBoardInput ?: @{};
            }
            mutableResult[@"provider_attempts"] = providerAttempts;
            result = mutableResult;
        }
    } else if ([type isEqualToString:@"swipe"]) {
        capability = @"input.perform";
        double startX = 0.0;
        double startY = 0.0;
        double endX = 0.0;
        double endY = 0.0;
        BOOL hasStart = OPDoubleForKey(action, @"start_x", &startX) &&
                OPDoubleForKey(action, @"start_y", &startY);
        BOOL hasEnd = OPDoubleForKey(action, @"end_x", &endX) &&
                OPDoubleForKey(action, @"end_y", &endY);
        if (!hasStart || !hasEnd) {
            result = @{
                @"state": @"action.denied.missing_coordinates",
                @"task_id": taskId,
                @"capability": capability,
                @"detail": @"missing_swipe_coordinates",
                @"source": @"openphone.agentd"
            };
        } else {
            long durationMs = OPLongLongFromRequest(action, @"duration_ms", 300, 50, 5000);
            NSDictionary *swipe = OPPerformHIDSwipe(startX, startY, endX, endY, durationMs);
            result = @{
                @"state": [swipe[@"ok"] boolValue]
                        ? @"action.executed" : @"action.denied.input_failed",
                @"task_id": taskId,
                @"capability": capability,
                @"detail": [NSString stringWithFormat:@"swipe:%0.1f,%0.1f:%0.1f,%0.1f:%ldms",
                             startX, startY, endX, endY, durationMs],
                @"provider_result": swipe,
                @"source": @"openphone.agentd"
            };
        }
    } else if ([type isEqualToString:@"type_text"]) {
        capability = @"input.perform";
        NSString *text = [action[@"text"] isKindOfClass:[NSString class]] ? action[@"text"] : @"";
        NSDictionary *appInput = nil;
        recordedRequest = @{
            @"command": request[@"command"] ?: @"execute_action",
            @"task_id": taskId ?: @"",
            @"action": OPActionForRecording(action)
        };
        if (text.length == 0) {
            result = @{
                @"state": @"action.denied.missing_argument",
                @"task_id": taskId,
                @"capability": capability,
                @"detail": @"missing_text",
                @"source": @"openphone.agentd"
            };
        } else {
            NSDictionary *screen = OPGetScreen(@{
                @"command": @"get_screen",
                @"task_id": taskId ?: @"",
                @"include_screenshot": @NO,
                @"compact_trajectory": @YES,
                @"reason": @"type_text_app_input"
            });
            NSDictionary *context = [screen[@"context"] isKindOfClass:[NSDictionary class]]
                    ? screen[@"context"] : @{};
            NSString *foregroundBundleId = [context[@"foreground_app"] isKindOfClass:[NSString class]]
                    ? context[@"foreground_app"] : @"";
            NSDictionary *appUIState = [context[@"app_ui_state"] isKindOfClass:[NSDictionary class]]
                    ? context[@"app_ui_state"] : @{};
            NSString *elementId = [action[@"element_id"] isKindOfClass:[NSString class]]
                    ? action[@"element_id"] : @"";
            NSDictionary *resolvedElement = elementId.length > 0
                    ? OPInteractiveElementFromScreen(screen, elementId) : nil;
            BOOL appUIReady = [context[@"ui_tree_source"] isEqualToString:@"app_process"] &&
                    [appUIState[@"status"] isEqualToString:@"ok"] &&
                    OPBundleIdentifierLooksValid(foregroundBundleId);
            if (appUIReady) {
                NSDictionary *uiTree = [context[@"ui_tree"] isKindOfClass:[NSDictionary class]]
                        ? context[@"ui_tree"] : @{};
                NSString *preferredScope = [uiTree[@"scope"] isKindOfClass:[NSString class]]
                        ? uiTree[@"scope"] : @"";
                if (resolvedElement) {
                    NSString *elementInputScope = [resolvedElement[@"input_scope"] isKindOfClass:[NSString class]]
                            ? resolvedElement[@"input_scope"] : @"";
                    NSString *elementScope = [resolvedElement[@"scope"] isKindOfClass:[NSString class]]
                            ? resolvedElement[@"scope"] : @"";
                    preferredScope = elementInputScope.length > 0 ? elementInputScope : elementScope;
                    NSString *elementBundleId = [resolvedElement[@"source_bundle_id"] isKindOfClass:[NSString class]]
                            ? resolvedElement[@"source_bundle_id"] : @"";
                    if (OPBundleIdentifierLooksValid(elementBundleId)) {
                        foregroundBundleId = elementBundleId;
                    }
                }
                NSMutableDictionary *appAction = [action mutableCopy] ?: [NSMutableDictionary dictionary];
                appAction[@"type"] = @"type_text";
                appAction[@"text_length"] = @(text.length);
                if (resolvedElement) {
                    appAction[@"target"] = OPResolvedElementSummary(resolvedElement);
                }
                appAction[@"preferred_input_scope"] = preferredScope.length > 0
                        ? preferredScope : @"app_process";
                if (![appAction[@"input_timeout_ms"] respondsToSelector:@selector(longLongValue)]) {
                    appAction[@"input_timeout_ms"] = @3000;
                }
                appInput = OPAppInputInfo(appAction, foregroundBundleId);
                if ([appInput[@"status"] isEqualToString:@"ok"]) {
                    result = @{
                        @"state": @"action.executed",
                        @"task_id": taskId,
                        @"capability": capability,
                        @"detail": [NSString stringWithFormat:@"type_text:%lu:app_process",
                                     (unsigned long)text.length],
                        @"provider_result": appInput ?: @{},
                        @"provider_attempts": @[OPInputAttemptSummaryForAction(appInput, type)],
                        @"source": @"openphone.agentd"
                    };
                }
            }
            if (!result) {
                NSDictionary *typed = OPPerformHIDTypeText(text);
                NSMutableDictionary *mutableResult = [@{
                    @"state": [typed[@"ok"] boolValue]
                            ? @"action.executed" : @"action.denied.input_failed",
                    @"task_id": taskId,
                    @"capability": capability,
                    @"detail": [NSString stringWithFormat:@"type_text:%lu",
                                 (unsigned long)text.length],
                    @"provider_result": typed,
                    @"source": @"openphone.agentd"
                } mutableCopy];
                NSMutableArray *providerAttempts = [NSMutableArray array];
                if (appInput) {
                    [providerAttempts addObject:OPInputAttemptSummaryForAction(appInput, type)];
                }
                [providerAttempts addObject:OPInputAttemptSummaryForAction(typed, type)];
                mutableResult[@"provider_attempts"] = providerAttempts;
                result = mutableResult;
            }
        }
    } else {
        result = @{
            @"state": @"action.denied.unsupported",
            @"task_id": taskId,
            @"capability": capability,
            @"detail": type.length > 0 ? type : @"missing_action_type",
            @"source": @"openphone.agentd"
        };
    }
    if ([capability isEqualToString:@"input.perform"]) {
        result = OPFinalizeInputResult(result, type);
    }
    NSString *decision = [result[@"state"] isEqualToString:@"action.executed"]
            ? @"allow_task_scoped" : @"deny";
    OPRecordAudit([result[@"state"] isEqualToString:@"action.executed"]
            ? @"action_executed" : @"action_rejected", taskId, capability, decision,
            recordedRequest, result[@"detail"]);
    OPRecordTrajectory(taskId, @"tool_result", @{
        @"tool": @"execute_action",
        @"arguments": recordedRequest ?: @{},
        @"result": result ?: @{}
    });
    return result;
}

static NSDictionary *OPActionForGoal(NSString *goal) {
    NSString *trimmedGoal = [goal stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lower = [trimmedGoal.lowercaseString stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([lower hasPrefix:@"type_text "]) {
        NSString *text = [trimmedGoal substringFromIndex:10];
        return @{
            @"type": @"type_text",
            @"text": text,
            @"reason": @"deterministic run_task matched type_text"
        };
    }
    if ([lower hasPrefix:@"type "]) {
        NSString *text = [trimmedGoal substringFromIndex:5];
        return @{
            @"type": @"type_text",
            @"text": text,
            @"reason": @"deterministic run_task matched type"
        };
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSArray<NSString *> *rawParts = [lower componentsSeparatedByCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSString *part in rawParts) {
        if (part.length > 0) {
            [parts addObject:part];
        }
    }
    if (parts.count >= 3 && [parts[0] isEqualToString:@"tap"]) {
        return @{
            @"type": @"tap",
            @"x": @([parts[1] doubleValue]),
            @"y": @([parts[2] doubleValue]),
            @"reason": @"deterministic run_task matched tap coordinates"
        };
    }
    if (parts.count >= 3 && ([parts[0] isEqualToString:@"long_press"] ||
            ([parts[0] isEqualToString:@"long"] && parts.count >= 4 &&
             [parts[1] isEqualToString:@"press"]))) {
        NSUInteger xIndex = [parts[0] isEqualToString:@"long_press"] ? 1 : 2;
        NSUInteger yIndex = xIndex + 1;
        NSUInteger durationIndex = yIndex + 1;
        NSMutableDictionary *action = [@{
            @"type": @"long_press",
            @"x": @([parts[xIndex] doubleValue]),
            @"y": @([parts[yIndex] doubleValue]),
            @"reason": @"deterministic run_task matched long press coordinates"
        } mutableCopy];
        if (parts.count > durationIndex) {
            action[@"duration_ms"] = @([parts[durationIndex] integerValue]);
        }
        return action;
    }
    if (parts.count >= 5 && [parts[0] isEqualToString:@"swipe"]) {
        NSMutableDictionary *action = [@{
            @"type": @"swipe",
            @"start_x": @([parts[1] doubleValue]),
            @"start_y": @([parts[2] doubleValue]),
            @"end_x": @([parts[3] doubleValue]),
            @"end_y": @([parts[4] doubleValue]),
            @"reason": @"deterministic run_task matched swipe coordinates"
        } mutableCopy];
        if (parts.count >= 6) {
            action[@"duration_ms"] = @([parts[5] integerValue]);
        }
        return action;
    }
    if ([lower containsString:@"wake"] || [lower containsString:@"unlock"]) {
        return @{
            @"type": @"wake_and_home",
            @"reason": @"deterministic run_task matched wake/home"
        };
    }
    if ([lower isEqualToString:@"home"] || [lower containsString:@"home screen"]) {
        return @{
            @"type": @"home",
            @"reason": @"deterministic run_task matched home"
        };
    }
    NSString *explicitURL = OPExplicitURLFromText(goal ?: @"");
    if (explicitURL.length > 0) {
        return @{
            @"type": @"open_url",
            @"url": explicitURL,
            @"reason": @"deterministic run_task matched URL"
        };
    }
    if ([lower containsString:@"safari"]) {
        return @{
            @"type": @"open_app",
            @"target": @{@"package": @"com.apple.mobilesafari"},
            @"reason": @"deterministic run_task matched Safari"
        };
    }
    return @{
        @"type": @"wait",
        @"duration_ms": @1000,
        @"reason": @"deterministic run_task fallback"
    };
}

static NSArray<NSString *> *OPModelToolNames(void) {
    return @[
        @"get_screen",
        @"tap",
        @"tap_element",
        @"long_press",
        @"swipe",
        @"type_text",
        @"open_app",
        @"open_url",
        @"home",
        @"wake_and_home",
        @"wait",
        @"clipboard_read",
        @"clipboard_write",
        @"contacts_search",
        @"calendar_search",
        @"calls_search",
        @"messages_search",
        @"memory_save",
        @"memory_search",
        @"context_search",
        @"finish_task",
        @"fail_task"
    ];
}

static NSString *OPModelToolCapability(NSString *tool) {
    if ([tool isEqualToString:@"get_screen"]) {
        return @"screen.read.visible";
    }
    if ([tool isEqualToString:@"memory_save"]) {
        return @"memory.write";
    }
    if ([tool isEqualToString:@"clipboard_read"]) {
        return @"clipboard.read";
    }
    if ([tool isEqualToString:@"clipboard_write"]) {
        return @"clipboard.write";
    }
    if ([tool isEqualToString:@"contacts_search"]) {
        return @"contacts.read";
    }
    if ([tool isEqualToString:@"calendar_search"]) {
        return @"calendar.read";
    }
    if ([tool isEqualToString:@"calls_search"]) {
        return @"calls.read";
    }
    if ([tool isEqualToString:@"messages_search"]) {
        return @"messages.read";
    }
    if ([tool isEqualToString:@"memory_search"] || [tool isEqualToString:@"context_search"]) {
        return @"memory.read";
    }
    if ([tool isEqualToString:@"open_app"]) {
        return @"apps.launch";
    }
    if ([tool isEqualToString:@"open_url"]) {
        return @"network.use";
    }
    if ([tool isEqualToString:@"finish_task"] || [tool isEqualToString:@"fail_task"] ||
            [tool isEqualToString:@"wait"]) {
        return @"tasks.observe";
    }
    if ([OPModelToolNames() containsObject:tool]) {
        return @"input.perform";
    }
    return @"unknown";
}

static BOOL OPModelToolDrivesUI(NSString *tool) {
    static NSSet<NSString *> *tools = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tools = [NSSet setWithArray:@[
            @"tap",
            @"tap_element",
            @"long_press",
            @"swipe",
            @"type_text",
            @"open_app",
            @"open_url",
            @"home",
            @"wake_and_home"
        ]];
    });
    return [tools containsObject:tool ?: @""];
}

static NSString *OPExplicitURLFromText(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
        return @"";
    }
    NSArray<NSString *> *parts = [text componentsSeparatedByCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@"\"'“”‘’.,;!?)]}>"];
    for (NSString *part in parts) {
        NSString *candidate = [part stringByTrimmingCharactersInSet:trim];
        NSString *lower = candidate.lowercaseString;
        if ([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"]) {
            return candidate;
        }
    }
    return @"";
}

static BOOL OPModelToolShouldYieldToExplicitURL(NSString *tool) {
    static NSSet<NSString *> *tools = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tools = [NSSet setWithArray:@[
            @"get_screen",
            @"tap",
            @"tap_element",
            @"long_press",
            @"swipe",
            @"open_app",
            @"home",
            @"wake_and_home",
            @"wait"
        ]];
    });
    return [tools containsObject:tool ?: @""];
}

static NSDictionary *OPModelDecisionByApplyingGuardrails(NSDictionary *decision,
        NSString *goal, NSInteger step, NSDictionary **guardrailOut) {
    if (guardrailOut) {
        *guardrailOut = nil;
    }
    if (![decision isKindOfClass:[NSDictionary class]]) {
        return decision ?: @{};
    }
    NSString *tool = [decision[@"tool"] isKindOfClass:[NSString class]]
            ? decision[@"tool"] : @"";
    NSString *url = OPExplicitURLFromText(goal ?: @"");
    if (step == 1 && url.length > 0 && ![tool isEqualToString:@"open_url"] &&
            OPModelToolShouldYieldToExplicitURL(tool)) {
        NSMutableDictionary *rewritten = [decision mutableCopy];
        rewritten[@"tool"] = @"open_url";
        rewritten[@"arguments"] = @{
            @"url": url,
            @"reason": @"explicit URL in user goal"
        };
        rewritten[@"expected_visible_change"] = @"The requested URL opens in Safari or the active browser.";
        NSString *thought = [decision[@"thought"] isKindOfClass:[NSString class]]
                ? decision[@"thought"] : @"";
        rewritten[@"thought"] = thought.length > 0
                ? [NSString stringWithFormat:@"%@ Guardrail: explicit URL goals open the URL directly before tapping app icons.", thought]
                : @"Guardrail: explicit URL goals open the URL directly before tapping app icons.";
        if (guardrailOut) {
            *guardrailOut = @{
                @"reason": @"explicit_url_first_action",
                @"original_tool": tool ?: @"",
                @"rewritten_tool": @"open_url",
                @"url": url,
                @"step": @(step)
            };
        }
        return rewritten;
    }
    return decision;
}

static NSArray *OPModelCompactStrings(NSArray *values, NSUInteger limit) {
    NSMutableArray *result = [NSMutableArray array];
    for (id value in values) {
        if (![value isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length == 0) {
            continue;
        }
        if (text.length > 160) {
            text = [[text substringToIndex:160] stringByAppendingString:@"..."];
        }
        [result addObject:text];
        if (result.count >= limit) {
            break;
        }
    }
    return result;
}

static NSInteger OPModelElementPriority(NSDictionary *element) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in @[@"label", @"value", @"view_id", @"kind", @"tag", @"input_type",
            @"scope", @"input_scope", @"risk_hint", @"class"]) {
        NSString *part = [element[key] isKindOfClass:[NSString class]] ? element[key] : @"";
        if (part.length > 0) {
            [parts addObject:part.lowercaseString];
        }
    }
    NSString *haystack = [parts componentsJoinedByString:@" "];
    if ([haystack containsString:@"search"]) {
        return 0;
    }
    NSString *tag = [element[@"tag"] isKindOfClass:[NSString class]]
            ? [element[@"tag"] lowercaseString] : @"";
    NSString *kind = [element[@"kind"] isKindOfClass:[NSString class]]
            ? [element[@"kind"] lowercaseString] : @"";
    NSString *inputType = [element[@"input_type"] isKindOfClass:[NSString class]]
            ? element[@"input_type"] : @"";
    if ([kind containsString:@"input"] || [tag isEqualToString:@"input"] ||
            [tag isEqualToString:@"textarea"] || [tag isEqualToString:@"select"] ||
            inputType.length > 0) {
        return 1;
    }
    if ([haystack containsString:@"web_content_process"]) {
        return 2;
    }
    NSString *label = [element[@"label"] isKindOfClass:[NSString class]] ? element[@"label"] : @"";
    if (label.length > 0 && [element[@"enabled"] boolValue]) {
        return 3;
    }
    if (kind.length > 0 && ![kind isEqualToString:@"view"]) {
        return 4;
    }
    return 5;
}

static NSArray *OPModelCompactElements(NSArray *elements, NSUInteger limit) {
    NSMutableArray *ranked = [NSMutableArray array];
    NSUInteger index = 0;
    for (id value in elements) {
        if (![value isKindOfClass:[NSDictionary class]]) {
            index += 1;
            continue;
        }
        NSDictionary *element = value;
        [ranked addObject:@{
            @"priority": @(OPModelElementPriority(element)),
            @"index": @(index),
            @"element": element
        }];
        index += 1;
    }
    [ranked sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger priorityA = [a[@"priority"] integerValue];
        NSInteger priorityB = [b[@"priority"] integerValue];
        if (priorityA < priorityB) {
            return NSOrderedAscending;
        }
        if (priorityA > priorityB) {
            return NSOrderedDescending;
        }
        NSUInteger indexA = [a[@"index"] unsignedIntegerValue];
        NSUInteger indexB = [b[@"index"] unsignedIntegerValue];
        if (indexA < indexB) {
            return NSOrderedAscending;
        }
        if (indexA > indexB) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];

    NSMutableArray *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSDictionary *rankedElement in ranked) {
        NSDictionary *element = [rankedElement[@"element"] isKindOfClass:[NSDictionary class]]
                ? rankedElement[@"element"] : @{};
        NSMutableDictionary *compact = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"id", @"view_id", @"kind", @"label", @"value", @"enabled",
                @"bounds", @"risk_hint", @"scope", @"input_scope", @"tag", @"input_type",
                @"source_bundle_id", @"focused"]) {
            if (element[key]) {
                compact[key] = element[key];
            }
        }
        NSString *identifier = [compact[@"id"] isKindOfClass:[NSString class]]
                ? compact[@"id"] : @"";
        if (identifier.length > 0 && [seen containsObject:identifier]) {
            continue;
        }
        if (identifier.length > 0) {
            [seen addObject:identifier];
        }
        if (compact.count > 0) {
            [result addObject:compact];
        }
        if (result.count >= limit) {
            break;
        }
    }
    return result;
}

static NSDictionary *OPModelScreenSummary(NSDictionary *screen) {
    NSDictionary *context = [screen[@"context"] isKindOfClass:[NSDictionary class]]
            ? screen[@"context"] : @{};
    NSArray *visibleText = [context[@"visible_text"] isKindOfClass:[NSArray class]]
            ? context[@"visible_text"] : @[];
    NSArray *interactiveElements = [context[@"interactive_elements"] isKindOfClass:[NSArray class]]
            ? context[@"interactive_elements"] : @[];
    NSDictionary *lock = [context[@"lock"] isKindOfClass:[NSDictionary class]]
            ? context[@"lock"] : @{};
    NSDictionary *screenshot = [context[@"screenshot"] isKindOfClass:[NSDictionary class]]
            ? context[@"screenshot"] : @{};
    return @{
        @"state": screen[@"state"] ?: @"",
        @"foreground_app": context[@"foreground_app"] ?: @"unknown",
        @"foreground_source": context[@"foreground_source"] ?: @"unknown",
        @"locked": lock[@"locked"] ?: @NO,
        @"risk_flags": context[@"risk_flags"] ?: @[],
        @"visible_text": OPModelCompactStrings(visibleText, 20),
        @"interactive_elements": OPModelCompactElements(interactiveElements, 30),
        @"screenshot": @{
            @"status": screenshot[@"status"] ?: @"unknown",
            @"path": screenshot[@"path"] ?: @"",
            @"sha256": screenshot[@"sha256"] ?: @"",
            @"width": screenshot[@"width"] ?: @0,
            @"height": screenshot[@"height"] ?: @0
        }
    };
}

// Deterministic signature of a screen so we can detect "did the UI actually
// change" between two observations. Concatenates foreground bundle id + a
// stable digest of visible-text and interactive-element ids.
static NSString *OPModelScreenSignature(NSDictionary *screen) {
    if (![screen isKindOfClass:[NSDictionary class]]) return @"";
    NSDictionary *context = [screen[@"context"] isKindOfClass:[NSDictionary class]]
            ? screen[@"context"] : @{};
    NSString *fg = [context[@"foreground_app"] isKindOfClass:[NSString class]]
            ? context[@"foreground_app"] : @"";
    NSArray *vt = [context[@"visible_text"] isKindOfClass:[NSArray class]]
            ? context[@"visible_text"] : @[];
    NSArray *ie = [context[@"interactive_elements"] isKindOfClass:[NSArray class]]
            ? context[@"interactive_elements"] : @[];
    NSMutableArray *textParts = [NSMutableArray array];
    NSUInteger textCount = MIN(vt.count, (NSUInteger)15);
    for (NSUInteger i = 0; i < textCount; i++) {
        id v = vt[i];
        if ([v isKindOfClass:[NSString class]]) [textParts addObject:v];
        else if ([v isKindOfClass:[NSDictionary class]] &&
                 [v[@"text"] isKindOfClass:[NSString class]]) {
            [textParts addObject:v[@"text"]];
        }
    }
    NSMutableArray *elemParts = [NSMutableArray array];
    NSUInteger elemCount = MIN(ie.count, (NSUInteger)15);
    for (NSUInteger i = 0; i < elemCount; i++) {
        id v = ie[i];
        if ([v isKindOfClass:[NSDictionary class]] &&
                [v[@"id"] isKindOfClass:[NSString class]]) {
            [elemParts addObject:v[@"id"]];
        }
    }
    return [NSString stringWithFormat:@"%@|%@|%@",
            fg,
            [textParts componentsJoinedByString:@"§"],
            [elemParts componentsJoinedByString:@"§"]];
}

static NSDictionary *OPModelToolResultSummary(NSDictionary *toolResult) {
    if (![toolResult isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"status", @"state", @"reason", @"summary", @"source",
            @"detail", @"user_facing_status", @"tool", @"provider", @"system_clipboard",
            @"text_length", @"text_sha256", @"truncated", @"max_chars"]) {
        id value = toolResult[key];
        if (value) {
            summary[key] = value;
        }
    }
    if ([toolResult[@"tool"] isEqualToString:@"clipboard_read"] &&
            [toolResult[@"text"] isKindOfClass:[NSString class]]) {
        summary[@"text"] = toolResult[@"text"];
    }
    if ([toolResult[@"tool"] isEqualToString:@"contacts_search"] &&
            [toolResult[@"contacts"] isKindOfClass:[NSArray class]]) {
        summary[@"contacts"] = OPContactsSummaryContacts(toolResult[@"contacts"], 8);
        summary[@"count"] = toolResult[@"count"] ?: @0;
        summary[@"query_length"] = toolResult[@"query_length"] ?: @0;
        summary[@"query_sha256"] = toolResult[@"query_sha256"] ?: @"";
    }
    if ([toolResult[@"tool"] isEqualToString:@"calendar_search"] &&
            [toolResult[@"events"] isKindOfClass:[NSArray class]]) {
        summary[@"events"] = OPCalendarSummaryEvents(toolResult[@"events"], 8);
        summary[@"count"] = toolResult[@"count"] ?: @0;
        summary[@"query_length"] = toolResult[@"query_length"] ?: @0;
        summary[@"query_sha256"] = toolResult[@"query_sha256"] ?: @"";
        summary[@"start_at_ms"] = toolResult[@"start_at_ms"] ?: @0;
        summary[@"end_at_ms"] = toolResult[@"end_at_ms"] ?: @0;
    }
    if ([toolResult[@"tool"] isEqualToString:@"calls_search"] &&
            [toolResult[@"calls"] isKindOfClass:[NSArray class]]) {
        summary[@"calls"] = OPCallsSummaryCalls(toolResult[@"calls"], 8);
        summary[@"count"] = toolResult[@"count"] ?: @0;
        summary[@"query_length"] = toolResult[@"query_length"] ?: @0;
        summary[@"query_sha256"] = toolResult[@"query_sha256"] ?: @"";
        summary[@"start_at_ms"] = toolResult[@"start_at_ms"] ?: @0;
        summary[@"end_at_ms"] = toolResult[@"end_at_ms"] ?: @0;
    }
    if ([toolResult[@"tool"] isEqualToString:@"messages_search"] &&
            [toolResult[@"messages"] isKindOfClass:[NSArray class]]) {
        summary[@"messages"] = OPMessagesSummaryMessages(toolResult[@"messages"], 8, YES);
        summary[@"count"] = toolResult[@"count"] ?: @0;
        summary[@"query_length"] = toolResult[@"query_length"] ?: @0;
        summary[@"query_sha256"] = toolResult[@"query_sha256"] ?: @"";
        summary[@"start_at_ms"] = toolResult[@"start_at_ms"] ?: @0;
        summary[@"end_at_ms"] = toolResult[@"end_at_ms"] ?: @0;
    }
    if ([toolResult[@"verification"] isKindOfClass:[NSDictionary class]]) {
        summary[@"verification"] = toolResult[@"verification"];
    }
    NSArray *providerAttempts = [toolResult[@"provider_attempts"] isKindOfClass:[NSArray class]]
            ? toolResult[@"provider_attempts"] : @[];
    if (providerAttempts.count > 0) {
        NSMutableArray *attempts = [NSMutableArray array];
        for (id object in providerAttempts) {
            if (![object isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSDictionary *attempt = (NSDictionary *)object;
            NSMutableDictionary *compact = [NSMutableDictionary dictionary];
            for (NSString *key in @[@"provider", @"scope", @"action_type", @"status", @"reason",
                    @"activation_method", @"target_class", @"text_length",
                    @"before_text_length", @"after_text_length"]) {
                id value = attempt[key];
                if (value) {
                    compact[key] = value;
                }
            }
            if ([attempt[@"verification"] isKindOfClass:[NSDictionary class]]) {
                compact[@"verification"] = attempt[@"verification"];
            }
            if (compact.count > 0) {
                [attempts addObject:compact];
            }
        }
        if (attempts.count > 0) {
            summary[@"provider_attempts"] = attempts;
        }
    }
    return summary;
}

static NSDictionary *OPModelProviderVerification(NSDictionary *toolResult) {
    NSDictionary *verification = [toolResult[@"verification"] isKindOfClass:[NSDictionary class]]
            ? toolResult[@"verification"] : @{};
    if ([verification[@"status"] isEqualToString:@"verified"]) {
        return verification;
    }
    NSArray *providerAttempts = [toolResult[@"provider_attempts"] isKindOfClass:[NSArray class]]
            ? toolResult[@"provider_attempts"] : @[];
    for (id object in providerAttempts) {
        if (![object isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *attempt = (NSDictionary *)object;
        NSDictionary *attemptVerification = [attempt[@"verification"] isKindOfClass:[NSDictionary class]]
                ? attempt[@"verification"] : @{};
        if ([attemptVerification[@"status"] isEqualToString:@"verified"]) {
            return attemptVerification;
        }
    }
    return @{};
}

static BOOL OPModelToolResultIsProviderVerified(NSDictionary *toolResult) {
    if (![toolResult isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    NSString *userFacingStatus = [toolResult[@"user_facing_status"] isKindOfClass:[NSString class]]
            ? toolResult[@"user_facing_status"] : @"";
    if ([userFacingStatus isEqualToString:@"verified"] || [userFacingStatus isEqualToString:@"success"]) {
        return YES;
    }
    return OPModelProviderVerification(toolResult).count > 0;
}

static BOOL OPModelShouldUseProviderVerificationOnly(NSString *tool, NSDictionary *toolResult) {
    if (![tool isEqualToString:@"type_text"]) {
        return NO;
    }
    return OPModelToolResultIsProviderVerified(toolResult);
}

static NSDictionary *OPModelProviderVerificationState(NSString *tool, NSDictionary *toolResult,
        NSDictionary *beforeScreen, NSString *expectedVisibleChange) {
    NSDictionary *providerVerification = OPModelProviderVerification(toolResult ?: @{});
    NSString *source = [providerVerification[@"source"] isKindOfClass:[NSString class]]
            ? providerVerification[@"source"] : @"provider_verification";
    NSString *reason = [providerVerification[@"reason"] isKindOfClass:[NSString class]]
            ? providerVerification[@"reason"] : @"provider_verified_visible_effect";
    NSMutableDictionary *result = [@{
        @"status": @"verified",
        @"reason": reason,
        @"source": source,
        @"tool": tool ?: @"",
        @"expected_visible_change": expectedVisibleChange ?: @"",
        @"screen_state": beforeScreen[@"state"] ?: @"",
        @"post_action_screen_capture": @"skipped_provider_verified_type_text"
    } mutableCopy];
    if (providerVerification.count > 0) {
        result[@"provider_verification"] = providerVerification;
    }
    return result;
}

static BOOL OPStringContainsCaseInsensitive(NSString *haystack, NSString *needle) {
    if (haystack.length == 0 || needle.length == 0) {
        return NO;
    }
    return [haystack rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL OPModelVerifiedTypeTextCompletesGoal(NSString *goal, NSDictionary *decision,
        NSDictionary *verification) {
    if (![decision[@"tool"] isEqualToString:@"type_text"] ||
            ![verification[@"status"] isEqualToString:@"verified"]) {
        return NO;
    }
    NSDictionary *arguments = [decision[@"arguments"] isKindOfClass:[NSDictionary class]]
            ? decision[@"arguments"] : @{};
    NSString *text = [arguments[@"text"] isKindOfClass:[NSString class]]
            ? arguments[@"text"] : @"";
    if (text.length == 0 || !OPStringContainsCaseInsensitive(goal ?: @"", text)) {
        return NO;
    }
    NSArray<NSString *> *terminalHints = @[
        @"then finish",
        @"finish only after",
        @"type the exact text",
        @"enter the exact text"
    ];
    BOOL hasTerminalHint = NO;
    for (NSString *hint in terminalHints) {
        if (OPStringContainsCaseInsensitive(goal ?: @"", hint)) {
            hasTerminalHint = YES;
            break;
        }
    }
    if (!hasTerminalHint) {
        return NO;
    }
    NSString *lowerGoal = [(goal ?: @"") lowercaseString];
    NSArray<NSString *> *negatedSubmitHints = @[
        @"do not submit",
        @"don't submit",
        @"dont submit",
        @"without submitting",
        @"without submit",
        @"not submit",
        @"never submit"
    ];
    BOOL submitIsNegated = NO;
    for (NSString *hint in negatedSubmitHints) {
        if ([lowerGoal containsString:hint]) {
            submitIsNegated = YES;
            break;
        }
    }
    for (NSString *continuationHint in @[@"then send", @"then submit", @"then tap",
            @"tap send", @"press send", @"submit", @"post"]) {
        if (OPStringContainsCaseInsensitive(goal ?: @"", continuationHint)) {
            if (submitIsNegated &&
                    ([continuationHint isEqualToString:@"submit"] ||
                     [continuationHint isEqualToString:@"then submit"])) {
                continue;
            }
            return NO;
        }
    }
    return YES;
}

static NSDictionary *OPModelScreenTraceSummary(NSDictionary *screen) {
    NSDictionary *summary = OPModelScreenSummary(screen ?: @{});
    NSArray *elements = [summary[@"interactive_elements"] isKindOfClass:[NSArray class]]
            ? summary[@"interactive_elements"] : @[];
    return @{
        @"state": summary[@"state"] ?: @"",
        @"foreground_app": summary[@"foreground_app"] ?: @"unknown",
        @"foreground_source": summary[@"foreground_source"] ?: @"unknown",
        @"locked": summary[@"locked"] ?: @NO,
        @"risk_flags": summary[@"risk_flags"] ?: @[],
        @"visible_text": summary[@"visible_text"] ?: @[],
        @"interactive_element_count": @(elements.count),
        @"screenshot": summary[@"screenshot"] ?: @{}
    };
}

static NSDictionary *OPModelCompactScreenForLoop(NSDictionary *screen) {
    if (![screen isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSDictionary *context = [screen[@"context"] isKindOfClass:[NSDictionary class]]
            ? screen[@"context"] : @{};
    NSDictionary *summary = OPModelScreenSummary(screen);
    NSDictionary *uiTree = [context[@"ui_tree"] isKindOfClass:[NSDictionary class]]
            ? context[@"ui_tree"] : @{};
    NSDictionary *appUIState = [context[@"app_ui_state"] isKindOfClass:[NSDictionary class]]
            ? context[@"app_ui_state"] : @{};
    NSDictionary *springBoardState = [context[@"springboard_state"] isKindOfClass:[NSDictionary class]]
            ? context[@"springboard_state"] : @{};
    NSDictionary *display = [context[@"display"] isKindOfClass:[NSDictionary class]]
            ? context[@"display"] : @{};
    NSArray *recentApps = [context[@"recent_apps"] isKindOfClass:[NSArray class]]
            ? context[@"recent_apps"] : @[];
    NSMutableArray *compactRecentApps = [NSMutableArray array];
    for (id value in recentApps) {
        if (![value isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *app = value;
        NSMutableDictionary *compact = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"bundle_id", @"display_name", @"rank", @"source"]) {
            if (app[key]) {
                compact[key] = app[key];
            }
        }
        if (compact.count > 0) {
            [compactRecentApps addObject:compact];
        }
        if (compactRecentApps.count >= 8) {
            break;
        }
    }
    NSMutableDictionary *compactContext = [NSMutableDictionary dictionary];
    compactContext[@"foreground_app"] = summary[@"foreground_app"] ?: @"unknown";
    compactContext[@"foreground_package"] = summary[@"foreground_app"] ?: @"unknown";
    compactContext[@"foreground_source"] = summary[@"foreground_source"] ?: @"unknown";
    compactContext[@"lock"] = @{
        @"locked": summary[@"locked"] ?: @NO,
        @"status": [context[@"lock"] isKindOfClass:[NSDictionary class]]
                ? (context[@"lock"][@"status"] ?: @"unknown") : @"unknown"
    };
    compactContext[@"risk_flags"] = summary[@"risk_flags"] ?: @[];
    compactContext[@"visible_text"] = summary[@"visible_text"] ?: @[];
    compactContext[@"interactive_elements"] = summary[@"interactive_elements"] ?: @[];
    compactContext[@"screenshot"] = summary[@"screenshot"] ?: @{};
    compactContext[@"ui_tree_source"] = context[@"ui_tree_source"] ?: @"unknown";
    compactContext[@"ui_tree"] = @{
        @"status": uiTree[@"status"] ?: @"unknown",
        @"provider": uiTree[@"provider"] ?: @"unknown",
        @"scope": uiTree[@"scope"] ?: @"",
        @"text_count": uiTree[@"text_count"] ?: @0,
        @"element_count": uiTree[@"element_count"] ?: @0,
        @"visible_text": summary[@"visible_text"] ?: @[],
        @"interactive_elements": summary[@"interactive_elements"] ?: @[]
    };
    compactContext[@"app_ui_state"] = @{
        @"status": appUIState[@"status"] ?: @"unknown",
        @"effective_bundle_id": appUIState[@"effective_bundle_id"] ?: @"",
        @"reason": appUIState[@"reason"] ?: @"",
        @"age_ms": appUIState[@"age_ms"] ?: @0,
        @"received_transport": appUIState[@"received_transport"] ?: @""
    };
    compactContext[@"springboard_state"] = @{
        @"status": springBoardState[@"status"] ?: @"unknown",
        @"foreground_app": springBoardState[@"foreground_app"] ?: @"",
        @"foreground_source": springBoardState[@"foreground_source"] ?: @"",
        @"age_ms": springBoardState[@"age_ms"] ?: @0,
        @"scene_count": springBoardState[@"scene_count"] ?: @0
    };
    compactContext[@"display"] = @{
        @"status": display[@"status"] ?: @"unknown",
        @"point_width": display[@"point_width"] ?: @0,
        @"point_height": display[@"point_height"] ?: @0,
        @"pixel_width": display[@"pixel_width"] ?: @0,
        @"pixel_height": display[@"pixel_height"] ?: @0,
        @"scale": display[@"scale"] ?: @0
    };
    compactContext[@"recent_apps"] = compactRecentApps;
    compactContext[@"recent_apps_source"] = context[@"recent_apps_source"] ?: @"";
    return @{
        @"status": screen[@"status"] ?: @"ok",
        @"state": screen[@"state"] ?: @"",
        @"task_id": screen[@"task_id"] ?: @"",
        @"timestamp_ms": screen[@"timestamp_ms"] ?: @(OPNowMs()),
        @"capture_mode": screen[@"capture_mode"] ?: @"metadata_only",
        @"source": screen[@"source"] ?: @"openphone.agentd.screen.compact",
        @"screenshot": summary[@"screenshot"] ?: @{},
        @"context": compactContext,
        @"request": screen[@"request"] ?: @{}
    };
}

static NSDictionary *OPModelVerificationTraceSummary(NSDictionary *verification) {
    if (![verification isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"status", @"reason", @"source", @"tool",
            @"expected_visible_change", @"screen_state", @"post_action_screen_capture"]) {
        id value = verification[key];
        if (value) {
            summary[key] = value;
        }
    }
    if ([verification[@"provider_verification"] isKindOfClass:[NSDictionary class]]) {
        summary[@"provider_verification"] = verification[@"provider_verification"];
    }
    NSDictionary *delta = [verification[@"screen_delta"] isKindOfClass:[NSDictionary class]]
            ? verification[@"screen_delta"] : nil;
    if (delta) {
        NSMutableDictionary *compactDelta = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"status", @"signals", @"signal_count", @"strong_signal",
                @"fields"]) {
            id value = delta[key];
            if (value) {
                compactDelta[key] = value;
            }
        }
        summary[@"screen_delta"] = compactDelta;
    }
    return summary;
}

static NSDictionary *OPModelScreenDelta(NSDictionary *beforeScreen, NSDictionary *afterScreen) {
    NSDictionary *before = OPModelScreenSummary(beforeScreen ?: @{});
    NSDictionary *after = OPModelScreenSummary(afterScreen ?: @{});
    NSMutableArray<NSString *> *signals = [NSMutableArray array];
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];

    NSString *beforeState = [before[@"state"] isKindOfClass:[NSString class]]
            ? before[@"state"] : @"";
    NSString *afterState = [after[@"state"] isKindOfClass:[NSString class]]
            ? after[@"state"] : @"";
    if (beforeState.length > 0 && afterState.length > 0 &&
            ![beforeState isEqualToString:afterState]) {
        [signals addObject:@"screen_state"];
        fields[@"screen_state"] = @{@"before": beforeState, @"after": afterState};
    }

    NSString *beforeForeground = [before[@"foreground_app"] isKindOfClass:[NSString class]]
            ? before[@"foreground_app"] : @"";
    NSString *afterForeground = [after[@"foreground_app"] isKindOfClass:[NSString class]]
            ? after[@"foreground_app"] : @"";
    if (beforeForeground.length > 0 && afterForeground.length > 0 &&
            ![beforeForeground isEqualToString:afterForeground]) {
        [signals addObject:@"foreground_app"];
        fields[@"foreground_app"] = @{@"before": beforeForeground, @"after": afterForeground};
    }

    BOOL beforeLocked = [before[@"locked"] respondsToSelector:@selector(boolValue)] &&
            [before[@"locked"] boolValue];
    BOOL afterLocked = [after[@"locked"] respondsToSelector:@selector(boolValue)] &&
            [after[@"locked"] boolValue];
    if (beforeLocked != afterLocked) {
        [signals addObject:@"lock_state"];
        fields[@"lock_state"] = @{@"before": @(beforeLocked), @"after": @(afterLocked)};
    }

    NSArray *beforeText = [before[@"visible_text"] isKindOfClass:[NSArray class]]
            ? before[@"visible_text"] : @[];
    NSArray *afterText = [after[@"visible_text"] isKindOfClass:[NSArray class]]
            ? after[@"visible_text"] : @[];
    if (![beforeText isEqualToArray:afterText]) {
        [signals addObject:@"visible_text"];
        fields[@"visible_text"] = @{
            @"before_count": @(beforeText.count),
            @"after_count": @(afterText.count),
            @"before": beforeText,
            @"after": afterText
        };
    }

    NSArray *beforeElements = [before[@"interactive_elements"] isKindOfClass:[NSArray class]]
            ? before[@"interactive_elements"] : @[];
    NSArray *afterElements = [after[@"interactive_elements"] isKindOfClass:[NSArray class]]
            ? after[@"interactive_elements"] : @[];
    if (![beforeElements isEqualToArray:afterElements]) {
        [signals addObject:@"ui_tree"];
        fields[@"ui_tree"] = @{
            @"before_element_count": @(beforeElements.count),
            @"after_element_count": @(afterElements.count)
        };
    }

    NSDictionary *beforeScreenshot = [before[@"screenshot"] isKindOfClass:[NSDictionary class]]
            ? before[@"screenshot"] : @{};
    NSDictionary *afterScreenshot = [after[@"screenshot"] isKindOfClass:[NSDictionary class]]
            ? after[@"screenshot"] : @{};
    NSString *beforeHash = [beforeScreenshot[@"sha256"] isKindOfClass:[NSString class]]
            ? beforeScreenshot[@"sha256"] : @"";
    NSString *afterHash = [afterScreenshot[@"sha256"] isKindOfClass:[NSString class]]
            ? afterScreenshot[@"sha256"] : @"";
    if (beforeHash.length > 0 && afterHash.length > 0 && ![beforeHash isEqualToString:afterHash]) {
        [signals addObject:@"screenshot_hash"];
        fields[@"screenshot_hash"] = @{
            @"before": beforeHash,
            @"after": afterHash,
            @"before_status": beforeScreenshot[@"status"] ?: @"unknown",
            @"after_status": afterScreenshot[@"status"] ?: @"unknown"
        };
    }

    BOOL strong = [signals containsObject:@"foreground_app"] ||
            [signals containsObject:@"lock_state"] ||
            [signals containsObject:@"visible_text"] ||
            [signals containsObject:@"ui_tree"] ||
            [signals containsObject:@"screen_state"];
    return @{
        @"status": signals.count > 0 ? @"changed" : @"unchanged",
        @"signals": signals,
        @"signal_count": @(signals.count),
        @"strong_signal": @(strong),
        @"fields": fields,
        @"before": before,
        @"after": after,
        @"source": @"openphone.agentd.visible_effect"
    };
}

static NSDictionary *OPModelPromptContext(NSString *goal, NSString *taskId,
        NSDictionary *screen, NSDictionary *modelStatus, NSArray *approvedCapabilities,
        NSDictionary *loopState) {
    NSDictionary *memory = OPMemorySearch(@{
        @"task_id": taskId ?: @"",
        @"query": goal ?: @"",
        @"limit": @5,
        @"suppress_trajectory": @YES,
        @"reason": @"model prompt memory context"
    });
    NSDictionary *context = OPContextSearch(@{
        @"task_id": taskId ?: @"",
        @"query": goal ?: @"",
        @"limit": @5,
        @"suppress_trajectory": @YES,
        @"reason": @"model prompt continuity context"
    });
    return @{
        @"schema": @"openphone.model_prompt_context.v1",
        @"goal": goal ?: @"",
        @"autonomy_mode": @"yolo",
        @"approved_capabilities": approvedCapabilities ?: @[],
        @"model": @{
            @"status": modelStatus[@"status"] ?: @"unknown",
            @"mode": modelStatus[@"mode"] ?: @"broker",
            @"model": modelStatus[@"model"] ?: @""
        },
        @"tools": OPModelToolNames(),
        @"loop": loopState ?: @{},
        @"screen": OPModelScreenSummary(screen ?: @{}),
        @"memory": @{
            @"count": memory[@"count"] ?: @0,
            @"memories": memory[@"memories"] ?: @[]
        },
        @"context": @{
            @"count": context[@"count"] ?: @0,
            @"events": context[@"events"] ?: @[]
        }
    };
}

static NSDictionary *OPModelPromptContextTraceSummary(NSDictionary *context) {
    if (![context isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    NSDictionary *memory = [context[@"memory"] isKindOfClass:[NSDictionary class]]
            ? context[@"memory"] : @{};
    NSDictionary *continuity = [context[@"context"] isKindOfClass:[NSDictionary class]]
            ? context[@"context"] : @{};
    NSArray *tools = [context[@"tools"] isKindOfClass:[NSArray class]]
            ? context[@"tools"] : @[];
    NSArray *approved = [context[@"approved_capabilities"] isKindOfClass:[NSArray class]]
            ? context[@"approved_capabilities"] : @[];
    NSString *goal = [context[@"goal"] isKindOfClass:[NSString class]] ? context[@"goal"] : @"";
    return @{
        @"schema": context[@"schema"] ?: @"openphone.model_prompt_context.v1",
        @"goal_length": @(goal.length),
        @"autonomy_mode": context[@"autonomy_mode"] ?: @"",
        @"tool_count": @(tools.count),
        @"approved_capability_count": @(approved.count),
        @"loop": context[@"loop"] ?: @{},
        @"screen": context[@"screen"] ?: @{},
        @"memory": @{
            @"count": memory[@"count"] ?: @0
        },
        @"context": @{
            @"count": continuity[@"count"] ?: @0
        },
        @"model": context[@"model"] ?: @{}
    };
}

static NSString *OPTruncatedString(NSString *value, NSUInteger limit) {
    if (value.length <= limit) {
        return value ?: @"";
    }
    return [[value substringToIndex:limit] stringByAppendingFormat:@"...<truncated:%lu>",
            (unsigned long)value.length];
}

static NSString *OPModelJSONStringForPrompt(id object, NSUInteger limit) {
    NSString *json = OPJSONString(OPRedactedObject(object ?: @{}, 0));
    return OPTruncatedString(json, limit);
}

static NSString *OPModelPromptText(NSDictionary *requestBody) {
    NSString *goal = [requestBody[@"goal"] isKindOfClass:[NSString class]]
            ? requestBody[@"goal"] : @"";
    NSArray *tools = [requestBody[@"tools"] isKindOfClass:[NSArray class]]
            ? requestBody[@"tools"] : OPModelToolNames();
    NSDictionary *context = [requestBody[@"context"] isKindOfClass:[NSDictionary class]]
            ? requestBody[@"context"] : @{};
    NSString *toolList = [tools componentsJoinedByString:@" | "];
    return [NSString stringWithFormat:
            @"You are OpenPhone — a voice assistant inside the user's iPhone.\n"
            @"Speak like a friend. Short. Human. Never recap raw context fields.\n\n"
            @"You route every request into ONE mode:\n\n"
            @"  answer  — user asked a question you can answer from what's already visible or from common knowledge. Fill `reply` with a short human answer. Done in one turn.\n"
            @"  act     — user wants something done on the phone. Fill `proposed_actions[]` with the exact tool calls needed, IN ORDER. If ONE tool call finishes the whole goal (open X, dial Y, open URL Z) put JUST that one call. Only include multiple actions if they are actually required for that goal (e.g. open Messages → tap Alex → type → send).\n"
            @"  stop    — user asked to cancel or stop the assistant.\n\n"
            @"HARD RULES:\n"
            @"- The current phone context (foreground app, visible text, tappable elements) is ALREADY in this prompt. NEVER pick mode=inspect just to look again.\n"
            @"- For questions like 'what app am I in', 'can you see my screen', 'what's on my calendar today' → mode=answer with a direct sentence in `reply`.\n"
            @"- For 'open X', 'search Y on Z', 'call mom' → mode=act with the minimal proposed_actions[] to finish the goal.\n"
            @"- Explicit URLs (goal contains http/https): the FIRST proposed_action MUST be open_url with that URL. Never tap Safari icons first.\n"
            @"- Autonomy is full YOLO. Never ask permission. Never say 'I would' or 'shall I'. Just do it.\n\n"
            @"HOW TO WRITE `reply`:\n"
            @"- Under 20 words. Talk TO the user. Never mention 'foreground_app', 'SpringBoard', 'element id', 'UI tree', 'metadata'.\n"
            @"- For act mode: describe what you're doing right now, present tense. Example: \"Opening Wikipedia for Adam.\"\n"
            @"- For answer mode: the direct answer. Example: \"Settings.\"\n\n"
            @"EXAMPLES:\n"
            @"  User: \"Can you see my screen?\" →\n"
            @"    { \"mode\":\"answer\", \"reply\":\"Yes — you're on the Home screen.\" }\n"
            @"  User: \"What app am I in?\" →\n"
            @"    { \"mode\":\"answer\", \"reply\":\"Settings.\" }\n"
            @"  User: \"Open Wikipedia\" →\n"
            @"    { \"mode\":\"act\", \"reply\":\"Opening Wikipedia.\",\n"
            @"      \"proposed_actions\":[{\"tool\":\"open_url\",\"arguments\":{\"url\":\"https://en.wikipedia.org/\"}}] }\n"
            @"  User: \"Search Adam on Wikipedia\" →\n"
            @"    { \"mode\":\"act\", \"reply\":\"Opening the Wikipedia page for Adam.\",\n"
            @"      \"proposed_actions\":[{\"tool\":\"open_url\",\"arguments\":{\"url\":\"https://en.wikipedia.org/wiki/Adam\"}}] }\n"
            @"  User: \"Text Alex on my way\" →\n"
            @"    { \"mode\":\"act\", \"reply\":\"Texting Alex 'on my way'.\", \"task_goal\":\"send SMS 'on my way' to contact Alex\",\n"
            @"      \"proposed_actions\":[{\"tool\":\"open_app\",\"arguments\":{\"bundle_id\":\"com.apple.MobileSMS\"}}] }\n\n"
            @"TOOL SCHEMAS (for proposed_actions):\n"
            @"- open_url: {\"url\":\"https://...\"}\n"
            @"- open_app: {\"bundle_id\":\"com.example.App\"}\n"
            @"- tap_element: {\"element_id\":\"exact visible id from the screen context\"}\n"
            @"- tap: {\"x\":num,\"y\":num}\n"
            @"- type_text: {\"text\":\"...\",\"element_id\":\"field id\"}\n"
            @"- swipe: {\"start_x\",\"start_y\",\"end_x\",\"end_y\"}\n"
            @"- home: {}\n\n"
            @"Return ONE JSON object matching this schema — no markdown, no prose outside JSON:\n"
            @"{\"schema\":\"openphone.model_decision.v3\",\"mode\":\"answer|act|stop\",\"reply\":\"user-facing text\",\"task_goal\":\"only if multi-step\",\"proposed_actions\":[{\"tool\":\"...\",\"arguments\":{...}}],\"reason\":\"private, brief\"}\n\n"
            @"Allowed tools inside proposed_actions: %@\n"
            @"User said: %@\n\n"
            @"Current phone context:\n%@",
            toolList,
            goal,
            OPModelJSONStringForPrompt(context, 6000)];
}

static NSString *OPModelBedrockEndpoint(NSDictionary *config, NSString *model) {
    NSString *endpoint = [config[@"endpoint_url"] isKindOfClass:[NSString class]]
            ? config[@"endpoint_url"] : @"";
    if (endpoint.length > 0 && [endpoint rangeOfString:@"/model/"].location != NSNotFound) {
        return endpoint;
    }
    NSString *region = [config[@"region"] isKindOfClass:[NSString class]]
            ? config[@"region"] : @"us-east-1";
    NSString *base = endpoint.length > 0
            ? [endpoint stringByTrimmingCharactersInSet:
                    [NSCharacterSet characterSetWithCharactersInString:@"/"]]
            : [NSString stringWithFormat:@"https://bedrock-runtime.%@.amazonaws.com",
                    region.length > 0 ? region : @"us-east-1"];
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLPathAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@":/?#[]@!$&'()*+,;="];
    NSString *encodedModel = [model stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: model ?: @"";
    return [NSString stringWithFormat:@"%@/model/%@/converse", base, encodedModel];
}

static NSDictionary *OPModelBedrockConverseDecision(NSDictionary *modelStatus,
        NSDictionary *requestBody) {
    NSDictionary *config = OPModelConfig();
    NSString *model = [config[@"model"] isKindOfClass:[NSString class]]
            ? config[@"model"] : @"";
    if (model.length == 0) {
        return OPError(@"model_not_configured");
    }
    NSString *credential = OPModelCredentialValue();
    if (credential.length == 0) {
        return OPError(@"model_credential_missing");
    }
    NSString *endpoint = OPModelBedrockEndpoint(config, model);
    NSURL *url = [NSURL URLWithString:endpoint ?: @""];
    if (!url || !url.scheme || !url.host) {
        return OPError(@"bedrock_endpoint_invalid");
    }
    long long timeoutMs = [modelStatus[@"timeout_ms"] respondsToSelector:@selector(longLongValue)]
            ? [modelStatus[@"timeout_ms"] longLongValue] : 30000;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:MAX(1.0, (NSTimeInterval)timeoutMs / 1000.0)];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", credential]
   forHTTPHeaderField:@"Authorization"];

    NSString *instructions = [requestBody[@"instructions"] isKindOfClass:[NSString class]]
            ? requestBody[@"instructions"] : @"Return exactly one JSON object.";
    NSDictionary *body = @{
        @"system": @[@{@"text": instructions}],
        @"messages": @[@{
            @"role": @"user",
            @"content": @[@{@"text": OPModelPromptText(requestBody)}]
        }],
        @"inferenceConfig": @{
            @"maxTokens": @800,
            @"temperature": @0
        }
    };
    request.HTTPBody = OPCanonicalJSONData(body);

    NSURLResponse *response = nil;
    NSError *error = nil;
    long long startedMs = OPNowMs();
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSData *data = [NSURLConnection sendSynchronousRequest:request
                                         returningResponse:&response
                                                     error:&error];
#pragma clang diagnostic pop
    long long latencyMs = OPNowMs() - startedMs;
    if (error || !data) {
        return OPError([NSString stringWithFormat:@"bedrock_request_failed:%@",
                        error.localizedDescription ?: @"unknown"]);
    }
    NSInteger statusCode = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        statusCode = [(NSHTTPURLResponse *)response statusCode];
    }
    if (statusCode < 200 || statusCode >= 300) {
        return @{
            @"status": @"error",
            @"reason": [NSString stringWithFormat:@"bedrock_http_status:%ld", (long)statusCode],
            @"http_status": @(statusCode),
            @"response_bytes": @(data.length),
            @"source": @"openphone.agentd"
        };
    }
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        return @{
            @"status": @"error",
            @"reason": @"bedrock_response_not_object",
            @"http_status": @(statusCode),
            @"response_bytes": @(data.length),
            @"source": @"openphone.agentd"
        };
    }
    NSDictionary *object = parsed;
    NSDictionary *output = [object[@"output"] isKindOfClass:[NSDictionary class]]
            ? object[@"output"] : @{};
    NSDictionary *message = [output[@"message"] isKindOfClass:[NSDictionary class]]
            ? output[@"message"] : @{};
    NSArray *content = [message[@"content"] isKindOfClass:[NSArray class]]
            ? message[@"content"] : @[];
    NSMutableArray<NSString *> *textParts = [NSMutableArray array];
    for (id blockValue in content) {
        if (![blockValue isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *text = [blockValue[@"text"] isKindOfClass:[NSString class]]
                ? blockValue[@"text"] : @"";
        if (text.length > 0) {
            [textParts addObject:text];
        }
    }
    NSString *decisionText = [[textParts componentsJoinedByString:@"\n"]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (decisionText.length == 0) {
        return @{
            @"status": @"error",
            @"reason": @"bedrock_empty_text",
            @"http_status": @(statusCode),
            @"response_bytes": @(data.length),
            @"source": @"openphone.agentd"
        };
    }
    NSMutableDictionary *result = [@{
        @"status": @"ok",
        @"provider": @"bedrock_converse",
        @"http_status": @(statusCode),
        @"response_bytes": @(data.length),
        @"decision": decisionText,
        @"source": @"openphone.agentd",
        @"metadata": @{
            @"provider": @"bedrock_converse",
            @"provider_backed": @YES,
            @"model": model,
            @"region": config[@"region"] ?: @"us-east-1",
            @"latency_ms": @(latencyMs)
        }
    } mutableCopy];
    if ([object[@"usage"] isKindOfClass:[NSDictionary class]]) {
        result[@"usage"] = object[@"usage"];
    }
    return result;
}

static NSDictionary *OPModelBrokerDecision(NSDictionary *modelStatus, NSDictionary *requestBody) {
    NSDictionary *config = OPModelConfig();
    NSString *endpoint = [config[@"endpoint_url"] isKindOfClass:[NSString class]]
            ? config[@"endpoint_url"] : @"";
    NSURL *url = [NSURL URLWithString:endpoint ?: @""];
    if (!url || !url.scheme || !url.host) {
        return OPError(@"model_endpoint_invalid");
    }
    long long timeoutMs = [modelStatus[@"timeout_ms"] respondsToSelector:@selector(longLongValue)]
            ? [modelStatus[@"timeout_ms"] longLongValue] : 30000;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:MAX(1.0, (NSTimeInterval)timeoutMs / 1000.0)];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSString *credential = OPModelCredentialValue();
    if (credential.length > 0) {
        [request setValue:[NSString stringWithFormat:@"Bearer %@", credential]
       forHTTPHeaderField:@"Authorization"];
    }
    request.HTTPBody = OPCanonicalJSONData(requestBody ?: @{});

    NSURLResponse *response = nil;
    NSError *error = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSData *data = [NSURLConnection sendSynchronousRequest:request
                                         returningResponse:&response
                                                     error:&error];
#pragma clang diagnostic pop
    if (error || !data) {
        return OPError([NSString stringWithFormat:@"model_broker_request_failed:%@",
                        error.localizedDescription ?: @"unknown"]);
    }
    NSInteger statusCode = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        statusCode = [(NSHTTPURLResponse *)response statusCode];
    }
    if (statusCode < 200 || statusCode >= 300) {
        return @{
            @"status": @"error",
            @"reason": [NSString stringWithFormat:@"model_broker_http_status:%ld", (long)statusCode],
            @"http_status": @(statusCode),
            @"response_bytes": @(data.length),
            @"source": @"openphone.agentd"
        };
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return @{
            @"status": @"error",
            @"reason": @"model_broker_response_not_object",
            @"http_status": @(statusCode),
            @"response_bytes": @(data.length),
            @"source": @"openphone.agentd"
        };
    }
    NSDictionary *envelope = object;
    id decision = envelope[@"decision"];
    if (!decision && [envelope[@"decision_json"] isKindOfClass:[NSString class]]) {
        decision = envelope[@"decision_json"];
    }
    if (!decision && ([envelope[@"schema"] isEqualToString:@"openphone.model_decision.v1"] ||
                      [envelope[@"schema"] isEqualToString:@"openphone.model_decision.v2"] ||
                      [envelope[@"schema"] isEqualToString:@"openphone.model_decision.v3"])) {
        decision = envelope;
    }
    if (!decision) {
        return @{
            @"status": @"error",
            @"reason": @"model_broker_missing_decision",
            @"http_status": @(statusCode),
            @"response_bytes": @(data.length),
            @"source": @"openphone.agentd"
        };
    }
    NSMutableDictionary *result = [@{
        @"status": @"ok",
        @"provider": modelStatus[@"mode"] ?: @"broker",
        @"http_status": @(statusCode),
        @"response_bytes": @(data.length),
        @"decision": decision,
        @"source": @"openphone.agentd"
    } mutableCopy];
    if ([envelope[@"usage"] isKindOfClass:[NSDictionary class]]) {
        result[@"usage"] = envelope[@"usage"];
    }
    if ([envelope[@"metadata"] isKindOfClass:[NSDictionary class]]) {
        result[@"metadata"] = envelope[@"metadata"];
    }
    return result;
}

static NSDictionary *OPModelProviderDecision(NSDictionary *modelStatus, NSDictionary *requestBody) {
    NSString *mode = [modelStatus[@"mode"] isKindOfClass:[NSString class]]
            ? modelStatus[@"mode"] : @"broker";
    if ([mode isEqualToString:@"bedrock_converse"]) {
        return OPModelBedrockConverseDecision(modelStatus, requestBody);
    }
    return OPModelBrokerDecision(modelStatus, requestBody);
}

static NSError *OPRealtimeError(NSString *message) {
    return [NSError errorWithDomain:@"OpenPhoneRealtime"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"realtime_error"}];
}

@interface OPRealtimeWebSocket : NSObject
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionWebSocketTask *task;
@end

@implementation OPRealtimeWebSocket

+ (instancetype)connectWithURL:(NSURL *)url bearerToken:(NSString *)bearerToken
                     timeoutMs:(long long)timeoutMs error:(NSError **)errorOut {
    if (!url || bearerToken.length == 0) {
        if (errorOut) {
            *errorOut = OPRealtimeError(@"realtime_url_or_credential_missing");
        }
        return nil;
    }
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = MAX(1.0, (NSTimeInterval)timeoutMs / 1000.0);
    configuration.timeoutIntervalForResource = MAX(1.0, (NSTimeInterval)timeoutMs / 1000.0);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:configuration.timeoutIntervalForRequest];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", bearerToken]
   forHTTPHeaderField:@"Authorization"];
    [request setValue:@"openphone-ios-agentd" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"openphone-ios-local-user" forHTTPHeaderField:@"OpenAI-Safety-Identifier"];
    NSURLSessionWebSocketTask *task = [session webSocketTaskWithRequest:request];
    OPRealtimeWebSocket *socket = [OPRealtimeWebSocket new];
    socket.session = session;
    socket.task = task;
    [task resume];
    return socket;
}

- (BOOL)sendEvent:(NSDictionary *)event timeoutMs:(long long)timeoutMs error:(NSError **)errorOut {
    NSString *text = OPJSONString(event ?: @{});
    NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:text];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *sendError = nil;
    [self.task sendMessage:message completionHandler:^(NSError *error) {
        sendError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(MAX(1LL, timeoutMs) * NSEC_PER_MSEC));
    if (dispatch_semaphore_wait(semaphore, deadline) != 0) {
        if (errorOut) {
            *errorOut = OPRealtimeError(@"realtime_send_timeout");
        }
        return NO;
    }
    if (sendError) {
        if (errorOut) {
            *errorOut = sendError;
        }
        return NO;
    }
    return YES;
}

- (NSDictionary *)readEventWithTimeoutMs:(long long)timeoutMs error:(NSError **)errorOut {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSURLSessionWebSocketMessage *message = nil;
    __block NSError *receiveError = nil;
    [self.task receiveMessageWithCompletionHandler:
            ^(NSURLSessionWebSocketMessage *incoming, NSError *error) {
        message = incoming;
        receiveError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(MAX(1LL, timeoutMs) * NSEC_PER_MSEC));
    if (dispatch_semaphore_wait(semaphore, deadline) != 0) {
        if (errorOut) {
            *errorOut = OPRealtimeError(@"realtime_receive_timeout");
        }
        return nil;
    }
    if (receiveError || !message) {
        if (errorOut) {
            *errorOut = receiveError ?: OPRealtimeError(@"realtime_receive_failed");
        }
        return nil;
    }
    NSString *text = nil;
    if (message.type == NSURLSessionWebSocketMessageTypeString) {
        text = message.string;
    } else if (message.data) {
        text = [[NSString alloc] initWithData:message.data encoding:NSUTF8StringEncoding];
    }
    if (text.length == 0) {
        if (errorOut) {
            *errorOut = OPRealtimeError(@"realtime_empty_message");
        }
        return nil;
    }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![object isKindOfClass:[NSDictionary class]]) {
        if (errorOut) {
            *errorOut = OPRealtimeError(@"realtime_message_not_json_object");
        }
        return nil;
    }
    return object;
}

- (void)close {
    [self.task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    [self.session invalidateAndCancel];
}

@end

static NSDictionary *OPRealtimeProperty(NSString *type, NSString *description) {
    return @{
        @"type": type ?: @"string",
        @"description": description ?: @""
    };
}

static NSDictionary *OPRealtimeParameters(NSDictionary *properties, NSArray *required) {
    return @{
        @"type": @"object",
        @"properties": properties ?: @{},
        @"required": required ?: @[],
        @"additionalProperties": @YES
    };
}

static NSDictionary *OPRealtimeToolDefinition(NSString *name, NSString *description,
        NSDictionary *properties, NSArray *required) {
    return @{
        @"type": @"function",
        @"name": name ?: @"",
        @"description": description ?: @"",
        @"parameters": OPRealtimeParameters(properties, required)
    };
}

static NSArray *OPRealtimeToolDefinitions(void) {
    NSMutableArray *tools = [NSMutableArray array];
    [tools addObject:OPRealtimeToolDefinition(@"get_screen",
            @"Observe the current iPhone screen, foreground app, UI tree, visible text, and screenshot metadata.",
            @{
                @"include_screenshot": OPRealtimeProperty(@"boolean", @"Include screenshot metadata when available."),
                @"include_ui_tree": OPRealtimeProperty(@"boolean", @"Include the daemon's best UI tree."),
                @"include_activity": OPRealtimeProperty(@"boolean", @"Include foreground/activity metadata."),
                @"reason": OPRealtimeProperty(@"string", @"Why this observation is needed.")
            }, @[@"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"tap",
            @"Tap raw screen coordinates.",
            @{
                @"x": OPRealtimeProperty(@"number", @"Screen x coordinate in points."),
                @"y": OPRealtimeProperty(@"number", @"Screen y coordinate in points."),
                @"reason": OPRealtimeProperty(@"string", @"Why this tap should progress the task.")
            }, @[@"x", @"y", @"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"tap_element",
            @"Tap a visible UI element by id from get_screen.",
            @{
                @"element_id": OPRealtimeProperty(@"string", @"Element id from the current UI tree."),
                @"reason": OPRealtimeProperty(@"string", @"Why this element should be tapped.")
            }, @[@"element_id", @"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"long_press",
            @"Long-press raw screen coordinates.",
            @{
                @"x": OPRealtimeProperty(@"number", @"Screen x coordinate in points."),
                @"y": OPRealtimeProperty(@"number", @"Screen y coordinate in points."),
                @"duration_ms": OPRealtimeProperty(@"number", @"Press duration in milliseconds."),
                @"reason": OPRealtimeProperty(@"string", @"Why this long press should progress the task.")
            }, @[@"x", @"y", @"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"swipe",
            @"Swipe from one coordinate to another.",
            @{
                @"start_x": OPRealtimeProperty(@"number", @"Start x coordinate in points."),
                @"start_y": OPRealtimeProperty(@"number", @"Start y coordinate in points."),
                @"end_x": OPRealtimeProperty(@"number", @"End x coordinate in points."),
                @"end_y": OPRealtimeProperty(@"number", @"End y coordinate in points."),
                @"duration_ms": OPRealtimeProperty(@"number", @"Swipe duration in milliseconds."),
                @"reason": OPRealtimeProperty(@"string", @"Why this swipe should progress the task.")
            }, @[@"start_x", @"start_y", @"end_x", @"end_y", @"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"type_text",
            @"Type text into the focused or specified editable field.",
            @{
                @"text": OPRealtimeProperty(@"string", @"Text to enter."),
                @"element_id": OPRealtimeProperty(@"string", @"Optional editable element id from get_screen."),
                @"reason": OPRealtimeProperty(@"string", @"Why this text entry should progress the task.")
            }, @[@"text", @"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"open_app",
            @"Open an installed app by bundle id.",
            @{
                @"bundle_id": OPRealtimeProperty(@"string", @"iOS bundle identifier, for example com.apple.mobilesafari."),
                @"reason": OPRealtimeProperty(@"string", @"Why this app should be opened.")
            }, @[@"bundle_id", @"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"open_url",
            @"Open a URL through iOS.",
            @{
                @"url": OPRealtimeProperty(@"string", @"Absolute URL to open."),
                @"reason": OPRealtimeProperty(@"string", @"Why this URL should be opened.")
            }, @[@"url", @"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"home",
            @"Press the Home gesture/button equivalent.",
            @{@"reason": OPRealtimeProperty(@"string", @"Why returning home should progress the task.")},
            @[@"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"wake_and_home",
            @"Wake the display and return to Home.",
            @{@"reason": OPRealtimeProperty(@"string", @"Why waking/home should progress the task.")},
            @[@"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"wait",
            @"Wait briefly before observing or acting again.",
            @{
                @"duration_ms": OPRealtimeProperty(@"number", @"Wait duration in milliseconds."),
                @"reason": OPRealtimeProperty(@"string", @"Why waiting should progress the task.")
            }, @[@"duration_ms", @"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"clipboard_read",
            @"Read bounded text from the iPhone clipboard.",
            @{
                @"max_chars": OPRealtimeProperty(@"number", @"Maximum clipboard characters to return."),
                @"reason": OPRealtimeProperty(@"string", @"Why copied text is needed for this task.")
            }, @[@"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"clipboard_write",
            @"Write text to the iPhone clipboard.",
            @{
                @"text": OPRealtimeProperty(@"string", @"Text to copy onto the iPhone clipboard."),
                @"reason": OPRealtimeProperty(@"string", @"Why this text should be copied.")
            }, @[@"text", @"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"contacts_search",
            @"Search the iPhone contacts provider for people, organizations, phone numbers, or email addresses.",
            @{
                @"query": OPRealtimeProperty(@"string", @"Contact name, organization, phone, or email to search for."),
                @"limit": OPRealtimeProperty(@"number", @"Maximum result count."),
                @"reason": OPRealtimeProperty(@"string", @"Why contact lookup is needed for this task.")
            }, @[@"query", @"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"calendar_search",
            @"Search the iPhone calendar provider for saved events or schedule context.",
            @{
                @"query": OPRealtimeProperty(@"string", @"Event title, calendar name, location, or notes text to search for."),
                @"start_at_ms": OPRealtimeProperty(@"number", @"Optional Unix epoch milliseconds lower bound for event start time."),
                @"end_at_ms": OPRealtimeProperty(@"number", @"Optional Unix epoch milliseconds upper bound for event start time."),
                @"limit": OPRealtimeProperty(@"number", @"Maximum result count."),
                @"reason": OPRealtimeProperty(@"string", @"Why calendar lookup is needed for this task.")
            }, @[@"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"calls_search",
            @"Search the iPhone call-history provider for recent phone or FaceTime calls.",
            @{
                @"query": OPRealtimeProperty(@"string", @"Phone number, caller name, service, direction, or call type to search for."),
                @"start_at_ms": OPRealtimeProperty(@"number", @"Optional Unix epoch milliseconds lower bound for call start time."),
                @"end_at_ms": OPRealtimeProperty(@"number", @"Optional Unix epoch milliseconds upper bound for call start time."),
                @"limit": OPRealtimeProperty(@"number", @"Maximum result count."),
                @"reason": OPRealtimeProperty(@"string", @"Why call-history lookup is needed for this task.")
            }, @[@"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"messages_search",
            @"Search the iPhone SMS/iMessage provider for saved message context.",
            @{
                @"query": OPRealtimeProperty(@"string", @"Message text, phone number, email, handle, or service to search for."),
                @"start_at_ms": OPRealtimeProperty(@"number", @"Optional Unix epoch milliseconds lower bound for message time."),
                @"end_at_ms": OPRealtimeProperty(@"number", @"Optional Unix epoch milliseconds upper bound for message time."),
                @"limit": OPRealtimeProperty(@"number", @"Maximum result count."),
                @"reason": OPRealtimeProperty(@"string", @"Why message lookup is needed for this task.")
            }, @[@"reason"])];
    [tools addObject:OPRealtimeToolDefinition(@"memory_save",
            @"Save an explicit durable user preference or fact.",
            @{
                @"text": OPRealtimeProperty(@"string", @"Memory text to save."),
                @"type": OPRealtimeProperty(@"string", @"Memory type such as preference, fact, or instruction."),
                @"subject": OPRealtimeProperty(@"string", @"Optional memory subject."),
                @"reason": OPRealtimeProperty(@"string", @"Why this should be remembered.")
            }, @[@"text"])];
    [tools addObject:OPRealtimeToolDefinition(@"memory_search",
            @"Search durable memories for task-relevant user preferences or facts.",
            @{
                @"query": OPRealtimeProperty(@"string", @"Search query."),
                @"limit": OPRealtimeProperty(@"number", @"Maximum result count."),
                @"reason": OPRealtimeProperty(@"string", @"Why memory context may help.")
            }, @[@"query"])];
    [tools addObject:OPRealtimeToolDefinition(@"context_search",
            @"Search recent task/conversation context.",
            @{
                @"query": OPRealtimeProperty(@"string", @"Search query."),
                @"limit": OPRealtimeProperty(@"number", @"Maximum result count."),
                @"reason": OPRealtimeProperty(@"string", @"Why prior context may help.")
            }, @[@"query"])];
    [tools addObject:OPRealtimeToolDefinition(@"finish_task",
            @"Mark the task complete only when the requested result is visible or otherwise verified.",
            @{@"summary": OPRealtimeProperty(@"string", @"Brief completion summary.")},
            @[@"summary"])];
    [tools addObject:OPRealtimeToolDefinition(@"fail_task",
            @"Mark the task blocked or failed with a precise reason.",
            @{@"reason": OPRealtimeProperty(@"string", @"Precise blocker or failure reason.")},
            @[@"reason"])];
    return tools;
}

static NSString *OPRealtimeDeviceTimeContext(void) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"EEE yyyy-MM-dd HH:mm zzz";
    return [NSString stringWithFormat:@"%@ (unix_ms %lld)",
            [formatter stringFromDate:[NSDate date]], OPNowMs()];
}

static NSString *OPRealtimeInstructions(NSString *mode) {
    BOOL realtime2 = [mode isEqualToString:@"openai_realtime2"];
    return [NSString stringWithFormat:
            @"You are OpenPhone Agent, a persistent mobile GUI agent running inside an iPhone. "
            @"The iPhone daemon is the runtime authority. You can control the phone only through the provided function tools. "
            @"Autonomy mode is full YOLO: the user's task authorizes registered tools for this task. Do not ask for OpenPhone confirmation. "
            @"Be execution-biased: observe, choose one useful action, inspect the result, recover from no-ops, and continue until the task is visibly complete or truly blocked. "
            @"First call get_screen with include_ui_tree=true, include_activity=true, and include_screenshot=true before operating visible UI unless the next tool is obviously read-only memory/context. "
            @"Use tap_element when an element id exists; use raw coordinates only when the UI tree is sparse or unlabeled. "
            @"Use open_url for URLs instead of typing them into a browser field. Use memory_search/context_search when prior phone context would help. "
            @"Use clipboard_read when the task depends on copied text, clipboard_write when the user asks to copy text, contacts_search when the task needs a saved person, organization, phone, or email, calendar_search when the task needs saved events or schedule context, calls_search when the task needs recent call-history context, and messages_search when the task needs saved SMS/iMessage context. "
            @"Do not narrate a plan or answer with plain text when a phone tool can progress the task. "
            @"For broad choices like random, any, best, or surprise me, choose a reasonable visible/default option yourself. "
            @"Call finish_task only when the visible screen or tool result verifies the requested outcome. "
            @"Never say Done unless finish_task has been called.%@",
            realtime2 ? @" Realtime 2 should use low reasoning effort and concise tool selection." : @""];
}

static NSString *OPRealtimeInitialTaskPrompt(NSString *goal) {
    return [NSString stringWithFormat:
            @"Start this iPhone task and keep working until it is visibly complete or blocked. "
            @"Device time: %@. Compute dates and deadlines from this device time. "
            @"User goal: %@",
            OPRealtimeDeviceTimeContext(), goal ?: @""];
}

static NSString *OPRealtimeTextOnlyCorrectionPrompt(NSString *modelText) {
    return [NSString stringWithFormat:
            @"You replied with text instead of taking a phone-agent step: %@\n\n"
            @"Choose exactly one tool call now. If you have not observed the phone, call get_screen. "
            @"If the task is already complete, call finish_task. If no concrete step exists, call fail_task.",
            modelText ?: @""];
}

static NSURL *OPRealtimeURL(NSDictionary *config, NSString *model) {
    NSString *endpoint = [config[@"endpoint_url"] isKindOfClass:[NSString class]]
            ? config[@"endpoint_url"] : @"";
    if (endpoint.length > 0) {
        return [NSURL URLWithString:endpoint];
    }
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"&=+"];
    NSString *encoded = [model stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: model ?: @"";
    return [NSURL URLWithString:[NSString stringWithFormat:
            @"wss://api.openai.com/v1/realtime?model=%@", encoded]];
}

static NSDictionary *OPRealtimeSessionUpdateEvent(NSString *mode, NSString *model) {
    NSMutableDictionary *session = [@{
        @"type": @"realtime",
        @"model": model ?: @"",
        @"instructions": OPRealtimeInstructions(mode ?: @"openai_realtime"),
        @"output_modalities": @[@"text"],
        @"tool_choice": @"auto",
        @"tools": OPRealtimeToolDefinitions()
    } mutableCopy];
    if ([mode isEqualToString:@"openai_realtime2"] ||
            [model isEqualToString:OPOpenAIRealtime2Model]) {
        session[@"reasoning"] = @{@"effort": @"low"};
    }
    return @{
        @"type": @"session.update",
        @"session": session
    };
}

// Streaming session config: accepts pcm16 mic audio and lets the server run
// voice-activity detection so end-of-turn is decided server-side instead of by
// our local record-then-transcribe VAD. Output stays text so the existing tool
// loop is unchanged; the agent speaks through the island, not TTS.
static NSDictionary *OPRealtimeStreamingSessionUpdateEvent(NSString *mode, NSString *model,
        long long sampleRateHz) {
    NSMutableDictionary *session = [@{
        @"type": @"realtime",
        @"model": model ?: @"",
        @"instructions": OPRealtimeInstructions(mode ?: @"openai_realtime2"),
        @"output_modalities": @[@"text"],
        @"tool_choice": @"auto",
        @"tools": OPRealtimeToolDefinitions(),
        @"audio": @{
            @"input": @{
                @"format": @{
                    @"type": @"audio/pcm",
                    @"rate": @(sampleRateHz > 0 ? sampleRateHz : 16000)
                },
                @"turn_detection": @{
                    @"type": @"server_vad",
                    @"threshold": @0.5,
                    @"prefix_padding_ms": @300,
                    @"silence_duration_ms": @700,
                    @"create_response": @YES
                }
            }
        }
    } mutableCopy];
    if ([mode isEqualToString:@"openai_realtime2"] ||
            [model isEqualToString:OPOpenAIRealtime2Model]) {
        session[@"reasoning"] = @{@"effort": @"low"};
    }
    return @{
        @"type": @"session.update",
        @"session": session
    };
}

static NSDictionary *OPRealtimeAudioAppendEvent(NSString *base64Audio) {
    return @{
        @"type": @"input_audio_buffer.append",
        @"audio": base64Audio ?: @""
    };
}

static NSDictionary *OPRealtimeResponseCreateEvent(BOOL requireTool) {
    NSMutableDictionary *response = [@{
        @"output_modalities": @[@"text"]
    } mutableCopy];
    if (requireTool) {
        response[@"tool_choice"] = @"required";
    }
    return @{
        @"type": @"response.create",
        @"response": response
    };
}

static BOOL OPRealtimeSendUserMessage(OPRealtimeWebSocket *socket, NSString *text,
        long long timeoutMs, NSError **errorOut) {
    NSDictionary *event = @{
        @"type": @"conversation.item.create",
        @"item": @{
            @"type": @"message",
            @"role": @"user",
            @"content": @[@{
                @"type": @"input_text",
                @"text": text ?: @""
            }]
        }
    };
    return [socket sendEvent:event timeoutMs:timeoutMs error:errorOut];
}

static BOOL OPRealtimeSendFunctionOutput(OPRealtimeWebSocket *socket, NSString *callId,
        NSDictionary *toolResult, long long timeoutMs, NSError **errorOut) {
    NSString *output = OPJSONString(OPRedactedObject(toolResult ?: @{}, 0));
    NSDictionary *event = @{
        @"type": @"conversation.item.create",
        @"item": @{
            @"type": @"function_call_output",
            @"call_id": callId ?: @"",
            @"output": output ?: @"{}"
        }
    };
    return [socket sendEvent:event timeoutMs:timeoutMs error:errorOut];
}

static BOOL OPRealtimeSendScreenFollowupIfUseful(OPRealtimeWebSocket *socket,
        NSString *toolName, NSDictionary *toolResult, long long timeoutMs, NSError **errorOut) {
    if (![toolName isEqualToString:@"get_screen"]) {
        return YES;
    }
    NSString *text = [NSString stringWithFormat:@"Latest iPhone screen observation:\n%@",
            OPJSONString(OPRedactedObject(toolResult ?: @{}, 0))];
    return OPRealtimeSendUserMessage(socket, text, timeoutMs, errorOut);
}

static NSString *OPRealtimeStringFromValue(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if (value) {
        return OPJSONString(value);
    }
    return @"";
}

static NSDictionary *OPRealtimeFunctionCallFromEvent(NSDictionary *event) {
    NSString *type = [event[@"type"] isKindOfClass:[NSString class]] ? event[@"type"] : @"";
    if ([type isEqualToString:@"response.function_call_arguments.done"]) {
        return @{
            @"call_id": OPRealtimeStringFromValue(event[@"call_id"]),
            @"name": OPRealtimeStringFromValue(event[@"name"]),
            @"arguments": OPRealtimeStringFromValue(event[@"arguments"])
        };
    }
    if ([type isEqualToString:@"response.output_item.done"]) {
        NSDictionary *item = [event[@"item"] isKindOfClass:[NSDictionary class]]
                ? event[@"item"] : @{};
        if ([item[@"type"] isEqualToString:@"function_call"]) {
            return @{
                @"call_id": OPRealtimeStringFromValue(item[@"call_id"]),
                @"name": OPRealtimeStringFromValue(item[@"name"]),
                @"arguments": OPRealtimeStringFromValue(item[@"arguments"])
            };
        }
    }
    return nil;
}

static void OPRealtimeAddOrUpgradeCall(NSMutableArray *calls, NSDictionary *incoming) {
    NSString *callId = [incoming[@"call_id"] isKindOfClass:[NSString class]]
            ? incoming[@"call_id"] : @"";
    NSString *name = [incoming[@"name"] isKindOfClass:[NSString class]]
            ? incoming[@"name"] : @"";
    if (callId.length == 0 || name.length == 0) {
        return;
    }
    NSString *incomingArguments = [incoming[@"arguments"] isKindOfClass:[NSString class]]
            ? incoming[@"arguments"] : @"";
    for (NSUInteger i = 0; i < calls.count; i++) {
        NSDictionary *existing = [calls[i] isKindOfClass:[NSDictionary class]] ? calls[i] : @{};
        NSString *existingCallId = [existing[@"call_id"] isKindOfClass:[NSString class]]
                ? existing[@"call_id"] : @"";
        NSString *existingArguments = [existing[@"arguments"] isKindOfClass:[NSString class]]
                ? existing[@"arguments"] : @"";
        if ([existingCallId isEqualToString:callId]) {
            if (existingArguments.length == 0 && incomingArguments.length > 0) {
                calls[i] = incoming;
            }
            return;
        }
    }
    [calls addObject:incoming];
}

static NSString *OPRealtimeTextFromMessageItem(NSDictionary *item) {
    NSArray *content = [item[@"content"] isKindOfClass:[NSArray class]]
            ? item[@"content"] : @[];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (id value in content) {
        if (![value isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *part = value;
        NSString *text = [part[@"text"] isKindOfClass:[NSString class]]
                ? part[@"text"] : ([part[@"transcript"] isKindOfClass:[NSString class]]
                ? part[@"transcript"] : @"");
        if (text.length > 0) {
            [parts addObject:text];
        }
    }
    return [parts componentsJoinedByString:@"\n"];
}

static void OPRealtimeCollectResponseDone(NSDictionary *response, NSMutableArray *calls,
        NSMutableString *finalText) {
    NSArray *output = [response[@"output"] isKindOfClass:[NSArray class]]
            ? response[@"output"] : @[];
    for (id value in output) {
        if (![value isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *item = value;
        if ([item[@"type"] isEqualToString:@"function_call"]) {
            OPRealtimeAddOrUpgradeCall(calls, @{
                @"call_id": OPRealtimeStringFromValue(item[@"call_id"]),
                @"name": OPRealtimeStringFromValue(item[@"name"]),
                @"arguments": OPRealtimeStringFromValue(item[@"arguments"])
            });
        } else if ([item[@"type"] isEqualToString:@"message"]) {
            NSString *text = OPRealtimeTextFromMessageItem(item);
            if (text.length > 0) {
                if (finalText.length > 0) {
                    [finalText appendString:@"\n"];
                }
                [finalText appendString:text];
            }
        }
    }
}

static NSDictionary *OPRealtimeWaitForEventType(OPRealtimeWebSocket *socket,
        NSString *expectedType, long long timeoutMs) {
    long long deadlineMs = OPNowMs() + timeoutMs;
    while (OPNowMs() < deadlineMs) {
        NSError *error = nil;
        NSDictionary *event = [socket readEventWithTimeoutMs:MAX(1, deadlineMs - OPNowMs())
                                                       error:&error];
        if (!event) {
            return OPError([NSString stringWithFormat:@"realtime_read_failed:%@",
                    error.localizedDescription ?: @"unknown"]);
        }
        NSString *type = [event[@"type"] isKindOfClass:[NSString class]] ? event[@"type"] : @"";
        if ([type isEqualToString:expectedType]) {
            return @{@"status": @"ok", @"event": event};
        }
        if ([type isEqualToString:@"error"]) {
            return @{
                @"status": @"error",
                @"reason": @"realtime_error_event",
                @"event": event,
                @"source": @"openphone.agentd"
            };
        }
    }
    return OPError([NSString stringWithFormat:@"realtime_wait_timeout:%@", expectedType ?: @""]);
}

static NSDictionary *OPRealtimeWaitForTurn(OPRealtimeWebSocket *socket, long long timeoutMs) {
    NSMutableArray *calls = [NSMutableArray array];
    NSMutableString *finalText = [NSMutableString string];
    NSMutableString *inputTranscript = [NSMutableString string];
    long long deadlineMs = OPNowMs() + timeoutMs;
    while (OPNowMs() < deadlineMs) {
        NSError *error = nil;
        NSDictionary *event = [socket readEventWithTimeoutMs:MAX(1, deadlineMs - OPNowMs())
                                                       error:&error];
        if (!event) {
            return OPError([NSString stringWithFormat:@"realtime_read_failed:%@",
                    error.localizedDescription ?: @"unknown"]);
        }
        NSString *type = [event[@"type"] isKindOfClass:[NSString class]] ? event[@"type"] : @"";
        if ([type isEqualToString:@"error"]) {
            return @{
                @"status": @"error",
                @"reason": @"realtime_error_event",
                @"event": event,
                @"source": @"openphone.agentd"
            };
        }
        // Server-VAD transcript of the user's own speech (streaming mode). Used
        // to persist the voice turn and to seed the island transcript line.
        if ([type isEqualToString:@"conversation.item.input_audio_transcription.completed"]) {
            NSString *transcript = [event[@"transcript"] isKindOfClass:[NSString class]]
                    ? event[@"transcript"] : @"";
            if (transcript.length > 0) {
                if (inputTranscript.length > 0) {
                    [inputTranscript appendString:@" "];
                }
                [inputTranscript appendString:transcript];
            }
        }
        NSDictionary *call = OPRealtimeFunctionCallFromEvent(event);
        if (call) {
            OPRealtimeAddOrUpgradeCall(calls, call);
        }
        if ([type isEqualToString:@"response.output_text.done"] ||
                [type isEqualToString:@"response.text.done"]) {
            NSString *text = [event[@"text"] isKindOfClass:[NSString class]]
                    ? event[@"text"] : ([event[@"content"] isKindOfClass:[NSString class]]
                    ? event[@"content"] : @"");
            if (text.length > 0) {
                if (finalText.length > 0) {
                    [finalText appendString:@"\n"];
                }
                [finalText appendString:text];
            }
        }
        if ([type isEqualToString:@"response.done"]) {
            NSDictionary *response = [event[@"response"] isKindOfClass:[NSDictionary class]]
                    ? event[@"response"] : @{};
            OPRealtimeCollectResponseDone(response, calls, finalText);
            return @{
                @"status": @"ok",
                @"function_calls": calls,
                @"final_text": finalText ?: @"",
                @"input_transcript": inputTranscript ?: @""
            };
        }
    }
    return OPError(@"realtime_turn_timeout");
}

static NSDictionary *OPRealtimeArgumentsFromString(NSString *arguments) {
    if (arguments.length == 0) {
        return @{};
    }
    NSData *data = [arguments dataUsingEncoding:NSUTF8StringEncoding];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:[NSDictionary class]] ? object : @{};
}

static NSDictionary *OPRealtimeDecisionFromCall(NSDictionary *call) {
    NSString *tool = [call[@"name"] isKindOfClass:[NSString class]] ? call[@"name"] : @"";
    NSString *argumentsString = [call[@"arguments"] isKindOfClass:[NSString class]]
            ? call[@"arguments"] : @"";
    NSMutableDictionary *arguments = [OPRealtimeArgumentsFromString(argumentsString) mutableCopy];
    if (![tool isEqualToString:@"finish_task"] && ![tool isEqualToString:@"fail_task"] &&
            ![arguments[@"reason"] isKindOfClass:[NSString class]]) {
        arguments[@"reason"] = @"Continue the active iPhone task.";
    }
    return @{
        @"schema": @"openphone.model_decision.v1",
        @"thought": @"Realtime tool call.",
        @"tool": tool ?: @"",
        @"arguments": arguments ?: @{},
        @"expected_visible_change": [arguments[@"expected_visible_change"] isKindOfClass:[NSString class]]
                ? arguments[@"expected_visible_change"] : @"",
        @"confidence": @0.8
    };
}

static NSDictionary *OPModelDecisionFromObject(id object, NSString **errorOut) {
    if (![object isKindOfClass:[NSDictionary class]]) {
        if (errorOut) {
            *errorOut = @"decision_not_object";
        }
        return nil;
    }
    NSDictionary *decision = object;
    NSString *schema = [decision[@"schema"] isKindOfClass:[NSString class]]
            ? decision[@"schema"] : @"";
    if (![schema isEqualToString:@"openphone.model_decision.v1"] &&
            ![schema isEqualToString:@"openphone.model_decision.v2"] &&
            ![schema isEqualToString:@"openphone.model_decision.v3"]) {
        if (errorOut) {
            *errorOut = @"invalid_decision_schema";
        }
        return nil;
    }
    // v3 router decisions don't need a `tool` field — they carry mode/reply
    // instead. Short-circuit here so the tool validation below doesn't reject.
    if ([schema isEqualToString:@"openphone.model_decision.v3"]) {
        return decision;
    }
    NSString *tool = [decision[@"tool"] isKindOfClass:[NSString class]] ? decision[@"tool"] : @"";
    if (![OPModelToolNames() containsObject:tool]) {
        if (errorOut) {
            *errorOut = tool.length > 0 ? @"unknown_model_tool" : @"missing_model_tool";
        }
        return nil;
    }
    NSDictionary *arguments = [decision[@"arguments"] isKindOfClass:[NSDictionary class]]
            ? decision[@"arguments"] : @{};
    NSString *expected = [decision[@"expected_visible_change"] isKindOfClass:[NSString class]]
            ? decision[@"expected_visible_change"] : @"";
    if (OPModelToolDrivesUI(tool) && expected.length == 0) {
        if (errorOut) {
            *errorOut = @"missing_expected_visible_change";
        }
        return nil;
    }
    NSMutableDictionary *parsed = [NSMutableDictionary dictionary];
    parsed[@"schema"] = schema;
    parsed[@"tool"] = tool;
    parsed[@"arguments"] = arguments;
    parsed[@"expected_visible_change"] = expected;
    if ([decision[@"thought"] isKindOfClass:[NSString class]]) {
        NSString *thought = decision[@"thought"];
        parsed[@"thought"] = thought.length > 400
                ? [[thought substringToIndex:400] stringByAppendingString:@"..."] : thought;
    }
    if ([decision[@"confidence"] respondsToSelector:@selector(doubleValue)]) {
        double confidence = [decision[@"confidence"] doubleValue];
        parsed[@"confidence"] = @(MAX(0.0, MIN(confidence, 1.0)));
    }
    if ([decision[@"memory_relevance"] isKindOfClass:[NSString class]]) {
        parsed[@"memory_relevance"] = decision[@"memory_relevance"];
    }
    return parsed;
}

static id OPModelJSONObjectFromString(NSString *string, NSString **errorOut) {
    if (string.length == 0) {
        if (errorOut) {
            *errorOut = @"empty_json";
        }
        return nil;
    }
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        if (errorOut) {
            *errorOut = @"json_encoding_failed";
        }
        return nil;
    }
    NSError *jsonError = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (!object && errorOut) {
        *errorOut = jsonError.localizedDescription.length > 0
                ? [NSString stringWithFormat:@"invalid_json:%@", jsonError.localizedDescription]
                : @"invalid_json";
    }
    return object;
}

static NSString *OPModelExtractBalancedJSONObject(NSString *string) {
    if (string.length == 0) {
        return @"";
    }
    BOOL inString = NO;
    BOOL escaped = NO;
    NSInteger depth = 0;
    NSUInteger start = NSNotFound;
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar ch = [string characterAtIndex:i];
        if (inString) {
            if (escaped) {
                escaped = NO;
            } else if (ch == '\\') {
                escaped = YES;
            } else if (ch == '"') {
                inString = NO;
            }
            continue;
        }
        if (ch == '"') {
            inString = YES;
            continue;
        }
        if (ch == '{') {
            if (depth == 0) {
                start = i;
            }
            depth += 1;
            continue;
        }
        if (ch == '}' && depth > 0) {
            depth -= 1;
            if (depth == 0 && start != NSNotFound) {
                return [string substringWithRange:NSMakeRange(start, i - start + 1)];
            }
        }
    }
    return @"";
}

static NSDictionary *OPModelDecisionFromString(NSString *string, NSString **errorOut,
        NSString **repairStrategyOut) {
    if (repairStrategyOut) {
        *repairStrategyOut = @"";
    }
    NSString *rawError = nil;
    id rawObject = OPModelJSONObjectFromString(string, &rawError);
    if (rawObject) {
        return OPModelDecisionFromObject(rawObject, errorOut);
    }
    NSString *candidate = OPModelExtractBalancedJSONObject(string);
    if (candidate.length == 0 || [candidate isEqualToString:string]) {
        if (errorOut) {
            *errorOut = rawError.length > 0 ? rawError : @"invalid_json";
        }
        return nil;
    }
    NSString *repairJsonError = nil;
    id repairedObject = OPModelJSONObjectFromString(candidate, &repairJsonError);
    NSString *decisionError = nil;
    NSDictionary *decision = OPModelDecisionFromObject(repairedObject, &decisionError);
    if (!decision) {
        if (errorOut) {
            *errorOut = decisionError.length > 0
                    ? decisionError
                    : (repairJsonError.length > 0 ? repairJsonError : @"repair_failed");
        }
        return nil;
    }
    if (repairStrategyOut) {
        *repairStrategyOut = @"balanced_json_object";
    }
    return decision;
}

static NSDictionary *OPModelExecuteDecision(NSDictionary *decision, NSString *taskId,
        NSArray *approvedCapabilities) {
    NSString *tool = decision[@"tool"] ?: @"";
    NSString *capability = OPModelToolCapability(tool);
    if (![approvedCapabilities containsObject:capability]) {
        return @{
            @"status": @"error",
            @"state": @"tool.denied.capability",
            @"tool": tool,
            @"capability": capability,
            @"reason": @"capability_not_approved",
            @"source": @"openphone.agentd"
        };
    }
    NSDictionary *arguments = [decision[@"arguments"] isKindOfClass:[NSDictionary class]]
            ? decision[@"arguments"] : @{};
    NSMutableDictionary *toolRequest = [arguments mutableCopy];
    toolRequest[@"task_id"] = taskId ?: @"";
    if ([tool isEqualToString:@"get_screen"]) {
        toolRequest[@"include_screenshot"] = toolRequest[@"include_screenshot"] ?: @YES;
        toolRequest[@"include_activity"] = @YES;
        toolRequest[@"include_ui_tree"] = @YES;
        toolRequest[@"compact_trajectory"] = @YES;
        toolRequest[@"reason"] = toolRequest[@"reason"] ?: @"model decision observation";
        return OPModelCompactScreenForLoop(OPGetScreen(toolRequest));
    }
    if ([tool isEqualToString:@"memory_save"]) {
        toolRequest[@"reason"] = toolRequest[@"reason"] ?: @"model decision memory_save";
        return OPMemorySave(toolRequest);
    }
    if ([tool isEqualToString:@"memory_search"]) {
        toolRequest[@"reason"] = toolRequest[@"reason"] ?: @"model decision memory_search";
        return OPMemorySearch(toolRequest);
    }
    if ([tool isEqualToString:@"context_search"]) {
        toolRequest[@"reason"] = toolRequest[@"reason"] ?: @"model decision context_search";
        return OPContextSearch(toolRequest);
    }
    if ([tool isEqualToString:@"clipboard_read"]) {
        toolRequest[@"reason"] = toolRequest[@"reason"] ?: @"model decision clipboard_read";
        return OPClipboardRead(toolRequest);
    }
    if ([tool isEqualToString:@"clipboard_write"]) {
        toolRequest[@"reason"] = toolRequest[@"reason"] ?: @"model decision clipboard_write";
        return OPClipboardWrite(toolRequest);
    }
    if ([tool isEqualToString:@"contacts_search"]) {
        toolRequest[@"reason"] = toolRequest[@"reason"] ?: @"model decision contacts_search";
        return OPContactsSearch(toolRequest);
    }
    if ([tool isEqualToString:@"calendar_search"]) {
        toolRequest[@"reason"] = toolRequest[@"reason"] ?: @"model decision calendar_search";
        return OPCalendarSearch(toolRequest);
    }
    if ([tool isEqualToString:@"calls_search"]) {
        toolRequest[@"reason"] = toolRequest[@"reason"] ?: @"model decision calls_search";
        return OPCallsSearch(toolRequest);
    }
    if ([tool isEqualToString:@"messages_search"]) {
        toolRequest[@"reason"] = toolRequest[@"reason"] ?: @"model decision messages_search";
        return OPMessagesSearch(toolRequest);
    }
    if ([tool isEqualToString:@"finish_task"]) {
        NSString *summary = OPStringFromRequest(toolRequest, @"summary",
                OPStringFromRequest(toolRequest, @"result", @""));
        if (summary.length == 0) {
            summary = @"Task finished.";
        }
        return @{
            @"status": @"ok",
            @"state": @"task.finished",
            @"task_id": taskId ?: @"",
            @"summary": summary,
            @"source": @"openphone.agentd"
        };
    }
    if ([tool isEqualToString:@"fail_task"]) {
        NSString *reason = OPStringFromRequest(toolRequest, @"reason",
                OPStringFromRequest(toolRequest, @"summary",
                OPStringFromRequest(toolRequest, @"result", @"")));
        if (reason.length == 0) {
            reason = @"Task failed.";
        }
        return @{
            @"status": @"ok",
            @"state": @"task.failed",
            @"task_id": taskId ?: @"",
            @"reason": reason,
            @"source": @"openphone.agentd"
        };
    }
    NSMutableDictionary *action = [arguments mutableCopy];
    action[@"type"] = tool;
    return OPExecuteAction(@{
        @"command": @"execute_action",
        @"task_id": taskId ?: @"",
        @"action": action
    });
}

static NSDictionary *OPModelVerificationState(NSString *tool, NSDictionary *toolResult,
        NSDictionary *beforeScreen, NSDictionary *afterScreen, NSString *expectedVisibleChange) {
    if (!OPModelToolDrivesUI(tool)) {
        return @{
            @"status": @"not_required",
            @"reason": @"non_ui_tool"
        };
    }
    NSString *state = [toolResult[@"state"] isKindOfClass:[NSString class]]
            ? toolResult[@"state"] : @"";
    BOOL toolOK = [toolResult[@"status"] isEqualToString:@"ok"] ||
            [state isEqualToString:@"action.executed"];
    NSDictionary *delta = OPModelScreenDelta(beforeScreen ?: @{}, afterScreen ?: @{});
    NSDictionary *providerVerification = [toolResult[@"verification"] isKindOfClass:[NSDictionary class]]
            ? toolResult[@"verification"] : @{};
    NSString *userFacingStatus = [toolResult[@"user_facing_status"] isKindOfClass:[NSString class]]
            ? toolResult[@"user_facing_status"] : @"";
    if (!toolOK) {
        return @{
            @"status": @"failed",
            @"reason": toolResult[@"detail"] ?: toolResult[@"reason"] ?: @"tool_failed",
            @"source": @"tool_result",
            @"expected_visible_change": expectedVisibleChange ?: @"",
            @"screen_state": afterScreen[@"state"] ?: @"",
            @"screen_delta": delta
        };
    }
    if ([userFacingStatus isEqualToString:@"verified"] ||
            [userFacingStatus isEqualToString:@"success"] ||
            [providerVerification[@"status"] isEqualToString:@"verified"]) {
        return @{
            @"status": @"verified",
            @"reason": @"provider_verified_visible_effect",
            @"source": providerVerification[@"source"] ?: @"provider_verification",
            @"expected_visible_change": expectedVisibleChange ?: @"",
            @"screen_state": afterScreen[@"state"] ?: @"",
            @"screen_delta": delta
        };
    }
    BOOL changed = [delta[@"status"] isEqualToString:@"changed"];
    BOOL strongSignal = [delta[@"strong_signal"] boolValue];
    if (changed && strongSignal) {
        return @{
            @"status": @"verified",
            @"reason": @"observed_visible_screen_change",
            @"source": @"before_after_screen_delta",
            @"expected_visible_change": expectedVisibleChange ?: @"",
            @"screen_state": afterScreen[@"state"] ?: @"",
            @"screen_delta": delta
        };
    }
    if (changed) {
        return @{
            @"status": @"observed_change",
            @"reason": @"observed_screenshot_or_metadata_change",
            @"source": @"before_after_screen_delta",
            @"expected_visible_change": expectedVisibleChange ?: @"",
            @"screen_state": afterScreen[@"state"] ?: @"",
            @"screen_delta": delta
        };
    }
    return @{
        @"status": @"unverified_dispatch_only",
        @"reason": userFacingStatus.length > 0 ? userFacingStatus : @"visible_effect_not_proven",
        @"source": providerVerification[@"source"] ?: @"provider_dispatch",
        @"expected_visible_change": expectedVisibleChange ?: @"",
        @"screen_state": afterScreen[@"state"] ?: @"",
        @"screen_delta": delta
    };
}

static NSDictionary *OPRunOpenAIRealtimeTask(NSDictionary *request) {
    long long startedMs = OPNowMs();
    NSString *goal = OPStringFromRequest(request, @"goal", @"");
    NSArray *approved = [request[@"approved_capabilities"] isKindOfClass:[NSArray class]]
            ? request[@"approved_capabilities"] : OPFullYoloCapabilities();
    NSDictionary *modelStatus = OPModelStatusDictionary();
    NSString *mode = [modelStatus[@"mode"] isKindOfClass:[NSString class]]
            ? modelStatus[@"mode"] : @"broker";
    if (!OPModelModeIsOpenAIRealtime(mode)) {
        return OPError(@"model_mode_not_openai_realtime");
    }
    if (![modelStatus[@"status"] isEqualToString:@"ready"]) {
        return OPError(@"model_provider_not_configured");
    }

    long long configuredMaxSteps = [modelStatus[@"max_steps"] respondsToSelector:@selector(longLongValue)]
            ? [modelStatus[@"max_steps"] longLongValue] : 25;
    long long configuredMaxDuration = [modelStatus[@"max_duration_ms"] respondsToSelector:@selector(longLongValue)]
            ? [modelStatus[@"max_duration_ms"] longLongValue] : 120000;
    long long timeoutMs = [modelStatus[@"timeout_ms"] respondsToSelector:@selector(longLongValue)]
            ? [modelStatus[@"timeout_ms"] longLongValue] : 30000;
    long long maxSteps = OPLongLongFromRequest(request, @"max_steps", configuredMaxSteps, 1, 120);
    long long maxDurationMs = OPLongLongFromRequest(request, @"max_duration_ms",
            configuredMaxDuration, 1000, 3300000);
    NSDictionary *limits = @{
        @"max_steps": @(maxSteps),
        @"max_duration_ms": @(maxDurationMs),
        @"max_tool_errors": @2,
        @"max_unverified_ui_actions": @2,
        @"max_text_only_turns": @3
    };

    NSString *requestedTaskId = OPStringFromRequest(request, @"task_id", @"");
    BOOL adoptedTask = NO;
    NSDictionary *task = nil;
    if (requestedTaskId.length > 0) {
        task = OPReadJSONFile(OPTaskPath(requestedTaskId));
        if (![task isKindOfClass:[NSDictionary class]]) {
            return OPError(@"task_not_found");
        }
        adoptedTask = YES;
    } else {
        task = OPStartTask(@{@"goal": goal, @"approved_capabilities": approved});
    }
    NSString *taskId = adoptedTask ? requestedTaskId : task[@"task_id"];
    if (adoptedTask && goal.length == 0 && [task[@"goal"] isKindOfClass:[NSString class]]) {
        goal = task[@"goal"];
    }

    NSString *cancelReason = @"";
    if (OPTaskCancellationRequested(taskId, &cancelReason)) {
        NSDictionary *cancelledSummary = @{
            @"status": @"task.cancelled",
            @"goal": goal ?: @"",
            @"task_id": taskId ?: @"",
            @"runner": @"model",
            @"model_provider": mode ?: @"openai_realtime",
            @"model_runtime": @"openai_realtime_websocket",
            @"model": modelStatus[@"model"] ?: @"",
            @"limits": limits,
            @"steps_used": @0,
            @"tool_errors": @0,
            @"unverified_ui_actions": @0,
            @"duration_ms": @(OPNowMs() - startedMs),
            @"stop_reason": @"cancelled",
            @"cancel_reason": cancelReason.length > 0 ? cancelReason : @"cancelled",
            @"last_tool_result": @{
                @"status": @"ok",
                @"state": @"task.cancelled",
                @"reason": cancelReason.length > 0 ? cancelReason : @"cancelled",
                @"task_id": taskId ?: @"",
                @"source": @"openphone.agentd"
            },
            @"trajectory": OPTrajectoryPath(taskId ?: @""),
            @"source": @"openphone.agentd"
        };
        OPUpdateTask(taskId, @"stopped", @{
            @"model_loop_summary": cancelledSummary,
            @"completed_at": @(OPNowMs()),
            @"cancel_requested": @YES,
            @"cancel_reason": cancelReason.length > 0 ? cancelReason : @"cancelled"
        });
        OPRecordTrajectory(taskId, @"model_loop_cancelled", cancelledSummary);
        OPRecordTrajectory(taskId, @"model_loop_finished", cancelledSummary);
        return cancelledSummary;
    }

    OPUpdateTask(taskId, @"active", @{
        @"runner": @"model",
        @"model_provider": mode ?: @"openai_realtime",
        @"model_runtime": @"openai_realtime_websocket",
        @"model": modelStatus[@"model"] ?: @"",
        @"runner_pid": @(getpid()),
        @"runner_started_at": @(OPNowMs()),
        @"limits": limits
    });
    OPRecordTrajectory(taskId, adoptedTask ? @"model_loop_attached" : @"model_loop_started", @{
        @"runner": @"model",
        @"provider": mode ?: @"openai_realtime",
        @"runtime": @"openai_realtime_websocket",
        @"model": modelStatus[@"model"] ?: @"",
        @"goal": goal ?: @""
    });

    OPRealtimeWebSocket *socket = nil;
    NSDictionary *screen = @{};
    NSDictionary *lastToolResult = @{};
    NSString *lastModelTool = @"";
    NSString *stopReason = @"unknown";
    BOOL terminal = NO;
    BOOL succeeded = NO;
    BOOL cancelled = NO;
    long long stepsUsed = 0;
    long long toolErrors = 0;
    long long unverifiedUIActions = 0;
    long long textOnlyTurns = 0;

    NSDictionary *config = OPModelConfig();
    NSString *model = [modelStatus[@"model"] isKindOfClass:[NSString class]]
            ? modelStatus[@"model"] : OPModelEffectiveModel(config);
    NSString *credential = OPModelCredentialValue();
    NSURL *url = OPRealtimeURL(config, model);
    if (!url || !url.scheme || !url.host) {
        stopReason = @"realtime_endpoint_invalid";
        toolErrors = 1;
        lastToolResult = OPError(stopReason);
    } else if (credential.length == 0) {
        stopReason = @"model_credential_missing";
        toolErrors = 1;
        lastToolResult = OPError(stopReason);
    } else {
        NSError *error = nil;
        OPRecordTrajectory(taskId, @"realtime_session_starting", @{
            @"provider": mode ?: @"openai_realtime",
            @"model": model ?: @"",
            @"endpoint_host": url.host ?: @"",
            @"timeout_ms": @(timeoutMs)
        });
        socket = [OPRealtimeWebSocket connectWithURL:url bearerToken:credential
                                           timeoutMs:timeoutMs error:&error];
        if (!socket) {
            stopReason = @"realtime_connect_failed";
            toolErrors = 1;
            lastToolResult = OPError(error.localizedDescription ?: stopReason);
        } else if (![socket sendEvent:OPRealtimeSessionUpdateEvent(mode, model)
                            timeoutMs:timeoutMs error:&error]) {
            stopReason = @"realtime_session_update_send_failed";
            toolErrors = 1;
            lastToolResult = OPError(error.localizedDescription ?: stopReason);
        } else {
            NSDictionary *sessionUpdated = OPRealtimeWaitForEventType(socket, @"session.updated", timeoutMs);
            if (![sessionUpdated[@"status"] isEqualToString:@"ok"]) {
                stopReason = sessionUpdated[@"reason"] ?: @"realtime_session_update_failed";
                toolErrors = 1;
                lastToolResult = sessionUpdated ?: OPError(stopReason);
            } else if (!OPRealtimeSendUserMessage(socket, OPRealtimeInitialTaskPrompt(goal),
                    timeoutMs, &error)) {
                stopReason = @"realtime_initial_message_failed";
                toolErrors = 1;
                lastToolResult = OPError(error.localizedDescription ?: stopReason);
            } else if ((screen = OPModelCompactScreenForLoop(OPGetScreen(@{
                        @"include_screenshot": @YES,
                        @"include_ui_tree": @YES,
                        @"include_activity": @YES,
                        @"compact_trajectory": @YES,
                        @"task_id": taskId ?: @"",
                        @"reason": @"realtime initial forced observation"
                    }))) && !OPRealtimeSendUserMessage(socket,
                        [NSString stringWithFormat:@"Current iPhone screen observation:\n%@",
                                OPJSONString(OPRedactedObject(screen, 0))],
                        timeoutMs, &error)) {
                stopReason = @"realtime_initial_observation_failed";
                toolErrors = 1;
                lastToolResult = OPError(error.localizedDescription ?: stopReason);
            } else if (![socket sendEvent:OPRealtimeResponseCreateEvent(YES)
                                timeoutMs:timeoutMs error:&error]) {
                stopReason = @"realtime_response_create_failed";
                toolErrors = 1;
                lastToolResult = OPError(error.localizedDescription ?: stopReason);
            } else {
                OPRecordTrajectory(taskId, @"realtime_session_ready", @{
                    @"provider": mode ?: @"openai_realtime",
                    @"model": model ?: @"",
                    @"runtime": @"openai_realtime_websocket"
                });

                for (long long step = 1; step <= maxSteps; step++) {
                    if (OPTaskCancellationRequested(taskId, &cancelReason)) {
                        cancelled = YES;
                        stopReason = @"cancelled";
                        break;
                    }
                    if (OPNowMs() - startedMs > maxDurationMs) {
                        stopReason = @"duration_limit";
                        break;
                    }
                    stepsUsed = step;
                    OPUpdateTask(taskId, @"active", @{
                        @"model_loop_current": @{
                            @"status": @"realtime_waiting_for_turn",
                            @"step": @(step),
                            @"max_steps": @(maxSteps),
                            @"tool": lastModelTool ?: @"",
                            @"updated_at_ms": @(OPNowMs())
                        }
                    });
                    NSDictionary *turn = OPRealtimeWaitForTurn(socket, timeoutMs);
                    if (![turn[@"status"] isEqualToString:@"ok"]) {
                        toolErrors += 1;
                        stopReason = turn[@"reason"] ?: @"realtime_turn_failed";
                        lastToolResult = turn ?: OPError(stopReason);
                        break;
                    }
                    NSString *finalText = [turn[@"final_text"] isKindOfClass:[NSString class]]
                            ? turn[@"final_text"] : @"";
                    if (finalText.length > 0) {
                        OPRecordTrajectory(taskId, @"realtime_model_text", @{
                            @"step": @(step),
                            @"provider": mode ?: @"openai_realtime",
                            @"text": OPTruncatedString(finalText, 1000)
                        });
                    }
                    NSArray *calls = [turn[@"function_calls"] isKindOfClass:[NSArray class]]
                            ? turn[@"function_calls"] : @[];
                    if (calls.count == 0) {
                        textOnlyTurns += 1;
                        if (textOnlyTurns >= 3) {
                            stopReason = @"agent.blocked";
                            lastToolResult = @{
                                @"status": @"error",
                                @"state": @"task.failed",
                                @"reason": @"realtime_returned_text_without_tool_calls",
                                @"model_text": OPTruncatedString(finalText, 1000),
                                @"source": @"openphone.agentd"
                            };
                            break;
                        }
                        NSError *correctionError = nil;
                        if (!OPRealtimeSendUserMessage(socket,
                                OPRealtimeTextOnlyCorrectionPrompt(finalText),
                                timeoutMs, &correctionError) ||
                                ![socket sendEvent:OPRealtimeResponseCreateEvent(YES)
                                         timeoutMs:timeoutMs error:&correctionError]) {
                            toolErrors += 1;
                            stopReason = @"realtime_text_correction_failed";
                            lastToolResult = OPError(correctionError.localizedDescription ?: stopReason);
                            break;
                        }
                        continue;
                    }
                    textOnlyTurns = 0;

                    for (id value in calls) {
                        if (![value isKindOfClass:[NSDictionary class]]) {
                            continue;
                        }
                        NSDictionary *call = value;
                        if (OPTaskCancellationRequested(taskId, &cancelReason)) {
                            cancelled = YES;
                            stopReason = @"cancelled";
                            break;
                        }
                        NSDictionary *decision = OPRealtimeDecisionFromCall(call);
                        NSDictionary *guardrail = nil;
                        decision = OPModelDecisionByApplyingGuardrails(decision, goal, step, &guardrail);
                        NSString *tool = [decision[@"tool"] isKindOfClass:[NSString class]]
                                ? decision[@"tool"] : @"";
                        lastModelTool = tool ?: @"";
                        OPUpdateTask(taskId, @"active", @{
                            @"model_loop_current": @{
                                @"status": @"decision_received",
                                @"step": @(step),
                                @"max_steps": @(maxSteps),
                                @"tool": tool ?: @"",
                                @"updated_at_ms": @(OPNowMs())
                            }
                        });
                        OPIslandPublishToolStep(taskId, tool, @"decision_received", step, maxSteps);
                        {
                            NSString *msg = [decision[@"assistant_message"] isKindOfClass:[NSString class]]
                                    ? decision[@"assistant_message"] : @"";
                            if (msg.length > 0) OPIslandPublishAssistantMessage(msg, taskId);
                        }
                        OPRecordTrajectory(taskId, @"model_decision", @{
                            @"step": @(step),
                            @"provider": mode ?: @"openai_realtime",
                            @"runtime": @"openai_realtime_websocket",
                            @"call_id": call[@"call_id"] ?: @"",
                            @"decision": decision
                        });
                        if (guardrail.count > 0) {
                            OPRecordTrajectory(taskId, @"model_decision_guardrail", guardrail);
                        }
                        if (![OPModelToolNames() containsObject:tool]) {
                            toolErrors += 1;
                            lastToolResult = @{
                                @"status": @"error",
                                @"state": @"task.failed",
                                @"reason": [NSString stringWithFormat:@"unknown_model_tool:%@", tool ?: @""],
                                @"source": @"openphone.agentd"
                            };
                            NSError *outputError = nil;
                            OPRealtimeSendFunctionOutput(socket, call[@"call_id"], lastToolResult,
                                    timeoutMs, &outputError);
                            stopReason = @"unknown_model_tool";
                            break;
                        }

                        if (screen.count == 0 && OPModelToolDrivesUI(tool)) {
                            screen = OPModelCompactScreenForLoop(OPGetScreen(@{
                                @"task_id": taskId ?: @"",
                                @"include_screenshot": @YES,
                                @"include_activity": @YES,
                                @"include_ui_tree": @YES,
                                @"compact_trajectory": @YES,
                                @"reason": @"realtime model pre-action observation"
                            }));
                        }
                        OPRecordTrajectory(taskId, @"tool_call", @{
                            @"tool": tool ?: @"",
                            @"step": @(step),
                            @"arguments": decision[@"arguments"] ?: @{}
                        });
                        OPUpdateTask(taskId, @"active", @{
                            @"model_loop_current": @{
                                @"status": @"tool_running",
                                @"step": @(step),
                                @"max_steps": @(maxSteps),
                                @"tool": tool ?: @"",
                                @"updated_at_ms": @(OPNowMs())
                            }
                        });
                        OPIslandPublishToolStep(taskId, tool, @"tool_running", step, maxSteps);

                        NSDictionary *toolResult = OPModelExecuteDecision(decision, taskId, approved);
                        lastToolResult = toolResult ?: @{};
                        NSString *state = [toolResult[@"state"] isKindOfClass:[NSString class]]
                                ? toolResult[@"state"] : @"";
                        BOOL toolOK = [toolResult[@"status"] isEqualToString:@"ok"] ||
                                [state isEqualToString:@"action.executed"] ||
                                [state isEqualToString:@"task.finished"] ||
                                [state isEqualToString:@"task.failed"];
                        if (!toolOK || [state hasPrefix:@"action.denied"] ||
                                [toolResult[@"status"] isEqualToString:@"error"]) {
                            toolErrors += 1;
                        }

                        NSDictionary *afterScreen = @{};
                        NSDictionary *verification = @{@"status": @"not_required", @"reason": @"non_ui_tool"};
                        BOOL skippedPostActionScreen = NO;
                        if (OPModelToolDrivesUI(tool)) {
                            if (!toolOK) {
                                skippedPostActionScreen = YES;
                                verification = @{
                                    @"status": @"failed",
                                    @"reason": toolResult[@"detail"] ?: toolResult[@"reason"] ?: @"tool_failed",
                                    @"source": @"tool_result",
                                    @"expected_visible_change": decision[@"expected_visible_change"] ?: @"",
                                    @"screen_state": screen[@"state"] ?: @""
                                };
                            } else if (OPModelShouldUseProviderVerificationOnly(tool, toolResult)) {
                                skippedPostActionScreen = YES;
                                verification = OPModelProviderVerificationState(tool, toolResult, screen,
                                        decision[@"expected_visible_change"] ?: @"");
                            } else {
                                afterScreen = OPModelCompactScreenForLoop(OPGetScreen(@{
                                    @"task_id": taskId ?: @"",
                                    @"include_screenshot": @YES,
                                    @"include_activity": @YES,
                                    @"include_ui_tree": @YES,
                                    @"compact_trajectory": @YES,
                                    @"reason": @"realtime model post-action verification"
                                }));
                                verification = OPModelVerificationState(tool, toolResult, screen,
                                        afterScreen, decision[@"expected_visible_change"] ?: @"");
                            }
                            if ([verification[@"status"] isEqualToString:@"unverified_dispatch_only"]) {
                                unverifiedUIActions += 1;
                            }
                        }
                        OPRecordTrajectory(taskId, @"model_step_verified", @{
                            @"step": @(step),
                            @"tool": tool ?: @"",
                            @"tool_result": OPModelToolResultSummary(toolResult ?: @{}),
                            @"verification": OPModelVerificationTraceSummary(verification),
                            @"before_screen": screen.count > 0 ? OPModelScreenTraceSummary(screen) : @{},
                            @"after_screen": (!skippedPostActionScreen && afterScreen.count > 0)
                                    ? OPModelScreenTraceSummary(afterScreen) : @{}
                        });
                        OPUpdateTask(taskId, @"active", @{
                            @"model_loop_current": @{
                                @"status": @"step_verified",
                                @"step": @(step),
                                @"max_steps": @(maxSteps),
                                @"tool": tool ?: @"",
                                @"verification": verification[@"status"] ?: @"not_required",
                                @"updated_at_ms": @(OPNowMs())
                            }
                        });

                        NSError *outputError = nil;
                        if (!OPRealtimeSendFunctionOutput(socket, call[@"call_id"], toolResult ?: @{},
                                timeoutMs, &outputError) ||
                                !OPRealtimeSendScreenFollowupIfUseful(socket, tool, toolResult ?: @{},
                                        timeoutMs, &outputError)) {
                            toolErrors += 1;
                            stopReason = @"realtime_function_output_failed";
                            lastToolResult = OPError(outputError.localizedDescription ?: stopReason);
                            break;
                        }

                        if (OPModelVerifiedTypeTextCompletesGoal(goal, decision, verification)) {
                            terminal = YES;
                            succeeded = YES;
                            stopReason = @"verified_type_text_goal_complete";
                            lastToolResult = @{
                                @"status": @"ok",
                                @"state": @"task.finished",
                                @"task_id": taskId ?: @"",
                                @"summary": @"Verified text entry completed.",
                                @"reason": stopReason,
                                @"action_result": OPModelToolResultSummary(toolResult ?: @{}),
                                @"source": @"openphone.agentd"
                            };
                            break;
                        }
                        if ([tool isEqualToString:@"finish_task"] || [state isEqualToString:@"task.finished"]) {
                            terminal = YES;
                            succeeded = YES;
                            stopReason = @"finish_task";
                            break;
                        }
                        if ([tool isEqualToString:@"fail_task"] || [state isEqualToString:@"task.failed"]) {
                            terminal = YES;
                            succeeded = NO;
                            stopReason = @"fail_task";
                            break;
                        }
                        if (toolErrors >= 2) {
                            stopReason = @"tool_error_limit";
                            break;
                        }
                        if (unverifiedUIActions >= 2) {
                            stopReason = @"no_visible_progress";
                            break;
                        }
                        screen = afterScreen.count > 0 ? afterScreen : screen;
                    }
                    if (terminal || cancelled ||
                            ![stopReason isEqualToString:@"unknown"] ||
                            toolErrors >= 2 || unverifiedUIActions >= 2) {
                        break;
                    }
                    NSError *nextError = nil;
                    if (![socket sendEvent:OPRealtimeResponseCreateEvent(YES)
                                  timeoutMs:timeoutMs error:&nextError]) {
                        toolErrors += 1;
                        stopReason = @"realtime_response_create_failed";
                        lastToolResult = OPError(nextError.localizedDescription ?: stopReason);
                        break;
                    }
                }
            }
        }
    }

    if (socket) {
        [socket close];
    }

    if (cancelled) {
        lastToolResult = @{
            @"status": @"ok",
            @"state": @"task.cancelled",
            @"reason": cancelReason.length > 0 ? cancelReason : @"cancelled",
            @"task_id": taskId ?: @"",
            @"source": @"openphone.agentd"
        };
        succeeded = NO;
    } else if (!terminal) {
        if ([stopReason isEqualToString:@"unknown"]) {
            stopReason = stepsUsed >= maxSteps ? @"step_limit" : @"model_stopped";
        }
        NSDictionary *failure = OPFailTask(@{
            @"task_id": taskId ?: @"",
            @"reason": stopReason ?: @"model_stopped"
        });
        lastToolResult = failure ?: lastToolResult;
        succeeded = NO;
    }

    long long durationMs = OPNowMs() - startedMs;
    NSDictionary *summary = @{
        @"status": succeeded ? @"task.finished" : (cancelled ? @"task.cancelled" : @"task.failed"),
        @"goal": goal ?: @"",
        @"task_id": taskId ?: @"",
        @"runner": @"model",
        @"model_provider": mode ?: @"openai_realtime",
        @"model_runtime": @"openai_realtime_websocket",
        @"model": model ?: @"",
        @"limits": limits,
        @"steps_used": @(stepsUsed),
        @"tool_errors": @(toolErrors),
        @"unverified_ui_actions": @(unverifiedUIActions),
        @"text_only_turns": @(textOnlyTurns),
        @"duration_ms": @(durationMs),
        @"stop_reason": stopReason ?: @"unknown",
        @"cancel_reason": cancelled ? (cancelReason.length > 0 ? cancelReason : @"cancelled") : @"",
        @"last_tool_result": lastToolResult ?: @{},
        @"trajectory": OPTrajectoryPath(taskId ?: @""),
        @"source": @"openphone.agentd"
    };
    OPUpdateTask(taskId, succeeded ? @"completed" : (cancelled ? @"stopped" : @"failed"), @{
        @"result": lastToolResult ?: @{},
        @"model_loop_summary": summary,
        @"model_loop_current": @{
            @"status": summary[@"status"] ?: @"task.finished",
            @"step": @(stepsUsed),
            @"max_steps": @(maxSteps),
            @"tool": lastModelTool ?: @"",
            @"stop_reason": stopReason ?: @"unknown",
            @"updated_at_ms": @(OPNowMs())
        },
        @"completed_at": @(OPNowMs()),
        @"cancel_requested": cancelled ? @YES : @NO,
        @"cancel_reason": cancelled ? (cancelReason.length > 0 ? cancelReason : @"cancelled") : @""
    });
    OPRecordAudit(succeeded ? @"model_task_finished" :
            (cancelled ? @"model_task_cancelled" : @"model_task_failed"), taskId,
            @"tasks.observe", succeeded ? @"allow_task_scoped" : (cancelled ? @"cancelled" : @"failed"),
            @{
                @"command": @"run_task",
                @"mode": @"model",
                @"goal": goal ?: @"",
                @"status": summary[@"status"] ?: @"unknown",
                @"stop_reason": stopReason ?: @"unknown",
                @"model_provider": summary[@"model_provider"] ?: @"unknown",
                @"model_runtime": summary[@"model_runtime"] ?: @"unknown",
                @"model": model ?: @"",
                @"steps_used": summary[@"steps_used"] ?: @0
            },
            stopReason ?: @"unknown");
    if (cancelled) {
        OPRecordTrajectory(taskId, @"model_loop_cancelled", summary);
    }
    OPRecordTrajectory(taskId, @"model_loop_finished", summary);
    return summary;
}

static NSDictionary *OPRunModelTask(NSDictionary *request) {
    long long startedMs = OPNowMs();
    NSString *goal = OPStringFromRequest(request, @"goal", @"");
    NSArray *approved = [request[@"approved_capabilities"] isKindOfClass:[NSArray class]]
            ? request[@"approved_capabilities"] : OPFullYoloCapabilities();
    NSDictionary *modelStatus = OPModelStatusDictionary();
    NSArray *fixtureDecisions = [request[@"model_decisions"] isKindOfClass:[NSArray class]]
            ? request[@"model_decisions"] : @[];
    BOOL hasFixture = fixtureDecisions.count > 0;
    if (!hasFixture && ![modelStatus[@"status"] isEqualToString:@"ready"]) {
        return OPError(@"model_provider_not_configured");
    }
    long long configuredMaxSteps = [modelStatus[@"max_steps"] respondsToSelector:@selector(longLongValue)]
            ? [modelStatus[@"max_steps"] longLongValue] : 5;
    long long configuredMaxDuration = [modelStatus[@"max_duration_ms"] respondsToSelector:@selector(longLongValue)]
            ? [modelStatus[@"max_duration_ms"] longLongValue] : 120000;
    long long maxSteps = OPLongLongFromRequest(request, @"max_steps", configuredMaxSteps, 1, 25);
    long long maxDurationMs = OPLongLongFromRequest(request, @"max_duration_ms", configuredMaxDuration, 1000, 600000);
    NSDictionary *limits = @{
        @"max_steps": @(maxSteps),
        @"max_duration_ms": @(maxDurationMs),
        @"max_parser_failures": @2,
        @"max_tool_errors": @2,
        @"max_unverified_ui_actions": @2
    };
    NSString *requestedTaskId = OPStringFromRequest(request, @"task_id", @"");
    BOOL adoptedTask = NO;
    NSDictionary *task = nil;
    if (requestedTaskId.length > 0) {
        task = OPReadJSONFile(OPTaskPath(requestedTaskId));
        if (![task isKindOfClass:[NSDictionary class]]) {
            return OPError(@"task_not_found");
        }
        adoptedTask = YES;
    } else {
        task = OPStartTask(@{@"goal": goal, @"approved_capabilities": approved});
    }
    NSString *taskId = adoptedTask ? requestedTaskId : task[@"task_id"];
    if (adoptedTask && goal.length == 0 && [task[@"goal"] isKindOfClass:[NSString class]]) {
        goal = task[@"goal"];
    }
    NSString *cancelReason = @"";
    if (OPTaskCancellationRequested(taskId, &cancelReason)) {
        long long durationMs = OPNowMs() - startedMs;
        NSDictionary *summary = @{
            @"status": @"task.cancelled",
            @"goal": goal ?: @"",
            @"task_id": taskId ?: @"",
            @"runner": @"model",
            @"model_provider": hasFixture ? @"fixture" : (modelStatus[@"mode"] ?: @"broker"),
            @"limits": limits,
            @"steps_used": @0,
            @"parser_failures": @0,
            @"tool_errors": @0,
            @"unverified_ui_actions": @0,
            @"duration_ms": @(durationMs),
            @"stop_reason": @"cancelled",
            @"cancel_reason": cancelReason.length > 0 ? cancelReason : @"cancelled",
            @"last_tool_result": @{
                @"status": @"ok",
                @"state": @"task.cancelled",
                @"reason": cancelReason.length > 0 ? cancelReason : @"cancelled",
                @"task_id": taskId ?: @"",
                @"source": @"openphone.agentd"
            },
            @"trajectory": OPTrajectoryPath(taskId ?: @""),
            @"source": @"openphone.agentd"
        };
        OPUpdateTask(taskId, @"stopped", @{
            @"model_loop_summary": summary,
            @"completed_at": @(OPNowMs()),
            @"cancel_requested": @YES,
            @"cancel_reason": cancelReason.length > 0 ? cancelReason : @"cancelled"
        });
        OPRecordAudit(@"model_task_cancelled", taskId, @"tasks.observe", @"cancelled",
                @{@"command": @"run_task", @"mode": @"model", @"goal": goal ?: @""}, cancelReason);
        OPRecordTrajectory(taskId, @"model_loop_cancelled", summary);
        OPRecordTrajectory(taskId, @"model_loop_finished", summary);
        return summary;
    }
    OPUpdateTask(taskId, @"active", @{
        @"runner": @"model",
        @"model_provider": hasFixture ? @"fixture" : (modelStatus[@"mode"] ?: @"broker"),
        @"runner_pid": @(getpid()),
        @"runner_started_at": @(OPNowMs()),
        @"limits": limits
    });
    if (adoptedTask) {
        OPRecordAudit(@"model_task_attached", taskId, @"tasks.observe", @"allow_task_scoped",
                @{@"command": @"run_task", @"mode": @"model", @"goal": goal ?: @""},
                @"adopted_existing_task");
        OPRecordTrajectory(taskId, @"model_loop_attached", @{
            @"runner": @"model",
            @"provider": hasFixture ? @"fixture" : (modelStatus[@"mode"] ?: @"broker"),
            @"goal": goal ?: @""
        });
    }

    NSDictionary *screen = OPModelCompactScreenForLoop(OPGetScreen(@{
        @"task_id": taskId ?: @"",
        @"include_screenshot": @YES,
        @"include_activity": @YES,
        @"include_ui_tree": @YES,
        @"compact_trajectory": @YES,
        @"reason": @"model run_task initial observation"
    }));
    NSDictionary *promptContext = OPModelPromptContext(goal, taskId, screen, modelStatus, approved, @{});
    OPRecordTrajectory(taskId, @"model_prompt_prepared", @{
        @"provider": hasFixture ? @"fixture" : (modelStatus[@"mode"] ?: @"broker"),
        @"context": OPModelPromptContextTraceSummary(promptContext ?: @{})
    });

    long long parserFailures = 0;
    long long toolErrors = 0;
    long long unverifiedUIActions = 0;
    long long stepsUsed = 0;
    NSString *stopReason = @"unknown";
    NSDictionary *lastToolResult = @{};
    NSString *lastModelTool = @"";
    long long consecutiveGetScreenCount = 0;
    NSString *lastDecisionSig = @"";
    long long lastDecisionRepeats = 0;
    // Router-mode queue: when the model returns mode=act with proposed_actions,
    // we drain them one by one *without* re-prompting the model. Massively
    // reduces roundtrips + eliminates the source of loop bugs.
    NSMutableArray *routerActionQueue = [NSMutableArray array];
    NSString *routerReply = @"";
    NSString *routerLastScreenSignature = @"";
    long long consecutiveNoProgress = 0;
    BOOL terminal = NO;
    BOOL succeeded = NO;
    BOOL cancelled = NO;

    for (long long step = 1; step <= maxSteps; step++) {
        @autoreleasepool {
        if (OPTaskCancellationRequested(taskId, &cancelReason)) {
            cancelled = YES;
            stopReason = @"cancelled";
            break;
        }
        stepsUsed = step;
        OPUpdateTask(taskId, @"active", @{
            @"model_loop_current": @{
                @"status": @"step_started",
                @"step": @(step),
                @"max_steps": @(maxSteps),
                @"tool": lastModelTool ?: @"",
                @"updated_at_ms": @(OPNowMs())
            }
        });
        if (OPNowMs() - startedMs > maxDurationMs) {
            stopReason = @"duration_limit";
            break;
        }
        id rawDecision = nil;
        if (hasFixture && (NSUInteger)(step - 1) < fixtureDecisions.count) {
            rawDecision = fixtureDecisions[(NSUInteger)(step - 1)];
        } else if (routerActionQueue.count > 0) {
            // Router pre-planned action queue: drain the next action WITHOUT
            // hitting the model again. This is what kills the loop bug.
            NSDictionary *action = routerActionQueue.firstObject;
            [routerActionQueue removeObjectAtIndex:0];
            NSMutableDictionary *synth = [NSMutableDictionary dictionary];
            synth[@"schema"] = @"openphone.model_decision.v2";
            synth[@"tool"] = action[@"tool"] ?: @"";
            synth[@"arguments"] = action[@"arguments"] ?: @{};
            synth[@"expected_visible_change"] = @"progress toward goal";
            synth[@"confidence"] = @(0.95);
            synth[@"assistant_message"] = routerReply ?: @"";
            synth[@"reasoning"] = @"pre-planned action from router";
            rawDecision = synth;
            OPRecordTrajectory(taskId, @"router_action_dequeued", @{
                @"step": @(step),
                @"tool": synth[@"tool"],
                @"queue_remaining": @(routerActionQueue.count)
            });
        } else {
            // Loop guidance: tell the model exactly what it did last and,
            // if that action already succeeded, that it should finish now.
            NSString *guidance = @"";
            if ([lastModelTool isEqualToString:@"get_screen"]) {
                guidance = @"HARD RULE: last_tool was get_screen. You MUST choose an action tool (tap, tap_element, type_text, open_url, open_app, swipe, home, finish_task, fail_task) this step. Do NOT choose get_screen again — the observation is already in this prompt.";
            } else if (lastModelTool.length > 0) {
                NSString *lastState = [lastToolResult[@"state"] isKindOfClass:[NSString class]]
                        ? lastToolResult[@"state"] : @"";
                if ([lastState isEqualToString:@"action.executed"] ||
                        [lastState isEqualToString:@"task.finished"]) {
                    guidance = [NSString stringWithFormat:
                            @"HARD RULE: last_tool was %@ and it EXECUTED SUCCESSFULLY. Do NOT repeat the same action. The user's request is now satisfied by that action. Call finish_task with a short human summary of what you did.",
                            lastModelTool];
                }
            }
            NSDictionary *loopState = @{
                @"step": @(step),
                @"last_tool": lastModelTool ?: @"",
                @"last_tool_result": OPModelToolResultSummary(lastToolResult),
                @"last_screen": OPModelScreenSummary(screen ?: @{}),
                @"guidance": guidance
            };
            promptContext = step == 1 ? promptContext
                    : OPModelPromptContext(goal, taskId, screen, modelStatus, approved, loopState);
            NSDictionary *brokerRequest = @{
                @"schema": @"openphone.model_request.v1",
                @"task_id": taskId ?: @"",
                @"goal": goal ?: @"",
                @"step": @(step),
                @"autonomy_mode": @"yolo",
                @"decision_schema": @"openphone.model_decision.v1",
                @"model": modelStatus[@"model"] ?: @"",
                @"mode": modelStatus[@"mode"] ?: @"broker",
                @"tools": OPModelToolNames(),
                @"context": promptContext ?: @{},
                @"instructions": @"Return exactly one JSON object matching openphone.model_decision.v1. Do not include prose outside JSON."
            };
            OPRecordTrajectory(taskId, @"model_request", @{
                @"step": @(step),
                @"provider": modelStatus[@"mode"] ?: @"broker",
                @"model": modelStatus[@"model"] ?: @"",
                @"timeout_ms": modelStatus[@"timeout_ms"] ?: @30000,
                @"request_schema": @"openphone.model_request.v1",
                @"endpoint_configured": modelStatus[@"endpoint_configured"] ?: @NO,
                @"context": OPModelPromptContextTraceSummary(promptContext ?: @{})
            });
            // Publish an island update BEFORE the blocking Bedrock call so the
            // user sees "Thinking · N/25" immediately instead of a frozen pill.
            OPIslandUpdate(@{
                @"mode": @"thinking",
                @"subtitle": @"Thinking",
                @"step": @(step),
                @"max_steps": @(maxSteps),
                @"task_id": taskId ?: @"",
                @"accent": @"blue"
            });
            NSDictionary *brokerResponse = OPModelProviderDecision(modelStatus, brokerRequest);
            OPRecordTrajectory(taskId, @"model_response", @{
                @"step": @(step),
                @"provider": modelStatus[@"mode"] ?: @"broker",
                @"status": brokerResponse[@"status"] ?: @"unknown",
                @"http_status": brokerResponse[@"http_status"] ?: @0,
                @"response_bytes": brokerResponse[@"response_bytes"] ?: @0,
                @"usage": brokerResponse[@"usage"] ?: @{},
                @"metadata": brokerResponse[@"metadata"] ?: @{},
                @"reason": brokerResponse[@"reason"] ?: @""
            });
            if (![brokerResponse[@"status"] isEqualToString:@"ok"]) {
                toolErrors += 1;
                lastToolResult = brokerResponse ?: @{};
                stopReason = @"model_provider_error";
                break;
            }
            rawDecision = brokerResponse[@"decision"];
        }

        if (OPTaskCancellationRequested(taskId, &cancelReason)) {
            cancelled = YES;
            stopReason = @"cancelled";
            break;
        }

        NSString *parseError = nil;
        NSString *repairStrategy = nil;
        NSDictionary *decision = [rawDecision isKindOfClass:[NSString class]]
                ? OPModelDecisionFromString(rawDecision, &parseError, &repairStrategy)
                : OPModelDecisionFromObject(rawDecision, &parseError);
        if (!decision) {
            parserFailures += 1;
            OPRecordTrajectory(taskId, @"model_parse_error", @{
                @"step": @(step),
                @"provider": hasFixture ? @"fixture" : (modelStatus[@"mode"] ?: @"broker"),
                @"reason": parseError ?: @"parse_failed"
            });
            if (parserFailures >= 2) {
                stopReason = @"parser_failure_limit";
                break;
            }
            continue;
        }
        if (repairStrategy.length > 0) {
            OPRecordTrajectory(taskId, @"model_parse_repaired", @{
                @"step": @(step),
                @"provider": hasFixture ? @"fixture" : (modelStatus[@"mode"] ?: @"broker"),
                @"strategy": repairStrategy,
                @"source_type": @"string",
                @"source_length": @([(NSString *)rawDecision length])
            });
        }

        // Router: if the model returned a v3 mode-router decision, translate
        // it into the internal single-tool decision + optionally queue more
        // actions to run without another model call.
        NSString *rMode = [decision[@"mode"] isKindOfClass:[NSString class]]
                ? decision[@"mode"] : @"";
        NSString *rSchema = [decision[@"schema"] isKindOfClass:[NSString class]]
                ? decision[@"schema"] : @"";
        BOOL isRouter = rMode.length > 0 || [rSchema isEqualToString:@"openphone.model_decision.v3"];
        if (isRouter) {
            NSString *reply = [decision[@"reply"] isKindOfClass:[NSString class]]
                    ? decision[@"reply"] : @"";
            NSArray *proposed = [decision[@"proposed_actions"] isKindOfClass:[NSArray class]]
                    ? decision[@"proposed_actions"] : @[];
            routerReply = reply;
            OPRecordTrajectory(taskId, @"router_decision", @{
                @"step": @(step),
                @"mode": rMode ?: @"",
                @"reply": reply ?: @"",
                @"proposed_action_count": @(proposed.count)
            });
            if ([rMode isEqualToString:@"answer"] || [rMode isEqualToString:@"clarify"] ||
                    proposed.count == 0) {
                // Single-turn: fill finish_task and go.
                NSMutableDictionary *synth = [NSMutableDictionary dictionary];
                synth[@"schema"] = @"openphone.model_decision.v2";
                synth[@"tool"] = @"finish_task";
                synth[@"arguments"] = @{@"summary": reply.length > 0 ? reply : @"Done."};
                synth[@"assistant_message"] = reply;
                synth[@"expected_visible_change"] = @"none";
                synth[@"confidence"] = @(0.95);
                decision = synth;
            } else if ([rMode isEqualToString:@"stop"]) {
                NSMutableDictionary *synth = [NSMutableDictionary dictionary];
                synth[@"schema"] = @"openphone.model_decision.v2";
                synth[@"tool"] = @"fail_task";
                synth[@"arguments"] = @{@"reason": reply.length > 0 ? reply : @"Stopped."};
                synth[@"assistant_message"] = reply;
                synth[@"expected_visible_change"] = @"none";
                synth[@"confidence"] = @(0.95);
                decision = synth;
            } else {
                // mode=act: pull first proposed_action as this step's decision,
                // queue the rest, and ALWAYS append a synthetic finish_task at
                // the end so the loop terminates after the last planned action
                // — no re-prompting the model, which is where loops happen.
                NSDictionary *first = proposed.firstObject;
                if ([first isKindOfClass:[NSDictionary class]]) {
                    NSMutableDictionary *synth = [NSMutableDictionary dictionary];
                    synth[@"schema"] = @"openphone.model_decision.v2";
                    synth[@"tool"] = [first[@"tool"] isKindOfClass:[NSString class]] ? first[@"tool"] : @"";
                    synth[@"arguments"] = [first[@"arguments"] isKindOfClass:[NSDictionary class]] ? first[@"arguments"] : @{};
                    synth[@"assistant_message"] = reply;
                    synth[@"expected_visible_change"] = @"progress toward goal";
                    synth[@"confidence"] = @(0.95);
                    decision = synth;
                    [routerActionQueue removeAllObjects];
                    for (NSUInteger i = 1; i < proposed.count; i++) {
                        id a = proposed[i];
                        if ([a isKindOfClass:[NSDictionary class]]) {
                            [routerActionQueue addObject:a];
                        }
                    }
                    // Sentinel finish_task at end of the queue.
                    NSString *finishMsg = reply.length > 0 ? reply : @"Done.";
                    [routerActionQueue addObject:@{
                        @"tool": @"finish_task",
                        @"arguments": @{@"summary": finishMsg}
                    }];
                }
            }
        }

        NSDictionary *guardrail = nil;
        decision = OPModelDecisionByApplyingGuardrails(decision, goal, step, &guardrail);
        NSString *tool = decision[@"tool"] ?: @"";
        // NOTE: the aggressive "one-action-then-finish" guard was removed here
        // — the router handles single-vs-multi-step upfront via
        // proposed_actions[]. If we ever want to add it back for legacy
        // decisions, only trigger when no routerActionQueue was ever populated
        // (i.e. the model refused the router pattern).
        OPUpdateTask(taskId, @"active", @{
            @"model_loop_current": @{
                @"status": @"decision_received",
                @"step": @(step),
                @"max_steps": @(maxSteps),
                @"tool": tool ?: @"",
                @"updated_at_ms": @(OPNowMs())
            }
        });
        OPIslandPublishToolStep(taskId, tool, @"decision_received", step, maxSteps);
        {
            NSString *msg = [decision[@"assistant_message"] isKindOfClass:[NSString class]]
                    ? decision[@"assistant_message"] : @"";
            if (msg.length == 0) {
                // Fall back to arguments.summary / .answer / .reply so the user
                // still hears the model's words even if it forgot the top-level
                // assistant_message field.
                NSDictionary *args = [decision[@"arguments"] isKindOfClass:[NSDictionary class]]
                        ? decision[@"arguments"] : @{};
                for (NSString *key in @[@"summary", @"answer", @"reply", @"response", @"message", @"text"]) {
                    NSString *v = OPStringFromRequest(args, key, @"");
                    if (v.length > 0) { msg = v; break; }
                }
            }
            if (msg.length > 0) OPIslandPublishAssistantMessage(msg, taskId);
        }
        OPRecordTrajectory(taskId, @"model_decision", @{
            @"step": @(step),
            @"provider": hasFixture ? @"fixture" : (modelStatus[@"mode"] ?: @"broker"),
            @"decision": decision
        });
        if (guardrail.count > 0) {
            OPRecordTrajectory(taskId, @"model_decision_guardrail", guardrail);
        }
        // Track consecutive read-only observations. A page can take a beat to
        // render (App Store loading, Safari navigation) so let the model
        // re-observe up to 3 times before failing.
        if ([tool isEqualToString:@"get_screen"]) {
            consecutiveGetScreenCount += 1;
        } else {
            consecutiveGetScreenCount = 0;
        }
        if (consecutiveGetScreenCount >= 4) {
            stopReason = @"repeated_read_only_observation";
            lastToolResult = @{
                @"status": @"ok",
                @"state": @"task.failed",
                @"reason": stopReason,
                @"tool": tool,
                @"task_id": taskId ?: @"",
                @"source": @"openphone.agentd"
            };
            OPRecordTrajectory(taskId, @"model_no_progress", @{
                @"step": @(step),
                @"tool": tool,
                @"consecutive_get_screen": @(consecutiveGetScreenCount),
                @"reason": stopReason,
                @"last_tool_result": OPModelToolResultSummary(lastToolResult)
            });
            break;
        }
        // Same-action loop guard: if the model picks the identical tool+args
        // twice in a row (e.g. open_url with the same URL), force finish. The
        // action already succeeded once; repeating it is dead loop.
        NSDictionary *decArgs = [decision[@"arguments"] isKindOfClass:[NSDictionary class]]
                ? decision[@"arguments"] : @{};
        NSData *argsData = [NSJSONSerialization dataWithJSONObject:decArgs
                                                            options:NSJSONWritingSortedKeys
                                                              error:nil];
        NSString *argsSig = argsData ? [[NSString alloc] initWithData:argsData
                                                             encoding:NSUTF8StringEncoding] : @"";
        NSString *sig = [NSString stringWithFormat:@"%@|%@", tool ?: @"", argsSig ?: @""];
        if ([sig isEqualToString:lastDecisionSig] &&
                ![tool isEqualToString:@"finish_task"] && ![tool isEqualToString:@"fail_task"] &&
                ![tool isEqualToString:@"get_screen"]) {
            lastDecisionRepeats += 1;
        } else {
            lastDecisionRepeats = 0;
        }
        lastDecisionSig = sig;
        if (lastDecisionRepeats >= 1) {
            // 2nd identical action in a row → treat previous run as successful
            // and finish. Better UX than looping forever.
            NSString *msg = @"Done.";
            NSString *url = [decArgs[@"url"] isKindOfClass:[NSString class]]
                    ? decArgs[@"url"] : @"";
            if (url.length > 0) {
                msg = [NSString stringWithFormat:@"Opened %@.", url];
            }
            OPRecordTrajectory(taskId, @"model_loop_guard_same_action", @{
                @"step": @(step),
                @"tool": tool,
                @"arguments": decArgs,
                @"reason": @"same_action_repeated"
            });
            lastToolResult = @{
                @"status": @"ok",
                @"state": @"task.finished",
                @"task_id": taskId ?: @"",
                @"summary": msg,
                @"source": @"openphone.agentd"
            };
            terminal = YES;
            succeeded = YES;
            stopReason = @"same_action_repeated";
            break;
        }
        OPRecordTrajectory(taskId, @"tool_call", @{
            @"tool": tool,
            @"step": @(step),
            @"arguments": decision[@"arguments"] ?: @{}
        });
        OPUpdateTask(taskId, @"active", @{
            @"model_loop_current": @{
                @"status": @"tool_running",
                @"step": @(step),
                @"max_steps": @(maxSteps),
                @"tool": tool ?: @"",
                @"updated_at_ms": @(OPNowMs())
            }
        });
        OPIslandPublishToolStep(taskId, tool, @"tool_running", step, maxSteps);

        // Autonomy modes: reviewed pauses on UI-driving tools; dry_run refuses
        // outright. yolo (default) proceeds as before.
        NSString *autonomy = OPAutonomyMode();
        if (![autonomy isEqualToString:@"yolo"] && OPModelToolDrivesUI(tool)) {
            if ([autonomy isEqualToString:@"dry_run"]) {
                lastToolResult = @{
                    @"status": @"ok",
                    @"state": @"action.denied",
                    @"reason": @"dry_run_mode",
                    @"tool": tool,
                    @"task_id": taskId ?: @"",
                    @"source": @"openphone.agentd"
                };
                OPRecordTrajectory(taskId, @"tool_denied_dry_run", @{@"tool": tool});
                stopReason = @"dry_run_denied";
                break;
            }
            // reviewed
            NSString *thought = [decision[@"thought"] isKindOfClass:[NSString class]]
                    ? decision[@"thought"] : @"";
            NSString *summary = thought.length > 0 ? thought
                    : [NSString stringWithFormat:@"Run %@?", tool];
            BOOL approvedNow = OPRequestUserConfirmation(taskId, tool, summary, 30.0);
            if (!approvedNow) {
                lastToolResult = @{
                    @"status": @"ok",
                    @"state": @"action.denied",
                    @"reason": @"user_denied",
                    @"tool": tool,
                    @"task_id": taskId ?: @"",
                    @"source": @"openphone.agentd"
                };
                OPRecordTrajectory(taskId, @"tool_denied_by_user", @{@"tool": tool});
                stopReason = @"user_denied";
                break;
            }
            // Reset island back to action mode after approval.
            OPIslandPublishToolStep(taskId, tool, @"tool_running", step, maxSteps);
        }

        // Step-1 get_screen is wasted work: the current screen is already in
        // the step-1 prompt. Skip the second observation, mark last_tool as
        // get_screen so the loop's guidance forces an action on step 2.
        NSDictionary *toolResult;
        if (step == 1 && [tool isEqualToString:@"get_screen"]) {
            toolResult = @{
                @"status": @"ok",
                @"state": @"observation.reused_from_step1_prompt",
                @"tool": @"get_screen",
                @"task_id": taskId ?: @"",
                @"reason": @"screen already observed in step 1 prompt",
                @"source": @"openphone.agentd"
            };
            OPRecordTrajectory(taskId, @"model_step1_get_screen_shortcircuit", @{
                @"step": @(step),
                @"tool": tool
            });
        } else {
            toolResult = OPModelExecuteDecision(decision, taskId, approved);
        }
        lastToolResult = toolResult ?: @{};
        NSString *state = [toolResult[@"state"] isKindOfClass:[NSString class]]
                ? toolResult[@"state"] : @"";
        BOOL toolOK = [toolResult[@"status"] isEqualToString:@"ok"] ||
                [state isEqualToString:@"action.executed"] ||
                [state isEqualToString:@"task.finished"] ||
                [state isEqualToString:@"task.failed"];
        if (!toolOK || [state hasPrefix:@"action.denied"] ||
                [toolResult[@"status"] isEqualToString:@"error"]) {
            toolErrors += 1;
        }

        NSDictionary *afterScreen = @{};
        NSDictionary *verification = @{@"status": @"not_required", @"reason": @"non_ui_tool"};
        BOOL skippedPostActionScreen = NO;
        if (OPModelToolDrivesUI(tool)) {
            if (!toolOK) {
                skippedPostActionScreen = YES;
                verification = @{
                    @"status": @"failed",
                    @"reason": toolResult[@"detail"] ?: toolResult[@"reason"] ?: @"tool_failed",
                    @"source": @"tool_result",
                    @"expected_visible_change": decision[@"expected_visible_change"] ?: @"",
                    @"screen_state": screen[@"state"] ?: @""
                };
            } else if (OPModelShouldUseProviderVerificationOnly(tool, toolResult)) {
                skippedPostActionScreen = YES;
                verification = OPModelProviderVerificationState(tool, toolResult, screen,
                        decision[@"expected_visible_change"] ?: @"");
            } else {
                afterScreen = OPModelCompactScreenForLoop(OPGetScreen(@{
                    @"task_id": taskId ?: @"",
                    @"include_screenshot": @YES,
                    @"include_activity": @YES,
                    @"include_ui_tree": @YES,
                    @"compact_trajectory": @YES,
                    @"reason": @"model run_task post-action verification"
                }));
                verification = OPModelVerificationState(tool, toolResult, screen, afterScreen,
                        decision[@"expected_visible_change"] ?: @"");
            }
            if ([verification[@"status"] isEqualToString:@"unverified_dispatch_only"]) {
                unverifiedUIActions += 1;
            }
        }
        if (OPTaskCancellationRequested(taskId, &cancelReason)) {
            cancelled = YES;
            stopReason = @"cancelled";
        }
        OPRecordTrajectory(taskId, @"model_step_verified", @{
            @"step": @(step),
            @"tool": tool,
            @"tool_result": OPModelToolResultSummary(toolResult ?: @{}),
            @"verification": OPModelVerificationTraceSummary(verification),
            @"before_screen": screen.count > 0 ? OPModelScreenTraceSummary(screen) : @{},
            @"after_screen": (!skippedPostActionScreen && afterScreen.count > 0)
                    ? OPModelScreenTraceSummary(afterScreen) : @{}
        });
        OPUpdateTask(taskId, @"active", @{
            @"model_loop_current": @{
                @"status": @"step_verified",
                @"step": @(step),
                @"max_steps": @(maxSteps),
                @"tool": tool ?: @"",
                @"verification": verification[@"status"] ?: @"not_required",
                @"updated_at_ms": @(OPNowMs())
            }
        });
        if (cancelled) {
            break;
        }
        lastModelTool = tool;

        if (OPModelVerifiedTypeTextCompletesGoal(goal, decision, verification)) {
            terminal = YES;
            succeeded = YES;
            stopReason = @"verified_type_text_goal_complete";
            lastToolResult = @{
                @"status": @"ok",
                @"state": @"task.finished",
                @"task_id": taskId ?: @"",
                @"summary": @"Verified text entry completed.",
                @"reason": stopReason,
                @"action_result": OPModelToolResultSummary(toolResult ?: @{}),
                @"source": @"openphone.agentd"
            };
            break;
        }
        if ([tool isEqualToString:@"finish_task"]) {
            terminal = YES;
            succeeded = YES;
            stopReason = @"finish_task";
            break;
        }
        if ([tool isEqualToString:@"fail_task"]) {
            terminal = YES;
            succeeded = NO;
            stopReason = @"fail_task";
            break;
        }
        if (toolErrors >= 2) {
            stopReason = @"tool_error_limit";
            break;
        }
        if (unverifiedUIActions >= 2) {
            stopReason = @"no_visible_progress";
            break;
        }
        // Screen-signature no-progress detection: if we ran a UI-driving tool
        // and the screen didn't materially change, count as "no progress".
        // Two consecutive no-progress steps → terminate as done.
        if (OPModelToolDrivesUI(tool) && afterScreen.count > 0) {
            NSString *newSig = OPModelScreenSignature(afterScreen);
            if (routerLastScreenSignature.length > 0 &&
                    [newSig isEqualToString:routerLastScreenSignature]) {
                consecutiveNoProgress += 1;
            } else {
                consecutiveNoProgress = 0;
            }
            routerLastScreenSignature = newSig;
            if (consecutiveNoProgress >= 2) {
                OPRecordTrajectory(taskId, @"model_no_progress_by_signature", @{
                    @"step": @(step),
                    @"signature": newSig
                });
                terminal = YES;
                succeeded = YES;
                stopReason = @"no_progress_signature";
                if (routerReply.length > 0) {
                    lastToolResult = @{
                        @"status": @"ok",
                        @"state": @"task.finished",
                        @"task_id": taskId ?: @"",
                        @"summary": routerReply,
                        @"source": @"openphone.agentd"
                    };
                }
                break;
            }
        }
        screen = afterScreen.count > 0 ? afterScreen : screen;
        } // @autoreleasepool
    }

    if (cancelled) {
        lastToolResult = @{
            @"status": @"ok",
            @"state": @"task.cancelled",
            @"reason": cancelReason.length > 0 ? cancelReason : @"cancelled",
            @"task_id": taskId ?: @"",
            @"source": @"openphone.agentd"
        };
        succeeded = NO;
    } else if (!terminal) {
        if ([stopReason isEqualToString:@"unknown"]) {
            stopReason = stepsUsed >= maxSteps ? @"step_limit" : @"model_stopped";
        }
        NSDictionary *failure = OPFailTask(@{
            @"task_id": taskId ?: @"",
            @"reason": stopReason
        });
        lastToolResult = failure ?: lastToolResult;
        succeeded = NO;
    }

    long long durationMs = OPNowMs() - startedMs;
    NSDictionary *summary = @{
        @"status": succeeded ? @"task.finished" : (cancelled ? @"task.cancelled" : @"task.failed"),
        @"goal": goal ?: @"",
        @"task_id": taskId ?: @"",
        @"runner": @"model",
        @"model_provider": hasFixture ? @"fixture" : (modelStatus[@"mode"] ?: @"broker"),
        @"limits": limits,
        @"steps_used": @(stepsUsed),
        @"parser_failures": @(parserFailures),
        @"tool_errors": @(toolErrors),
        @"unverified_ui_actions": @(unverifiedUIActions),
        @"duration_ms": @(durationMs),
        @"stop_reason": stopReason ?: @"unknown",
        @"cancel_reason": cancelled ? (cancelReason.length > 0 ? cancelReason : @"cancelled") : @"",
        @"last_tool_result": lastToolResult ?: @{},
        @"trajectory": OPTrajectoryPath(taskId ?: @""),
        @"source": @"openphone.agentd"
    };
    OPUpdateTask(taskId, succeeded ? @"completed" : (cancelled ? @"stopped" : @"failed"), @{
        @"result": lastToolResult ?: @{},
        @"model_loop_summary": summary,
        @"model_loop_current": @{
            @"status": summary[@"status"] ?: @"task.finished",
            @"step": @(stepsUsed),
            @"max_steps": @(maxSteps),
            @"tool": lastModelTool ?: @"",
            @"stop_reason": stopReason ?: @"unknown",
            @"updated_at_ms": @(OPNowMs())
        },
        @"completed_at": @(OPNowMs()),
        @"cancel_requested": cancelled ? @YES : @NO,
        @"cancel_reason": cancelled ? (cancelReason.length > 0 ? cancelReason : @"cancelled") : @""
    });
    OPRecordAudit(succeeded ? @"model_task_finished" :
            (cancelled ? @"model_task_cancelled" : @"model_task_failed"), taskId,
            @"tasks.observe", succeeded ? @"allow_task_scoped" : (cancelled ? @"cancelled" : @"failed"),
            @{
                @"command": @"run_task",
                @"mode": @"model",
                @"goal": goal ?: @"",
                @"status": summary[@"status"] ?: @"unknown",
                @"stop_reason": stopReason ?: @"unknown",
                @"model_provider": summary[@"model_provider"] ?: @"unknown",
                @"steps_used": summary[@"steps_used"] ?: @0
            },
            stopReason ?: @"unknown");
    if (cancelled) {
        OPRecordTrajectory(taskId, @"model_loop_cancelled", summary);
    }
    OPRecordTrajectory(taskId, @"model_loop_finished", summary);

    // Publish terminal island state now that the loop is truly done. The
    // per-tool OPFinishTask / OPFailTask handlers only fire for explicit
    // tool calls, not for the model's finish_task decision — the loop just
    // sets succeeded=YES and returns. Without this, the island stays stuck
    // in "action / Finishing" forever.
    NSString *terminalMsg = @"";
    if (lastToolResult && [lastToolResult isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"summary", @"answer", @"reply", @"message", @"text", @"reason"]) {
            NSString *v = OPStringFromRequest(lastToolResult, key, @"");
            if (v.length > 0) { terminalMsg = v; break; }
        }
    }
    if (terminalMsg.length == 0) {
        terminalMsg = succeeded ? @"Done." : (cancelled ? @"Cancelled" : @"Couldn't finish that.");
    }
    OPIslandPublishTerminal(taskId, succeeded, terminalMsg);
    OPRecordAssistantTurn(terminalMsg, taskId, succeeded);

    return summary;
}

static NSDictionary *OPRunDeterministicTask(NSDictionary *request) {
    long long startedMs = OPNowMs();
    NSString *goal = [request[@"goal"] isKindOfClass:[NSString class]] ? request[@"goal"] : @"";
    long long maxSteps = OPLongLongFromRequest(request, @"max_steps", 1, 1, 25);
    long long maxDurationMs = OPLongLongFromRequest(request, @"max_duration_ms", 60000, 1000, 600000);
    BOOL includeScreenshot = OPBoolFromRequest(request, @"include_screenshot", YES);
    NSDictionary *limits = @{
        @"max_steps": @(maxSteps),
        @"max_duration_ms": @(maxDurationMs),
        @"max_tool_errors": @1,
        @"no_progress_detection": @"pending_screen_provider",
        @"include_screenshot": @(includeScreenshot)
    };
    NSDictionary *task = OPStartTask(@{@"goal": goal, @"approved_capabilities": OPFullYoloCapabilities()});
    NSString *taskId = task[@"task_id"];
    OPUpdateTask(taskId, @"active", @{
        @"runner": @"deterministic",
        @"runner_pid": @(getpid()),
        @"runner_started_at": @(OPNowMs()),
        @"limits": limits
    });
    NSDictionary *beforeScreen = OPGetScreen(@{
        @"task_id": taskId ?: @"",
        @"include_screenshot": @(includeScreenshot),
        @"include_activity": @YES,
        @"include_ui_tree": @YES,
        @"reason": @"deterministic run_task preflight"
    });
    NSDictionary *action = OPActionForGoal(goal);
    NSDictionary *recordedAction = OPActionForRecording(action);
    long long stepsUsed = 1;
    OPRecordTrajectory(taskId, @"tool_call", @{
        @"tool": @"execute_action",
        @"step": @(stepsUsed),
        @"arguments": recordedAction
    });
    NSDictionary *actionResult = OPExecuteAction(@{@"task_id": taskId ?: @"", @"action": action});
    NSDictionary *afterScreen = OPGetScreen(@{
        @"task_id": taskId ?: @"",
        @"include_screenshot": @(includeScreenshot),
        @"include_activity": @YES,
        @"include_ui_tree": @YES,
        @"reason": @"deterministic run_task verification"
    });
    BOOL executed = [actionResult[@"state"] isEqualToString:@"action.executed"];
    long long durationMs = OPNowMs() - startedMs;
    BOOL durationLimited = durationMs > maxDurationMs;
    long long toolErrors = executed ? 0 : 1;
    NSString *stopReason = executed ? @"finished" : @"action_failed";
    if (durationLimited) {
        stopReason = @"duration_limit";
    } else if (stepsUsed >= maxSteps && !executed) {
        stopReason = @"step_limit_or_action_failed";
    }
    BOOL succeeded = executed && !durationLimited;
    NSString *finalStatus = succeeded ? @"completed" : @"failed";
    NSDictionary *summary = @{
        @"status": succeeded ? @"task.finished" : @"task.failed",
        @"goal": goal,
        @"task_id": taskId ?: @"",
        @"runner": @"deterministic",
        @"limits": limits,
        @"steps_used": @(stepsUsed),
        @"tool_errors": @(toolErrors),
        @"duration_ms": @(durationMs),
        @"stop_reason": stopReason,
        @"action": recordedAction,
        @"action_result": actionResult,
        @"before_screen_state": beforeScreen[@"state"] ?: @"",
        @"after_screen_state": afterScreen[@"state"] ?: @"",
        @"trajectory": OPTrajectoryPath(taskId ?: @""),
        @"source": @"openphone.agentd"
    };
    OPUpdateTask(taskId, finalStatus, @{
        @"result": summary,
        @"completed_at": @(OPNowMs())
    });
    OPRecordAudit(succeeded ? @"task_finished" : @"task_failed", taskId, @"tasks.observe",
            succeeded ? @"allow_task_scoped" : @"failed", request, stopReason);
    OPRecordTrajectory(taskId, succeeded ? @"task_finished" : @"task_failed", summary);
    return summary;
}

static NSString *OPEffectiveRunTaskMode(NSDictionary *request) {
    NSString *mode = [OPStringFromRequest(request, @"mode",
            OPStringFromRequest(request, @"runner", @"auto")) lowercaseString];
    if (mode.length == 0) {
        mode = @"auto";
    }
    if ([mode isEqualToString:@"auto"]) {
        NSDictionary *modelStatus = OPModelStatusDictionary();
        NSArray *fixtureDecisions = [request[@"model_decisions"] isKindOfClass:[NSArray class]]
                ? request[@"model_decisions"] : @[];
        mode = ([modelStatus[@"status"] isEqualToString:@"ready"] || fixtureDecisions.count > 0)
                ? @"model" : @"deterministic";
    }
    return mode;
}

static NSDictionary *OPRunTask(NSDictionary *request) {
    NSString *mode = OPEffectiveRunTaskMode(request ?: @{});
    if ([mode isEqualToString:@"model"]) {
        NSDictionary *modelStatus = OPModelStatusDictionary();
        NSArray *fixtureDecisions = [request[@"model_decisions"] isKindOfClass:[NSArray class]]
                ? request[@"model_decisions"] : @[];
        NSString *providerMode = [modelStatus[@"mode"] isKindOfClass:[NSString class]]
                ? modelStatus[@"mode"] : @"broker";
        if (fixtureDecisions.count == 0 && OPModelModeIsOpenAIRealtime(providerMode)) {
            return OPRunOpenAIRealtimeTask(request);
        }
        return OPRunModelTask(request);
    }
    if (![mode isEqualToString:@"deterministic"]) {
        return OPError(@"invalid_run_task_mode");
    }
    return OPRunDeterministicTask(request);
}

static void *OPAsyncRunTaskMain(void *context) {
    @autoreleasepool {
        NSDictionary *request = (__bridge_transfer NSDictionary *)context;
        NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
        NSString *source = OPStringFromRequest(request, @"source", @"async_run_task");
        NSString *goal = OPStringFromRequest(request, @"goal", @"");
        OPLog(@"async run_task started task_id=%@ source=%@ mode=%@",
                taskId ?: @"", source ?: @"", request[@"mode"] ?: @"auto");
        NSDictionary *result = OPRunTask(request ?: @{});
        NSString *resultTaskId = [result[@"task_id"] isKindOfClass:[NSString class]]
                ? result[@"task_id"] : taskId;
        NSString *status = [result[@"status"] isKindOfClass:[NSString class]]
                ? result[@"status"] : @"unknown";
        OPRecordContextEvent(@"async_run_task_finished", @"openphone.agentd",
                resultTaskId ?: @"", goal ?: @"", status ?: @"unknown", @{
                    @"source": source ?: @"async_run_task",
                    @"mode": request[@"mode"] ?: @"auto",
                    @"runner": result[@"runner"] ?: @"unknown",
                    @"stop_reason": result[@"stop_reason"] ?: @""
                });
        OPRecordAudit(@"async_run_task_finished", resultTaskId ?: @"", @"tasks.observe",
                [status isEqualToString:@"task.finished"] ? @"allow_task_scoped" : @"failed",
                request ?: @{}, status ?: @"unknown");
        OPLog(@"async run_task finished task_id=%@ status=%@ runner=%@ stop_reason=%@",
                resultTaskId ?: @"", status ?: @"unknown",
                result[@"runner"] ?: @"unknown", result[@"stop_reason"] ?: @"");
    }
    return NULL;
}

static NSDictionary *OPStartAsyncRunTask(NSDictionary *request) {
    pthread_t thread;
    NSDictionary *ownedRequest = [request copy] ?: @{};
    int rc = pthread_create(&thread, NULL, OPAsyncRunTaskMain,
            (__bridge_retained void *)ownedRequest);
    if (rc != 0) {
        return @{
            @"status": @"error",
            @"reason": [NSString stringWithFormat:@"pthread_create_failed:%d", rc],
            @"source": @"openphone.agentd"
        };
    }
    pthread_detach(thread);
    return @{
        @"status": @"ok",
        @"state": @"task.started_async",
        @"task_id": ownedRequest[@"task_id"] ?: @"",
        @"mode": ownedRequest[@"mode"] ?: @"auto",
        @"runner": @"async_agent_loop",
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPHardwareTrigger(NSDictionary *request) {
    NSString *trigger = OPStringFromRequest(request, @"trigger", @"hardware");
    NSString *source = OPStringFromRequest(request, @"source", @"springboard");
    NSString *reason = OPStringFromRequest(request, @"reason", @"hardware trigger received");
    NSString *taskId = [NSString stringWithFormat:@"ios-trigger-%lld-%d", OPNowMs(), getpid()];
    NSDictionary *control = OPAgentControlSummary();
    BOOL controlAllowsTrigger = ![control[@"paused"] boolValue] &&
            [control[@"hardware_triggers_enabled"] boolValue] &&
            [control[@"yolo_enabled"] boolValue];
    if (!controlAllowsTrigger && !OPBoolFromRequest(request, @"bypass_agent_control", NO)) {
        NSString *state = [control[@"paused"] boolValue] ? @"trigger.paused"
                : (![control[@"hardware_triggers_enabled"] boolValue]
                ? @"trigger.disabled" : @"trigger.yolo_disabled");
        NSDictionary *result = @{
            @"status": @"ok",
            @"state": state,
            @"trigger": trigger ?: @"hardware",
            @"task_id": taskId,
            @"source": @"openphone.agentd",
            @"runtime_authority": @"phone_local",
            @"model_loop_status": @"paused",
            @"control": control,
            @"deduped": @NO
        };
        OPRecordContextEvent(@"hardware_trigger_suppressed", source, taskId,
                trigger, state, result);
        OPRecordAudit(@"hardware_trigger_suppressed", taskId, @"background.run",
                state, request, [NSString stringWithFormat:@"trigger:%@ control:%@",
                trigger, control[@"trigger_policy"] ?: @"unknown"]);
        OPRecordTrajectory(taskId, @"hardware_trigger_suppressed", result);
        return result;
    }
    long long now = OPNowMs();
    BOOL dedupe = OPBoolFromRequest(request, @"dedupe", YES);
    long long cooldownMs = OPLongLongFromRequest(request, @"cooldown_ms", 10000, 0, 60000);
    if (dedupe && cooldownMs > 0) {
        pthread_mutex_lock(&OPHardwareTriggerMutex);
        long long ageMs = OPHardwareTriggerLastAcceptedMs > 0
                ? MAX(0, now - OPHardwareTriggerLastAcceptedMs) : cooldownMs + 1;
        BOOL duplicate = OPHardwareTriggerLastAcceptedMs > 0 && ageMs < cooldownMs;
        if (!duplicate) {
            OPHardwareTriggerLastAcceptedMs = now;
        }
        pthread_mutex_unlock(&OPHardwareTriggerMutex);
        if (duplicate) {
            NSDictionary *result = @{
                @"status": @"ok",
                @"state": @"trigger.ignored_duplicate",
                @"trigger": trigger ?: @"hardware",
                @"task_id": taskId,
                @"source": @"openphone.agentd",
                @"runtime_authority": @"phone_local",
                @"model_loop_status": @"suppressed_duplicate",
                @"deduped": @YES,
                @"cooldown_ms": @(cooldownMs),
                @"last_trigger_age_ms": @(ageMs)
            };
            OPRecordContextEvent(@"hardware_trigger_suppressed", source, taskId,
                    trigger, @"duplicate hardware trigger suppressed", result);
            OPRecordAudit(@"hardware_trigger_suppressed", taskId, @"background.run",
                    @"allow_yolo", request, [NSString stringWithFormat:@"trigger:%@ duplicate_age_ms:%lld",
                    trigger, ageMs]);
            OPRecordTrajectory(taskId, @"hardware_trigger_suppressed", result);
            return result;
        }
    }

    long long preObserveDelayMs = OPLongLongFromRequest(request,
            @"pre_observe_delay_ms", 0, 0, 5000);
    if (preObserveDelayMs > 0) {
        OPLog(@"hardware trigger pre-observe delay ms=%lld source=%@ trigger=%@",
                preObserveDelayMs, source ?: @"", trigger ?: @"");
        usleep((useconds_t)(preObserveDelayMs * 1000));
    }

    NSDictionary *screen = OPGetScreen(@{
        @"task_id": taskId,
        @"include_screenshot": @NO,
        @"include_activity": @YES,
        @"include_ui_tree": @YES,
        @"reason": reason
    });
    long long contextId = OPRecordContextEvent(@"hardware_trigger", source, taskId,
            trigger, reason, @{
                @"trigger": trigger ?: @"hardware",
                @"screen_state": screen[@"state"] ?: @"",
                @"foreground_app": screen[@"context"][@"foreground_app"] ?: @"unknown"
            });
    OPRecordAudit(@"hardware_trigger", taskId, @"background.run", @"allow_yolo",
            request, [NSString stringWithFormat:@"trigger:%@ source:%@", trigger, source]);

    NSDictionary *modelStatus = OPModelStatusDictionary();
    NSMutableDictionary *result = [@{
        @"status": @"ok",
        @"trigger": trigger ?: @"hardware",
        @"task_id": taskId,
        @"context_event_id": @(contextId),
        @"screen_state": screen[@"state"] ?: @"",
        @"source": @"openphone.agentd",
        @"runtime_authority": @"phone_local",
        @"model_loop_status": @"not_started",
        @"model_status": modelStatus[@"status"] ?: @"unknown"
    } mutableCopy];

    BOOL modelReady = [modelStatus[@"status"] isEqualToString:@"ready"];
    BOOL runTask = OPBoolFromRequest(request, @"run_task", modelReady);
    BOOL createBackgroundJob = OPBoolFromRequest(request, @"create_background_job", !runTask);
    NSString *goal = OPStringFromRequest(request, @"goal", OPDefaultHardwareTriggerGoal);
    if (goal.length == 0 || [goal isEqualToString:OPLegacyHardwareTriggerGoal]) {
        goal = OPDefaultHardwareTriggerGoal;
    }
    if (createBackgroundJob) {
        NSDictionary *jobResult = OPBackgroundJobCreate(@{
            @"task_id": taskId,
            @"title": @"Hardware volume trigger",
            @"prompt": goal,
            @"type": @"agent_turn",
            @"reason": reason,
            @"source": source,
            @"payload": @{
                @"trigger": trigger ?: @"hardware",
                @"context_event_id": @(contextId),
                @"screen_state": screen[@"state"] ?: @""
            }
        });
        result[@"background_job"] = jobResult;
        if (OPBoolFromRequest(request, @"run_background_jobs", YES) &&
                [jobResult[@"status"] isEqualToString:@"ok"]) {
            NSDictionary *createdJob = [jobResult[@"job"] isKindOfClass:[NSDictionary class]]
                    ? jobResult[@"job"] : @{};
            id createdJobId = createdJob[@"id"] ?: jobResult[@"job_id"];
            NSMutableDictionary *schedulerRequest = [@{
                @"command": @"background_job_run_due",
                @"task_id": taskId,
                @"limit": @1,
                @"max_steps": @1,
                @"max_duration_ms": @10000,
                @"source": source,
                @"reason": @"hardware trigger scheduler tick",
                @"repair_stuck": @NO,
                @"materialize_watchers": @NO,
                @"run_jobs": @NO
            } mutableCopy];
            if ([createdJobId respondsToSelector:@selector(longLongValue)] &&
                    [createdJobId longLongValue] > 0) {
                schedulerRequest[@"job_id"] = createdJobId;
            }
            result[@"scheduler"] = OPBackgroundJobRunDue(schedulerRequest);
        }
    }

    if (runTask) {
        NSString *requestedMode = OPStringFromRequest(request, @"mode", @"auto");
        NSDictionary *modeProbe = @{
            @"mode": requestedMode.length > 0 ? requestedMode : @"auto",
            @"goal": goal ?: @"",
            @"reason": reason ?: @"hardware trigger"
        };
        NSString *effectiveMode = OPEffectiveRunTaskMode(modeProbe);
        result[@"requested_run_mode"] = requestedMode.length > 0 ? requestedMode : @"auto";
        result[@"effective_run_mode"] = effectiveMode ?: @"unknown";
        if (![effectiveMode isEqualToString:@"model"]) {
            result[@"run_task"] = @{
                @"status": @"error",
                @"reason": @"model_provider_not_configured",
                @"requested_mode": requestedMode.length > 0 ? requestedMode : @"auto",
                @"effective_mode": effectiveMode ?: @"unknown",
                @"source": @"openphone.agentd"
            };
            result[@"model_loop_status"] = @"provider_not_ready";
        } else {
            NSDictionary *task = OPStartTask(@{
                @"goal": goal,
                @"approved_capabilities": OPFullYoloCapabilities()
            });
            NSString *agentTaskId = [task[@"task_id"] isKindOfClass:[NSString class]]
                    ? task[@"task_id"] : @"";
            NSMutableDictionary *runRequest = [@{
                @"task_id": agentTaskId,
                @"goal": goal,
                @"reason": reason,
                @"mode": @"model",
                @"max_steps": @(OPLongLongFromRequest(request, @"max_steps", 5, 1, 25)),
                @"max_duration_ms": @(OPLongLongFromRequest(request, @"max_duration_ms", 120000, 1000, 600000)),
                @"source": source ?: @"hardware_trigger",
                @"trigger_task_id": taskId
            } mutableCopy];
            result[@"agent_task_id"] = agentTaskId ?: @"";
            result[@"run_task"] = OPStartAsyncRunTask(runRequest);
            result[@"model_loop_status"] = [result[@"run_task"][@"status"] isEqualToString:@"ok"]
                    ? @"started_async" : @"start_failed";
        }
    }

    OPRecordTrajectory(taskId, @"hardware_trigger", result);
    return result;
}

typedef struct {
    AudioQueueRef queue;
    NSMutableData *__unsafe_unretained pcmData;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    BOOL done;
    BOOL heardSpeech;
    BOOL stopOnVAD;
    long long startedMs;
    long long lastSpeechMs;
    long long maxMs;
    long long minRecordMs;
    long long initialSpeechTimeoutMs;
    long long endSilenceMs;
    double rmsThreshold;
    double lastRms;
    double peakRms;
    UInt32 sampleRate;
    char stopReason[64];
} OPVoiceCaptureState;

static void OPVoiceSetLast(NSString *state, NSString *transcript,
        NSString *error, NSString *provider, BOOL running) {
    pthread_mutex_lock(&OPVoiceTriggerMutex);
    OPVoiceTriggerRunning = running;
    OPVoiceTriggerLastState = [state copy] ?: @"unknown";
    if (transcript != nil) {
        OPVoiceTriggerLastTranscript = [transcript copy];
    }
    if (error != nil) {
        OPVoiceTriggerLastError = [error copy];
    }
    if (provider != nil) {
        OPVoiceTriggerLastProvider = [provider copy];
    }
    if (!running) {
        OPVoiceTriggerLastFinishedMs = OPNowMs();
    }
    pthread_mutex_unlock(&OPVoiceTriggerMutex);
}

static NSDictionary *OPVoiceStatus(NSDictionary *request) {
    (void)request;
    pthread_mutex_lock(&OPVoiceTriggerMutex);
    NSDictionary *status = @{
        @"status": @"ok",
        @"state": OPVoiceTriggerRunning ? @"voice.listening_or_transcribing" :
                (OPVoiceTriggerLastState ?: @"voice.idle"),
        @"running": @(OPVoiceTriggerRunning),
        @"runtime_authority": @"phone_local",
        @"microphone_owner": @"openphone-agentd",
        @"default_transcription_provider": @"openai_transcription",
        @"apple_speech_fallback": @"explicit_debug_only",
        @"last_started_at_ms": @(OPVoiceTriggerLastStartedMs),
        @"last_finished_at_ms": @(OPVoiceTriggerLastFinishedMs),
        @"last_transcript": OPVoiceTriggerLastTranscript ?: @"",
        @"last_error": OPVoiceTriggerLastError ?: @"",
        @"last_provider": OPVoiceTriggerLastProvider ?: @"",
        @"voice_credential_file": OPVoiceCredentialPath(),
        @"audio_path": [OPVoicePath() stringByAppendingPathComponent:@"last-command.wav"],
        @"source": @"openphone.agentd"
    };
    pthread_mutex_unlock(&OPVoiceTriggerMutex);
    return status;
}

static void OPVoiceSetDoneLocked(OPVoiceCaptureState *state, const char *reason) {
    if (!state || state->done) {
        return;
    }
    state->done = YES;
    strlcpy(state->stopReason, reason ?: "done", sizeof(state->stopReason));
    pthread_cond_signal(&state->cond);
}

static double OPVoiceRMSForPCM16(const void *bytes, UInt32 byteCount) {
    if (!bytes || byteCount < sizeof(int16_t)) {
        return 0.0;
    }
    const int16_t *samples = (const int16_t *)bytes;
    UInt32 count = byteCount / sizeof(int16_t);
    double sum = 0.0;
    for (UInt32 i = 0; i < count; i++) {
        double sample = (double)samples[i];
        sum += sample * sample;
    }
    return sqrt(sum / (double)count);
}

static void OPVoiceAudioQueueInputCallback(void *userData, AudioQueueRef queue,
        AudioQueueBufferRef buffer, const AudioTimeStamp *startTime,
        UInt32 packetCount, const AudioStreamPacketDescription *packetDescriptions) {
    (void)startTime;
    (void)packetCount;
    (void)packetDescriptions;
    OPVoiceCaptureState *state = (OPVoiceCaptureState *)userData;
    if (!state || !buffer) {
        return;
    }

    long long now = OPNowMs();
    double rms = OPVoiceRMSForPCM16(buffer->mAudioData, buffer->mAudioDataByteSize);
    BOOL shouldRequeue = NO;
    pthread_mutex_lock(&state->mutex);
    if (!state->done) {
        if (buffer->mAudioDataByteSize > 0) {
            [state->pcmData appendBytes:buffer->mAudioData
                                 length:buffer->mAudioDataByteSize];
        }
        state->lastRms = rms;
        if (rms > state->peakRms) {
            state->peakRms = rms;
        }
        if (rms >= state->rmsThreshold) {
            state->heardSpeech = YES;
            state->lastSpeechMs = now;
        }

        long long elapsedMs = MAX(0, now - state->startedMs);
        if (elapsedMs >= state->maxMs) {
            OPVoiceSetDoneLocked(state, "max_duration");
        } else if (state->stopOnVAD && !state->heardSpeech &&
                elapsedMs >= state->initialSpeechTimeoutMs) {
            OPVoiceSetDoneLocked(state, "initial_speech_timeout");
        } else if (state->stopOnVAD && state->heardSpeech &&
                elapsedMs >= state->minRecordMs &&
                state->lastSpeechMs > 0 &&
                (now - state->lastSpeechMs) >= state->endSilenceMs) {
            OPVoiceSetDoneLocked(state, "end_silence");
        }
        shouldRequeue = !state->done;
    }
    if (state->done) {
        pthread_cond_signal(&state->cond);
    }
    pthread_mutex_unlock(&state->mutex);

    if (shouldRequeue) {
        AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    }
}

static void OPVoiceAppendLE16(NSMutableData *data, uint16_t value) {
    uint8_t bytes[2] = {
        (uint8_t)(value & 0xff),
        (uint8_t)((value >> 8) & 0xff)
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void OPVoiceAppendLE32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[4] = {
        (uint8_t)(value & 0xff),
        (uint8_t)((value >> 8) & 0xff),
        (uint8_t)((value >> 16) & 0xff),
        (uint8_t)((value >> 24) & 0xff)
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static NSData *OPVoiceWAVDataFromPCM16(NSData *pcmData, UInt32 sampleRate) {
    NSMutableData *wav = [NSMutableData data];
    UInt32 dataSize = (UInt32)MIN((NSUInteger)UINT32_MAX, pcmData.length);
    UInt32 riffSize = 36 + dataSize;
    [wav appendData:[@"RIFF" dataUsingEncoding:NSASCIIStringEncoding]];
    OPVoiceAppendLE32(wav, riffSize);
    [wav appendData:[@"WAVEfmt " dataUsingEncoding:NSASCIIStringEncoding]];
    OPVoiceAppendLE32(wav, 16);
    OPVoiceAppendLE16(wav, 1);
    OPVoiceAppendLE16(wav, 1);
    OPVoiceAppendLE32(wav, sampleRate);
    OPVoiceAppendLE32(wav, sampleRate * 2);
    OPVoiceAppendLE16(wav, 2);
    OPVoiceAppendLE16(wav, 16);
    [wav appendData:[@"data" dataUsingEncoding:NSASCIIStringEncoding]];
    OPVoiceAppendLE32(wav, dataSize);
    [wav appendData:pcmData ?: [NSData data]];
    return wav;
}

static NSString *OPVoiceActivateAudioSession(void) {
#if TARGET_OS_IPHONE
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (!session) {
        return @"audio_session_unavailable";
    }
    AVAudioSessionCategoryOptions options =
            AVAudioSessionCategoryOptionAllowBluetoothHFP |
            AVAudioSessionCategoryOptionDuckOthers |
            AVAudioSessionCategoryOptionDefaultToSpeaker;
    if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                         mode:AVAudioSessionModeMeasurement
                      options:options
                        error:&error]) {
        return [NSString stringWithFormat:@"set_category_failed:%@",
                error.localizedDescription ?: @"unknown"];
    }
    error = nil;
    [session setPreferredSampleRate:16000.0 error:&error];
    error = nil;
    [session setActive:YES error:&error];
    if (error) {
        return [NSString stringWithFormat:@"set_active_failed:%@",
                error.localizedDescription ?: @"unknown"];
    }
    return @"";
#else
    return @"audio_session_unavailable_on_macos";
#endif
}

static NSData *OPVoiceRecordWAV(NSDictionary *request, NSDictionary **metadataOut,
        NSString **errorOut) {
    NSString *sessionWarning = OPVoiceActivateAudioSession();
    UInt32 sampleRate = (UInt32)OPLongLongFromRequest(request,
            @"sample_rate_hz", 16000, 8000, 48000);
    // Generous defaults tuned for real conversation. People naturally pause
    // 1.5-2s between clauses when explaining a task; 1.7s of silence was
    // cutting them off mid-sentence.
    long long maxMs = OPLongLongFromRequest(request,
            @"record_max_ms", 45000, 1000, 90000);
    long long minRecordMs = OPLongLongFromRequest(request,
            @"record_min_ms", 900, 100, 10000);
    long long initialSpeechTimeoutMs = OPLongLongFromRequest(request,
            @"initial_speech_timeout_ms", 8000, 500, 20000);
    long long endSilenceMs = OPLongLongFromRequest(request,
            @"end_silence_ms", 3000, 300, 10000);
    double rmsThreshold = (double)OPLongLongFromRequest(request,
            @"rms_threshold", 700, 50, 15000);
    BOOL stopOnVAD = OPBoolFromRequest(request, @"vad", YES);

    NSMutableData *pcm = [NSMutableData data];
    OPVoiceCaptureState state;
    memset(&state, 0, sizeof(state));
    state.pcmData = pcm;
    state.stopOnVAD = stopOnVAD;
    state.startedMs = OPNowMs();
    state.maxMs = maxMs;
    state.minRecordMs = minRecordMs;
    state.initialSpeechTimeoutMs = initialSpeechTimeoutMs;
    state.endSilenceMs = endSilenceMs;
    state.rmsThreshold = rmsThreshold;
    state.sampleRate = sampleRate;
    strlcpy(state.stopReason, "unknown", sizeof(state.stopReason));
    pthread_mutex_init(&state.mutex, NULL);
    pthread_cond_init(&state.cond, NULL);

    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    format.mBytesPerPacket = 2;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 2;
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 16;

    OSStatus status = AudioQueueNewInput(&format, OPVoiceAudioQueueInputCallback,
            &state, NULL, NULL, 0, &state.queue);
    if (status != noErr || !state.queue) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"audio_queue_new_input_failed:%d",
                         (int)status];
        }
        pthread_mutex_destroy(&state.mutex);
        pthread_cond_destroy(&state.cond);
        return nil;
    }

    UInt32 bufferBytes = sampleRate * 2 / 10;
    if (bufferBytes < 2048) {
        bufferBytes = 2048;
    } else if (bufferBytes > 8192) {
        bufferBytes = 8192;
    }
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef buffer = NULL;
        status = AudioQueueAllocateBuffer(state.queue, bufferBytes, &buffer);
        if (status != noErr || !buffer) {
            if (errorOut) {
                *errorOut = [NSString stringWithFormat:@"audio_queue_allocate_buffer_failed:%d",
                             (int)status];
            }
            AudioQueueDispose(state.queue, true);
            pthread_mutex_destroy(&state.mutex);
            pthread_cond_destroy(&state.cond);
            return nil;
        }
        AudioQueueEnqueueBuffer(state.queue, buffer, 0, NULL);
    }

    status = AudioQueueStart(state.queue, NULL);
    if (status != noErr) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"audio_queue_start_failed:%d",
                         (int)status];
        }
        AudioQueueDispose(state.queue, true);
        pthread_mutex_destroy(&state.mutex);
        pthread_cond_destroy(&state.cond);
        return nil;
    }

    pthread_mutex_lock(&state.mutex);
    while (!state.done) {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        struct timespec ts;
        ts.tv_sec = tv.tv_sec + 1;
        ts.tv_nsec = tv.tv_usec * 1000;
        pthread_cond_timedwait(&state.cond, &state.mutex, &ts);
        long long now = OPNowMs();
        long long elapsedMs = MAX(0, now - state.startedMs);
        if (elapsedMs >= maxMs + 2000) {
            OPVoiceSetDoneLocked(&state, "watchdog_timeout");
        }
        if (OPVoiceCancelRequested) {
            OPVoiceSetDoneLocked(&state, "cancelled");
        }
    }
    NSString *stopReason = [NSString stringWithUTF8String:state.stopReason];
    BOOL heardSpeech = state.heardSpeech;
    double peakRms = state.peakRms;
    double lastRms = state.lastRms;
    long long durationMs = MAX(0, OPNowMs() - state.startedMs);
    pthread_mutex_unlock(&state.mutex);

    AudioQueueStop(state.queue, true);
    AudioQueueDispose(state.queue, true);
    pthread_mutex_destroy(&state.mutex);
    pthread_cond_destroy(&state.cond);

    NSData *wav = OPVoiceWAVDataFromPCM16(pcm, sampleRate);
    if (metadataOut) {
        *metadataOut = @{
            @"sample_rate_hz": @(sampleRate),
            @"pcm_bytes": @(pcm.length),
            @"wav_bytes": @(wav.length),
            @"duration_ms": @(durationMs),
            @"stop_reason": stopReason ?: @"unknown",
            @"heard_speech": @(heardSpeech),
            @"peak_rms": @(peakRms),
            @"last_rms": @(lastRms),
            @"rms_threshold": @(rmsThreshold),
            @"vad": @(stopOnVAD),
            @"audio_session_warning": sessionWarning ?: @""
        };
    }
    return wav;
}

static NSString *OPVoiceCredentialValue(NSString **sourceOut) {
    for (NSString *envName in @[@"OPENPHONE_VOICE_BEARER_TOKEN",
                                @"OPENPHONE_OPENAI_API_KEY",
                                @"OPENAI_API_KEY"]) {
        const char *value = getenv(envName.UTF8String);
        if (value && value[0] != '\0') {
            if (sourceOut) {
                *sourceOut = [NSString stringWithFormat:@"env:%@", envName];
            }
            return [NSString stringWithUTF8String:value] ?: @"";
        }
    }

    NSData *data = [NSData dataWithContentsOfFile:OPVoiceCredentialPath()];
    if (data) {
        NSString *text = [[NSString alloc] initWithData:data
                                               encoding:NSUTF8StringEncoding] ?: @"";
        text = [text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length > 0) {
            id parsed = [NSJSONSerialization JSONObjectWithData:
                    [text dataUsingEncoding:NSUTF8StringEncoding]
                                                     options:0 error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) {
                NSDictionary *object = parsed;
                for (NSString *key in @[@"openai_api_key", @"api_key",
                                        @"credential", @"bearer", @"value"]) {
                    if ([object[key] isKindOfClass:[NSString class]] &&
                            [object[key] length] > 0) {
                        if (sourceOut) {
                            *sourceOut = @"voice_credential_file";
                        }
                        return object[key];
                    }
                }
            } else {
                if (sourceOut) {
                    *sourceOut = @"voice_credential_file";
                }
                return text;
            }
        }
    }

    NSDictionary *modelConfig = OPModelConfig();
    NSString *mode = [modelConfig[@"mode"] isKindOfClass:[NSString class]]
            ? modelConfig[@"mode"] : @"";
    if (OPModelModeIsOpenAIRealtime(mode)) {
        NSString *credential = OPModelCredentialValue();
        if (credential.length > 0) {
            if (sourceOut) {
                *sourceOut = @"model_credential_file";
            }
            return credential;
        }
    }
    if (sourceOut) {
        *sourceOut = @"none";
    }
    return @"";
}

static void OPVoiceAppendMultipartText(NSMutableData *body, NSString *boundary,
        NSString *name, NSString *value) {
    NSString *part = [NSString stringWithFormat:
            @"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n",
            boundary ?: @"", name ?: @"", value ?: @""];
    [body appendData:[part dataUsingEncoding:NSUTF8StringEncoding]];
}

static void OPVoiceAppendMultipartFile(NSMutableData *body, NSString *boundary,
        NSString *name, NSString *filename, NSString *contentType, NSData *data) {
    NSString *header = [NSString stringWithFormat:
            @"--%@\r\nContent-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n"
            @"Content-Type: %@\r\n\r\n",
            boundary ?: @"", name ?: @"file", filename ?: @"audio.wav",
            contentType ?: @"application/octet-stream"];
    [body appendData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [body appendData:data ?: [NSData data]];
    [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
}

static NSDictionary *OPVoiceTranscribeOpenAI(NSData *wavData, NSDictionary *request) {
    NSString *credentialSource = nil;
    NSString *credential = OPVoiceCredentialValue(&credentialSource);
    if (credential.length == 0) {
        return OPError(@"openai_voice_credential_missing");
    }
    NSString *model = OPStringFromRequest(request,
            @"transcription_model", @"gpt-4o-mini-transcribe");
    NSString *endpoint = OPStringFromRequest(request,
            @"transcription_endpoint", @"https://api.openai.com/v1/audio/transcriptions");
    NSURL *url = [NSURL URLWithString:endpoint ?: @""];
    if (!url || !url.scheme || !url.host) {
        return OPError(@"openai_transcription_endpoint_invalid");
    }

    NSString *boundary = [NSString stringWithFormat:@"openphone-%lld-%d",
            OPNowMs(), getpid()];
    NSString *language = OPStringFromRequest(request, @"language", @"en");
    NSMutableData *body = [NSMutableData data];
    OPVoiceAppendMultipartText(body, boundary, @"model", model);
    OPVoiceAppendMultipartText(body, boundary, @"response_format", @"json");
    if (language.length > 0) {
        OPVoiceAppendMultipartText(body, boundary, @"language", language);
    }
    OPVoiceAppendMultipartFile(body, boundary, @"file", @"command.wav",
            @"audio/wav", wavData ?: [NSData data]);
    NSString *footer = [NSString stringWithFormat:@"--%@--\r\n", boundary];
    [body appendData:[footer dataUsingEncoding:NSUTF8StringEncoding]];

    long long timeoutMs = OPLongLongFromRequest(request,
            @"transcription_timeout_ms", 30000, 5000, 120000);
    NSMutableURLRequest *httpRequest = [NSMutableURLRequest requestWithURL:url
            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
        timeoutInterval:MAX(1.0, (NSTimeInterval)timeoutMs / 1000.0)];
    httpRequest.HTTPMethod = @"POST";
    [httpRequest setValue:[NSString stringWithFormat:@"Bearer %@", credential]
       forHTTPHeaderField:@"Authorization"];
    [httpRequest setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@",
                           boundary]
       forHTTPHeaderField:@"Content-Type"];
    [httpRequest setValue:@"openphone-ios-agentd" forHTTPHeaderField:@"User-Agent"];
    [httpRequest setValue:@"openphone-ios-local-user"
       forHTTPHeaderField:@"OpenAI-Safety-Identifier"];
    httpRequest.HTTPBody = body;

    NSURLResponse *response = nil;
    NSError *error = nil;
    long long startedMs = OPNowMs();
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSData *data = [NSURLConnection sendSynchronousRequest:httpRequest
                                         returningResponse:&response
                                                     error:&error];
#pragma clang diagnostic pop
    long long latencyMs = OPNowMs() - startedMs;
    if (error || !data) {
        return OPError([NSString stringWithFormat:@"openai_transcription_failed:%@",
                        error.localizedDescription ?: @"unknown"]);
    }
    NSInteger statusCode = 0;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        statusCode = [(NSHTTPURLResponse *)response statusCode];
    }
    if (statusCode < 200 || statusCode >= 300) {
        return @{
            @"status": @"error",
            @"reason": [NSString stringWithFormat:@"openai_transcription_http_status:%ld",
                        (long)statusCode],
            @"http_status": @(statusCode),
            @"response_bytes": @(data.length),
            @"provider": @"openai_transcription",
            @"source": @"openphone.agentd"
        };
    }
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        return OPError(@"openai_transcription_response_not_object");
    }
    NSDictionary *object = parsed;
    NSString *text = [object[@"text"] isKindOfClass:[NSString class]]
            ? object[@"text"] : @"";
    text = [text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) {
        return OPError(@"openai_transcription_empty");
    }
    return @{
        @"status": @"ok",
        @"provider": @"openai_transcription",
        @"credential_source": credentialSource ?: @"unknown",
        @"model": model ?: @"",
        @"transcript": text,
        @"http_status": @(statusCode),
        @"response_bytes": @(data.length),
        @"latency_ms": @(latencyMs),
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPVoiceTranscribeAppleSpeech(NSURL *audioURL, NSDictionary *request) {
    if (!audioURL) {
        return OPError(@"apple_speech_audio_url_missing");
    }
    if (!NSClassFromString(@"SFSpeechRecognizer")) {
        return OPError(@"apple_speech_framework_unavailable");
    }

    __block SFSpeechRecognizerAuthorizationStatus auth =
            [SFSpeechRecognizer authorizationStatus];
    if (auth == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        dispatch_semaphore_t authSemaphore = dispatch_semaphore_create(0);
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
            auth = status;
            dispatch_semaphore_signal(authSemaphore);
        }];
        dispatch_semaphore_wait(authSemaphore,
                dispatch_time(DISPATCH_TIME_NOW, 5000 * NSEC_PER_MSEC));
    }
    if (auth != SFSpeechRecognizerAuthorizationStatusAuthorized) {
        return OPError([NSString stringWithFormat:@"apple_speech_not_authorized:%ld",
                        (long)auth]);
    }

    NSLocale *locale = [NSLocale currentLocale] ?: [NSLocale localeWithLocaleIdentifier:@"en_US"];
    SFSpeechRecognizer *recognizer = [[SFSpeechRecognizer alloc] initWithLocale:locale];
    if (!recognizer || !recognizer.available) {
        recognizer = [[SFSpeechRecognizer alloc] initWithLocale:
                [NSLocale localeWithLocaleIdentifier:@"en_US"]];
    }
    if (!recognizer || !recognizer.available) {
        return OPError(@"apple_speech_recognizer_unavailable");
    }

    SFSpeechURLRecognitionRequest *speechRequest =
            [[SFSpeechURLRecognitionRequest alloc] initWithURL:audioURL];
    speechRequest.shouldReportPartialResults = YES;

    long long timeoutMs = OPLongLongFromRequest(request,
            @"transcription_timeout_ms", 30000, 5000, 120000);
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSString *transcript = @"";
    __block NSError *finalError = nil;
    __block BOOL finished = NO;
    SFSpeechRecognitionTask *task = [recognizer recognitionTaskWithRequest:speechRequest
            resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        if (result.bestTranscription.formattedString.length > 0) {
            transcript = result.bestTranscription.formattedString;
        }
        if (result.isFinal || error) {
            finalError = error;
            finished = YES;
            dispatch_semaphore_signal(semaphore);
        }
    }];
    if (!task) {
        return OPError(@"apple_speech_task_create_failed");
    }
    long long startedMs = OPNowMs();
    intptr_t waitResult = dispatch_semaphore_wait(semaphore,
            dispatch_time(DISPATCH_TIME_NOW, timeoutMs * NSEC_PER_MSEC));
    if (waitResult != 0) {
        [task cancel];
    }
    long long latencyMs = OPNowMs() - startedMs;
    transcript = [transcript stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (transcript.length == 0) {
        if (finalError) {
            return OPError([NSString stringWithFormat:@"apple_speech_failed:%@",
                            finalError.localizedDescription ?: @"unknown"]);
        }
        return OPError(waitResult == 0 && finished
                ? @"apple_speech_empty"
                : @"apple_speech_timeout");
    }
    return @{
        @"status": @"ok",
        @"provider": @"apple_speech_daemon",
        @"transcript": transcript,
        @"latency_ms": @(latencyMs),
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPVoiceTranscribe(NSData *wavData, NSURL *audioURL,
        NSDictionary *request) {
    NSString *provider = [OPStringFromRequest(request,
            @"transcription_provider", @"auto") lowercaseString];
    if ([provider isEqualToString:@"openai"]) {
        return OPVoiceTranscribeOpenAI(wavData, request);
    }
    if ([provider isEqualToString:@"apple"] ||
            [provider isEqualToString:@"apple_speech"]) {
        return OPVoiceTranscribeAppleSpeech(audioURL, request);
    }
    NSString *credentialSource = nil;
    NSString *credential = OPVoiceCredentialValue(&credentialSource);
    if (credential.length > 0) {
        NSDictionary *openAI = OPVoiceTranscribeOpenAI(wavData, request);
        if ([openAI[@"status"] isEqualToString:@"ok"]) {
            return openAI;
        }
        if (!OPBoolFromRequest(request, @"apple_speech_fallback", NO)) {
            return openAI;
        }
        OPLog(@"openai transcription explicit fallback provider=apple_speech reason=%@",
                openAI[@"reason"] ?: @"unknown");
        return OPVoiceTranscribeAppleSpeech(audioURL, request);
    }
    if (OPBoolFromRequest(request, @"apple_speech_fallback", NO)) {
        return OPVoiceTranscribeAppleSpeech(audioURL, request);
    }
    return OPError(@"openai_voice_credential_missing");
}

// ---- Realtime-2 streaming voice pipeline -----------------------------------
// Streams mic PCM16 straight to the OpenAI Realtime WebSocket so the server
// runs VAD and decides end-of-turn, instead of our local record-then-transcribe
// path. Output modality stays text: the model's tool calls drive the phone and
// its replies surface on the island. Barge-in: while the agent is mid-turn, a
// sustained loud RMS from the mic cancels the in-flight response so the user can
// interrupt (Android parity: RMS >= 1700 sustained for a 240ms guard).
typedef struct {
    AudioQueueRef queue;
    __unsafe_unretained OPRealtimeWebSocket *socket;
    pthread_mutex_t mutex;
    BOOL streaming;         // pushing audio to the socket
    BOOL stopped;
    BOOL bargeInArmed;      // agent is mid-turn; watch for interruption
    volatile int bargeInDetected;
    long long bargeInStartMs;
    long long sendTimeoutMs;
    double bargeInRmsThreshold;
    long long bargeInGuardMs;
    UInt32 sampleRate;
} OPRealtimeStreamState;

static void OPRealtimeStreamInputCallback(void *userData, AudioQueueRef queue,
        AudioQueueBufferRef buffer, const AudioTimeStamp *startTime,
        UInt32 packetCount, const AudioStreamPacketDescription *packetDescriptions) {
    (void)startTime;
    (void)packetCount;
    (void)packetDescriptions;
    OPRealtimeStreamState *state = (OPRealtimeStreamState *)userData;
    if (!state || !buffer) {
        return;
    }
    pthread_mutex_lock(&state->mutex);
    BOOL streaming = state->streaming && !state->stopped;
    OPRealtimeWebSocket *socket = state->socket;
    BOOL bargeArmed = state->bargeInArmed;
    double threshold = state->bargeInRmsThreshold;
    long long guardMs = state->bargeInGuardMs;
    long long sendTimeout = state->sendTimeoutMs;
    pthread_mutex_unlock(&state->mutex);

    if (!streaming || !socket) {
        if (!state->stopped) {
            AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
        }
        return;
    }

    // Barge-in detection: sustained loud input while the agent is talking.
    if (bargeArmed && buffer->mAudioDataByteSize > 0) {
        double rms = OPVoiceRMSForPCM16(buffer->mAudioData, buffer->mAudioDataByteSize);
        long long now = OPNowMs();
        pthread_mutex_lock(&state->mutex);
        if (rms >= threshold) {
            if (state->bargeInStartMs == 0) {
                state->bargeInStartMs = now;
            } else if (now - state->bargeInStartMs >= guardMs) {
                state->bargeInDetected = 1;
            }
        } else {
            state->bargeInStartMs = 0;
        }
        pthread_mutex_unlock(&state->mutex);
    }

    if (buffer->mAudioDataByteSize > 0) {
        NSData *pcm = [NSData dataWithBytesNoCopy:buffer->mAudioData
                                          length:buffer->mAudioDataByteSize
                                    freeWhenDone:NO];
        NSString *b64 = [pcm base64EncodedStringWithOptions:0];
        NSError *sendError = nil;
        [socket sendEvent:OPRealtimeAudioAppendEvent(b64)
                timeoutMs:sendTimeout > 0 ? sendTimeout : 5000
                    error:&sendError];
    }

    if (!state->stopped) {
        AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    }
}

// Start a mic AudioQueue that streams pcm16 to the socket. Returns "" on
// success or an error string. Caller owns the returned queue via state.
static NSString *OPRealtimeStreamStart(OPRealtimeStreamState *state) {
    NSString *sessionWarning = OPVoiceActivateAudioSession();
    (void)sessionWarning;
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = state->sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    format.mBytesPerPacket = 2;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 2;
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 16;
    OSStatus status = AudioQueueNewInput(&format, OPRealtimeStreamInputCallback,
            state, NULL, NULL, 0, &state->queue);
    if (status != noErr || !state->queue) {
        return [NSString stringWithFormat:@"audio_queue_new_input_failed:%d", (int)status];
    }
    UInt32 bufferBytes = state->sampleRate * 2 / 10; // ~100ms chunks
    if (bufferBytes < 2048) bufferBytes = 2048;
    else if (bufferBytes > 8192) bufferBytes = 8192;
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef buffer = NULL;
        status = AudioQueueAllocateBuffer(state->queue, bufferBytes, &buffer);
        if (status != noErr || !buffer) {
            AudioQueueDispose(state->queue, true);
            state->queue = NULL;
            return [NSString stringWithFormat:@"audio_queue_allocate_buffer_failed:%d", (int)status];
        }
        AudioQueueEnqueueBuffer(state->queue, buffer, 0, NULL);
    }
    status = AudioQueueStart(state->queue, NULL);
    if (status != noErr) {
        AudioQueueDispose(state->queue, true);
        state->queue = NULL;
        return [NSString stringWithFormat:@"audio_queue_start_failed:%d", (int)status];
    }
    return @"";
}

static void OPRealtimeStreamStop(OPRealtimeStreamState *state) {
    if (!state || !state->queue) {
        return;
    }
    pthread_mutex_lock(&state->mutex);
    state->stopped = YES;
    state->streaming = NO;
    pthread_mutex_unlock(&state->mutex);
    AudioQueueStop(state->queue, true);
    AudioQueueDispose(state->queue, true);
    state->queue = NULL;
}

// Drive the streaming realtime voice loop. Mirrors OPRunOpenAIRealtimeTask's
// tool execution, but the first user turn arrives from the mic (server-VAD)
// rather than a pre-transcribed goal. Returns a summary dict.
static NSDictionary *OPRunStreamingRealtimeVoice(NSString *voiceTaskId,
        NSDictionary *request) {
    long long startedMs = OPNowMs();
    NSDictionary *modelStatus = OPModelStatusDictionary();
    NSString *mode = [modelStatus[@"mode"] isKindOfClass:[NSString class]]
            ? modelStatus[@"mode"] : @"openai_realtime2";
    NSDictionary *config = OPModelConfig();
    NSString *model = [modelStatus[@"model"] isKindOfClass:[NSString class]]
            ? modelStatus[@"model"] : OPModelEffectiveModel(config);
    // Realtime is always OpenAI, so prefer the OpenAI voice credential. Only
    // fall back to the model credential when a realtime2 model mode is actually
    // configured (in which case model-credential.json holds the OpenAI key).
    NSString *credential = OPVoiceCredentialValue(NULL);
    if (credential.length == 0) {
        credential = OPModelCredentialValue();
    }
    long long timeoutMs = [modelStatus[@"timeout_ms"] respondsToSelector:@selector(longLongValue)]
            ? [modelStatus[@"timeout_ms"] longLongValue] : 30000;
    long long maxSteps = OPLongLongFromRequest(request, @"max_steps", 25, 1, 120);
    long long maxDurationMs = OPLongLongFromRequest(request, @"max_duration_ms",
            600000, 1000, 3300000);
    // OpenAI Realtime requires the input PCM rate >= 24000 Hz.
    UInt32 sampleRate = (UInt32)OPLongLongFromRequest(request, @"sample_rate_hz",
            24000, 24000, 48000);
    NSArray *approved = OPFullYoloCapabilities();

    NSURL *url = OPRealtimeURL(config, model);
    if (!url || !url.scheme || credential.length == 0) {
        return OPError(@"realtime_stream_endpoint_or_credential_invalid");
    }

    NSDictionary *task = OPStartTask(@{@"goal": @"Voice conversation (streaming).",
            @"approved_capabilities": approved});
    NSString *taskId = [task[@"task_id"] isKindOfClass:[NSString class]]
            ? task[@"task_id"] : voiceTaskId;
    OPUpdateTask(taskId, @"active", @{
        @"runner": @"model",
        @"model_provider": mode ?: @"openai_realtime2",
        @"model_runtime": @"openai_realtime_streaming",
        @"model": model ?: @"",
        @"runner_pid": @(getpid())
    });
    OPRecordTrajectory(taskId, @"realtime_stream_started", @{
        @"provider": mode ?: @"openai_realtime2",
        @"model": model ?: @"",
        @"sample_rate_hz": @(sampleRate)
    });

    NSError *error = nil;
    OPRealtimeWebSocket *socket = [OPRealtimeWebSocket connectWithURL:url
            bearerToken:credential timeoutMs:timeoutMs error:&error];
    if (!socket) {
        OPUpdateTask(taskId, @"failed", @{@"stop_reason": @"realtime_connect_failed"});
        return OPError(error.localizedDescription ?: @"realtime_connect_failed");
    }
    if (![socket sendEvent:OPRealtimeStreamingSessionUpdateEvent(mode, model, sampleRate)
                 timeoutMs:timeoutMs error:&error]) {
        [socket close];
        OPUpdateTask(taskId, @"failed", @{@"stop_reason": @"realtime_session_update_failed"});
        return OPError(error.localizedDescription ?: @"realtime_session_update_failed");
    }
    NSDictionary *sessionUpdated = OPRealtimeWaitForEventType(socket, @"session.updated", timeoutMs);
    if (![sessionUpdated[@"status"] isEqualToString:@"ok"]) {
        OPRecordTrajectory(taskId, @"realtime_session_update_failed",
                OPRedactedObject(sessionUpdated ?: @{}, 0));
        [socket close];
        OPUpdateTask(taskId, @"failed", @{@"stop_reason": @"realtime_session_update_failed"});
        return sessionUpdated ?: OPError(@"realtime_session_update_failed");
    }

    OPRealtimeStreamState stream;
    memset(&stream, 0, sizeof(stream));
    pthread_mutex_init(&stream.mutex, NULL);
    stream.socket = socket;
    stream.sampleRate = sampleRate;
    stream.streaming = YES;
    stream.sendTimeoutMs = MIN(timeoutMs, 5000);
    stream.bargeInRmsThreshold = (double)OPLongLongFromRequest(request,
            @"barge_in_rms", 1700, 200, 15000);
    stream.bargeInGuardMs = OPLongLongFromRequest(request, @"barge_in_guard_ms",
            240, 60, 2000);
    NSString *streamStartError = OPRealtimeStreamStart(&stream);
    if (streamStartError.length > 0) {
        [socket close];
        pthread_mutex_destroy(&stream.mutex);
        OPUpdateTask(taskId, @"failed", @{@"stop_reason": streamStartError});
        return OPError(streamStartError);
    }

    // Yellow realtime island: server-VAD is now listening on the live mic.
    OPIslandReset(@"realtime", @"Listening", @"yellow");
    OPIslandUpdate(@{@"task_id": taskId ?: @""});
    OPVoiceSetLast(@"voice.realtime_listening", @"", @"", mode ?: @"openai_realtime2", YES);

    NSString *stopReason = @"unknown";
    NSString *lastTranscript = @"";
    BOOL cancelled = NO;
    BOOL terminal = NO;
    BOOL succeeded = NO;
    long long stepsUsed = 0;
    long long toolErrors = 0;
    NSDictionary *screen = @{};
    NSString *cancelReason = @"";

    for (long long step = 1; step <= maxSteps; step++) {
        if (OPVoiceCancelRequested || OPTaskCancellationRequested(taskId, &cancelReason)) {
            cancelled = YES;
            stopReason = @"cancelled";
            break;
        }
        if (OPNowMs() - startedMs > maxDurationMs) {
            stopReason = @"duration_limit";
            break;
        }
        stepsUsed = step;

        // Wait for a server-VAD-delimited model turn. Long timeout: the user
        // may take a while to start speaking.
        pthread_mutex_lock(&stream.mutex);
        stream.bargeInArmed = NO;
        stream.bargeInStartMs = 0;
        stream.bargeInDetected = 0;
        pthread_mutex_unlock(&stream.mutex);

        NSDictionary *turn = OPRealtimeWaitForTurn(socket, MAX(timeoutMs, 60000));
        if (![turn[@"status"] isEqualToString:@"ok"]) {
            // A read/turn timeout with no speech is a natural end of conversation,
            // not an error. The socket's own receive timeout surfaces as
            // "realtime_read_failed:realtime_receive_timeout"; treat any timeout
            // flavor as a graceful idle end.
            stopReason = [turn[@"reason"] isKindOfClass:[NSString class]]
                    ? turn[@"reason"] : @"realtime_turn_failed";
            if ([stopReason isEqualToString:@"realtime_turn_timeout"] ||
                    [stopReason rangeOfString:@"timeout"].location != NSNotFound) {
                stopReason = @"conversation_idle_timeout";
                terminal = YES;
                succeeded = YES;
            } else {
                toolErrors += 1;
            }
            break;
        }
        NSString *transcript = [turn[@"input_transcript"] isKindOfClass:[NSString class]]
                ? turn[@"input_transcript"] : @"";
        if (transcript.length > 0) {
            lastTranscript = transcript;
            OPRecordVoiceTurn(transcript, taskId);
            OPIslandUpdate(@{@"transcript": transcript, @"mode": @"realtime",
                    @"accent": @"yellow", @"task_id": taskId ?: @""});
        }
        NSString *finalText = [turn[@"final_text"] isKindOfClass:[NSString class]]
                ? turn[@"final_text"] : @"";
        NSArray *calls = [turn[@"function_calls"] isKindOfClass:[NSArray class]]
                ? turn[@"function_calls"] : @[];

        if (calls.count == 0) {
            if (finalText.length > 0) {
                OPIslandPublishAssistantMessage(finalText, taskId);
            }
            // No tool call: agent spoke or is waiting. Re-arm mic for next turn.
            pthread_mutex_lock(&stream.mutex);
            stream.bargeInArmed = YES;
            pthread_mutex_unlock(&stream.mutex);
            continue;
        }

        for (id value in calls) {
            if (![value isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *call = value;
            if (OPVoiceCancelRequested || OPTaskCancellationRequested(taskId, &cancelReason)) {
                cancelled = YES;
                stopReason = @"cancelled";
                break;
            }
            NSDictionary *decision = OPRealtimeDecisionFromCall(call);
            NSDictionary *guardrail = nil;
            decision = OPModelDecisionByApplyingGuardrails(decision, lastTranscript, step, &guardrail);
            NSString *tool = [decision[@"tool"] isKindOfClass:[NSString class]]
                    ? decision[@"tool"] : @"";
            if (![OPModelToolNames() containsObject:tool]) {
                toolErrors += 1;
                NSError *outErr = nil;
                OPRealtimeSendFunctionOutput(socket, call[@"call_id"],
                        OPError([NSString stringWithFormat:@"unknown_model_tool:%@", tool]),
                        timeoutMs, &outErr);
                continue;
            }
            OPIslandPublishToolStep(taskId, tool, @"tool_running", step, maxSteps);
            {
                NSString *msg = [decision[@"assistant_message"] isKindOfClass:[NSString class]]
                        ? decision[@"assistant_message"] : @"";
                if (msg.length > 0) OPIslandPublishAssistantMessage(msg, taskId);
            }
            if (screen.count == 0 && OPModelToolDrivesUI(tool)) {
                screen = OPModelCompactScreenForLoop(OPGetScreen(@{
                    @"task_id": taskId ?: @"",
                    @"include_screenshot": @YES,
                    @"include_activity": @YES,
                    @"include_ui_tree": @YES,
                    @"compact_trajectory": @YES,
                    @"reason": @"realtime stream pre-action observation"
                }));
            }
            NSDictionary *toolResult = OPModelExecuteDecision(decision, taskId, approved);
            NSString *state = [toolResult[@"state"] isKindOfClass:[NSString class]]
                    ? toolResult[@"state"] : @"";
            NSError *outputError = nil;
            OPRealtimeSendFunctionOutput(socket, call[@"call_id"], toolResult ?: @{},
                    timeoutMs, &outputError);
            OPRealtimeSendScreenFollowupIfUseful(socket, tool, toolResult ?: @{},
                    timeoutMs, &outputError);
            if ([tool isEqualToString:@"finish_task"] || [state isEqualToString:@"task.finished"]) {
                terminal = YES;
                succeeded = YES;
                stopReason = @"finish_task";
                break;
            }
            if ([tool isEqualToString:@"fail_task"] || [state isEqualToString:@"task.failed"]) {
                terminal = YES;
                stopReason = @"fail_task";
                break;
            }
        }
        if (terminal || cancelled) {
            break;
        }
        // Post-action: re-arm barge-in and keep the loop alive for follow-ups.
        pthread_mutex_lock(&stream.mutex);
        stream.bargeInArmed = YES;
        pthread_mutex_unlock(&stream.mutex);
        if (stream.bargeInDetected) {
            OPRecordTrajectory(taskId, @"realtime_barge_in", @{@"step": @(step)});
            [socket sendEvent:@{@"type": @"response.cancel"} timeoutMs:timeoutMs error:&error];
            pthread_mutex_lock(&stream.mutex);
            stream.bargeInDetected = 0;
            stream.bargeInStartMs = 0;
            pthread_mutex_unlock(&stream.mutex);
        }
    }

    OPRealtimeStreamStop(&stream);
    [socket close];
    pthread_mutex_destroy(&stream.mutex);

    if ([stopReason isEqualToString:@"unknown"]) {
        stopReason = cancelled ? @"cancelled" : (stepsUsed >= maxSteps ? @"step_limit" : @"model_stopped");
    }
    long long durationMs = OPNowMs() - startedMs;
    NSDictionary *summary = @{
        @"status": succeeded ? @"task.finished" : (cancelled ? @"task.cancelled" : @"task.failed"),
        @"task_id": taskId ?: @"",
        @"runner": @"model",
        @"model_provider": mode ?: @"openai_realtime2",
        @"model_runtime": @"openai_realtime_streaming",
        @"model": model ?: @"",
        @"steps_used": @(stepsUsed),
        @"tool_errors": @(toolErrors),
        @"duration_ms": @(durationMs),
        @"stop_reason": stopReason ?: @"unknown",
        @"last_transcript": lastTranscript ?: @"",
        @"trajectory": OPTrajectoryPath(taskId ?: @""),
        @"source": @"openphone.agentd"
    };
    OPUpdateTask(taskId, succeeded ? @"completed" : (cancelled ? @"stopped" : @"failed"), @{
        @"model_loop_summary": summary,
        @"completed_at": @(OPNowMs())
    });
    OPRecordTrajectory(taskId, @"realtime_stream_finished", summary);
    if (succeeded) {
        OPIslandReset(@"success", @"Done", @"green");
    } else if (cancelled) {
        OPIslandReset(@"idle", @"Cancelled", @"cyan");
    } else {
        OPIslandReset(@"error", @"Stopped", @"red");
    }
    OPVoiceSetLast(succeeded ? @"voice.realtime_finished" : @"voice.realtime_stopped",
            lastTranscript, succeeded ? @"" : stopReason, mode ?: @"openai_realtime2", NO);
    return summary;
}

static void *OPAsyncVoiceTriggerMain(void *context) {
    @autoreleasepool {
        NSDictionary *request = (__bridge_transfer NSDictionary *)context;
        NSString *voiceTaskId = [NSString stringWithFormat:@"ios-voice-%lld-%d",
                OPNowMs(), getpid()];
        NSString *source = OPStringFromRequest(request,
                @"source", @"openphone_agentd_voice");
        OPVoiceSetLast(@"voice.recording", @"", @"", @"", YES);
        OPIslandReset(@"listening", @"Listening", @"red");
        OPIslandUpdate(@{@"task_id": voiceTaskId ?: @""});
        OPRecordContextEvent(@"voice_trigger_started", source, voiceTaskId,
                @"volume voice trigger", @"daemon microphone capture started", @{
            @"microphone_owner": @"openphone-agentd",
            @"runtime_authority": @"phone_local"
        });
        OPRecordAudit(@"voice_trigger_started", voiceTaskId, @"background.run",
                @"allow_yolo", request ?: @{}, @"daemon microphone capture");

        // Realtime-2 streaming path: hand the live mic to the OpenAI Realtime
        // WebSocket (server-VAD end-of-turn), skipping record-then-transcribe.
        // Opt out per-request with stream:false for the legacy capture path.
        NSDictionary *voiceModelStatus = OPModelStatusDictionary();
        NSString *voiceMode = [voiceModelStatus[@"mode"] isKindOfClass:[NSString class]]
                ? voiceModelStatus[@"mode"] : @"";
        if ([voiceMode isEqualToString:@"openai_realtime2"] &&
                OPBoolFromRequest(request ?: @{}, @"stream", YES)) {
            NSDictionary *streamSummary = OPRunStreamingRealtimeVoice(voiceTaskId, request ?: @{});
            OPRecordAudit(@"voice_trigger_finished", voiceTaskId, @"background.run",
                    [streamSummary[@"status"] isEqualToString:@"task.finished"] ? @"completed" : @"stopped",
                    request ?: @{}, [streamSummary[@"stop_reason"] isKindOfClass:[NSString class]]
                            ? streamSummary[@"stop_reason"] : @"streaming");
            OPRecordContextEvent(@"voice_trigger_finished", source, voiceTaskId,
                    @"realtime streaming voice", @"streaming voice loop finished",
                    streamSummary ?: @{});
            return NULL;
        }

        NSDictionary *captureMetadata = nil;
        NSString *captureError = nil;
        NSData *wavData = OPVoiceRecordWAV(request ?: @{}, &captureMetadata, &captureError);
        NSString *audioPath = [OPVoicePath() stringByAppendingPathComponent:@"last-command.wav"];
        NSURL *audioURL = [NSURL fileURLWithPath:audioPath];
        if (wavData.length > 0) {
            [wavData writeToFile:audioPath atomically:YES];
            chmod(audioPath.UTF8String, 0600);
        }
        NSString *captureStopReason = [captureMetadata[@"stop_reason"] isKindOfClass:[NSString class]]
                ? captureMetadata[@"stop_reason"] : @"";
        if ([captureStopReason isEqualToString:@"cancelled"]) {
            OPVoiceSetLast(@"voice.cancelled", @"", @"cancelled", @"audio_queue", NO);
            OPIslandReset(@"idle", @"Cancelled", @"cyan");
            OPLog(@"voice trigger cancelled during capture");
            return NULL;
        }
        if (!wavData || wavData.length == 0) {
            NSString *reason = captureError ?: @"voice_capture_empty";
            OPVoiceSetLast(@"voice.capture_failed", @"", reason, @"audio_queue", NO);
            OPIslandReset(@"error", @"Microphone failed", @"red");
            NSDictionary *result = @{
                @"status": @"error",
                @"reason": reason,
                @"task_id": voiceTaskId,
                @"capture": captureMetadata ?: @{},
                @"source": @"openphone.agentd"
            };
            OPRecordContextEvent(@"voice_trigger_failed", source, voiceTaskId,
                    @"voice capture", reason, result);
            OPRecordAudit(@"voice_trigger_failed", voiceTaskId, @"background.run",
                    @"failed", request ?: @{}, reason);
            OPRecordTrajectory(voiceTaskId, @"voice_trigger_failed", result);
            OPLog(@"voice trigger capture failed reason=%@", reason);
            return NULL;
        }

        OPVoiceSetLast(@"voice.transcribing", @"", @"", @"", YES);
        OPIslandUpdate(@{@"mode": @"transcribing",
                         @"subtitle": @"Transcribing",
                         @"accent": @"blue"});
        NSDictionary *transcription = OPVoiceTranscribe(wavData, audioURL, request ?: @{});
        if (![transcription[@"status"] isEqualToString:@"ok"]) {
            NSString *reason = [transcription[@"reason"] isKindOfClass:[NSString class]]
                    ? transcription[@"reason"] : @"voice_transcription_failed";
            OPVoiceSetLast(@"voice.transcription_failed", @"", reason,
                    transcription[@"provider"] ?: @"unknown", NO);
            OPIslandReset(@"error", @"Transcription failed", @"red");
            NSMutableDictionary *result = [@{
                @"status": @"error",
                @"reason": reason,
                @"task_id": voiceTaskId,
                @"capture": captureMetadata ?: @{},
                @"transcription": transcription ?: @{},
                @"source": @"openphone.agentd"
            } mutableCopy];
            OPRecordContextEvent(@"voice_trigger_failed", source, voiceTaskId,
                    @"voice transcription", reason, result);
            OPRecordAudit(@"voice_trigger_failed", voiceTaskId, @"background.run",
                    @"failed", request ?: @{}, reason);
            OPRecordTrajectory(voiceTaskId, @"voice_trigger_failed", result);
            OPLog(@"voice trigger transcription failed reason=%@", reason);
            return NULL;
        }

        NSString *transcript = [transcription[@"transcript"] isKindOfClass:[NSString class]]
                ? transcription[@"transcript"] : @"";
        transcript = [transcript stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *provider = [transcription[@"provider"] isKindOfClass:[NSString class]]
                ? transcription[@"provider"] : @"unknown";
        if (transcript.length == 0) {
            OPVoiceSetLast(@"voice.empty_transcript", @"", @"empty_transcript",
                    provider, NO);
            OPIslandReset(@"error", @"No speech heard", @"orange");
            OPRecordContextEvent(@"voice_trigger_empty", source, voiceTaskId,
                    @"voice transcription", @"empty transcript", @{
                @"capture": captureMetadata ?: @{},
                @"provider": provider ?: @"unknown"
            });
            OPLog(@"voice trigger empty transcript provider=%@", provider);
            return NULL;
        }

        OPVoiceSetLast(@"voice.agent_starting", transcript, @"", provider, YES);
        // Prepend recent conversation context if a follow-up turn arrives within 10s.
        NSArray *recentTurns = OPRecentVoiceTurnsSnapshot(10 * 1000);
        NSString *effectiveGoal = transcript;
        if (recentTurns.count > 0) {
            NSMutableString *contextGoal = [NSMutableString string];
            [contextGoal appendString:@"Follow-up to recent voice turn(s):\n"];
            for (NSDictionary *t in recentTurns) {
                [contextGoal appendFormat:@"- \"%@\"\n", t[@"transcript"] ?: @""];
            }
            [contextGoal appendFormat:@"\nCurrent request: %@", transcript];
            effectiveGoal = contextGoal;
            OPLog(@"voice follow-up context turns=%lu", (unsigned long)recentTurns.count);
        }
        OPRecordVoiceTurn(transcript, voiceTaskId);
        OPIslandUpdate(@{@"mode": @"thinking",
                         @"subtitle": @"Thinking",
                         @"transcript": transcript ?: @"",
                         @"goal": transcript ?: @"",
                         @"accent": @"blue"});
        NSDictionary *hardwareRequest = @{
            @"command": @"hardware_trigger",
            @"trigger": OPStringFromRequest(request, @"trigger", @"volume_up_down_combo"),
            @"source": @"openphone_agentd_voice",
            @"reason": @"daemon microphone transcript",
            @"goal": effectiveGoal,
            @"mode": OPStringFromRequest(request, @"mode", @"auto"),
            @"run_task": @YES,
            @"create_background_job": @NO,
            @"run_background_jobs": @NO,
            @"dedupe": @NO,
            @"max_steps": @(OPLongLongFromRequest(request, @"max_steps", 25, 1, 25)),
            @"max_duration_ms": @(OPLongLongFromRequest(request,
                    @"max_duration_ms", 600000, 1000, 600000)),
            @"trigger_input": @"daemon_microphone_transcript",
            @"voice_task_id": voiceTaskId,
            @"voice_provider": provider,
            @"voice_capture": captureMetadata ?: @{}
        };
        NSDictionary *agentStart = OPHardwareTrigger(hardwareRequest);
        BOOL started = [agentStart[@"model_loop_status"] isEqualToString:@"started_async"];
        NSString *finalState = started ? @"voice.agent_started" : @"voice.agent_not_started";
        OPVoiceSetLast(finalState, transcript, started ? @"" :
                (agentStart[@"model_loop_status"] ?: agentStart[@"state"] ?: @"agent_not_started"),
                provider, NO);
        NSDictionary *result = @{
            @"status": @"ok",
            @"state": finalState,
            @"task_id": voiceTaskId,
            @"transcript": transcript,
            @"provider": provider,
            @"capture": captureMetadata ?: @{},
            @"transcription": transcription ?: @{},
            @"agent_start": agentStart ?: @{},
            @"source": @"openphone.agentd"
        };
        OPRecordContextEvent(@"voice_trigger_finished", source, voiceTaskId,
                transcript, finalState, result);
        OPRecordAudit(@"voice_trigger_finished", voiceTaskId, @"background.run",
                started ? @"allow_yolo" : @"failed", hardwareRequest, finalState);
        OPRecordTrajectory(voiceTaskId, @"voice_trigger_finished", result);
        OPLog(@"voice trigger finished state=%@ provider=%@ transcript_chars=%lu",
                finalState, provider, (unsigned long)transcript.length);
    }
    return NULL;
}

static NSDictionary *OPVoiceTrigger(NSDictionary *request) {
    pthread_mutex_lock(&OPVoiceTriggerMutex);
    if (OPVoiceTriggerRunning) {
        NSDictionary *result = @{
            @"status": @"ok",
            @"state": @"voice.already_running",
            @"runtime_authority": @"phone_local",
            @"microphone_owner": @"openphone-agentd",
            @"last_started_at_ms": @(OPVoiceTriggerLastStartedMs),
            @"source": @"openphone.agentd"
        };
        pthread_mutex_unlock(&OPVoiceTriggerMutex);
        return result;
    }
    pthread_mutex_unlock(&OPVoiceTriggerMutex);

    NSString *provider = [OPStringFromRequest(request,
            @"transcription_provider", @"auto") lowercaseString];
    BOOL explicitAppleDebug = [provider isEqualToString:@"apple"] ||
            [provider isEqualToString:@"apple_speech"] ||
            OPBoolFromRequest(request, @"apple_speech_fallback", NO) ||
            OPBoolFromRequest(request, @"allow_record_without_credential", NO);
    NSString *credentialSource = nil;
    NSString *credential = explicitAppleDebug ? @"" : OPVoiceCredentialValue(&credentialSource);
    if (!explicitAppleDebug && credential.length == 0) {
        pthread_mutex_lock(&OPVoiceTriggerMutex);
        OPVoiceTriggerLastStartedMs = OPNowMs();
        pthread_mutex_unlock(&OPVoiceTriggerMutex);
        OPVoiceSetLast(@"voice.credential_missing", @"",
                @"openai_voice_credential_missing", @"openai_transcription", NO);
        OPIslandReset(@"error", @"Need OpenAI voice key", @"orange");
        NSDictionary *result = @{
            @"status": @"error",
            @"state": @"voice.credential_missing",
            @"reason": @"openai_voice_credential_missing",
            @"runtime_authority": @"phone_local",
            @"microphone_owner": @"openphone-agentd",
            @"default_transcription_provider": @"openai_transcription",
            @"voice_credential_file": OPVoiceCredentialPath(),
            @"source": @"openphone.agentd"
        };
        OPRecordContextEvent(@"voice_trigger_suppressed", @"openphone_agentd_voice",
                [NSString stringWithFormat:@"ios-voice-%lld-%d", OPNowMs(), getpid()],
                @"voice credential", @"openai_voice_credential_missing", result);
        OPLog(@"voice trigger suppressed reason=openai_voice_credential_missing");
        return result;
    }

    pthread_mutex_lock(&OPVoiceTriggerMutex);
    OPVoiceTriggerRunning = YES;
    OPVoiceTriggerLastStartedMs = OPNowMs();
    OPVoiceTriggerLastState = @"voice.starting";
    OPVoiceTriggerLastError = @"";
    OPVoiceCancelRequested = 0;
    pthread_mutex_unlock(&OPVoiceTriggerMutex);

    NSMutableDictionary *ownedRequest = [request mutableCopy] ?: [NSMutableDictionary dictionary];
    if (!ownedRequest[@"mode"]) {
        ownedRequest[@"mode"] = @"auto";
    }
    if (!ownedRequest[@"max_steps"]) {
        ownedRequest[@"max_steps"] = @25;
    }
    if (!ownedRequest[@"max_duration_ms"]) {
        ownedRequest[@"max_duration_ms"] = @600000;
    }
    pthread_t thread;
    int rc = pthread_create(&thread, NULL, OPAsyncVoiceTriggerMain,
            (__bridge_retained void *)[ownedRequest copy]);
    if (rc != 0) {
        OPVoiceSetLast(@"voice.start_failed", @"",
                [NSString stringWithFormat:@"pthread_create_failed:%d", rc],
                @"", NO);
        return @{
            @"status": @"error",
            @"reason": [NSString stringWithFormat:@"pthread_create_failed:%d", rc],
            @"source": @"openphone.agentd"
        };
    }
    pthread_detach(thread);
    return @{
        @"status": @"ok",
        @"state": @"voice.started_async",
        @"runtime_authority": @"phone_local",
        @"microphone_owner": @"openphone-agentd",
        @"max_steps": ownedRequest[@"max_steps"] ?: @25,
        @"max_duration_ms": ownedRequest[@"max_duration_ms"] ?: @600000,
        @"source": @"openphone.agentd"
    };
}

static NSDictionary *OPVoiceTranscribeFile(NSDictionary *request) {
    NSString *path = OPStringFromRequest(request, @"path",
            OPStringFromRequest(request, @"audio_path",
            [OPVoicePath() stringByAppendingPathComponent:@"last-command.wav"]));
    if (path.length == 0) {
        return OPError(@"voice_audio_path_missing");
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length == 0) {
        return OPError(@"voice_audio_file_missing_or_empty");
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    NSDictionary *result = OPVoiceTranscribe(data, url, request ?: @{});
    NSMutableDictionary *withMetadata = [result mutableCopy] ?: [NSMutableDictionary dictionary];
    withMetadata[@"audio_path"] = path;
    withMetadata[@"audio_bytes"] = @(data.length);
    return withMetadata;
}

static pthread_t OPVolumeTriggerThread;
static volatile int OPVolumeTriggerThreadStarted = 0;
static volatile int OPVolumeTriggerCallbackRegistered = 0;
static volatile int OPVolumeTriggerActivationAttempted = 0;
static volatile int OPVolumeTriggerActivated = 0;
static volatile long long OPVolumeTriggerEventsSeen = 0;
static volatile long long OPVolumeTriggerKeyboardEventsSeen = 0;
static volatile long long OPVolumeTriggerCount = 0;
static volatile long long OPVolumeTriggerLastEventMs = 0;
static volatile long long OPVolumeTriggerLastTriggerMs = 0;
static volatile uint32_t OPVolumeTriggerLastUsagePage = 0;
static volatile uint32_t OPVolumeTriggerLastUsage = 0;
static volatile int OPVolumeTriggerLastDown = 0;
static CFAbsoluteTime OPVolumeTriggerLastUpSeconds = 0;
static CFAbsoluteTime OPVolumeTriggerLastDownSeconds = 0;
static CFAbsoluteTime OPVolumeTriggerLastFireSeconds = 0;
static NSString *OPVolumeTriggerStartError = nil;
static NSString *OPVolumeTriggerActivationError = nil;
static NSString *OPVolumeTriggerLastRoute = nil;
static NSString *OPVolumeTriggerLastFireState = nil;
static NSString *OPVolumeTriggerLastFireTaskId = nil;

static void OPVolumeTriggerFire(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSDictionary *preferences = OPVolumeTriggerPreferences();
            BOOL daemonVoice = OPBoolFromRequest(preferences, @"DaemonVoiceAgent", YES);
            NSDictionary *result = nil;
            if (daemonVoice) {
                OPVolumeTriggerLastRoute = @"daemon_voice_agent";
                result = OPVoiceTrigger(@{
                    @"command": @"voice_trigger",
                    @"trigger": @"volume_up_down_combo",
                    @"source": @"agentd_hid_listener",
                    @"reason": @"phone-local HID volume combo",
                    @"mode": @"auto",
                    @"max_steps": @25,
                    @"max_duration_ms": @600000
                });
                OPVolumeTriggerLastFireState = result[@"state"] ?: result[@"reason"] ?: @"";
                OPVolumeTriggerLastFireTaskId = result[@"task_id"] ?: @"";
            } else {
                OPVolumeTriggerLastRoute = @"direct_hardware_trigger";
                NSMutableDictionary *request = [@{
                    @"command": @"hardware_trigger",
                    @"trigger": @"volume_up_down_combo",
                    @"source": @"agentd_hid_listener",
                    @"reason": @"phone-local HID volume combo",
                    @"goal": OPVolumeTriggerGoalFromPreferences(preferences),
                    @"mode": @"auto",
                    @"run_task": @(OPBoolFromRequest(preferences, @"RunTask", YES)),
                    @"create_background_job": @(OPBoolFromRequest(preferences, @"CreateBackgroundJob", NO)),
                    @"run_background_jobs": @(OPBoolFromRequest(preferences, @"RunBackgroundJobs", NO)),
                    @"cooldown_ms": @(OPVolumeTriggerCooldownMs(preferences)),
                    @"max_steps": @5,
                    @"max_duration_ms": @120000,
                    @"trigger_input": @"daemon_hid_listener"
                } mutableCopy];
                result = OPHardwareTrigger(request);
                OPVolumeTriggerLastFireState = result[@"model_loop_status"] ?: result[@"state"] ?: @"";
                OPVolumeTriggerLastFireTaskId = result[@"agent_task_id"] ?: result[@"task_id"] ?: @"";
            }
            OPLog(@"volume trigger fired route=%@ result_status=%@ state=%@ task_id=%@",
                    OPVolumeTriggerLastRoute ?: @"",
                    result[@"status"] ?: @"unknown",
                    OPVolumeTriggerLastFireState ?: @"",
                    OPVolumeTriggerLastFireTaskId ?: @"");
        }
    });
}

static void OPVolumeTriggerRecordButton(BOOL volumeUp) {
    NSDictionary *preferences = OPVolumeTriggerPreferences();
    if (!OPBoolFromRequest(preferences, @"Enabled", YES)) {
        OPLog(@"volume trigger button ignored provider=agentd_hid_listener reason=disabled");
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (volumeUp) {
        OPVolumeTriggerLastUpSeconds = now;
    } else {
        OPVolumeTriggerLastDownSeconds = now;
    }

    BOOL combo = fabs(OPVolumeTriggerLastUpSeconds - OPVolumeTriggerLastDownSeconds) <=
            ((double)OPVolumeTriggerWindowMs(preferences) / 1000.0);
    BOOL cooledDown = (now - OPVolumeTriggerLastFireSeconds) >=
            ((double)OPVolumeTriggerCooldownMs(preferences) / 1000.0);
    if (combo && cooledDown) {
        OPVolumeTriggerLastFireSeconds = now;
        OPVolumeTriggerLastTriggerMs = OPNowMs();
        OPVolumeTriggerCount++;
        OPLog(@"volume trigger combo detected provider=agentd_hid_listener");
        OPVolumeTriggerFire();
    }
}

static void OPVolumeTriggerEventCallback(void *target, void *refcon,
        OPHIDEventQueueRef queue, OPHIDEventRef event) {
    (void)target;
    (void)refcon;
    (void)queue;
    if (!event || !OPHIDEventGetType || !OPHIDEventGetIntegerValue) {
        return;
    }
    OPVolumeTriggerEventsSeen++;
    uint32_t type = OPHIDEventGetType(event);
    if (type != OPIOHIDEventTypeKeyboard) {
        return;
    }
    OPVolumeTriggerKeyboardEventsSeen++;
    uint32_t usagePage = (uint32_t)OPHIDEventGetIntegerValue(event,
            OPIOHIDEventFieldKeyboardUsagePage);
    uint32_t usage = (uint32_t)OPHIDEventGetIntegerValue(event,
            OPIOHIDEventFieldKeyboardUsage);
    int down = OPHIDEventGetIntegerValue(event, OPIOHIDEventFieldKeyboardDown);
    OPVolumeTriggerLastEventMs = OPNowMs();
    OPVolumeTriggerLastUsagePage = usagePage;
    OPVolumeTriggerLastUsage = usage;
    OPVolumeTriggerLastDown = down;
    if (!down || usagePage != OPIOHIDUsagePageConsumer) {
        return;
    }
    if (usage == OPIOHIDUsageConsumerVolumeIncrement) {
        OPVolumeTriggerRecordButton(YES);
    } else if (usage == OPIOHIDUsageConsumerVolumeDecrement) {
        OPVolumeTriggerRecordButton(NO);
    }
}

static void *OPVolumeTriggerThreadMain(void *unused) {
    (void)unused;
    @autoreleasepool {
        OPEnsureHIDInputLoaded();
        if (!OPHIDCreateSimpleClient && !OPHIDCreateClient) {
            OPVolumeTriggerStartError = @"missing_hid_client_create";
            OPLog(@"volume trigger listener unavailable: %@", OPVolumeTriggerStartError);
            return NULL;
        }
        if (!OPHIDRegisterEventCallback || !OPHIDScheduleWithRunLoop ||
                !OPHIDEventGetType || !OPHIDEventGetIntegerValue) {
            OPVolumeTriggerStartError = @"missing_hid_callback_symbols";
            OPLog(@"volume trigger listener unavailable: %@", OPVolumeTriggerStartError);
            return NULL;
        }
        OPHIDEventSystemClientRef client = OPHIDCreateSimpleClient
                ? OPHIDCreateSimpleClient(kCFAllocatorDefault)
                : OPHIDCreateClient(kCFAllocatorDefault);
        if (!client) {
            OPVolumeTriggerStartError = @"client_create_failed";
            OPLog(@"volume trigger listener unavailable: %@", OPVolumeTriggerStartError);
            return NULL;
        }
        OPHIDRegisterEventCallback(client, OPVolumeTriggerEventCallback, NULL, NULL);
        OPHIDScheduleWithRunLoop(client, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        OPVolumeTriggerActivationAttempted = 0;
        OPVolumeTriggerActivated = 0;
        OPVolumeTriggerActivationError = @"skipped_runloop_client_avoids_ios_assert";
        OPVolumeTriggerCallbackRegistered = 1;
        OPLog(@"volume trigger listener started provider=IOHIDEventSystemClient activated=%d reason=%@",
                OPVolumeTriggerActivated != 0, OPVolumeTriggerActivationError ?: @"");
        CFRunLoopRun();
    }
    return NULL;
}

static void OPStartVolumeTriggerListener(void) {
    if (OPVolumeTriggerThreadStarted) {
        return;
    }
    OPVolumeTriggerThreadStarted = 1;
    int rc = pthread_create(&OPVolumeTriggerThread, NULL, OPVolumeTriggerThreadMain, NULL);
    if (rc != 0) {
        OPVolumeTriggerThreadStarted = 0;
        OPVolumeTriggerStartError = [NSString stringWithFormat:@"pthread_create_failed:%d", rc];
        OPLog(@"volume trigger listener failed: %@", OPVolumeTriggerStartError);
        return;
    }
    pthread_detach(OPVolumeTriggerThread);
}

static NSDictionary *OPVolumeTriggerStatus(void) {
    BOOL symbolsAvailable = OPHIDRegisterEventCallback && OPHIDScheduleWithRunLoop
            && OPHIDEventGetType && OPHIDEventGetIntegerValue;
    NSDictionary *springBoardFallback = OPSpringBoardTriggerStatus();
    NSDictionary *preferences = OPVolumeTriggerPreferences();
    return @{
        @"status": OPVolumeTriggerCallbackRegistered
                ? @"implemented_experimental"
                : (OPVolumeTriggerThreadStarted ? @"starting_or_unavailable" : @"not_started"),
        @"provider": @"IOKit.IOHIDEventSystemClient.event_callback",
        @"thread_started": @(OPVolumeTriggerThreadStarted != 0),
        @"callback_registered": @(OPVolumeTriggerCallbackRegistered != 0),
        @"activation_attempted": @(OPVolumeTriggerActivationAttempted != 0),
        @"activated": @(OPVolumeTriggerActivated != 0),
        @"activation_error": OPVolumeTriggerActivationError ?: @"",
        @"symbols_available": @(symbolsAvailable),
        @"events_seen": @((long long)OPVolumeTriggerEventsSeen),
        @"keyboard_events_seen": @((long long)OPVolumeTriggerKeyboardEventsSeen),
        @"trigger_count": @((long long)OPVolumeTriggerCount),
        @"last_event_ms": @((long long)OPVolumeTriggerLastEventMs),
        @"last_trigger_ms": @((long long)OPVolumeTriggerLastTriggerMs),
        @"last_usage_page": @((uint32_t)OPVolumeTriggerLastUsagePage),
        @"last_usage": @((uint32_t)OPVolumeTriggerLastUsage),
        @"last_down": @(OPVolumeTriggerLastDown != 0),
        @"start_error": OPVolumeTriggerStartError ?: @"",
        @"last_route": OPVolumeTriggerLastRoute ?: @"",
        @"last_fire_state": OPVolumeTriggerLastFireState ?: @"",
        @"last_fire_task_id": OPVolumeTriggerLastFireTaskId ?: @"",
        @"preferences": @{
            @"enabled": @(OPBoolFromRequest(preferences, @"Enabled", YES)),
            @"daemon_voice_agent": @(OPBoolFromRequest(preferences, @"DaemonVoiceAgent", YES)),
            @"run_task": @(OPBoolFromRequest(preferences, @"RunTask", YES)),
            @"create_background_job": @(OPBoolFromRequest(preferences, @"CreateBackgroundJob", NO)),
            @"run_background_jobs": @(OPBoolFromRequest(preferences, @"RunBackgroundJobs", NO)),
            @"window_ms": @(OPVolumeTriggerWindowMs(preferences)),
            @"cooldown_ms": @(OPVolumeTriggerCooldownMs(preferences)),
            @"trigger_goal_present": @(OPVolumeTriggerGoalFromPreferences(preferences).length > 0)
        },
        @"springboard_tweak": @"packaged_fallback_requires_tweak_injection",
        @"springboard_fallback": springBoardFallback ?: @{}
    };
}

static NSDictionary *OPHandleRequest(NSDictionary *request, NSDate *startedAt) {
    NSString *command = [request[@"command"] isKindOfClass:[NSString class]] ? request[@"command"] : nil;
    if (!command) {
        command = [request[@"method"] isKindOfClass:[NSString class]] ? request[@"method"] : @"health";
    }
    if (OPProtectedDataHelperRole() && !OPProtectedDataHelperCommandAllowed(command)) {
        return OPError(@"protected_data_helper_command_denied");
    }
    if ([command isEqualToString:@"health"]) {
        return OPHealth(startedAt);
    }
    if ([command isEqualToString:@"jetsam_priority_set"] ||
            [command isEqualToString:@"openphone.jetsam.priority_set"]) {
        return OPJetsamPrioritySet(request);
    }
    if ([command isEqualToString:@"model_status"] ||
            [command isEqualToString:@"openphone.model.status"]) {
        return OPModelStatus(request);
    }
    if ([command isEqualToString:@"model_configure"] ||
            [command isEqualToString:@"openphone.model.configure"]) {
        return OPModelConfigure(request);
    }
    if ([command isEqualToString:@"agent_status"] ||
            [command isEqualToString:@"openphone.agent.status"]) {
        return OPAgentStatus(request);
    }
    if ([command isEqualToString:@"agent_control"] ||
            [command isEqualToString:@"openphone.agent.control"]) {
        return OPAgentControl(request);
    }
    if ([command isEqualToString:@"agent_pause"]) {
        NSMutableDictionary *controlRequest = [request mutableCopy] ?: [NSMutableDictionary dictionary];
        controlRequest[@"action"] = @"pause";
        return OPAgentControl(controlRequest);
    }
    if ([command isEqualToString:@"agent_resume"]) {
        NSMutableDictionary *controlRequest = [request mutableCopy] ?: [NSMutableDictionary dictionary];
        controlRequest[@"action"] = @"resume";
        return OPAgentControl(controlRequest);
    }
    if ([command isEqualToString:@"start_task"]) {
        return OPStartTask(request);
    }
    if ([command isEqualToString:@"stop_task"]) {
        return OPStopTask(request);
    }
    if ([command isEqualToString:@"finish_task"] ||
            [command isEqualToString:@"openphone.task.finish"]) {
        return OPFinishTask(request);
    }
    if ([command isEqualToString:@"fail_task"] ||
            [command isEqualToString:@"openphone.task.fail"]) {
        return OPFailTask(request);
    }
    if ([command isEqualToString:@"get_task"]) {
        return OPGetTask(request);
    }
    if ([command isEqualToString:@"list_tasks"]) {
        return OPListTasks(request);
    }
    if ([command isEqualToString:@"task_repair_stale_active"] ||
            [command isEqualToString:@"openphone.tasks.repair_stale_active"]) {
        return OPRepairStaleActiveTasks(request);
    }
    if ([command isEqualToString:@"get_audit"]) {
        return OPGetAudit(request);
    }
    if ([command isEqualToString:@"get_trajectory"]) {
        return OPGetTrajectory(request);
    }
    if ([command isEqualToString:@"memory_save"] ||
            [command isEqualToString:@"openphone.memory.save"]) {
        return OPMemorySave(request);
    }
    if ([command isEqualToString:@"memory_search"] ||
            [command isEqualToString:@"openphone.memory.search"]) {
        return OPMemorySearch(request);
    }
    if ([command isEqualToString:@"memory_update"] ||
            [command isEqualToString:@"openphone.memory.update"]) {
        return OPMemoryUpdate(request);
    }
    if ([command isEqualToString:@"memory_delete"] ||
            [command isEqualToString:@"openphone.memory.delete"]) {
        return OPMemoryDelete(request);
    }
    if ([command isEqualToString:@"memory_merge"] ||
            [command isEqualToString:@"openphone.memory.merge"]) {
        return OPMemoryMerge(request);
    }
    if ([command isEqualToString:@"context_search"] ||
            [command isEqualToString:@"openphone.context.search"]) {
        return OPContextSearch(request);
    }
    if ([command isEqualToString:@"clipboard_read"] ||
            [command isEqualToString:@"openphone.clipboard.read"]) {
        return OPClipboardRead(request);
    }
    if ([command isEqualToString:@"clipboard_write"] ||
            [command isEqualToString:@"openphone.clipboard.write"]) {
        return OPClipboardWrite(request);
    }
    if ([command isEqualToString:@"contacts_search"] ||
            [command isEqualToString:@"openphone.contacts.search"]) {
        return OPContactsSearch(request);
    }
    if ([command isEqualToString:@"calendar_search"] ||
            [command isEqualToString:@"calendar_events_search"] ||
            [command isEqualToString:@"openphone.calendar.search"] ||
            [command isEqualToString:@"openphone.calendar.events.search"]) {
        return OPCalendarSearch(request);
    }
    if ([command isEqualToString:@"calls_search"] ||
            [command isEqualToString:@"call_history_search"] ||
            [command isEqualToString:@"openphone.calls.search"] ||
            [command isEqualToString:@"openphone.call_history.search"]) {
        return OPCallsSearch(request);
    }
    if ([command isEqualToString:@"messages_search"] ||
            [command isEqualToString:@"message_search"] ||
            [command isEqualToString:@"sms_search"] ||
            [command isEqualToString:@"openphone.messages.search"] ||
            [command isEqualToString:@"openphone.sms.search"]) {
        return OPMessagesSearch(request);
    }
    if ([command isEqualToString:@"commitment_create"] ||
            [command isEqualToString:@"openphone.commitments.create"] ||
            [command isEqualToString:@"openphone.commitment.create"]) {
        return OPCommitmentCreate(request);
    }
    if ([command isEqualToString:@"commitment_search"] ||
            [command isEqualToString:@"openphone.commitments.search"] ||
            [command isEqualToString:@"openphone.commitment.search"]) {
        return OPCommitmentSearch(request);
    }
    if ([command isEqualToString:@"commitment_update_status"] ||
            [command isEqualToString:@"openphone.commitments.update_status"] ||
            [command isEqualToString:@"openphone.commitment.update_status"]) {
        return OPCommitmentUpdateStatus(request);
    }
    if ([command isEqualToString:@"commitment_run_due"] ||
            [command isEqualToString:@"openphone.commitments.run_due"] ||
            [command isEqualToString:@"openphone.commitment.run_due"]) {
        NSUInteger limit = OPLimitFromRequest(request, 5, 25);
        if (limit == 0) {
            limit = 5;
        }
        NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
        NSString *source = OPStringFromRequest(request, @"source", @"commitment_scheduler_command");
        id deliveryRequest = OPJSONObjectFromRequest(request, @"delivery", nil);
        return OPCommitmentMaterializeDue(limit, OPNowMs(), taskId, source,
                [deliveryRequest isKindOfClass:[NSDictionary class]] ? deliveryRequest : nil);
    }
    if ([command isEqualToString:@"watcher_create"] ||
            [command isEqualToString:@"openphone.watchers.create"]) {
        return OPWatcherCreate(request);
    }
    if ([command isEqualToString:@"watcher_list"] ||
            [command isEqualToString:@"openphone.watchers.list"]) {
        return OPWatcherList(request);
    }
    if ([command isEqualToString:@"watcher_stop"] ||
            [command isEqualToString:@"openphone.watchers.stop"]) {
        return OPWatcherStop(request);
    }
    if ([command isEqualToString:@"watcher_repair_stuck"] ||
            [command isEqualToString:@"openphone.watchers.repair_stuck"]) {
        return OPWatcherRepairStuck(request);
    }
    if ([command isEqualToString:@"watcher_debug_mark_running"]) {
        return OPWatcherDebugMarkRunning(request);
    }
    if ([command isEqualToString:@"watcher_run_due"] ||
            [command isEqualToString:@"openphone.watchers.run_due"]) {
        NSUInteger limit = OPLimitFromRequest(request, 5, 25);
        if (limit == 0) {
            limit = 5;
        }
        NSString *taskId = OPStringFromRequest(request, @"task_id", @"");
        NSString *source = OPStringFromRequest(request, @"source", @"watcher_scheduler_command");
        return OPWatcherMaterializeDue(limit, OPNowMs(), taskId, source);
    }
    if ([command isEqualToString:@"background_job_create"] ||
            [command isEqualToString:@"openphone.jobs.create"]) {
        return OPBackgroundJobCreate(request);
    }
    if ([command isEqualToString:@"background_job_list"] ||
            [command isEqualToString:@"openphone.jobs.list"]) {
        return OPBackgroundJobList(request);
    }
    if ([command isEqualToString:@"background_job_stop"] ||
            [command isEqualToString:@"openphone.jobs.stop"]) {
        return OPBackgroundJobStop(request);
    }
    if ([command isEqualToString:@"background_job_repair_stuck"] ||
            [command isEqualToString:@"openphone.jobs.repair_stuck"]) {
        return OPBackgroundJobRepairStuck(request);
    }
    if ([command isEqualToString:@"background_job_debug_mark_running"]) {
        return OPBackgroundJobDebugMarkRunning(request);
    }
    if ([command isEqualToString:@"background_job_run_due"] ||
            [command isEqualToString:@"openphone.jobs.run_due"] ||
            [command isEqualToString:@"run_due_background_jobs"]) {
        return OPBackgroundJobRunDue(request);
    }
    if ([command isEqualToString:@"voice_memory_promote"] ||
            [command isEqualToString:@"openphone.voice.promote_memory"]) {
        return OPPromoteVoiceTurnsToMemory(request);
    }
    if ([command isEqualToString:@"notification_ingest"] ||
            [command isEqualToString:@"openphone.notification.ingest"]) {
        return OPNotificationIngest(request);
    }
    if ([command isEqualToString:@"notification_list"] ||
            [command isEqualToString:@"openphone.notification.list"]) {
        return OPNotificationList(request);
    }
    if ([command isEqualToString:@"list_apps"]) {
        return OPListApps(request);
    }
    if ([command isEqualToString:@"app_ui_publish"] ||
            [command isEqualToString:@"openphone.app_ui.publish"]) {
        return OPAppUIPublish(request);
    }
    if ([command isEqualToString:@"get_screen"]) {
        return OPGetScreen(request);
    }
    if ([command isEqualToString:@"execute_action"]) {
        return OPExecuteAction(request);
    }
    if ([command isEqualToString:@"run_task"]) {
        return OPRunTask(request);
    }
    if ([command isEqualToString:@"voice_trigger"] ||
            [command isEqualToString:@"openphone.trigger.voice"] ||
            [command isEqualToString:@"openphone.voice.trigger"]) {
        return OPVoiceTrigger(request);
    }
    if ([command isEqualToString:@"voice_status"] ||
            [command isEqualToString:@"openphone.voice.status"]) {
        return OPVoiceStatus(request);
    }
    if ([command isEqualToString:@"voice_transcribe_file"] ||
            [command isEqualToString:@"openphone.voice.transcribe_file"]) {
        return OPVoiceTranscribeFile(request);
    }
    if ([command isEqualToString:@"voice_confirm"] ||
            [command isEqualToString:@"voice_deny"] ||
            [command isEqualToString:@"openphone.voice.confirm"] ||
            [command isEqualToString:@"openphone.voice.deny"]) {
        BOOL approve = [command containsString:@"confirm"];
        NSDictionary *payload = @{
            @"decision": approve ? @"approve" : @"deny",
            @"received_at_ms": @(OPNowMs()),
            @"source": OPStringFromRequest(request, @"source", @"island_chip")
        };
        NSString *dir = [OPStorePath() stringByAppendingPathComponent:@"springboard"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:nil];
        NSString *path = [dir stringByAppendingPathComponent:@"confirmation-response.json"];
        OPWriteJSONFile(path, payload);
        return @{
            @"status": @"ok",
            @"decision": approve ? @"approve" : @"deny",
            @"source": @"openphone.agentd"
        };
    }
    if ([command isEqualToString:@"voice_cancel"] ||
            [command isEqualToString:@"openphone.voice.cancel"] ||
            [command isEqualToString:@"cancel_active"]) {
        pthread_mutex_lock(&OPVoiceTriggerMutex);
        BOOL voiceRunning = OPVoiceTriggerRunning;
        OPVoiceCancelRequested = 1;
        pthread_mutex_unlock(&OPVoiceTriggerMutex);

        pthread_mutex_lock(&OPIslandMutex);
        OPIslandEnsureState();
        NSString *activeTaskId = [OPIslandState[@"task_id"] isKindOfClass:[NSString class]]
                ? [OPIslandState[@"task_id"] copy] : @"";
        NSString *mode = [OPIslandState[@"mode"] isKindOfClass:[NSString class]]
                ? [OPIslandState[@"mode"] copy] : @"idle";
        pthread_mutex_unlock(&OPIslandMutex);

        BOOL activeModelTask = activeTaskId.length > 0 &&
                ([mode isEqualToString:@"thinking"] ||
                 [mode isEqualToString:@"action"]);
        if (activeModelTask) {
            OPStopTask(@{
                @"task_id": activeTaskId,
                @"reason": OPStringFromRequest(request, @"reason", @"user_cancelled")
            });
        }
        if (voiceRunning || activeModelTask) {
            OPIslandReset(@"idle", @"Cancelled", @"cyan");
        }
        return @{
            @"status": @"ok",
            @"state": (voiceRunning || activeModelTask) ?
                    @"voice.cancelling" : @"voice.cancel_noop",
            @"voice_was_running": @(voiceRunning),
            @"model_task_cancelled": @(activeModelTask),
            @"active_task_id": activeTaskId,
            @"source": @"openphone.agentd"
        };
    }
    if ([command isEqualToString:@"hardware_trigger"] ||
            [command isEqualToString:@"openphone.trigger.hardware"] ||
            [command isEqualToString:@"openphone.hardware.trigger"]) {
        return OPHardwareTrigger(request);
    }
    return OPError([NSString stringWithFormat:@"unknown_command:%@", command]);
}

static NSDictionary *OPParseRequest(NSData *data) {
    if (data.length == 0) {
        return @{@"command": @"health"};
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([object isKindOfClass:[NSDictionary class]]) {
        return object;
    }
    return @{@"command": @"health"};
}

static NSData *OPReadClient(int clientFd) {
    NSMutableData *data = [NSMutableData data];
    char buffer[4096];
    while (data.length < (256 * 1024)) {
        ssize_t count = read(clientFd, buffer, sizeof(buffer));
        if (count > 0) {
            [data appendBytes:buffer length:(NSUInteger)count];
            if (memchr(buffer, '\n', (size_t)count) != NULL) {
                break;
            }
            continue;
        }
        break;
    }
    return data;
}

static int OPCreateServerSocket(void) {
    NSString *socketPath = OPSocketPath();
    unlink(socketPath.UTF8String);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        OPLog(@"socket failed: %s", strerror(errno));
        return -1;
    }

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, socketPath.UTF8String, sizeof(address.sun_path));

    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        OPLog(@"bind failed: %s", strerror(errno));
        close(fd);
        return -1;
    }
    OPRestrictSocketToMobile(socketPath);
    if (listen(fd, 16) != 0) {
        OPLog(@"listen failed: %s", strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static int OPCreateAppUIIntakeSocket(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        OPAppUIIntakeStartError = [NSString stringWithFormat:@"socket_failed:%s", strerror(errno)];
        OPLog(@"app ui intake socket failed: %s", strerror(errno));
        return -1;
    }
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(27631);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        OPAppUIIntakeStartError = [NSString stringWithFormat:@"bind_failed:%s", strerror(errno)];
        OPLog(@"app ui intake bind failed: %s", strerror(errno));
        close(fd);
        return -1;
    }
    if (listen(fd, 8) != 0) {
        OPAppUIIntakeStartError = [NSString stringWithFormat:@"listen_failed:%s", strerror(errno)];
        OPLog(@"app ui intake listen failed: %s", strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static void *OPAppUIIntakeThreadMain(void *unused) {
    (void)unused;
    @autoreleasepool {
        int fd = OPCreateAppUIIntakeSocket();
        if (fd < 0) {
            return NULL;
        }
        OPAppUIIntakeFd = fd;
        OPAppUIIntakeReady = 1;
        OPLog(@"app ui intake started tcp=127.0.0.1:27631");
        while (OPRunning) {
            struct sockaddr_in peer;
            socklen_t peerLen = sizeof(peer);
            int clientFd = accept(fd, (struct sockaddr *)&peer, &peerLen);
            if (clientFd < 0) {
                if (errno == EINTR || !OPRunning) {
                    continue;
                }
                OPLog(@"app ui intake accept failed: %s", strerror(errno));
                continue;
            }
            BOOL loopback = peer.sin_family == AF_INET &&
                    ntohl(peer.sin_addr.s_addr) == INADDR_LOOPBACK;
            struct timeval timeout;
            timeout.tv_sec = 2;
            timeout.tv_usec = 0;
            setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            @autoreleasepool {
                NSDictionary *response = nil;
                if (!loopback) {
                    response = OPError(@"app_ui_intake_non_loopback_peer_rejected");
                } else {
                    NSData *requestData = OPReadClient(clientFd);
                    NSDictionary *request = OPParseRequest(requestData);
                    NSString *command = [request[@"command"] isKindOfClass:[NSString class]]
                            ? request[@"command"] : @"";
                    if ([command isEqualToString:@"app_ui_publish"] ||
                            [command isEqualToString:@"openphone.app_ui.publish"] ||
                            [request[@"schema"] isEqualToString:@"openphone.app_ui_state.v1"]) {
                        NSMutableDictionary *publishRequest = [request mutableCopy] ?: [NSMutableDictionary dictionary];
                        publishRequest[@"transport"] = @"tcp_loopback";
                        response = OPAppUIPublish(publishRequest);
                    } else if ([command isEqualToString:@"app_input_poll"] ||
                            [command isEqualToString:@"openphone.app_input.poll"]) {
                        response = OPAppInputPoll(request);
                    } else if ([command isEqualToString:@"app_input_complete"] ||
                            [command isEqualToString:@"openphone.app_input.complete"]) {
                        response = OPAppInputComplete(request);
                    } else {
                        response = OPError(@"app_ui_intake_command_rejected");
                    }
                }
                NSData *responseData = OPJSONData(response);
                OPWriteAll(clientFd, responseData);
            }
            close(clientFd);
        }
        close(fd);
        OPAppUIIntakeFd = -1;
        OPAppUIIntakeReady = 0;
    }
    return NULL;
}

static void OPStartAppUIIntakeServer(void) {
    if (OPAppUIIntakeThreadStarted) {
        return;
    }
    OPAppUIIntakeThreadStarted = 1;
    pthread_t thread;
    int rc = pthread_create(&thread, NULL, OPAppUIIntakeThreadMain, NULL);
    if (rc != 0) {
        OPAppUIIntakeThreadStarted = 0;
        OPAppUIIntakeStartError = [NSString stringWithFormat:@"pthread_create_failed:%d", rc];
        OPLog(@"app ui intake thread failed: %@", OPAppUIIntakeStartError);
        return;
    }
    pthread_detach(thread);
}

// Raise the jetsam band + task limit for `pid`. Returns the band actually
// applied (0 if every attempt was rejected) and writes the last errno/rc out.
// Runs in whatever uid the caller has: as mobile it usually gets EPERM; the
// setuid-root protected-data helper can call this successfully.
static int32_t OPApplyJetsamPriority(int32_t pid, int32_t requestedBand,
        int32_t limitMB, int *rcOut, int *errnoOut) {
    memorystatus_priority_properties_t props;
    props.priority = requestedBand > 0 ? requestedBand : JETSAM_PRIORITY_AUDIO_AND_ACCESSORY;
    props.user_data = 0;
    int rc = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES,
            pid, 0, &props, sizeof(props));
    if (rc != 0 && props.priority != JETSAM_PRIORITY_FOREGROUND) {
        // Fall back to plain foreground band (100).
        props.priority = JETSAM_PRIORITY_FOREGROUND;
        rc = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES,
                pid, 0, &props, sizeof(props));
    }
    if (rcOut) *rcOut = rc;
    if (errnoOut) *errnoOut = rc != 0 ? errno : 0;
    if (limitMB > 0) {
        int32_t mb = limitMB;
        (void)memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT,
                pid, 0, &mb, sizeof(mb));
    }
    return rc == 0 ? props.priority : 0;
}

// Helper-role command: raise the requesting agentd's jetsam band from root.
static NSDictionary *OPJetsamPrioritySet(NSDictionary *request) {
    int32_t pid = (int32_t)OPLongLongFromRequest(request, @"pid", 0, 0, INT32_MAX);
    if (pid <= 0) {
        return OPError(@"jetsam_priority_pid_missing");
    }
    int32_t band = (int32_t)OPLongLongFromRequest(request, @"band",
            JETSAM_PRIORITY_AUDIO_AND_ACCESSORY, 0, JETSAM_PRIORITY_MAX);
    int32_t limitMB = (int32_t)OPLongLongFromRequest(request, @"limit_mb", 256, 0, 4096);
    int rc = 0, err = 0;
    int32_t applied = OPApplyJetsamPriority(pid, band, limitMB, &rc, &err);
    return @{
        @"status": applied > 0 ? @"ok" : @"error",
        @"band": @(applied),
        @"requested_band": @(band),
        @"limit_mb": @(limitMB),
        @"rc": @(rc),
        @"errno": @(err),
        @"pid": @(pid),
        @"euid": @(geteuid()),
        @"source": @"openphone.agentd"
    };
}

static void OPRaiseJetsamPriority(void) {
    // Long model tasks temporarily hold screenshots + prompt text + HTTP body —
    // 256 MB is conservative headroom, still below iPhone's per-process cap.
    int rc = 0, err = 0;
    int32_t band = OPApplyJetsamPriority(getpid(),
            JETSAM_PRIORITY_AUDIO_AND_ACCESSORY, 256, &rc, &err);
    if (band > 0) {
        OPLog(@"jetsam priority raised band=%d rc=%d limit_mb=256 via=self", (int)band, rc);
        return;
    }
    OPLog(@"jetsam priority set failed rc=%d errno=%d; delegating to root helper", rc, err);
    // mobile-uid daemon got EPERM. Route the bump through the setuid-root
    // protected-data helper, which can set our band from root.
    NSDictionary *helper = OPProtectedDataHelperRequest(@{
        @"command": @"jetsam_priority_set",
        @"pid": @(getpid()),
        @"band": @(JETSAM_PRIORITY_AUDIO_AND_ACCESSORY),
        @"limit_mb": @256
    });
    if ([helper[@"status"] isEqualToString:@"ok"]) {
        OPLog(@"jetsam priority raised band=%@ via=root_helper", helper[@"band"] ?: @0);
    } else {
        OPLog(@"jetsam priority root-helper delegation failed: %@",
                helper[@"reason"] ?: helper[@"errno"] ?: @"unavailable");
    }
}

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSDate *startedAt = [NSDate date];
        OPProcessStartMs = (long long)([startedAt timeIntervalSince1970] * 1000.0);
        signal(SIGTERM, OPHandleSignal);
        signal(SIGINT, OPHandleSignal);
        signal(SIGPIPE, SIG_IGN);

        OPRaiseJetsamPriority();
        OPEnsureDirectories();
        OPServerFd = OPCreateServerSocket();
        if (OPServerFd < 0) {
            return 1;
        }
        OPLog(@"openphone-agentd %@ started socket=%@", OPAgentVersion, OPSocketPath());
        if (!OPProtectedDataHelperRole() && !OPEnvFlagEnabled("OPENPHONE_DISABLE_PROTECTED_DATA_HELPER")) {
            BOOL helperReady = OPProtectedDataHelperSocketConnectable();
            OPLog(@"protected data helper %@ socket=%@ error=%@",
                    helperReady ? @"ready" : @"not_ready",
                    OPProtectedDataHelperSocketPath(),
                    OPProtectedDataHelperLastSpawnError ?: @"");
        }
        if (!OPProtectedDataHelperRole() && !OPEnvFlagEnabled("OPENPHONE_AGENTD_DISABLE_TASK_REPAIR")) {
            // Resume any task that was active within the last 60s (likely
            // interrupted by a jetsam kill mid-run) by re-enqueueing it as a
            // fresh async run with the same goal. Older tasks still fail.
            NSUInteger resumedCount = 0;
            long long nowMs = OPNowMs();
            NSArray<NSString *> *taskFiles = [[NSFileManager defaultManager]
                    contentsOfDirectoryAtPath:OPTasksPath() error:nil] ?: @[];
            NSMutableArray<NSString *> *resumeIds = [NSMutableArray array];
            for (NSString *file in taskFiles) {
                if (![file.pathExtension isEqualToString:@"json"]) continue;
                NSDictionary *task = OPReadJSONFile(
                        [OPTasksPath() stringByAppendingPathComponent:file]);
                if (![task isKindOfClass:[NSDictionary class]]) continue;
                NSString *status = [task[@"status"] isKindOfClass:[NSString class]]
                        ? task[@"status"] : @"";
                if (![status isEqualToString:@"active"]) continue;
                long long updatedAt = [task[@"updated_at"] respondsToSelector:@selector(longLongValue)]
                        ? [task[@"updated_at"] longLongValue] : 0;
                long long createdAt = [task[@"created_at"] respondsToSelector:@selector(longLongValue)]
                        ? [task[@"created_at"] longLongValue] : 0;
                long long activityAt = updatedAt > 0 ? updatedAt : createdAt;
                long long ageMs = MAX(0, nowMs - activityAt);
                NSString *goal = [task[@"goal"] isKindOfClass:[NSString class]]
                        ? task[@"goal"] : @"";
                NSString *taskId = [task[@"task_id"] isKindOfClass:[NSString class]]
                        ? task[@"task_id"] : @"";
                if (ageMs <= 60000 && goal.length > 0 && taskId.length > 0) {
                    // Mark original task as resumed so the fail-repair sweep
                    // below skips it (status != "active"), and enqueue fresh
                    // work with the same goal.
                    OPUpdateTask(taskId, @"resumed_after_restart", @{
                        @"resumed_at_ms": @(nowMs),
                        @"stop_reason": @"resumed_after_daemon_restart",
                        @"result": @{
                            @"status": @"ok",
                            @"state": @"task.resumed",
                            @"reason": @"resumed_after_daemon_restart",
                            @"task_id": taskId,
                            @"source": @"openphone.agentd"
                        }
                    });
                    OPRecordTrajectory(taskId, @"task_resumed_after_restart", @{
                        @"task_id": taskId,
                        @"age_ms": @(ageMs),
                        @"goal": goal
                    });
                    OPStartAsyncRunTask(@{
                        @"command": @"run_task",
                        @"goal": goal,
                        @"mode": @"auto",
                        @"source": @"daemon_startup_resume",
                        @"reason": @"resumed after daemon restart",
                        @"trigger": @"resume",
                        @"trigger_input": @"resume_after_restart",
                        @"max_steps": @25,
                        @"max_duration_ms": @600000,
                        @"run_task": @YES
                    });
                    OPIslandUpdate(@{
                        @"mode": @"thinking",
                        @"subtitle": @"Resuming",
                        @"goal": goal,
                        @"accent": @"blue"
                    });
                    [resumeIds addObject:taskId];
                    resumedCount++;
                }
            }
            if (resumedCount > 0) {
                OPLog(@"task startup resumed count=%lu ids=%@",
                        (unsigned long)resumedCount,
                        [resumeIds componentsJoinedByString:@","]);
            }

            NSDictionary *taskRepair = OPRepairStaleActiveTasks(@{
                @"source": @"daemon_startup",
                @"stale_after_ms": @0,
                @"limit": @50,
                @"reason": @"daemon startup recovered active tasks from a previous process"
            });
            long long taskRepairCount = [taskRepair[@"repaired_count"] respondsToSelector:@selector(longLongValue)]
                    ? [taskRepair[@"repaired_count"] longLongValue] : 0;
            if (taskRepairCount > 0) {
                OPLog(@"task startup recovery repaired_count=%lld", taskRepairCount);
            }
        }
        if (!OPEnvFlagEnabled("OPENPHONE_AGENTD_DISABLE_VOLUME_TRIGGER")) {
            OPStartVolumeTriggerListener();
        }
        if (!OPEnvFlagEnabled("OPENPHONE_AGENTD_DISABLE_APP_UI_INTAKE")) {
            OPStartAppUIIntakeServer();
        }
        if (!OPEnvFlagEnabled("OPENPHONE_AGENTD_DISABLE_BACKGROUND_SCHEDULER")) {
            OPStartBackgroundJobScheduler();
        }

        while (OPRunning) {
            int clientFd = accept(OPServerFd, NULL, NULL);
            if (clientFd < 0) {
                if (errno == EINTR || !OPRunning) {
                    continue;
                }
                OPLog(@"accept failed: %s", strerror(errno));
                continue;
            }

            struct timeval timeout;
            timeout.tv_sec = 2;
            timeout.tv_usec = 0;
            setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

            @autoreleasepool {
                NSData *requestData = OPReadClient(clientFd);
                NSDictionary *request = OPParseRequest(requestData);
                NSDictionary *response = nil;
                @try {
                    response = OPHandleRequest(request, startedAt);
                } @catch (NSException *exception) {
                    NSString *command = [request[@"command"] isKindOfClass:[NSString class]]
                            ? request[@"command"] : @"unknown";
                    OPLog(@"request exception command=%@ exception=%@ reason=%@",
                            command, exception.name ?: @"NSException", exception.reason ?: @"");
                    response = OPError([NSString stringWithFormat:@"request_exception:%@",
                            exception.name ?: @"NSException"]);
                }
                NSData *responseData = OPJSONData(response);
                if (!OPWriteAll(clientFd, responseData)) {
                    OPLog(@"client write failed errno=%d", errno);
                }
            }
            close(clientFd);
        }

        if (OPServerFd >= 0) {
            close(OPServerFd);
            OPServerFd = -1;
        }
        if (OPAppUIIntakeFd >= 0) {
            close(OPAppUIIntakeFd);
            OPAppUIIntakeFd = -1;
        }
        unlink(OPSocketPath().UTF8String);
        OPLog(@"openphone-agentd stopped");
    }
    return 0;
}
