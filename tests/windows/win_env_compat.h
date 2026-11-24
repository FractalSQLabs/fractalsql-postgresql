/* tests/windows/win_env_compat.h -- the POSIX setenv/unsetenv on MSVC.
 *
 * The unit tests (tests/redact_unit.c) drive the audit trail's redaction by setting and
 * clearing an environment variable, which is how the server itself reads it at runtime.
 * MSVC has no setenv/unsetenv: the CRT's _putenv_s does the same job, and setting a
 * variable to the empty string removes it (the CRT's documented behaviour).
 *
 * The Windows gate force-includes this header (cl.exe /FI) before the test's own
 * includes, so the test source stays POSIX-flavoured and portable -- the same shape as
 * the sqlite repo's tests/windows/evil_nonterminating_plugin_win.c, which carries the
 * Windows version of a POSIX fixture instead of forking the fixture itself.
 */
#ifndef FSQL_WIN_ENV_COMPAT_H
#define FSQL_WIN_ENV_COMPAT_H

#ifdef _WIN32

#include <stdlib.h>

/* overwrite is ignored: _putenv_s always replaces the value. */
static inline int win_compat_setenv(const char *name, const char *value, int overwrite)
{
    (void)overwrite;
    return _putenv_s(name, value ? value : "");
}

static inline int win_compat_unsetenv(const char *name)
{
    return _putenv_s(name, "");
}

#define setenv win_compat_setenv
#define unsetenv win_compat_unsetenv

#endif /* _WIN32 */

#endif /* FSQL_WIN_ENV_COMPAT_H */
