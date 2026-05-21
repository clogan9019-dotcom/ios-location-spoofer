#ifndef FileLogger_h
#define FileLogger_h

#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

// Call once at app launch. Creates log directory and opens the file.
void filelog_init(void);

// Timestamped write. Also mirrors to NSLog. Thread-safe.
void filelog(const char *msg);

// printf-style variant.
void filelog_fmt(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// Sync to disk. Call after critical exploit sections.
void filelog_flush(void);

// Returns the primary log path on device.
const char *filelog_path(void);

// Wipe the log file so the next session starts fresh.
void filelog_clear(void);

#ifdef __cplusplus
}
#endif

#endif /* FileLogger_h */
