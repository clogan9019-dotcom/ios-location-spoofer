#ifndef CrashGuard_h
#define CrashGuard_h

#include <setjmp.h>
#include <signal.h>

#ifdef __cplusplus
extern "C" {
#endif

// Wraps ds_run() with signal-based crash protection + file logging.
// Returns:  0           success
//           positive    ds_run() returned an error
//           negative    signal caught (e.g. -11 = SIGSEGV)
int ds_run_safe(void);

int         ds_run_safe_last_signal(void);
const char *ds_run_safe_signal_name(void);

#ifdef __cplusplus
}
#endif
#endif
