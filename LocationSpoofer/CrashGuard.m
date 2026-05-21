#import "CrashGuard.h"
#import "FileLogger.h"
#import "kexploit/darksword.h"
#include <signal.h>
#include <setjmp.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

static sigjmp_buf            _cg_jmp;
static volatile sig_atomic_t _cg_active = 0;
static volatile int          _cg_last_sig = 0;

// Only async-signal-safe calls inside this handler
static void _cg_handler(int sig) {
    if (_cg_active) {
        _cg_active  = 0;
        _cg_last_sig = sig;
        siglongjmp(_cg_jmp, sig);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void _cg_install(void (*h)(int)) {
    signal(SIGSEGV, h);
    signal(SIGBUS,  h);
    signal(SIGILL,  h);
    signal(SIGABRT, h);
    signal(SIGFPE,  h);
    signal(SIGTRAP, h);
}

int ds_run_safe(void) {
    _cg_last_sig = 0;

    filelog("CrashGuard: installing signal handlers");
    filelog_flush();

    _cg_install(_cg_handler);
    _cg_active = 1;

    int caught = sigsetjmp(_cg_jmp, 1);
    if (caught != 0) {
        _cg_active = 0;
        _cg_install(SIG_DFL);

        char msg[256];
        snprintf(msg, sizeof(msg),
            "CrashGuard: CAUGHT SIGNAL %d (%s) — ds_run crashed",
            caught, ds_run_safe_signal_name());
        // Use write() — async-signal-safe
        write(STDERR_FILENO, msg, strlen(msg));
        write(STDERR_FILENO, "\n", 1);
        filelog(msg);
        filelog_flush();
        return -abs(caught);
    }

    filelog("CrashGuard: calling ds_run()...");
    filelog_flush();

    int ret = ds_run();

    _cg_active = 0;
    _cg_install(SIG_DFL);

    char result[128];
    snprintf(result, sizeof(result), "CrashGuard: ds_run() returned %d", ret);
    filelog(result);
    filelog_flush();
    return ret;
}

int ds_run_safe_last_signal(void) { return _cg_last_sig; }

const char *ds_run_safe_signal_name(void) {
    switch (_cg_last_sig) {
        case SIGSEGV: return "SIGSEGV (bad memory access)";
        case SIGBUS:  return "SIGBUS  (bus error / misaligned)";
        case SIGILL:  return "SIGILL  (illegal instruction / PAC failure)";
        case SIGABRT: return "SIGABRT (abort / assertion)";
        case SIGFPE:  return "SIGFPE  (arithmetic error)";
        case SIGTRAP: return "SIGTRAP (trace trap)";
        default:      return "unknown signal";
    }
}
