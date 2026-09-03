#import <Cocoa/Cocoa.h>
#import <Security/Security.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_media.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

static NSString * const AppName = @"RG For Mac";
static NSString * const KeychainService = @"com.rgformac.app";
static NSString * const DefaultCampusUser = @""; // 首次运行会弹窗让你填自己的校园网账号，这里不需要写死
static NSString * const ServiceHex = @"39:d3d0cfdf3178c9cfcdf800000000000000000000000000000000000000000000:r";
static NSString * const VersionString = @"RG-SU For Mac V1.35";
static NSString * const DNS1 = @"114.114.114.114";
static NSString * const DNS2 = @"114.114.115.115";
static NSString * const PrefSelectedInterface = @"selected-interface";
static const NSInteger kMaxAutoRetries = 3;
static const NSTimeInterval kAutoRetryDelaySeconds = 25.0; // Give the server time to clear the stale prior session

@interface NetworkInterfaceInfo : NSObject
@property(nonatomic, copy) NSString *bsdName;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *type;
@property(nonatomic, assign) BOOL isActive;
@property(nonatomic, copy) NSString *ipv4Address;
@end

@implementation NetworkInterfaceInfo
- (NSString *)description {
    NSString *status = self.isActive ? @"[已插线]" : @"[未插线]";
    if (self.ipv4Address.length > 0) {
        return [NSString stringWithFormat:@"%@ (%@) %@ - %@", self.bsdName, self.displayName, status, self.ipv4Address];
    }
    return [NSString stringWithFormat:@"%@ (%@) %@", self.bsdName, self.displayName, status];
}
@end

@interface NetworkHelper : NSObject
+ (BOOL)isInterfaceActive:(NSString *)bsdName;
+ (NSString *)getIPv4AddressForInterface:(NSString *)ifname;
+ (NSArray<NetworkInterfaceInfo *> *)allEthernetInterfaces;
+ (NetworkInterfaceInfo *)bestEthernetInterfaceWithPreferred:(NSString *)preferred;
@end

@implementation NetworkHelper

+ (BOOL)isInterfaceActive:(NSString *)bsdName {
    if (bsdName.length == 0) return NO;
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return NO;
    struct ifmediareq ifmr;
    memset(&ifmr, 0, sizeof(ifmr));
    strlcpy(ifmr.ifm_name, [bsdName UTF8String], sizeof(ifmr.ifm_name));
    BOOL active = NO;
    if (ioctl(s, SIOCGIFMEDIA, &ifmr) >= 0) {
        if (ifmr.ifm_status & IFM_AVALID) {
            active = (ifmr.ifm_status & IFM_ACTIVE) != 0;
        }
    }
    close(s);
    return active;
}

