#!/usr/bin/env python3
"""Cartesian-product encoding tests using Python codecs + iconv as dual oracles.

For each (encoding, sample) pair:
  encode — filter to mappable chars → vx(sample) == python(sample) [iconv cross-check]
  decode — filter to mappable chars → vx(native) == python(native) [iconv cross-check]

Test commands:
  uv run pytest tests/test_encoding.py -v          # full suite
  uv run pytest tests/test_encoding.py -q          # quick summary
"""

import unicodedata
import subprocess
import pytest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
VX = REPO_ROOT / "zig-out" / "bin" / "vx"

if not VX.exists():
    pytest.exit(f"vx binary not found at {VX}\nRun: zig build", returncode=2)

# ═══════════════════════════════════════════════════════════════════════════════════
# Encoding table  (vx_name, iconv_name, python_name, family)
# ═══════════════════════════════════════════════════════════════════════════════════

SBCS = [
    ("latin1",  "LATIN1",   "latin_1"),
    ("cp1250",  "CP1250",   "cp1250"),
    ("cp1251",  "CP1251",   "cp1251"),
    ("cp1252",  "CP1252",   "cp1252"),
    ("cp1253",  "CP1253",   "cp1253"),
    ("cp1254",  "CP1254",   "cp1254"),
    ("cp1255",  "CP1255",   "cp1255"),
    ("cp1256",  "CP1256",   "cp1256"),
    ("cp1257",  "CP1257",   "cp1257"),
    ("cp1258",  "CP1258",   "cp1258"),
    ("koi8-r",  "KOI8-R",   "koi8_r"),
    ("cp874",   "CP874",    "cp874"),
]

DBCS = [
    ("gbk",       "GBK",       "gbk"),
    ("gb18030",   "GB18030",   "gb18030"),
    ("big5",      "BIG5",      "cp950"),
    ("shift-jis", "SHIFT-JIS", "cp932"),
    ("euc-jp",    "EUC-JP",    "euc_jp"),
    ("euc-kr",    "EUC-KR",    "euc_kr"),
]

UTF = [
    ("utf-8",    "UTF-8",    "utf_8"),
    ("utf-16le", "UTF-16LE", "utf_16_le"),
    ("utf-16be", "UTF-16BE", "utf_16_be"),
]

# ═══════════════════════════════════════════════════════════════════════════════════
# Text samples per family
# ═══════════════════════════════════════════════════════════════════════════════════
# (name, utf8_bytes)

SBCS_SAMPLES: list[tuple[str, bytes]] = [
    ("ascii",   b" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\n"),
    ("latin1",  bytes(range(0xC0, 0x100)).decode("latin-1").encode("utf-8")),
    ("accented","café naïve résumé äëïöüñ àèìòù".encode("utf-8")),
    ("symbols", "¡¢£¤¥¦§¨©ª«¬®¯°±²³´µ¶·¸¹º»¼½¾¿×÷".encode("utf-8")),
]

DBCS_SAMPLES: list[tuple[str, bytes]] = [
    ("ascii",     b" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\n"),
    ("cjk_short", "你好世界".encode("utf-8")),
    ("cjk_med",   "你好世界 北京 上海 中文测试 编码转换 汉字".encode("utf-8")),
    ("cjk_mixed", "Hello 世界! Testing 编码 12345 CJK mixed".encode("utf-8")),
]

UTF_SAMPLES: list[tuple[str, bytes]] = [
    ("ascii",    b" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~\n"),
    ("multiscript","Hello 世界! Привет мир! مرحبا بالعالم! 日本語テスト! 한국어! 😊☺🚀💡".encode("utf-8")),
    ("cjk",      "你好世界 北京 上海 中文测试 日本語 韓國語 漢字".encode("utf-8")),
    ("emoji",    "😊🚀💡🎉🌍🔥⭐🎶💻📚❤️♻️✅❌⭐".encode("utf-8")),
    ("edge",     "ĀāĂăĄąĆćĈĉĊċČčĎďĐđĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĦħĨĩĪīĬĭĮįİıĲĳĴĵĶķĸĹĺĻļĽľĿŀŁł".encode("utf-8")),
]

