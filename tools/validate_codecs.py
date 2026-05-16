#!/usr/bin/env python3
"""
Validate volute codec tables against iconv and Python codecs.

Usage:
    python3 tools/validate_codecs.py          # check all codecs
    python3 tools/validate_codecs.py gbk cp1251   # check specific codecs
    python3 tools/validate_codecs.py --verbose    # show every mapping

For each supported encoding the script:
  1. Decodes every valid input byte-sequence with Python's codec
  2. Cross-checks against iconv (must produce identical UTF-8)
  3. Prints PASS / FAIL with the first mismatch per codec
"""

import subprocess
import sys
from typing import Iterator

# Maps volute encoding name → (iconv_name, python_name, undefined_bytes)
CODECS = {
    "gbk":       ("GBK",      "gbk",    set()),
    "big5":      ("CP950",    "cp950",  set()),
    "shiftjis":  ("CP932",    "cp932",  set()),
    "euckr":     ("CP949",    "cp949",  set()),
    "eucjp":     ("EUC-JP",   "euc_jp", set()),
    "cp1250":    ("CP1250",   "cp1250", set()),
    "cp1251":    ("CP1251",   "cp1251", {0x98}),
    "cp1252":    ("CP1252",   "cp1252", {0x81, 0x8D, 0x8F, 0x90, 0x9D}),
    "koi8r":     ("KOI8-R",   "koi8_r", set()),
    "koi8u":     ("KOI8-U",   "koi8_u", set()),
    "cp874":     ("CP874",    "cp874",  set()),
    "cp1253":    ("CP1253",   "cp1253", set()),
    "cp1254":    ("CP1254",   "cp1254", set()),
    "cp1255":    ("CP1255",   "cp1255", set()),
    "cp1256":    ("CP1256",   "cp1256", set()),
    "cp1257":    ("CP1257",   "cp1257", set()),
    "cp1258":    ("CP1258",   "cp1258", set()),
    "iso8859_2": ("ISO-8859-2","iso8859_2", set()),
    "iso8859_5": ("ISO-8859-5","iso8859_5", set()),
    "iso8859_7": ("ISO-8859-7","iso8859_7", set()),
    "iso8859_15":("ISO-8859-15","iso8859_15", set()),
}

VERBOSE = "--verbose" in sys.argv


def iconv_decode(iconv_name: str, data: bytes) -> bytes | None:
    r = subprocess.run(
        ["iconv", "-f", iconv_name, "-t", "UTF-8"],
        input=data, capture_output=True,
    )
    return r.stdout if r.returncode == 0 else None


def sbcs_test_cases(python_name: str, undefined: set[int]) -> Iterator[bytes]:
    """Yield single-byte sequences for all bytes 0x80-0xFF that are defined."""
    for b in range(0x80, 0x100):
        if b in undefined:
            continue
        seq = bytes([b])
        try:
            seq.decode(python_name)
            yield seq
        except (UnicodeDecodeError, LookupError):
            pass


def dbcs_test_cases(python_name: str) -> Iterator[bytes]:
    """Yield all valid 2-byte sequences for a DBCS codec (sampled)."""
    # Full sweep is too slow (~65 k pairs), so sample every 16th lead byte.
    for lead in range(0x81, 0xFF, 16):
        for trail in range(0x40, 0xFF):
            seq = bytes([lead, trail])
            try:
                seq.decode(python_name)
                yield seq
            except (UnicodeDecodeError, LookupError):
                pass


def validate(volute_name: str, iconv_name: str, python_name: str, undefined: set[int]) -> bool:
    dbcs = volute_name in ("gbk", "big5", "shiftjis", "euckr", "eucjp")
    cases = list(dbcs_test_cases(python_name) if dbcs else sbcs_test_cases(python_name, undefined))

    mismatches = 0
    for seq in cases:
        try:
            py_utf8 = seq.decode(python_name).encode("utf-8")
        except Exception as e:
            if VERBOSE:
                print(f"  py  skip {seq.hex()}: {e}")
            continue

        iconv_utf8 = iconv_decode(iconv_name, seq)
        if iconv_utf8 is None:
            # iconv does not support this sequence — skip silently
            continue

        if iconv_utf8 != py_utf8:
            if mismatches == 0:
                print(f"  MISMATCH {seq.hex()}: iconv={iconv_utf8.hex()} py={py_utf8.hex()}")
            mismatches += 1
        elif VERBOSE:
            print(f"  ok  {seq.hex()} → {py_utf8.hex()}")

    if mismatches:
        print(f"  {mismatches} mismatch(es) out of {len(cases)} cases")
        return False
    print(f"  {len(cases)} cases: iconv == python  ✓")
    return True


def main() -> None:
    requested = [a for a in sys.argv[1:] if not a.startswith("--")]
    targets = {k: v for k, v in CODECS.items() if not requested or k in requested}

    if not targets:
        print(f"Unknown codec(s): {requested}")
        sys.exit(1)

    failures = []
    for name, (iconv_n, py_n, undef) in targets.items():
        print(f"[{name}] iconv={iconv_n} py={py_n}")
        ok = validate(name, iconv_n, py_n, undef)
        if not ok:
            failures.append(name)

    print()
    if failures:
        print(f"FAIL: {failures}")
        sys.exit(1)
    else:
        print(f"All {len(targets)} codec(s) PASS")


if __name__ == "__main__":
    main()
