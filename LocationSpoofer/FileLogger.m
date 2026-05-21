#import "FileLogger.h"
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <time.h>
#include <string.h>
#include <stdio.h>
#include <sys/utsname.h>

// Fixed path — always findable via jailbroken file manager / AFC
#define FL_DIR  "/private/var/mobile/Documents/LocationSpooferLogs"
#define FL_FILE "/private/var/mobile/Documents/LocationSpooferLogs/logs.txt"

static int               g_fd    = -1;
static pthread_mutex_t   g_mutex = PTHREAD_MUTEX_INITIALIZER;
static char              g_path[512] = {0};

static void fl_write_raw(const char *line, int len) {
    if (g_fd >= 0) write(g_fd, line, len);
}

static void fl_write_mirror(const char *line) {
    @autoreleasepool {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *base = [paths.firstObject stringByAppendingPathComponent:@"SpooferLogs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:base
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *mirror = [base stringByAppendingPathComponent:@"logs.txt"];
        NSString *s = [NSString stringWithUTF8String:line];
        if (!s) return;
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:mirror];
        if (!fh) {
            [@"" writeToFile:mirror atomically:NO encoding:NSUTF8StringEncoding error:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:mirror];
        }
        [fh seekToEndOfFile];
        [fh writeData:[s dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

void filelog_init(void) {
    pthread_mutex_lock(&g_mutex);
    mkdir(FL_DIR, 0755);
    int fd = open(FL_FILE, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        g_fd = fd;
        strlcpy(g_path, FL_FILE, sizeof(g_path));
    }
    pthread_mutex_unlock(&g_mutex);

    // Gather device info for the header
    struct utsname u; uname(&u);
    NSString *ios = [[UIDevice currentDevice] systemVersion];
    NSString *model = [NSString stringWithUTF8String:u.machine];

    filelog_fmt("========== SESSION START ==========");
    filelog_fmt("Device : %s", u.machine);
    filelog_fmt("iOS    : %s", ios.UTF8String ?: "?");
    filelog_fmt("Kernel : %s", u.release);
    filelog_fmt("Log    : %s", FL_FILE);
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
    fl_write_raw(line, len);
    pthread_mutex_unlock(&g_mutex);

    fl_write_mirror(line);
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
    if (g_fd >= 0) fsync(g_fd);
    pthread_mutex_unlock(&g_mutex);
}

const char *filelog_path(void) { return g_path; }

void filelog_clear(void) {
    pthread_mutex_lock(&g_mutex);
    if (g_fd >= 0) { close(g_fd); g_fd = -1; }
    unlink(FL_FILE);
    int fd = open(FL_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) g_fd = fd;
    pthread_mutex_unlock(&g_mutex);
}
