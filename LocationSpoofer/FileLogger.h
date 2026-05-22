#ifndef FileLogger_h
#define FileLogger_h

#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

// Call once at app launch. Opens log files and starts the 5-second flush timer.
void filelog_init(void);

// Append a timestamped line to the in-memory buffer. Thread-safe.
// The buffer is flushed to disk automatically every 5 seconds.
void filelog(const char *msg);

// printf-style variant of filelog().
void filelog_fmt(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// Force an immediate flush of the buffer to both log files.
// Call after critical sections (exploit complete, crash caught, spoof written).
void filelog_flush(void);

// Returns the primary log path: /private/var/mobile/Documents/LocationSpooferLogs/logs.txt
const char *filelog_path(void);

// Wipe both log files and clear the in-memory buffer.
void filelog_clear(void);

#ifdef __cplusplus
}
#endif

#endif /* FileLogger_h */
