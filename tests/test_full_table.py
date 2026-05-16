#!/usr/bin/env python3
"""Full-table decode validation for DBCS codecs using Python as oracle.

For each DBCS codec, every 2-byte sequence that Python decodes as a single
non-U+FFFD character is fed to vx and the result is compared.  This validates
all entries in the codec's fwd_table that both Python and vx agree exist.

Tests are batched per lead byte (one subprocess call per lead byte) so the
entire suite completes in a few seconds.

Python codec mapping:
  vx gbk       -> Python gbk       (identical tables)
  vx big5      -> Python cp950     (Microsoft Big5 extension)
  vx shift-jis -> Python shift_jis (standard SJIS, not cp932 which has MS extras)
  vx euc-jp    -> Python euc_jp    (standard EUC-JP 2-byte only)
  vx euc-kr    -> Python cp949     (vx uses CP949 / UHC, a superset of EUC-KR)

Only pairs that Python decodes to a single non-U+FFFD character are tested;
this avoids noise from table-coverage divergences while still exercising every
mapping that the Python reference knows about.

Run:
    zig build -Dfetch=false   # required: local tables include ETen Big5 extensions (C6A1–C7FE)
    uv run pytest tests/test_full_table.py -v

Note: big5 (cp950) test covers ETen extensions present in tools/codecs/CP950.TXT
but absent from upstream Unicode CP950.TXT.
"""

import subprocess
import unicodedata
import pytest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
VX = REPO_ROOT / "zig-out" / "bin" / "vx"

if not VX.exists():
    pytest.exit(f"vx binary not found at {VX}\nRun: zig build", returncode=2)

# DBCS codecs: (vx_name, python_codec_name)
# Notes on Python codec choice:
#   shift_jis - standard SJIS, avoids CP932 Microsoft private-use extensions
#   cp949     - Microsoft CP949 / UHC, the superset of EUC-KR that vx implements
DBCS = [
    ("gbk",       "gbk"),
    ("big5",      "cp950"),
    ("shift-jis", "shift_jis"),
    ("euc-jp",    "euc_jp"),
    ("euc-kr",    "cp949"),
]

# Known WHATWG vs JIS/ISO variant pairs (both are "correct" in different standards).
# vx follows WHATWG; Python follows the JIS/ISO standard.  We normalise these
# so neither side is penalised for a legitimate standard difference.
_WHATWG_VARIANTS: dict[int, int] = {
    0xFF5E: 0x301C,   # FULLWIDTH TILDE <-> WAVE DASH
    0x2225: 0x2016,   # PARALLEL TO <-> DOUBLE VERTICAL LINE
    0xFF0D: 0x2212,   # FULLWIDTH HYPHEN-MINUS <-> MINUS SIGN
    0xFFE0: 0x00A2,   # FULLWIDTH CENT SIGN <-> CENT SIGN
    0xFFE1: 0x00A3,   # FULLWIDTH POUND SIGN <-> POUND SIGN
    0xFFE2: 0x00AC,   # FULLWIDTH NOT SIGN <-> NOT SIGN
}
# Reverse map: JIS/ISO -> WHATWG (for normalising Python's output)
_WHATWG_REVERSE: dict[int, int] = {v: k for k, v in _WHATWG_VARIANTS.items()}


def _normalise(ch: str) -> str:
    """NFC-normalise and map JIS/ISO variant codepoints to their WHATWG equivalents."""
    ch = unicodedata.normalize("NFC", ch)
    cp = ord(ch)
    if cp in _WHATWG_REVERSE:
        return chr(_WHATWG_REVERSE[cp])
    return ch


def _valid_pairs(py_name: str) -> dict[int, list[tuple[int, str]]]:
    """Return {lead: [(trail, expected_char), ...]} for all valid DBCS pairs.

    A pair is 'valid' when Python decodes [lead, trail] as a single non-U+FFFD char.
    For euc_jp, 3-byte-encoded chars are excluded (vx handles 2-byte JIS X 0208 only).
    """
    pairs_by_lead: dict[int, list[tuple[int, str]]] = {}
    for lead in range(0x80, 0x100):
        for trail in range(0x00, 0x100):
            try:
                s = bytes([lead, trail]).decode(py_name, errors="strict")
            except (UnicodeDecodeError, LookupError):
                continue
            if len(s) != 1 or s == "\ufffd":
                continue
            if py_name == "euc_jp":
                try:
                    if bytes([lead, trail]) != s.encode("euc_jp", errors="strict"):
                        continue
                except (UnicodeEncodeError, LookupError):
                    continue
            pairs_by_lead.setdefault(lead, []).append((trail, s))
    return pairs_by_lead


# Pre-compute at import time (once per run)
_VALID: dict[str, dict[int, list[tuple[int, str]]]] = {
    py_name: _valid_pairs(py_name)
    for _, py_name in DBCS
}


# ---- helpers -----------------------------------------------------------------

def _vx_decode(data: bytes, enc: str) -> bytes | None:
    r = subprocess.run([str(VX), "-e", enc, "-o", "-", "-"],
                       input=data, capture_output=True)
    return None if r.returncode != 0 else r.stdout


def _utf8_chars_from(utf8: bytes) -> list[str]:
    return list(utf8.decode("utf-8", errors="replace"))


# ---- build parametrize list --------------------------------------------------
# One test per (vx_name, lead_byte) that has at least one valid pair.

_CASES: list = []
for _vx, _py in DBCS:
    for _lead in sorted(_VALID[_py].keys()):
        _CASES.append(pytest.param(_vx, _py, _lead, id=f"{_vx}~0x{_lead:02X}"))


# ---- core test ---------------------------------------------------------------

@pytest.mark.parametrize("vx_name,py_name,lead", _CASES)
def test_dbcs_decode_lead_byte(vx_name: str, py_name: str, lead: int) -> None:
    """Decode all Python-valid [lead, trail] pairs and verify vx agrees.

    Only the (lead, trail) pairs that Python decodes as a single non-U+FFFD
    character are tested.  Since these pairs are all valid 2-byte sequences the
    vx decoder consumes them in predictable 2-byte units, so the output length
    exactly equals the number of pairs sent.
    """
    valid = _VALID[py_name][lead]  # [(trail, expected_char), ...]

    # Build input: concatenate all valid [lead, trail] pairs
    payload = bytes(b for (trail, _) in valid for b in (lead, trail))
    expected = [ch for (_, ch) in valid]

    got_utf8 = _vx_decode(payload, vx_name)
    assert got_utf8 is not None, f"{vx_name}: vx failed for lead=0x{lead:02X}"

    got_chars = _utf8_chars_from(got_utf8)

    assert len(got_chars) == len(expected), (
        f"{vx_name} lead=0x{lead:02X}: got {len(got_chars)} chars, "
        f"expected {len(expected)} (one per valid pair)"
    )

    mismatches: list[str] = []
    for i, (trail, _) in enumerate(valid):
        got_n = _normalise(got_chars[i])
        exp_n = _normalise(expected[i])
        if got_n != exp_n:
            mismatches.append(
                f"  trail=0x{trail:02X}: got U+{ord(got_chars[i]):04X} "
                f"exp U+{ord(expected[i]):04X}"
            )

    assert not mismatches, (
        f"{vx_name} lead=0x{lead:02X} - {len(mismatches)} mismatch(es):\n"
        + "\n".join(mismatches[:20])
        + ("\n  ..." if len(mismatches) > 20 else "")
    )
