"""Source an assistant command in the foreground terminal shell."""
import os
import time
from contextlib import ExitStack, contextmanager
from linux_protocol import CapturedOutput, LOG_LIMIT, load_request, pending_bytes, store_result

SHELL_OWNER_ID = 65533  # VM-side UID and GID of the terminal namespace’s root.


def process_parents():
    parents = {}
    for pid in os.listdir("/proc"):
        if pid.isdigit():
            try:
                # A shell command can change its UID inside the user namespace.
                # Use parentage to identify descendants across those changes.
                with open(f"/proc/{pid}/stat", "rb") as stat_file:
                    info = stat_file.read().rsplit(b")", 1)[1].split()
                parents[int(pid)] = int(info[1])
            except (FileNotFoundError, ProcessLookupError):
                pass
    return parents


@contextmanager
def command_directory():
    # Only init can create entries here. Each command gets its own FIFO inodes,
    # including when a background process still holds a previous writer.
    directory = "/run/tinybot/cmd-" + os.urandom(12).hex()
    os.mkdir(directory, 0o755)
    try:
        yield directory
    finally:
        for name in os.listdir(directory):
            os.unlink(f"{directory}/{name}")
        os.rmdir(directory)


class ShellTask:
    def __init__(self):
        with open("/dev/vdb", "rb", buffering=0) as disk:
            request = load_request(disk)
        # Only cancellation needs parentage. At submission a PID snapshot is enough.
        self.previous = {int(pid) for pid in os.listdir("/proc") if pid.isdigit()}
        self.cancelled_at = None
        self.pipes = {}
        self.capture = CapturedOutput()
        with ExitStack() as files:
            root = files.enter_context(command_directory())
            with open(f"{root}/source", "x", encoding="utf-8") as source:
                source.write(request["source"])
            for name in ("stdout", "stderr", "status"):
                path = f"{root}/{name}"
                os.mkfifo(path, 0o600)
                os.chown(path, SHELL_OWNER_ID, SHELL_OWNER_ID)
                # Keep a writer open locally so select does not spin on EOF
                # between accepting the command and ash opening its redirects.
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                files.callback(os.close, fd)
                hold = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
                files.callback(os.close, hold)
                if name == "status":
                    self.status_fd = fd
                else:
                    self.pipes[fd] = name
            program = "." if request["language"] == "shell" else "/usr/bin/python3 -u -B"
            with open(f"{root}/run", "x", encoding="ascii") as script:
                script.write(f"{program} {root}/source </dev/null >{root}/stdout 2>{root}/stderr\n"
                             f"command echo $? >{root}/status\n")
            self.command = f". {root}/run\r".encode("ascii")
            self.files = files.pop_all()

    def drain(self, fd, output, limit=65536):
        data = os.read(fd, limit)
        sample = self.capture.append(self.pipes[fd], data)
        if sample:
            output(sample.replace(b"\n", b"\r\n"))
        return len(data)

    def close(self, background):
        # A background command may still own its redirected stdout after the
        # foreground receipt. Drain it to EOF without blocking the next command
        # or delivering SIGPIPE to that command's descendants.
        try:
            for fd in self.pipes:
                background.add(os.dup(fd))
        finally:
            self.files.close()

    def stop(self, shell):
        import signal

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

    def result(self, output, shell_exit=None):
        code = shell_exit
        if code is None:
            try:
                # ash writes the short status line atomically before its prompt.
                code = int(os.read(self.status_fd, 16))
            except BlockingIOError:
                return False
        # Collect bytes already written when the command finished. A detached
        # descendant can keep a writer open indefinitely, so do not wait for EOF.
        for fd in self.pipes:
            pending = pending_bytes(fd)
            while pending:
                pending -= self.drain(fd, output, pending)
        result = self.capture.receipt(code)
        if self.capture.truncated:
            output(f"\r\n[Tinybot: output limited to {LOG_LIMIT // 1024} KiB per stream]\r\n".encode())
        with open("/dev/vdb", "r+b", buffering=0) as disk:
            store_result(disk, result)
        return result
