#!/usr/bin/env python3
"""
Strict integration tests for `vx` CLI transcoding flags.

Run after `zig build`:
    python3 tests/test_cli.py

Requirements: Python 3.8+, no external dependencies.
The `vx` binary is expected at `zig-out/bin/vx` relative to the repo root.
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# Locate the vx binary relative to this file's repo root.
REPO_ROOT = Path(__file__).resolve().parent.parent
VX = REPO_ROOT / "zig-out" / "bin" / "vx"


def vx(*args: str, stdin: bytes | None = None) -> subprocess.CompletedProcess:
    """Run `vx` with the given args, return CompletedProcess."""
    return subprocess.run(
        [str(VX), *args],
        input=stdin,
        capture_output=True,
    )


class TestCliTranscode(unittest.TestCase):
    """End-to-end tests for -e / --to / -o / -i batch transcoding."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def _path(self, name: str) -> str:
        return os.path.join(self.tmp, name)

    def _write(self, name: str, data: bytes) -> str:
        p = self._path(name)
        Path(p).write_bytes(data)
        return p

    # ── GBK → UTF-8 ───────────────────────────────────────────────────────────

    def test_gbk_to_utf8_file(self):
        """GBK-encoded file transcoded to UTF-8 via -e gbk -o out."""
        text = "你好世界"
        gbk_bytes = text.encode("gbk")
        src = self._write("hello.gbk", gbk_bytes)
        out = self._path("hello.utf8")

        r = vx("-e", "gbk", "--to", "utf-8", "-o", out, src)
        self.assertEqual(r.returncode, 0, r.stderr)
        result = Path(out).read_bytes().decode("utf-8")
        self.assertEqual(result, text)

    def test_gbk_to_utf8_stdout(self):
        """-o - streams transcoded bytes to stdout."""
        text = "中文测试"
        gbk_bytes = text.encode("gbk")
        src = self._write("text.gbk", gbk_bytes)

        r = vx("-e", "gbk", "--to", "utf-8", "-o", "-", src)
        self.assertEqual(r.returncode, 0, r.stderr)
        result = r.stdout.decode("utf-8")
        self.assertEqual(result, text)

    # ── UTF-8 → GBK ───────────────────────────────────────────────────────────

    def test_utf8_to_gbk_file(self):
        """UTF-8 source → GBK output round-trips correctly."""
        text = "北京上海"
        utf8_bytes = text.encode("utf-8")
        src = self._write("city.utf8", utf8_bytes)
        out = self._path("city.gbk")

        r = vx("--to", "gbk", "-o", out, src)
        self.assertEqual(r.returncode, 0, r.stderr)
        result = Path(out).read_bytes().decode("gbk")
        self.assertEqual(result, text)

    # ── Latin-1 → UTF-8 ───────────────────────────────────────────────────────

    def test_latin1_to_utf8(self):
        """Latin-1 high bytes (é, ñ, ü) convert correctly to UTF-8."""
        text = "café naïve résumé"
        latin1_bytes = text.encode("latin-1")
        src = self._write("latin.txt", latin1_bytes)
        out = self._path("latin.utf8")

        r = vx("-e", "latin-1", "--to", "utf-8", "-o", out, src)
        self.assertEqual(r.returncode, 0, r.stderr)
        result = Path(out).read_bytes().decode("utf-8")
        self.assertEqual(result, text)

    # ── CP1252 → UTF-8 ────────────────────────────────────────────────────────

    def test_cp1252_to_utf8(self):
        """Windows-1252 file (smart quotes, €) transcodes to UTF-8."""
        text = "\u201chello\u201d \u20ac"  # "hello" €
        cp1252_bytes = text.encode("cp1252")
        src = self._write("win.txt", cp1252_bytes)
        out = self._path("win.utf8")

        r = vx("-e", "cp1252", "--to", "utf-8", "-o", out, src)
        self.assertEqual(r.returncode, 0, r.stderr)
        result = Path(out).read_bytes().decode("utf-8")
        self.assertEqual(result, text)

    # ── Auto-detect ───────────────────────────────────────────────────────────

    def test_autodetect_utf8(self):
        """Without -e, UTF-8 files are detected and passed through unchanged."""
        text = "hello world 你好"
        utf8_bytes = text.encode("utf-8")
        src = self._write("auto.txt", utf8_bytes)
        out = self._path("auto.utf8")

        r = vx("--to", "utf-8", "-o", out, src)
        self.assertEqual(r.returncode, 0, r.stderr)
        result = Path(out).read_bytes().decode("utf-8")
        self.assertEqual(result, text)

    def test_autodetect_ascii(self):
        """Pure ASCII files are detected and passed through unchanged."""
        text = "plain ascii text\nnewline"
        src = self._write("ascii.txt", text.encode("ascii"))
        out = self._path("ascii.out")

        r = vx("-o", out, src)
        self.assertEqual(r.returncode, 0, r.stderr)
        result = Path(out).read_bytes().decode("ascii")
        self.assertEqual(result, text)

    # ── In-place (-i) ─────────────────────────────────────────────────────────

    def test_inplace_gbk_to_utf8(self):
        """In-place transcoding (-i) rewrites the file with target encoding."""
        text = "原文内容"
        gbk_bytes = text.encode("gbk")
        path = self._write("inplace.txt", gbk_bytes)

        r = vx("-e", "gbk", "--to", "utf-8", "-i", path)
        self.assertEqual(r.returncode, 0, r.stderr)
        result = Path(path).read_bytes().decode("utf-8")
        self.assertEqual(result, text)

    def test_inplace_multiple_files(self):
        """In-place mode processes multiple files independently."""
        words = ["北京", "上海", "广州"]
        paths = []
        for i, w in enumerate(words):
            p = self._write(f"city{i}.txt", w.encode("gbk"))
            paths.append(p)

        r = vx("-e", "gbk", "--to", "utf-8", "-i", *paths)
        self.assertEqual(r.returncode, 0, r.stderr)
        for p, expected in zip(paths, words):
            self.assertEqual(Path(p).read_bytes().decode("utf-8"), expected)

    # ── Round-trip ────────────────────────────────────────────────────────────

    def test_round_trip_gbk(self):
        """UTF-8 → GBK → UTF-8 produces identical text."""
        text = "测试数据 round trip"
        utf8_bytes = text.encode("utf-8")
        src = self._write("rt_src.utf8", utf8_bytes)
        gbk_tmp = self._path("rt.gbk")
        back = self._path("rt_back.utf8")

        r1 = vx("--to", "gbk", "-o", gbk_tmp, src)
        self.assertEqual(r1.returncode, 0, r1.stderr)
        r2 = vx("-e", "gbk", "--to", "utf-8", "-o", back, gbk_tmp)
        self.assertEqual(r2.returncode, 0, r2.stderr)
        self.assertEqual(Path(back).read_bytes(), utf8_bytes)

    # ── stdin support ─────────────────────────────────────────────────────────

    def test_stdin_gbk_to_utf8(self):
        """Input path '-' reads from stdin."""
        text = "标准输入"
        gbk_bytes = text.encode("gbk")
        out = self._path("stdin_out.utf8")

        r = vx("-e", "gbk", "--to", "utf-8", "-o", out, "-", stdin=gbk_bytes)
        self.assertEqual(r.returncode, 0, r.stderr)
        result = Path(out).read_bytes().decode("utf-8")
        self.assertEqual(result, text)

    # ── Error handling ────────────────────────────────────────────────────────

    def test_unknown_source_encoding(self):
        """Unknown -e name exits with non-zero code."""
        src = self._write("dummy.txt", b"hello")
        r = vx("-e", "totally_fake_encoding_xyz", "-o", "-", src)
        self.assertNotEqual(r.returncode, 0)

    def test_unknown_target_encoding(self):
        """Unknown --to / -t name exits with non-zero code."""
        src = self._write("dummy.txt", b"hello")
        r = vx("-t", "not_an_encoding", "-o", "-", src)
        self.assertNotEqual(r.returncode, 0)

    def test_inplace_no_files(self):
        """-i with no files exits with non-zero code."""
        r = vx("-i")
        self.assertNotEqual(r.returncode, 0)

    def test_inplace_and_output_exclusive(self):
        """-i and -o together exit with non-zero code."""
        src = self._write("dummy.txt", b"hello")
        out = self._path("out.txt")
        r = vx("-i", "-o", out, src)
        self.assertNotEqual(r.returncode, 0)

    def test_missing_arg_for_e(self):
        """-e without an argument exits with non-zero code."""
        r = vx("-e")
        self.assertNotEqual(r.returncode, 0)

    def test_unknown_flag(self):
        """Unknown flag exits with non-zero code."""
        r = vx("--not-a-real-flag")
        self.assertNotEqual(r.returncode, 0)

    # ── Long form aliases ──────────────────────────────────────────────────────

    def test_long_encoding_flag(self):
        """--encoding is equivalent to -e."""
        text = "你好"
        src = self._write("long_enc.gbk", text.encode("gbk"))
        out = self._path("long_enc.utf8")
        r = vx("--encoding", "gbk", "--output", out, src)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(Path(out).read_bytes().decode("utf-8"), text)

    def test_long_to_flag(self):
        """--to is equivalent to -t."""
        text = "测试"
        src = self._write("long_to.utf8", text.encode("utf-8"))
        out = self._path("long_to.gbk")
        r = vx("--to", "gbk", "--output", out, src)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(Path(out).read_bytes().decode("gbk"), text)

    def test_short_t_flag(self):
        """-t is equivalent to --to."""
        text = "北京"
        src = self._write("short_t.utf8", text.encode("utf-8"))
        out = self._path("short_t.gbk")
        r = vx("-t", "gbk", "-o", out, src)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(Path(out).read_bytes().decode("gbk"), text)

    def test_long_in_place_flag(self):
        """--in-place is equivalent to -i."""
        text = "上海"
        path = self._write("long_ip.txt", text.encode("gbk"))
        r = vx("--encoding", "gbk", "--to", "utf-8", "--in-place", path)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(Path(path).read_bytes().decode("utf-8"), text)

    # ── End-of-options (--) ────────────────────────────────────────────────────

    def test_double_dash_end_of_opts(self):
        """-- stops option parsing; subsequent -lookalike names are treated as files."""
        # Create a file whose name starts with '-'
        text = "content"
        dash_name = self._path("-myfile.txt")
        Path(dash_name).write_bytes(text.encode("utf-8"))
        out = self._path("dashdash_out.txt")
        r = vx("--to", "utf-8", "-o", out, "--", dash_name)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(Path(out).read_bytes().decode("utf-8"), text)

    def test_double_dash_mixed(self):
        """Options before -- are parsed; args after -- are positional."""
        text = "广州"
        src = self._write("dd_src.txt", text.encode("gbk"))
        out = self._path("dd_out.txt")
        r = vx("-e", "gbk", "-o", out, "--", src)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(Path(out).read_bytes().decode("utf-8"), text)

    # ── ASCII passthrough ─────────────────────────────────────────────────────

    def test_ascii_no_encoding_loss(self):
        """ASCII-only content survives GBK→UTF-8 and UTF-8→GBK unchanged."""
        text = "Hello, World! 123\n"
        ascii_bytes = text.encode("ascii")
        src = self._write("ascii_gbk.txt", ascii_bytes)
        out = self._path("ascii_out.txt")

        r = vx("-e", "gbk", "-t", "utf-8", "-o", out, src)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(Path(out).read_bytes(), ascii_bytes)


if __name__ == "__main__":
    if not VX.exists():
        print(f"ERROR: vx binary not found at {VX}")
        print("Run `zig build` first.")
        sys.exit(1)
    unittest.main(verbosity=2)
