"""Source an assistant command in the foreground terminal shell."""
import os
import signal
import tempfile
import time
from pathlib import Path
from linux_job import LOG_LIMIT, load_request, store_result

SHELL_OWNER_ID = 65533  # VM-side UID and GID of the terminal namespace’s root.


def process_parents():
    parents = {}
    for proc in Path("/proc").iterdir():
        if proc.name.isdigit():
            try:
                # A shell command can change its UID inside the user namespace.
                # Use parentage to identify descendants across those changes.
                info = (proc / "stat").read_bytes().rsplit(b")", 1)[1].split()
                parents[int(proc.name)] = int(info[1])
            except (FileNotFoundError, ProcessLookupError):
                pass
    return parents


class ShellTask:
    def __init__(self):
        with open("/dev/vdb", "rb", buffering=0) as disk:
            request = load_request(disk)
        self.previous = set(process_parents())
        self.cancelled_at = None
        # Init owns the directory. A background child can keep its old file
        # descriptor without ever writing a later command's result.
        self.files = tempfile.TemporaryDirectory(prefix="cmd-", dir="/run/tinybot")
        self.root = Path(self.files.name)
        self.root.chmod(0o755)
        (self.root / "source").write_text(request["source"], encoding="utf-8")
        for name in ("stdout", "stderr", "status"):
            file = self.root / name
            file.touch(mode=0o600)
            os.chown(file, SHELL_OWNER_ID, SHELL_OWNER_ID)
        program = "." if request["language"] == "shell" else "/usr/bin/python3 -B"
        (self.root / "run").write_text(
            f"{program} {self.root}/source </dev/null >{self.root}/stdout 2>{self.root}/stderr\n"
            f"command echo $? >{self.root}/status\n", encoding="ascii")
        self.command = f". {self.root}/run\r".encode("ascii")

    def stop(self, shell):
        self.cancelled_at = time.monotonic()
        parents = process_parents()
        for pid in parents.keys() - self.previous:
            ancestor = parents[pid]
            while ancestor in parents and ancestor not in self.previous:
                ancestor = parents[ancestor]
            if ancestor != shell:
                continue
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        os.kill(shell, signal.SIGINT)

    def result(self, shell_exit=None):
        with (self.root / "status").open("rb") as file:
            status = file.read(16).strip()
        if shell_exit is None and not status:
            return False
        code = shell_exit if shell_exit is not None else int(status)
        result = {"exitCode": code, "truncated": False}
        for name in ("stdout", "stderr"):
            with (self.root / name).open("rb") as stream:
                data = stream.read(LOG_LIMIT + 1)
            result[name] = data[:LOG_LIMIT].decode("utf-8", "replace")
            result["truncated"] |= len(data) > LOG_LIMIT
        with open("/dev/vdb", "r+b", buffering=0) as disk:
            store_result(disk, result)
        self.files.cleanup()
        return result
