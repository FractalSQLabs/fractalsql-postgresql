/*
 * fsql_fault.h -- test-only fault injection (compiled in only with
 * -DFSQL_FAULT_INJECT, which build_test.sh/.ps1 pass and a normal build never does).
 *
 * Makes the "this call failed" branches reachable from SQL: the SPI calls
 * and the core calls whose return codes the extension checks. They fail in
 * practice only on memory exhaustion or an engine fault, so no input can
 * reach them.
 *
 * Control is the session-local, superuser-only GUC fractalsql.fault_inject:
 *
 *     SET fractalsql.fault_inject = 'SPI_execute:3';
 *
 * fails the 3rd SPI_execute() call made after the SET (counting restarts at
 * every SET); 'SPI_execute:*' fails every call. A fired fault raises a
 * NOTICE ("fractalsql: fault injected at <site> #<n>") so a sweep can tell
 * when it has run past the last call site.
 *
 * Most sites make the call report failure: -1 (SPI_ERROR_ARGUMENT /
 * FSQL_ERR_INVALID), SPI_ERROR_CONNECT for SPI_connect, NULL for
 * fsql_new_sovereign. A few sites instead return success with a bad result,
 * the way a misbehaving core could:
 *   fsql_dispatch_ai_resp       call OK, response status -1
 *   fsql_dispatch_ai_nosummary  call OK, response status OK, summary NULL
 *   fsql_search_null_json       call OK, no result JSON
 *   fsql_topk_idx_neg/_big      top-k result whose first index is -1 / past the corpus
 *
 * The failure values are read through volatiles on purpose. A literal -1
 * lets the optimizer thread the fault straight into the error block and
 * skip the `if (rc != OK)` test, so coverage would show that branch as
 * never taken even though the error path ran.
 *
 * Only call sites in fractalsql.c (which includes this header) are affected.
 */
#ifndef FSQL_FAULT_H
#define FSQL_FAULT_H

#ifdef FSQL_FAULT_INJECT

static char *g_fi_spec = NULL;
static char  g_fi_site[48];
static long  g_fi_nth   = 0;     /* 0 = disabled, -1 = every call */
static long  g_fi_count = 0;

static volatile int          fi_rc_invalid  = FSQL_ERR_INVALID;
static volatile int          fi_rc_zero     = 0;
static volatile int          fi_rc_spi_arg  = SPI_ERROR_ARGUMENT;
static volatile int          fi_rc_spi_conn = SPI_ERROR_CONNECT;
static volatile int          fi_rc_not_comp = TYPEFUNC_OTHER;
static fsql_ctx *volatile    fi_null_ctx    = NULL;

static void
fi_assign(const char *newval, void *extra)
{
    const char *colon;
    size_t      n;

    (void) extra;
    g_fi_site[0] = '\0';
    g_fi_nth     = 0;
    g_fi_count   = 0;
    if (newval == NULL || newval[0] == '\0')
        return;
    colon = strchr(newval, ':');
    if (colon == NULL)
        return;
    n = (size_t) (colon - newval);
    if (n >= sizeof g_fi_site)
        return;
    memcpy(g_fi_site, newval, n);
    g_fi_site[n] = '\0';
    g_fi_nth = (colon[1] == '*') ? -1 : atol(colon + 1);
}

static bool
fi_hit(const char *site)
{
    if (g_fi_nth == 0 || strcmp(site, g_fi_site) != 0)
        return false;
    g_fi_count++;
    if (g_fi_nth > 0 && g_fi_count != g_fi_nth)
        return false;
    ereport(NOTICE, (errmsg("fractalsql: fault injected at %s #%ld", site, g_fi_count)));
    return true;
}

static void
fi_define_guc(void)
{
    DefineCustomStringVariable(
        "fractalsql.fault_inject",
        "Test builds only: fail the Nth call of a named SPI/core call site.",
        NULL,
        &g_fi_spec,
        NULL,
        PGC_SUSET,
        GUC_NO_SHOW_ALL | GUC_NOT_IN_SAMPLE, NULL, fi_assign, NULL);
}

static int
fi_SPI_connect(void)
{
    return fi_hit("SPI_connect") ? fi_rc_spi_conn : SPI_connect();
}