+ (NSString *)getIPv4AddressForInterface:(NSString *)ifname {
    if (ifname.length == 0) return nil;
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    NSString *address = nil;
    if (getifaddrs(&interfaces) == 0) {
        temp_addr = interfaces;
        while (temp_addr != NULL) {
            if (temp_addr->ifa_addr && temp_addr->ifa_addr->sa_family == AF_INET) {
                if (strcmp(temp_addr->ifa_name, [ifname UTF8String]) == 0) {
                    char ipStr[INET_ADDRSTRLEN] = {0};
                    struct sockaddr_in *addr_in = (struct sockaddr_in *)temp_addr->ifa_addr;
                    inet_ntop(AF_INET, &(addr_in->sin_addr), ipStr, sizeof(ipStr));
                    address = [NSString stringWithUTF8String:ipStr];
                    break;
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
        freeifaddrs(interfaces);
    }
    return address;
}

+ (NSArray<NetworkInterfaceInfo *> *)allEthernetInterfaces {
    NSMutableArray<NetworkInterfaceInfo *> *results = [NSMutableArray array];
    NSArray *interfaces = (__bridge_transfer NSArray *)SCNetworkInterfaceCopyAll();
    for (id iface in interfaces) {
        SCNetworkInterfaceRef scIface = (__bridge SCNetworkInterfaceRef)iface;
        NSString *bsdName = (__bridge NSString *)SCNetworkInterfaceGetBSDName(scIface);
        NSString *displayName = (__bridge NSString *)SCNetworkInterfaceGetLocalizedDisplayName(scIface);
        NSString *type = (__bridge NSString *)SCNetworkInterfaceGetInterfaceType(scIface);
        
        if (!bsdName.length) continue;
        
        // 只保留 Ethernet 类型
        if (![type isEqualToString:(__bridge NSString *)kSCNetworkInterfaceTypeEthernet]) {
            continue;
        }
        
        if ([bsdName hasPrefix:@"awdl"] || [bsdName hasPrefix:@"llw"] ||
            [bsdName hasPrefix:@"utun"] || [bsdName hasPrefix:@"anpi"] ||
            [bsdName hasPrefix:@"lo"] || [bsdName hasPrefix:@"gif"] ||
            [bsdName hasPrefix:@"stf"] || [bsdName hasPrefix:@"ap"]) {
            continue;
        }
        
        NetworkInterfaceInfo *info = [[NetworkInterfaceInfo alloc] init];
        info.bsdName = bsdName;
        info.displayName = displayName ?: bsdName;
        info.type = type ?: @"Ethernet";
        info.isActive = [self isInterfaceActive:bsdName];
        info.ipv4Address = [self getIPv4AddressForInterface:bsdName];
        [results addObject:info];
    }
    return results;
}

+ (NetworkInterfaceInfo *)bestEthernetInterfaceWithPreferred:(NSString *)preferred {
    NSArray<NetworkInterfaceInfo *> *all = [self allEthernetInterfaces];
    if (preferred.length > 0 && ![preferred isEqualToString:@"auto"]) {
        for (NetworkInterfaceInfo *info in all) {
            if ([info.bsdName isEqualToString:preferred]) {
                return info;
            }
        }
    }
    // 优先选择处于 Active 状态的有线网卡
    for (NetworkInterfaceInfo *info in all) {
        if (info.isActive) {
            return info;
        }
    }
    // 否则返回第一个有线网卡
    if (all.count > 0) {
        return all.firstObject;
    }
    return nil;
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *statusItemText;
@property(nonatomic, strong) NSMenuItem *ifaceItemText;
@property(nonatomic, strong) NSMenuItem *startItem;
@property(nonatomic, strong) NSMenuItem *stopItem;

@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, assign) BOOL starting;
@property(nonatomic, assign) BOOL stopping;
@property(nonatomic, assign) BOOL stopRequestedWhileStarting;
@property(nonatomic, assign) BOOL terminatingAfterStop;
@property(nonatomic, copy) NSString *lastStartError;
@property(nonatomic, copy) NSString *activeInterfaceName;
@property(nonatomic, assign) BOOL userWantsConnected;
@property(nonatomic, assign) BOOL wasRunningLastTick;
@property(nonatomic, assign) NSInteger autoRetryCount;
@property(nonatomic, assign) BOOL autoRetryScheduled;
- (void)stopAuthThenQuit:(BOOL)quitAfterStop force:(BOOL)force;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [self prepareDirectories];
    [self rotateLogsIfNeeded];
    [self buildMenu];
    [self refreshInterfaceList];
    [self updateStatus];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(updateStatus) userInfo:nil repeats:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self autoStartIfNeeded];
    });
}

- (NSString *)supportDir {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/RGForMac"];
}

- (NSString *)logDir {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/RGForMac"];
}

- (NSString *)logFile {
    return [[self logDir] stringByAppendingPathComponent:@"minieap.log"];
}

- (NSString *)pidFile {
    return [[self supportDir] stringByAppendingPathComponent:@"minieap.pid"];
}

- (NSString *)onlineMarkerFile {
    return [[self pidFile] stringByAppendingString:@".online"];
}

- (NSString *)confFile {
    return [[self supportDir] stringByAppendingPathComponent:@"minieap.conf"];
}