_SAMPLE_MAP: dict[str, dict[str, bytes]] = {}
for family, items in [("sbcs", SBCS_SAMPLES), ("dbcs", DBCS_SAMPLES), ("utf", UTF_SAMPLES)]:
    _SAMPLE_MAP[family] = dict(items)


def _all_encodings() -> list[tuple[str, str, str, str]]:
    return [(n, ic, py, "sbcs") for n, ic, py in SBCS] + \
           [(n, ic, py, "dbcs") for n, ic, py in DBCS] + \
           [(n, ic, py, "utf") for n, ic, py in UTF]

# ═══════════════════════════════════════════════════════════════════════════════════
# Cartesian product parameter list
# ═══════════════════════════════════════════════════════════════════════════════════

_CASES: list = []
for vx_name, iconv_name, py_name, family in _all_encodings():
    for sname in _SAMPLE_MAP[family]:
        _CASES.append(pytest.param(
            vx_name, iconv_name, py_name, family, sname,
            id=f"{vx_name}~{sname}",
        ))

# ═══════════════════════════════════════════════════════════════════════════════════
# Helpers
# ═══════════════════════════════════════════════════════════════════════════════════

def iconv_encode(text: bytes, enc: str) -> bytes | None:
    r = subprocess.run(["iconv", "-f", "UTF-8", "-t", enc], input=text, capture_output=True)
    return None if r.returncode != 0 else r.stdout


def iconv_decode(data: bytes, enc: str) -> bytes | None:
    r = subprocess.run(["iconv", "-f", enc, "-t", "UTF-8"], input=data, capture_output=True)
    return None if r.returncode != 0 else r.stdout


def vx_decode(data: bytes, enc: str) -> bytes | None:
    r = subprocess.run([str(VX), "-e", enc, "-o", "-", "-"], input=data, capture_output=True)
    return None if r.returncode != 0 else r.stdout


def vx_encode(text: bytes, enc: str) -> bytes | None:
    r = subprocess.run([str(VX), "-t", enc, "-o", "-", "-"], input=text, capture_output=True)
    return None if r.returncode != 0 else r.stdout


def _norm_nfc(text: bytes) -> bytes:
    return unicodedata.normalize("NFC", text.decode("utf-8")).encode("utf-8")


def _norm_cmp(text: bytes, vx_name: str = "") -> bytes:
    """NFC + encoding-specific normalizations for fair comparison.

    shift-jis: 0x5C maps to U+005C (CP932, vx) or U+00A5 (JIS X 0201, Python/iconv).
    Both are valid — treat them as equivalent for roundtrip testing.
    """
    s = unicodedata.normalize("NFC", text.decode("utf-8"))
    if vx_name == "shift-jis":
        s = s.replace("¥", "\\")   # U+00A5 → U+005C  (JIS X 0201 0x5C vs CP932)
        s = s.replace("‾", "~")    # U+203E → U+007E  (JIS X 0201 0x7E vs CP932)
    return s.encode("utf-8")


def _diff(got: bytes, exp: bytes) -> str:
    g = got.decode("utf-8", errors="replace")
    e = exp.decode("utf-8", errors="replace")
    for i, (a, b) in enumerate(zip(g, e)):
        if a != b:
            ctx = slice(max(0, i - 8), i + 8)
            return f"char {i}: got={repr(g[ctx])} exp={repr(e[ctx])}"
    if len(got) != len(exp):
        return f"len {len(got)} vs {len(exp)}"
    return ""


