/* src/t2s_verdict.h
 *
 * SPDX-License-Identifier: Apache-2.0
 * SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * The text-to-SQL REVIEW verdict. The reply's first word, after leading whitespace, is PASS in any case: the end of
 * the reply or a non-identifier character comes right after it. "Password column is missing", "Passage of time ..."
 * and "PASS2 ..." begin with the same four letters and are critiques. A critique read as a pass lets a bad candidate
 * through; a pass read as a critique only costs a retry. Header-only so a plain C program can test it.
 */
#ifndef FRACTALSQL_T2S_VERDICT_H
#define FRACTALSQL_T2S_VERDICT_H

#include <ctype.h>
#include <stdbool.h>
#include <string.h>

/* p points at the first non-whitespace byte of a NUL-terminated reply. */
static inline bool
t2s_verdict_is_pass(const char *p)
{
    if (p == NULL)
        return false;
    if (!(tolower((unsigned char) p[0]) == 'p' && p[0] != '\0' && tolower((unsigned char) p[1]) == 'a' &&
          p[1] != '\0' && tolower((unsigned char) p[2]) == 's' && p[2] != '\0' &&
          tolower((unsigned char) p[3]) == 's' && p[3] != '\0'))
        return false;
    return !(isalnum((unsigned char) p[4]) || p[4] == '_');
}

#endif /* FRACTALSQL_T2S_VERDICT_H */
