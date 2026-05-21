#ifndef CrashGuard_h
#define CrashGuard_h

#include <setjmp.h>
#include <signal.h>

#ifdef __cplusplus
extern "C" {
#endif

// Wraps ds_run() with signal-based crash protection.
// Returns:  0           on success
//           positive    ds_run() returned an error code
//           negative    signal was caught (e.g. -11 for SIGSEGV)
int ds_run_safe(void);

// Signal number of the last caught crash, 0 if none.
int ds_run_safe_last_signal(void);

// Human-readable name for the last caught signal.
const char *ds_run_safe_signal_name(void);

#ifdef __cplusplus
}
#endif

#endif /* CrashGuard_h */