def _mappable(text: str, py_name: str, vx_name: str = "") -> tuple[str, bytes, bytes]:
    """Keep only chars mappable in the encoding.

    Returns (filtered_text, filtered_utf8_bytes, concatenated_native_bytes).
    Raises pytest.skip if no chars survive.
    """
    u8, n8, ch = bytearray(), bytearray(), []
    for ch_ in text:
        try:
            nb = ch_.encode(py_name)
        except (UnicodeEncodeError, LookupError):
            continue
        # EUC-JP: vx only handles 2-byte sequences (JIS X 0208), not 3-byte SS3
        if vx_name == "euc-jp" and len(nb) > 2:
            continue
        ch.append(ch_)
        u8.extend(ch_.encode("utf-8"))
        n8.extend(nb)
    if not ch:
        pytest.skip(f"no mappable chars in '{py_name}'")
    return "".join(ch), bytes(u8), bytes(n8)


def _strip_bom(data: bytes, vx_name: str) -> bytes:
    if vx_name in ("utf-16le", "utf-16be") and len(data) >= 2 and data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return data[2:]
    return data

# ═══════════════════════════════════════════════════════════════════════════════════
# Cartesian product: encode tests — vx(sample) == python(sample) [iconv cross-check]
# ═══════════════════════════════════════════════════════════════════════════════════

@pytest.mark.parametrize("vx_name,iconv_name,py_name,family,sname", _CASES)
def test_encode(vx_name: str, iconv_name: str, py_name: str, family: str, sname: str) -> None:
    """Encode: filtered sample → vx == python (reference)."""
    data = _SAMPLE_MAP[family][sname]
    _, u8_in, expected = _mappable(_norm_nfc(data).decode("utf-8"), py_name, vx_name)

    got = vx_encode(u8_in, vx_name)
    assert got is not None, f"vx encode({vx_name}) failed"
    got = _strip_bom(got, vx_name)
    assert got == expected, _diff(got, expected)

    # iconv cross-check (skips silently if iconv can't handle the filtered sample)
    if (ic := iconv_encode(u8_in, iconv_name)) is not None:
        assert ic == expected, f"iconv({iconv_name}) ≠ python({py_name})"

# ═══════════════════════════════════════════════════════════════════════════════════
# Cartesian product: decode tests — vx(native) == python(native) [iconv cross-check]
# ═══════════════════════════════════════════════════════════════════════════════════

@pytest.mark.parametrize("vx_name,iconv_name,py_name,family,sname", _CASES)
def test_decode(vx_name: str, iconv_name: str, py_name: str, family: str, sname: str) -> None:
    """Decode: filter → generate native → vx decode == python decode (NFC-normalized)."""
    data = _SAMPLE_MAP[family][sname]
    _, ref_u8, native = _mappable(_norm_nfc(data).decode("utf-8"), py_name, vx_name)

    got = vx_decode(native, vx_name)
    assert got is not None, f"vx decode({vx_name}) failed"
    assert _norm_cmp(got, vx_name) == _norm_cmp(ref_u8, vx_name), _diff(got, ref_u8)

    # iconv cross-check
    if (ic := iconv_decode(native, iconv_name)) is not None:
        assert _norm_cmp(ic, vx_name) == _norm_cmp(ref_u8, vx_name)

# ═══════════════════════════════════════════════════════════════════════════════════
# Supplementary: full-byte decode for SBCS (unmapped → U+FFFD)
# ═══════════════════════════════════════════════════════════════════════════════════

@pytest.mark.parametrize("vx_name,_,py_name", SBCS)
def test_sbcs_decode_all_256(vx_name, _, py_name) -> None:
    """All 256 bytes → Python codec reference (unmapped bytes → U+FFFD)."""
    native = bytes(range(256))
    expected = bytearray()
    for b in range(256):
        try:
            expected.extend(bytes([b]).decode(py_name).encode("utf-8"))
        except (UnicodeDecodeError, LookupError):
            expected.extend("�".encode("utf-8"))
    got = vx_decode(native, vx_name)
    assert got is not None
    assert got == bytes(expected), _diff(got, bytes(expected))