- (NSString *)minieapPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *resourcePath = [NSBundle.mainBundle pathForResource:@"minieap" ofType:nil];
    if (resourcePath.length > 0) {
        [candidates addObject:resourcePath];
    }
    NSString *bundlePath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"minieap"];
    NSString *executableDirectory = [NSBundle.mainBundle.executablePath stringByDeletingLastPathComponent];
    NSString *siblingPath = [executableDirectory stringByAppendingPathComponent:@"minieap"];
    for (NSString *candidate in @[bundlePath, siblingPath]) {
        if (![candidates containsObject:candidate]) {
            [candidates addObject:candidate];
        }
    }
    for (NSString *candidate in candidates) {
        if ([fm isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

- (BOOL)isRegularPath:(NSString *)path {
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0
        && (info.st_mode & S_IFMT) == S_IFREG;
}

- (BOOL)isCurrentUserPath:(NSString *)path mode:(mode_t)expectedMode {
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        return NO;
    }
    return (info.st_mode & S_IFMT) == expectedMode && info.st_uid == getuid();
}

- (BOOL)ensureCurrentUserPath:(NSString *)path mode:(mode_t)expectedMode {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![self isCurrentUserPath:path mode:expectedMode]) {
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) == 0) {
            NSString *quarantinePath = [path stringByAppendingFormat:@".stale.%@", NSUUID.UUID.UUIDString];
            NSError *moveError = nil;
            if (![fm moveItemAtPath:path toPath:quarantinePath error:&moveError]) {
                NSLog(@"无法隔离不安全的运行路径 %@：%@", path, moveError);
                return NO;
            }
        }
        if (expectedMode == S_IFDIR) {
            if (![fm createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:nil]) {
                return NO;
            }
        } else if (![fm createFileAtPath:path contents:nil attributes:@{NSFilePosixPermissions: @0644}]) {
            return NO;
        }
    }
    return [self isCurrentUserPath:path mode:expectedMode];
}

- (BOOL)runtimePathsAreSafe {
    return [self isCurrentUserPath:[self supportDir] mode:S_IFDIR]
        && [self isCurrentUserPath:[self logDir] mode:S_IFDIR]
        && [self isCurrentUserPath:[self logFile] mode:S_IFREG]
        && [self isRegularPath:[self pidFile]];
}

- (void)prepareDirectories {
    BOOL ready = [self ensureCurrentUserPath:[self supportDir] mode:S_IFDIR];
    ready = [self ensureCurrentUserPath:[self logDir] mode:S_IFDIR] && ready;
    ready = [self ensureCurrentUserPath:[self logFile] mode:S_IFREG] && ready;

    BOOL pidReady = [self isCurrentUserPath:[self pidFile] mode:S_IFREG];
    if (!pidReady && [self isRegularPath:[self pidFile]] && [self miniEAPRunning]) {
        pidReady = YES;
    } else if (!pidReady) {
        pidReady = [self ensureCurrentUserPath:[self pidFile] mode:S_IFREG];
    }
    ready = pidReady && ready;
    if (!ready) {
        NSLog(@"运行目录或文件不安全，已禁止启动认证进程");
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:[self confFile]]) {
        [@"" writeToFile:[self confFile] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

- (void)buildMenu {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"RG";
    self.statusItem.button.toolTip = AppName;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:AppName];
    self.statusItemText = [[NSMenuItem alloc] initWithTitle:@"状态：检查中" action:nil keyEquivalent:@""];
    self.ifaceItemText = [[NSMenuItem alloc] initWithTitle:@"网卡：检测中" action:nil keyEquivalent:@""];
    self.startItem = [[NSMenuItem alloc] initWithTitle:@"启动认证" action:@selector(startAuth) keyEquivalent:@"s"];
    self.stopItem = [[NSMenuItem alloc] initWithTitle:@"停止认证" action:@selector(stopAuth) keyEquivalent:@"x"];
    NSMenuItem *repair = [[NSMenuItem alloc] initWithTitle:@"修复网络并重连" action:@selector(repairAndReconnect) keyEquivalent:@"r"];
    NSMenuItem *logs = [[NSMenuItem alloc] initWithTitle:@"打开日志文件夹" action:@selector(openLogs) keyEquivalent:@"l"];
    NSMenuItem *account = [[NSMenuItem alloc] initWithTitle:@"修改校园网账号密码" action:@selector(changeCredentials) keyEquivalent:@"p"];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出并断开认证" action:@selector(quit) keyEquivalent:@"q"];

    self.startItem.target = self;
    self.stopItem.target = self;
    repair.target = self;
    logs.target = self;
    account.target = self;
    quit.target = self;

    [menu addItem:self.statusItemText];
    [menu addItem:self.ifaceItemText];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:self.startItem];
    [menu addItem:self.stopItem];
    [menu addItem:repair];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:logs];
    [menu addItem:account];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:quit];
    self.statusItem.menu = menu;
}

