#import "CrashGuard.h"
#import "kexploit/darksword.h"
#include <signal.h>
#include <setjmp.h>
#include <string.h>

static sigjmp_buf  _cg_jmp;
static volatile sig_atomic_t _cg_active = 0;
static volatile int _cg_last_signal = 0;

static void _cg_install(void (*handler)(int));

static void _cg_handler(int sig) {
    if (_cg_active) {
        _cg_active = 0;
        _cg_last_signal = sig;
        siglongjmp(_cg_jmp, sig);
    }
    // Not in a guarded section — restore default and re-raise so the OS
    // can still generate a crash report.
    signal(sig, SIG_DFL);
    raise(sig);
}

static void _cg_install(void (*handler)(int)) {
    signal(SIGSEGV, handler);
    signal(SIGBUS,  handler);
    signal(SIGILL,  handler);
    signal(SIGABRT, handler);
    signal(SIGFPE,  handler);
    signal(SIGTRAP, handler);
}

int ds_run_safe(void) {
    _cg_last_signal = 0;
    _cg_install(_cg_handler);

    _cg_active = 1;
    int caught = sigsetjmp(_cg_jmp, 1);
    if (caught != 0) {
        // A signal landed — restore defaults and surface the error.
        _cg_active = 0;
        _cg_install(SIG_DFL);
        return -abs(caught);
    }

    int ret = ds_run();

    _cg_active = 0;
    _cg_install(SIG_DFL);
    return ret;
}

int ds_run_safe_last_signal(void) {
    return _cg_last_signal;
}

const char *ds_run_safe_signal_name(void) {
    switch (_cg_last_signal) {
        case SIGSEGV: return "SIGSEGV (bad memory access)";
        case SIGBUS:  return "SIGBUS  (bus error)";
        case SIGILL:  return "SIGILL  (illegal instruction / PAC failure)";
        case SIGABRT: return "SIGABRT (abort)";
        case SIGFPE:  return "SIGFPE  (arithmetic error)";
        case SIGTRAP: return "SIGTRAP (trace trap)";
        default:      return "unknown signal";
    }
}