static int
fi_SPI_execute(const char *src, bool read_only, long tcount)
{
    return fi_hit("SPI_execute") ? fi_rc_spi_arg : SPI_execute(src, read_only, tcount);
}

static int
fi_SPI_execute_with_args(const char *src, int nargs, Oid *argtypes, Datum *values,
                         const char *nulls, bool read_only, long tcount)
{
    return fi_hit("SPI_execute_with_args") ? fi_rc_spi_arg
         : SPI_execute_with_args(src, nargs, argtypes, values, nulls, read_only, tcount);
}

#define SPI_connect()               fi_SPI_connect()
#define SPI_execute(...)            fi_SPI_execute(__VA_ARGS__)
#define SPI_execute_with_args(...)  fi_SPI_execute_with_args(__VA_ARGS__)

/* Core calls that return a response: besides outright failure, the two
 * "call OK but the response is bad" shapes. */
static int
fi_dispatch_ai(fsql_ctx *ctx, const char *q, size_t ql, const char *c, size_t cl,
               fsql_ai_response_t *resp)
{
    if (fi_hit("fsql_dispatch_ai"))
    {
        memset(resp, 0, sizeof(*resp));
        return fi_rc_invalid;
    }
    if (fi_hit("fsql_dispatch_ai_resp"))
    {
        memset(resp, 0, sizeof(*resp));
        resp->rc = fi_rc_invalid;
        return fi_rc_zero;
    }
    if (fi_hit("fsql_dispatch_ai_nosummary"))
    {
        memset(resp, 0, sizeof(*resp));
        return fi_rc_zero;
    }
    return fsql_dispatch_ai(ctx, q, ql, c, cl, resp);
}
#define fsql_dispatch_ai(...)  fi_dispatch_ai(__VA_ARGS__)

static int
fi_search_ptr(fsql_ctx *ctx, const double *corpus, size_t n_rows, size_t dim,
              const double *query, size_t query_dim, int k,
              const char *params, size_t params_len,
              const char **result_json, size_t *result_len)
{
    if (fi_hit("fsql_search_ptr"))
        return fi_rc_invalid;
    if (fi_hit("fsql_search_null_json"))
    {
        *result_json = NULL;
        *result_len  = 0;
        return fi_rc_zero;
    }
    return fsql_search_ptr(ctx, corpus, n_rows, dim, query, query_dim, k,
                           params, params_len, result_json, result_len);
}
#define fsql_search_ptr(...)  fi_search_ptr(__VA_ARGS__)

static int
fi_extract_topk(const char *json, int max_k, int *out_idx, double *out_dist)
{
    int got;

    if (fi_hit("fsql_extract_topk"))
        return fi_rc_invalid;
    got = fsql_extract_topk(json, max_k, out_idx, out_dist);
    if (got > 0 && fi_hit("fsql_topk_idx_neg"))
        out_idx[0] = -1;
    if (got > 0 && fi_hit("fsql_topk_idx_big"))
        out_idx[0] = 0x7fffffff;
    return got;
}
#define fsql_extract_topk(...)  fi_extract_topk(__VA_ARGS__)

static fsql_ctx *
fi_new_sovereign(const fsql_storage_vfs_t *storage, const fsql_reasoning_vfs_t *reasoning)
{
    return fi_hit("fsql_new_sovereign") ? fi_null_ctx : fsql_new_sovereign(storage, reasoning);
}
#define fsql_new_sovereign(...)  fi_new_sovereign(__VA_ARGS__)

/* Result-type resolution: only the call sites that compare the result to
 * TYPEFUNC_COMPOSITE go through here (FSQL_RESULT_NOT_COMPOSITE). */
#define FSQL_RESULT_NOT_COMPOSITE(fcinfo, tupdesc) \
    ((fi_hit("get_call_result_type") ? (TypeFuncClass) fi_rc_not_comp \
                                     : get_call_result_type((fcinfo), NULL, (tupdesc))) != TYPEFUNC_COMPOSITE)

/* The set-returning functions' "caller can accept a materialized set" test. */
#define FSQL_SRF_NO_MATERIALIZE(rsinfo) \
    (fi_hit("srf_context") || (rsinfo) == NULL || !((rsinfo)->allowedModes & SFRM_Materialize))