- (void)refreshInterfaceList {
    NSString *savedIface = [[NSUserDefaults standardUserDefaults] stringForKey:PrefSelectedInterface] ?: @"auto";
    NetworkInterfaceInfo *best = [NetworkHelper bestEthernetInterfaceWithPreferred:savedIface];
    self.activeInterfaceName = best ? best.bsdName : nil;
}

- (NSString *)effectiveInterfaceName {
    NSString *savedIface = [[NSUserDefaults standardUserDefaults] stringForKey:PrefSelectedInterface] ?: @"auto";
    NetworkInterfaceInfo *best = [NetworkHelper bestEthernetInterfaceWithPreferred:savedIface];
    if (best) {
        self.activeInterfaceName = best.bsdName;
        return best.bsdName;
    }
    return nil;
}

- (void)rotateLogsIfNeeded {
    [self prepareDirectories];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:[self logFile] error:nil];
    unsigned long long size = [attrs fileSize];
    if (size > 2 * 1024 * 1024) {
        NSString *name = [NSString stringWithFormat:@"minieap-%@.log", [self timestamp]];
        NSString *rotated = [[self logDir] stringByAppendingPathComponent:name];
        [fm moveItemAtPath:[self logFile] toPath:rotated error:nil];
        [self ensureCurrentUserPath:[self logFile] mode:S_IFREG];
    }

    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-(14 * 24 * 60 * 60)];
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:[self logDir] error:nil];
    for (NSString *file in files) {
        if (![file hasPrefix:@"minieap-"] || ![[file pathExtension] isEqualToString:@"log"]) {
            continue;
        }
        NSString *path = [[self logDir] stringByAppendingPathComponent:file];
        NSDictionary *info = [fm attributesOfItemAtPath:path error:nil];
        NSDate *modified = info[NSFileModificationDate];
        if (modified && [modified compare:cutoff] == NSOrderedAscending) {
            NSURL *url = [NSURL fileURLWithPath:path];
            [[NSWorkspace sharedWorkspace] recycleURLs:@[url] completionHandler:nil];
        }
    }
}

- (void)updateStatus {
    BOOL isRunningNow = [self miniEAPRunning];
    BOOL isOnlineNow = isRunningNow && [self miniEAPOnline];
    if (self.starting && isRunningNow) {
        self.starting = NO;
    }
    if (isOnlineNow) {
        self.autoRetryCount = 0;
    }
    [self handlePossibleUnexpectedExitWithRunning:isRunningNow];
    self.wasRunningLastTick = isRunningNow;

    NSString *iface = [self effectiveInterfaceName];
    NSString *ip = iface ? [NetworkHelper getIPv4AddressForInterface:iface] : nil;
    self.ifaceItemText.title = [NSString stringWithFormat:@"网卡：%@%@", iface ?: @"无", ip ? [NSString stringWithFormat:@" (%@)", ip] : @""];

    if (self.starting) {
        self.statusItemText.title = @"状态：正在启动认证…";
        self.statusItem.button.title = @"RG…";
        self.startItem.enabled = NO;
        self.stopItem.enabled = YES;
        return;
    }
    if (self.stopping) {
        self.statusItemText.title = @"状态：正在停止认证…";
        self.statusItem.button.title = @"RG…";
        self.startItem.enabled = NO;
        self.stopItem.enabled = NO;
        return;
    }
    if (self.autoRetryScheduled) {
        self.statusItemText.title = [NSString stringWithFormat:@"状态：认证异常，准备第 %ld 次自动重试…", (long)self.autoRetryCount];
        self.statusItem.button.title = @"RG…";
        self.startItem.enabled = NO;
        self.stopItem.enabled = YES;
        return;
    }

    self.statusItemText.title = isOnlineNow ? [NSString stringWithFormat:@"状态：已连接 (PID: %@)", [self miniEAPPID]]
                               : isRunningNow ? @"状态：正在认证中…"
                               : @"状态：未连接";
    self.statusItem.button.title = isOnlineNow ? @"RG✓" : (isRunningNow ? @"RG…" : @"RG");
    self.startItem.enabled = !isRunningNow;
    self.stopItem.enabled = isRunningNow;
}

