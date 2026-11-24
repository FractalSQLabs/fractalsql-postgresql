#!/usr/bin/env python3
"""tests/unicode_matrix.py -- text in and out of the extension keeps its characters.

Accented Latin, CJK, right-to-left text, emoji (skin tone, flag, joined sequences), combining marks and JSON-special characters go
through fractal_chunk_text and a table round trip. Checks: one chunk holds the whole text unchanged, chunk offsets are character
offsets, chunks joined back give the text, the output is strict UTF-8 JSON, stored text comes back byte for byte, and bytes that are not
UTF-8 give an error or valid output (never invalid JSON).
Env: FSQL_PSQL_JSON -- the psql command as a JSON list (host, port, user, database, -X -tA). Exit status is nonzero when a check fails."""
import json, os, subprocess, sys
PSQL = json.loads(os.environ["FSQL_PSQL_JSON"])
CASES = {
    "latin": "Crème brûlée à la façon de São Paulo, naïve café, Ångström, straße",
    "cjk": "日本語のテキストと中文汉字、한국어 문장입니다",
    "rtl": "مرحبا بالعالم שלום עולם",
    "emoji": "😀👍🏽🇯🇵 👨‍👩‍👧‍👦 ok 🧪",
    "combining": "é ñ ạ̈ end",
    "specials": "quote \" backslash \\ tab\t newline\n ctrl \x01\x1f slash / <tag> &amp;    ",
}
passes = fails = 0
def check(cond, what, detail=""):
    global passes, fails
    if cond: passes += 1
    else: fails += 1; print("  FAIL %s %s" % (what, ("-- " + str(detail)[:250]) if detail else ""))
def sql(s):
    p = subprocess.run(PSQL + ["-v", "ON_ERROR_STOP=1", "-c", s], capture_output=True, timeout=120)
    return p.returncode, p.stdout.decode("utf-8", "replace").strip(), p.stderr.decode("utf-8", "replace")
def lit(t): return "convert_from(decode('%s','hex'),'UTF8')" % t.encode("utf-8").hex()
def chunks(t, size, ov, mode="fixed"):
    rc, out, err = sql("SELECT encode(convert_to(fractal_chunk_text(%s,%d,%d,'%s')::text,'UTF8'),'hex')" % (lit(t), size, ov, mode))
    if rc: raise RuntimeError(err[:200])
    return json.loads(bytes.fromhex(out).decode("utf-8"))
sql("DROP TABLE IF EXISTS fsql_uni; CREATE TABLE fsql_uni(id int, body text)")
for i, (name, text) in enumerate(CASES.items()):
    n = len(text)
    try:
        one = chunks(text, 100000, 0)
        check(len(one) == 1 and one[0]["text"] == text and one[0]["start"] == 0 and one[0]["end"] == n, name + ": one chunk holds the whole text", one)
        for size, ov in ((5, 0), (7, 3), (1, 0)):
            ch = chunks(text, size, ov)
            check(all(x["text"] == text[x["start"]:x["end"]] for x in ch), "%s: size %d overlap %d offsets are character offsets" % (name, size, ov))
            check(all(len(x["text"]) <= size for x in ch), "%s: size %d chunks are at most %d characters" % (name, size, size))
            if ov == 0: check("".join(x["text"] for x in ch) == text, "%s: size %d chunks join back to the text" % (name, size))
        for mode in ("paragraph", "sentence"):
            check(len(chunks(text, 100000, 0, mode)) >= 1, name + ": " + mode + " mode answers")
    except Exception as e:
        check(False, name + ": chunk_text output is strict UTF-8 JSON", e)
    sql("INSERT INTO fsql_uni VALUES (%d, %s)" % (i, lit(text)))
    rc, out, err = sql("SELECT encode(convert_to(body,'UTF8'),'hex'), char_length(body) FROM fsql_uni WHERE id=%d" % i)
    hx, ln = out.split("|")
    check(rc == 0 and bytes.fromhex(hx) == text.encode("utf-8") and int(ln) == n, name + ": a table round trip returns the same characters", out)
# bytes that are not UTF-8 cannot become a text value in PostgreSQL: the conversion is refused, cleanly
for label, raw in (("lone continuation", b"a\x80b"), ("0xff", b"a\xffb")):
    rc, out, err = sql("SELECT fractal_chunk_text(convert_from(decode('%s','hex'),'UTF8'),10,0)" % raw.hex())
    check(rc != 0 and "invalid byte sequence" in err, "invalid bytes (%s) are refused before the extension sees them" % label, err)
sql("DROP TABLE fsql_uni")
print("unicode_matrix: %d checks passed, %d failed" % (passes, fails)); sys.exit(1 if fails else 0)
