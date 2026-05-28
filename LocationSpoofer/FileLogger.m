#import "FileLogger.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <time.h>
#include <string.h>
#include <stdio.h>
#include <sys/utsname.h>

#define FL_DIR  "/private/var/mobile/Documents/LocationSpooferLogs"
#define FL_FILE "/private/var/mobile/Documents/LocationSpooferLogs/logs.txt"

static int                g_fd     = -1;
static pthread_mutex_t    g_mutex  = PTHREAD_MUTEX_INITIALIZER;
static char               g_path[512] = {0};
static NSMutableData     *g_buffer = nil;
static dispatch_source_t  g_timer  = NULL;

static void fl_set_path_locked(const char *path) {
    if (path && path[0] != '\0') {
        strlcpy(g_path, path, sizeof(g_path));
    }
}

// ─── Mirror path (Files app / Documents) ────────────────────────────────────

static NSString *fl_mirror_path(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *base = [paths.firstObject stringByAppendingPathComponent:@"SpooferLogs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:base
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [base stringByAppendingPathComponent:@"logs.txt"];
}

// ─── Internal flush (call with mutex already held) ──────────────────────────

static void fl_flush_locked(void) {
    if (!g_buffer || g_buffer.length == 0) return;

    // Primary file — /private/var/mobile/Documents/LocationSpooferLogs/logs.txt
    if (g_fd >= 0) {
        write(g_fd, g_buffer.bytes, g_buffer.length);
        fsync(g_fd);
    }

    // Mirror — Documents/SpooferLogs/logs.txt (visible in Files app)
    @autoreleasepool {
        NSString *mirror = fl_mirror_path();
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:mirror];
        if (!fh) {
            [@"" writeToFile:mirror atomically:NO encoding:NSUTF8StringEncoding error:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:mirror];
        }
        [fh seekToEndOfFile];
        [fh writeData:g_buffer];
        [fh closeFile];
    }

    [g_buffer setLength:0];
}

// ─── Public API ─────────────────────────────────────────────────────────────

void filelog_init(void) {
    pthread_mutex_lock(&g_mutex);

    if (!g_buffer) {
        g_buffer = [NSMutableData dataWithCapacity:4096];
    }

    // The primary path may be unavailable before the sandbox escape. Always
    // expose a valid path by falling back to the app-container mirror used by
    // Files.app and LogUploader. This keeps diagnostics from showing a blank
    // log path on first launch.
    NSString *mirror = fl_mirror_path();
    fl_set_path_locked(mirror.fileSystemRepresentation);

    [[NSFileManager defaultManager] createDirectoryAtPath:@FL_DIR
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    if (g_fd < 0) {
        int fd = open(FL_FILE, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            g_fd = fd;
            fl_set_path_locked(FL_FILE);
        }
    }

    BOOL shouldStartTimer = (g_timer == NULL);
    pthread_mutex_unlock(&g_mutex);

    // 5-second periodic flush — keeps both files current without per-write I/O.
    // filelog_init() can be called again after clearing logs, so only create one
    // timer for the process lifetime.
    if (shouldStartTimer) {
        dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
        g_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(g_timer,
                                  dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                  5 * NSEC_PER_SEC,
                                  500 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(g_timer, ^{ filelog_flush(); });
        dispatch_resume(g_timer);
    }

    // Session header — write and flush immediately so the file is never empty
    struct utsname u; uname(&u);
    NSString *ios = [[UIDevice currentDevice] systemVersion];
    filelog_fmt("========== SESSION START ==========");
    filelog_fmt("Device : %s", u.machine);
    filelog_fmt("iOS    : %s", ios.UTF8String ?: "?");
    filelog_fmt("Kernel : %s", u.release);
    filelog_fmt("Log    : %s", filelog_path());
    filelog_fmt("===================================");
    filelog_flush();
}

void filelog(const char *msg) {
    if (!msg) return;

    time_t t = time(NULL);
    struct tm *ti = localtime(&t);
    char ts[24];
    strftime(ts, sizeof(ts), "%H:%M:%S", ti);

    char line[4096];
    int len = snprintf(line, sizeof(line), "[%s] %s\n", ts, msg);
    if (len <= 0) return;

    NSLog(@"[Spoofer] %s", msg);

    pthread_mutex_lock(&g_mutex);
    if (!g_buffer) g_buffer = [NSMutableData dataWithCapacity:4096];
    [g_buffer appendBytes:line length:(NSUInteger)len];
    pthread_mutex_unlock(&g_mutex);
}

void filelog_fmt(const char *fmt, ...) {
    char buf[4096];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    filelog(buf);
}

void filelog_flush(void) {
    pthread_mutex_lock(&g_mutex);
    fl_flush_locked();
    pthread_mutex_unlock(&g_mutex);
}

const char *filelog_path(void) { return g_path; }

void filelog_clear(void) {
    pthread_mutex_lock(&g_mutex);

    if (g_buffer) [g_buffer setLength:0];

    if (g_fd >= 0) { close(g_fd); g_fd = -1; }
    unlink(FL_FILE);
    fl_set_path_locked("");

    @autoreleasepool {
        NSString *mirror = fl_mirror_path();
        [@"" writeToFile:mirror atomically:NO encoding:NSUTF8StringEncoding error:nil];
        fl_set_path_locked(mirror.fileSystemRepresentation);
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:@FL_DIR
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    int fd = open(FL_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        g_fd = fd;
        fl_set_path_locked(FL_FILE);
    }

    pthread_mutex_unlock(&g_mutex);
}