// minieap exits on its own after exhausting retries against the auth server
// (common right after a previous session was torn down and the server hasn't
// expired it yet). Without this, the app just silently falls back to "未连接"
// and the user has to notice and click 连接 again by hand.
- (void)handlePossibleUnexpectedExitWithRunning:(BOOL)isRunningNow {
    BOOL diedOnItsOwn = self.wasRunningLastTick && !isRunningNow
        && !self.starting && !self.stopping && !self.autoRetryScheduled;
    if (!diedOnItsOwn || !self.userWantsConnected) {
        return;
    }
    if (self.autoRetryCount >= kMaxAutoRetries) {
        self.autoRetryCount = 0;
        self.userWantsConnected = NO;
        [self showMessage:[NSString stringWithFormat:@"自动重试 %ld 次仍未连接，请检查网线、账号密码，或手动点击“连接”重试。", (long)kMaxAutoRetries]];
        return;
    }
    self.autoRetryCount += 1;
    self.autoRetryScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAutoRetryDelaySeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.autoRetryScheduled = NO;
        if (!strongSelf.userWantsConnected || [strongSelf miniEAPRunning]) {
            return; // User already intervened manually in the meantime
        }
        [strongSelf startAuthWithNetworkRepair:NO];
    });
}

- (NSString *)miniEAPPID {
    int open_flags = O_RDONLY;
#ifdef O_NOFOLLOW
    open_flags |= O_NOFOLLOW;
#endif
    int pid_fd = open([self pidFile].fileSystemRepresentation, open_flags);
    if (pid_fd < 0) {
        return nil;
    }
    struct stat info;
    if (fstat(pid_fd, &info) != 0 || (info.st_mode & S_IFMT) != S_IFREG) {
        close(pid_fd);
        return nil;
    }
    char pid_buffer[32];
    ssize_t length = read(pid_fd, pid_buffer, sizeof(pid_buffer) - 1);
    close(pid_fd);
    if (length <= 0) {
        return nil;
    }
    pid_buffer[length] = '\0';
    NSString *pidText = [[NSString alloc] initWithBytes:pid_buffer length:(NSUInteger)length encoding:NSUTF8StringEncoding];
    NSString *trimmed = [pidText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0
        || [trimmed rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound) {
        return nil;
    }
    NSInteger pid = trimmed.integerValue;
    return pid > 0 ? [NSString stringWithFormat:@"%ld", (long)pid] : nil;
}

// minieap runs as root (started via "administrator privileges"), while this app
// runs as the normal user. kill(pid, 0) and proc_name() both require matching
// privileges to inspect another user's process and fail with EPERM/empty here -
// which used to make the app always report "未连接" even while minieap was
// happily authenticated in the background. sysctl(KERN_PROC_PID) reads the same
// public process-table info the standard process-listing tools use, and works
// across the privilege gap without shelling out to any of them.
- (BOOL)miniEAPRunning {
    NSString *pidStr = [self miniEAPPID];
    if (pidStr.length == 0) {
        return NO;
    }
    pid_t pid = (pid_t)[pidStr integerValue];
    if (pid <= 0) {
        return NO;
    }
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc info;
    size_t len = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &len, NULL, 0) != 0 || len == 0) {
        return NO;
    }
    return strcmp(info.kp_proc.p_comm, "minieap") == 0;
}

// A process being alive only means it is negotiating (or retrying); minieap only
// touches this marker once EAP-Success actually lands, and removes it the moment
// it is no longer sure it is online. Always pair with -miniEAPRunning: a stale
// marker from a killed process is harmless once the PID check already says "dead".
- (BOOL)miniEAPOnline {
    if (![self miniEAPRunning]) {
        return NO;
    }
    int open_flags = O_RDONLY;
#ifdef O_NOFOLLOW
    open_flags |= O_NOFOLLOW;
#endif
    int fd = open([self onlineMarkerFile].fileSystemRepresentation, open_flags);
    if (fd < 0) {
        return NO;
    }
    struct stat info;
    BOOL isRegular = (fstat(fd, &info) == 0) && ((info.st_mode & S_IFMT) == S_IFREG);
    close(fd);
    return isRegular;
}

- (void)startAuth {
    self.autoRetryCount = 0;
    [self startAuthWithNetworkRepair:NO];
}