/* int-returning calls whose return code the extension checks: a fired
 * fault reports FSQL_ERR_INVALID (-1), except fsql_extract_population,
 * which is documented to return a count and so reports 0 parsed. */
#define FI_FAIL(site, fn, ...)  (fi_hit(site) ? fi_rc_invalid : fn(__VA_ARGS__))

#define fsql_load_reasoning(...)         FI_FAIL("fsql_load_reasoning", fsql_load_reasoning, __VA_ARGS__)
#define fsql_extract_best_point(...)     FI_FAIL("fsql_extract_best_point", fsql_extract_best_point, __VA_ARGS__)
#define fsql_extract_population(...)     (fi_hit("fsql_extract_population") ? fi_rc_zero : fsql_extract_population(__VA_ARGS__))
#define fsql_parse_embedding_array(...)  FI_FAIL("fsql_parse_embedding_array", fsql_parse_embedding_array, __VA_ARGS__)
#define fsql_cycle_detect_init(...)      FI_FAIL("fsql_cycle_detect_init", fsql_cycle_detect_init, __VA_ARGS__)
#define fsql_cycle_detect_feed(...)      FI_FAIL("fsql_cycle_detect_feed", fsql_cycle_detect_feed, __VA_ARGS__)
#define fsql_state_fingerprint(...)      FI_FAIL("fsql_state_fingerprint", fsql_state_fingerprint, __VA_ARGS__)
#define fsql_feedback_report(...)        FI_FAIL("fsql_feedback_report", fsql_feedback_report, __VA_ARGS__)
#define fsql_diversify_enable(...)       FI_FAIL("fsql_diversify_enable", fsql_diversify_enable, __VA_ARGS__)
#define fsql_diversify_disable(...)      FI_FAIL("fsql_diversify_disable", fsql_diversify_disable, __VA_ARGS__)
#define fsql_diversify_get_params(...)   FI_FAIL("fsql_diversify_get_params", fsql_diversify_get_params, __VA_ARGS__)
#define fsql_diversify_set_params(...)   FI_FAIL("fsql_diversify_set_params", fsql_diversify_set_params, __VA_ARGS__)
#define fsql_optimize_portfolio_ex(...)  FI_FAIL("fsql_optimize_portfolio_ex", fsql_optimize_portfolio_ex, __VA_ARGS__)

/* The enterprise core's entry points are function pointers resolved at
 * load time; fail them the same way. */
#define g_ent_ledger_flush(...)          FI_FAIL("g_ent_ledger_flush", g_ent_ledger_flush, __VA_ARGS__)
#define g_ent_ledger_load(...)           FI_FAIL("g_ent_ledger_load", g_ent_ledger_load, __VA_ARGS__)
#define g_ent_ledger_compact(...)        FI_FAIL("g_ent_ledger_compact", g_ent_ledger_compact, __VA_ARGS__)
#define g_ent_ledger_reset_soft(...)     FI_FAIL("g_ent_ledger_reset_soft", g_ent_ledger_reset_soft, __VA_ARGS__)
#define g_ent_ledger_reset_hard(...)     FI_FAIL("g_ent_ledger_reset_hard", g_ent_ledger_reset_hard, __VA_ARGS__)
#define g_ent_ledger_truth_count(...)    FI_FAIL("g_ent_ledger_truth_count", g_ent_ledger_truth_count, __VA_ARGS__)
#define g_ent_ledger_shadow_count(...)   FI_FAIL("g_ent_ledger_shadow_count", g_ent_ledger_shadow_count, __VA_ARGS__)
#define g_ent_optimize_portfolio_multimodal(...)        FI_FAIL("g_ent_optimize_portfolio_multimodal", g_ent_optimize_portfolio_multimodal, __VA_ARGS__)
#define g_ent_optimize_portfolio_multimodal_ex(...)     FI_FAIL("g_ent_optimize_portfolio_multimodal_ex", g_ent_optimize_portfolio_multimodal_ex, __VA_ARGS__)
#define g_ent_optimize_portfolio_multimodal_pareto(...) FI_FAIL("g_ent_optimize_portfolio_multimodal_pareto", g_ent_optimize_portfolio_multimodal_pareto, __VA_ARGS__)

#endif /* FSQL_FAULT_INJECT */
#endif /* FSQL_FAULT_H */