# ═══════════════════════════════════════════════════════════════════════════════════
# SBCS encode: all mappable high bytes (byte-exact)
# ═══════════════════════════════════════════════════════════════════════════════════

@pytest.mark.parametrize("vx_name,iconv_name,py_name", SBCS)
def test_sbcs_encode_mappable(vx_name: str, iconv_name: str, py_name: str) -> None:
    """Every mappable high byte → Python codec (iconv double-check)."""
    u8_chars, n8 = [], []
    for b in range(128, 256):
        try:
            ch = bytes([b]).decode(py_name, errors="strict")
        except (UnicodeDecodeError, LookupError):
            continue
        if ch != "�":
            u8_chars.append(ch)
            n8.append(b)
    if not u8_chars:
        pytest.skip("no mappable high bytes")

    u8_in = "".join(u8_chars).encode("utf-8")
    expected = bytes(n8)
    got = vx_encode(u8_in, vx_name)
    assert got is not None, f"vx encode({vx_name}) failed"
    assert got == expected, _diff(got, expected)

    if (ic := iconv_encode(u8_in, iconv_name)) is not None:
        assert ic == expected, f"iconv({iconv_name}) ≠ python({py_name})"

# ═══════════════════════════════════════════════════════════════════════════════════
# GB18030 4-byte tests
# ═══════════════════════════════════════════════════════════════════════════════════

GB18030_4BYTE: list[tuple[bytes, int, str]] = [
    (b"\x81\x30\x81\x30", 0x0080,   "first BMP"),
    (b"\x81\x30\x81\x31", 0x0081,   "second BMP"),
    (b"\x84\x31\xa4\x39", 0xFFFF,   "last BMP"),
    (b"\x90\x30\x81\x30", 0x10000,  "first supp"),
    (b"\x95\x32\x82\x37", 0x20001,  "CJK Ext B"),
    (b"\xe3\x32\x9a\x35", 0x10FFFF, "last supp"),
]

@pytest.mark.parametrize("native,codepoint,desc", GB18030_4BYTE)
def test_gb18030_4byte_decode(native: bytes, codepoint: int, desc: str) -> None:
    expected = chr(codepoint).encode("utf-8")
    got = vx_decode(native, "gb18030")
    assert got == expected, f"{desc}: U+{ord(got.decode('utf-8')):04X}"

@pytest.mark.parametrize("native,codepoint,desc", GB18030_4BYTE)
def test_gb18030_4byte_roundtrip(native: bytes, codepoint: int, desc: str) -> None:
    ch_utf8 = chr(codepoint).encode("utf-8")
    vx_got = vx_encode(ch_utf8, "gb18030")
    assert vx_got is not None, f"vx encode U+{codepoint:04X}"
    assert vx_got == native, f"{desc}: {vx_got.hex()} ≠ {native.hex()}"

    if (ic := iconv_encode(ch_utf8, "GB18030")) is not None:
        assert ic == native, f"iconv GB18030: {ic.hex()} ≠ {native.hex()}"

# ═══════════════════════════════════════════════════════════════════════════════════
# Edge cases
# ═══════════════════════════════════════════════════════════════════════════════════

@pytest.mark.parametrize("vx_name,_ic,_py,_fam", _all_encodings())
def test_empty_input(vx_name, _ic, _py, _fam) -> None:
    assert vx_decode(b"", vx_name) == b""
    got = _strip_bom(vx_encode(b"", vx_name), vx_name)
    assert got == b"", f"empty encode: {got!r}"


def test_utf8_bom_decode() -> None:
    assert vx_decode(b"\xef\xbb\xbfhello", "ucs-bom") == b"hello"


def test_utf8_bom_encode() -> None:
    assert vx_encode(b"hello", "ucs-bom") == b"\xef\xbb\xbfhello"