- (void)autoStartIfNeeded {
    self.autoRetryCount = 0;
    if (![self miniEAPRunning]) {
        [self startAuthWithNetworkRepair:NO];
    } else {
        self.userWantsConnected = YES;
        [self updateStatus];
    }
}

- (void)repairAndReconnect {
    self.autoRetryCount = 0;
    [self startAuthWithNetworkRepair:YES];
}

- (void)startAuthWithNetworkRepair:(BOOL)repairNetwork {
    if (self.starting) {
        return;
    }
    self.userWantsConnected = YES;
    if (!repairNetwork && [self miniEAPRunning]) {
        [self updateStatus];
        return;
    }
    if (![self minieapPath].length) {
        [self showMessage:@"应用内认证组件缺失，请重新构建应用。"];
        return;
    }
    [self rotateLogsIfNeeded];
    if (![self runtimePathsAreSafe]) {
        [self showMessage:@"认证运行目录或文件不安全，请检查应用支持目录后重试。"];
        return;
    }
    
    NSString *iface = [self effectiveInterfaceName];
    if (!iface.length) {
        [self refreshInterfaceList];
        iface = [self effectiveInterfaceName];
    }
    if (!iface.length) {
        [self showMessage:@"未检测到任何以太网接口，请先插上网线或外接网卡/扩展坞后再试。"];
        return;
    }

    NSDictionary *credentials = [self credentialsOrPrompt];
    if (!credentials) {
        [self showMessage:@"没有保存校园网账号密码，未启动认证。"];
        return;
    }

    [self markStarting];
    NSString *user = credentials[@"username"];
    NSString *password = credentials[@"password"];
    NSString *command = [self startCommandWithUser:user password:password interface:iface repairNetwork:repairNetwork];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = [self runAdminShell:command];
        BOOL running = [self waitForMiniEAPRunningWithTimeout:(repairNetwork ? 8.0 : 4.0)];

        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL stopAfterStart = self.stopRequestedWhileStarting;
            BOOL quitAfterStop = self.terminatingAfterStop;
            if (running) {
                self.lastStartError = nil;
            } else if ([result[@"ok"] boolValue]) {
                self.lastStartError = nil;
            } else {
                self.lastStartError = result[@"message"] ?: @"未知错误";
                [self showMessage:[NSString stringWithFormat:@"启动暂未成功：%@", self.lastStartError]];
            }
            self.starting = NO;
            if (stopAfterStart) {
                self.stopRequestedWhileStarting = NO;
                [self stopAuthThenQuit:quitAfterStop force:YES];
                return;
            }
            [self updateStatus];
        });
    });
}

- (void)stopAuth {
    [self stopAuthThenQuit:NO];
}

- (void)stopAuthThenQuit:(BOOL)quitAfterStop {
    [self stopAuthThenQuit:quitAfterStop force:NO];
}

- (void)stopAuthThenQuit:(BOOL)quitAfterStop force:(BOOL)force {
    if (self.stopping) {
        return;
    }
    if (self.starting) {
        self.stopRequestedWhileStarting = YES;
        self.terminatingAfterStop = self.terminatingAfterStop || quitAfterStop;
        [self updateStatus];
        return;
    }
    if (!force && ![self miniEAPRunning]) {
        self.userWantsConnected = NO;
        if (quitAfterStop) {
            self.terminatingAfterStop = YES;
            [NSApp terminate:nil];
        } else {
            [self updateStatus];
        }
        return;
    }

    self.userWantsConnected = NO;
    self.stopping = YES;
    [self updateStatus];
    NSString *command = [self stopCommand];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = [self runAdminShell:command];
        BOOL stopped = [self waitForMiniEAPStoppedWithTimeout:3.0];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.stopping = NO;
            if (!stopped || ![result[@"ok"] boolValue]) {
                self.terminatingAfterStop = NO;
                [self showMessage:[NSString stringWithFormat:@"停止失败：%@", result[@"message"] ?: @"未知错误"]];
                [self updateStatus];
                return;
            }
            [self prepareDirectories];
            if (quitAfterStop) {
                self.terminatingAfterStop = YES;
                [NSApp terminate:nil];
            } else {
                [self updateStatus];
            }
        });
    });
}

