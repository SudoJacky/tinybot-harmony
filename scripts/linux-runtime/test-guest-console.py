"""Exercise terminal input and bounded pipe capture on Linux or WSL."""
import itertools
import os
from pathlib import Path
import re
import runpy
import unittest


last_input_key = runpy.run_path(str(Path(__file__).with_name("guest-console.py")))["last_input_key"]


class ConsoleInputTest(unittest.TestCase):
    def test_cursor_replies_mixed_with_edits(self):
        report = re.compile(rb"\x1b\[\d+;\d+R")
        pieces = (b"abc", b"\0", b"\r", b"\x03", b"R", b"\x1b[24;80R",
                  b"\x1b[1;xR", b"\x1b[", b"1;2R")
        for count in range(4):
            for parts in itertools.product(pieces, repeat=count):
                data = b"".join(parts)
                keys = report.sub(b"", data)
                self.assertEqual(last_input_key(data), keys[-1] if keys else None, data)


class CaptureTest(unittest.TestCase):
    def test_discard_preserves_exact_limit_and_eof(self):
        protocol = runpy.run_path(str(Path(__file__).with_name("guest-protocol.py")))
        limit = protocol["LOG_LIMIT"]
        for extra in (b"", b"x"):
            read_fd, write_fd = os.pipe()
            with (os.fdopen(read_fd, "rb", buffering=0) as reader,
                  os.fdopen(write_fd, "wb", buffering=0) as writer,
                  open(os.devnull, "wb", buffering=0) as discard):
                capture = protocol["CapturedOutput"](discard.fileno())
                for _ in range(limit // 1024):
                    writer.write(b"a" * 1024)
                    self.assertEqual(capture.drain(reader.fileno(), "stdout"), (1024, b"a" * 1024))
                writer.write(extra)
                writer.close()
                self.assertEqual(capture.drain(reader.fileno(), "stdout"), (len(extra), b""))
                self.assertEqual(capture.drain(reader.fileno(), "stdout"), (0, b""))
                self.assertEqual(capture.receipt(0), {
                    "exitCode": 0, "stdout": "a" * limit, "stderr": "", "truncated": bool(extra)})


if __name__ == "__main__":
    unittest.main()
