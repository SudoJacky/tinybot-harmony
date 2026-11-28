"""Check which PTY input changes the shell's editing state (Linux or WSL)."""
import itertools
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


if __name__ == "__main__":
    unittest.main()