- (NSString *)stopCommand {
    // Give minieap up to ~2s to exit on its own after SIGINT before force-killing it.
    // It needs that time to send an EAPOL-Logoff to the server on the way out; a
    // SIGKILL skips that entirely and leaves a stale session for the server to
    // reject the *next* login attempt against, until its own timeout clears it.
    // This whole script already runs with administrator privileges (root), so
    // `kill -0` against minieap's own root-owned pid here is not the cross-user
    // permission gap the app's own status check had to work around.
    NSString *pidFilePath = [self shellQuote:[self pidFile]];
    return [NSString stringWithFormat:
        @"/usr/bin/killall -INT minieap >/dev/null 2>&1 || true\n"
         "for i in 1 2 3 4 5 6 7 8; do\n"
         "  MINIEAP_PID=\"\"\n"
         "  read MINIEAP_PID < %@ 2>/dev/null\n"
         "  if [ -z \"$MINIEAP_PID\" ] || ! /bin/kill -0 \"$MINIEAP_PID\" 2>/dev/null; then break; fi\n"
         "  /bin/sleep 0.25\n"
         "done\n"
         "/usr/bin/killall -KILL minieap >/dev/null 2>&1 || true\n",
        pidFilePath];
}

- (void)recoverFromLongStart {
    if (!self.starting) {
        return;
    }
    if ([self miniEAPRunning]) {
        return;
    }
    self.statusItemText.title = @"状态：等待系统授权或认证响应";
}

- (void)startLongStartWatchdog {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self recoverFromLongStart];
    });
}

- (void)markStarting {
    self.starting = YES;
    self.lastStartError = nil;
    [self updateStatus];
    [self startLongStartWatchdog];
}

- (BOOL)waitForMiniEAPRunningWithTimeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        if ([self miniEAPRunning]) {
            return YES;
        }
        [NSThread sleepForTimeInterval:0.1];
    }
    return [self miniEAPRunning];
}

- (BOOL)waitForMiniEAPStoppedWithTimeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        if (![self miniEAPRunning]) {
            return YES;
        }
        [NSThread sleepForTimeInterval:0.1];
    }
    return ![self miniEAPRunning];
}

- (void)openLogs {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[self logDir]]];
}

- (void)changeCredentials {
    NSDictionary *credentials = [self promptCredentials];
    if (!credentials) {
        return;
    }
    [self saveValue:credentials[@"username"] account:@"campus-username"];
    [self saveValue:credentials[@"password"] account:@"campus-password"];
    [self showMessage:@"校园网账号密码已保存到 macOS 钥匙串。"];
}

- (void)quit {
    [self stopAuthThenQuit:YES];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (self.terminatingAfterStop && !self.starting && !self.stopping) {
        return NSTerminateNow;
    }
    [self stopAuthThenQuit:YES];
    return NSTerminateCancel;
}

- (NSDictionary *)credentialsOrPrompt {
    NSString *username = [self loadValueForAccount:@"campus-username"];
    NSString *password = [self loadValueForAccount:@"campus-password"];
    if (username.length > 0 && password.length > 0) {
        return @{@"username": username, @"password": password};
    }
    NSDictionary *credentials = [self promptCredentials];
    if (!credentials) {
        return nil;
    }
    [self saveValue:credentials[@"username"] account:@"campus-username"];
    [self saveValue:credentials[@"password"] account:@"campus-password"];
    return credentials;
}

- (NSDictionary *)promptCredentials {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"校园网账号密码";
    alert.informativeText = @"第一次输入后会保存到 macOS 钥匙串。";
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];

    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 58)];
    NSTextField *userField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 34, 300, 24)];
    NSSecureTextField *passField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
    userField.placeholderString = @"校园网账号";
    passField.placeholderString = @"校园网密码";
    userField.stringValue = [self loadValueForAccount:@"campus-username"] ?: DefaultCampusUser;
    [view addSubview:userField];
    [view addSubview:passField];
    alert.accessoryView = view;

    NSModalResponse response = [alert runModal];
    if (response != NSAlertFirstButtonReturn || userField.stringValue.length == 0 || passField.stringValue.length == 0) {
        return nil;
    }
    return @{@"username": userField.stringValue, @"password": passField.stringValue};
}

- (NSString *)startCommandWithUser:(NSString *)user password:(NSString *)password interface:(NSString *)iface repairNetwork:(BOOL)repairNetwork {
    NSString *networkRepairPrefix = repairNetwork ? [NSString stringWithFormat:
        @"/usr/sbin/ipconfig set %@ DHCP >/dev/null 2>&1 || true\n"
         "/bin/sleep 0.3\n",
        iface
    ] : @"";
    
    // 启动前先无条件清理旧进程，防止冲突
    NSString *command = [NSString stringWithFormat:
        @"%@"
        "%@"
        "export MINIEAP_PASSWORD=%@\n"
        "export MINIEAP_REQUIRE_EXISTING_FILES=1\n"
        "%@ --if-impl libpcap --module rjv3 -u %@ --password-env MINIEAP_PASSWORD -n %@ -a 1 -d 2 --heartbeat 30 --version-str %@ --rj-option %@ --fake-dns1 %@ --fake-dns2 %@ --dhcp-script '/usr/sbin/ipconfig set %@ DHCP' --daemonize 3 --log-file %@ --pid-file %@ --conf-file /dev/null >/dev/null 2>&1 &\n",
        [self stopCommand],
        networkRepairPrefix,
        [self shellQuote:password],
        [self shellQuote:[self minieapPath]],
        [self shellQuote:user],
        iface,
        [self shellQuote:VersionString],
        [self shellQuote:ServiceHex],
        DNS1,
        [self shellQuote:DNS2],
        iface,
        [self shellQuote:[self logFile]],
        [self shellQuote:[self pidFile]]
    ];
    return command;
}

- (NSDictionary *)runAdminShell:(NSString *)command {
    NSString *script = [NSString stringWithFormat:@"do shell script %@ with administrator privileges", [self appleScriptQuote:command]];
    NSTask *task = [[NSTask alloc] init];
    NSPipe *outputPipe = [NSPipe pipe];
    NSPipe *errorPipe = [NSPipe pipe];
    task.launchPath = @"/usr/bin/osascript";
    task.arguments = @[@"-e", script];
    task.standardOutput = outputPipe;
    task.standardError = errorPipe;

    @try {
        [task launch];
    } @catch (NSException *exception) {
        return @{@"ok": @NO, @"message": exception.reason ?: @"无法启动 osascript"};
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45.0];
    while (task.isRunning && [[NSDate date] compare:deadline] == NSOrderedAscending) {
        [NSThread sleepForTimeInterval:0.05];
    }

    if (task.isRunning) {
        [task terminate];
        [NSThread sleepForTimeInterval:0.2];
        if (task.isRunning) {
            @try {
                [task interrupt];
            } @catch (__unused NSException *exception) {
            }
        }
        return @{@"ok": @NO, @"message": @"系统授权或管理员脚本超过 45 秒未返回，已取消本次操作。"};
    }

    NSData *stdoutData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
    NSData *stderrData = [[errorPipe fileHandleForReading] readDataToEndOfFile];
    NSString *stdoutText = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *stderrText = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";
    NSString *message = stderrText.length > 0 ? stderrText : stdoutText;
    if (task.terminationStatus != 0) {
        return @{@"ok": @NO, @"message": message.length > 0 ? message : [NSString stringWithFormat:@"管理员脚本退出码：%d", task.terminationStatus]};
    }
    return @{@"ok": @YES, @"message": stdoutText};
}

- (NSString *)loadValueForAccount:(NSString *)account {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: KeychainService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef item = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &item);
    if (status != errSecSuccess || !item) {
        return nil;
    }
    NSData *data = CFBridgingRelease(item);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)saveValue:(NSString *)value account:(NSString *)account {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: KeychainService,
        (__bridge id)kSecAttrAccount: account
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
    NSMutableDictionary *attrs = [query mutableCopy];
    attrs[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
    SecItemAdd((__bridge CFDictionaryRef)attrs, NULL);
}

- (void)showMessage:(NSString *)message {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = AppName;
    alert.informativeText = message;
    [alert runModal];
}

- (NSString *)timestamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    return [formatter stringFromDate:[NSDate date]];
}

- (NSString *)shellQuote:(NSString *)value {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

- (NSString *)appleScriptQuote:(NSString *)value {
    NSString *escaped = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
