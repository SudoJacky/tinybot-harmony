"""Run one unprivileged Linux job and stream its optional directory snapshots."""
import binascii
import os
import resource
import select
import signal
import stat
import struct
import subprocess
import sys

if __name__ == "__main__":
    sys.path.insert(0, "/")  # Allow direct isolated invocation on the guest.

from linux_protocol import CapturedOutput, HALF, load_request, pending_bytes, read_exact, store_result, write_all

TREE_OFFSET = 2 * HALF
FILE_LIMIT = 1024 * 1024
CHUNK = 1024 * 1024
GUEST_USER = 65534
ENTRY = struct.Struct("<IBQ")


def safe_parts(path):
    parts = path.split("/")
    if (len(path.encode()) >= 4096 or
            any(not part or part in (".", "..") or "\\" in part or
                any(ord(char) < 32 or ord(char) == 127 for char in part) for part in parts)):
        raise ValueError("invalid sandbox directory path")
    return parts


def copy_exact(source, destination, size):
    while size > 0:
        data = source.read(min(CHUNK, size))
        if not data:
            raise ValueError("truncated Linux file")
        write_all(destination, data)
        size -= len(data)


def restore_tree(stream, size, root, writable):
    def owned(path, mode):
        os.chmod(path, mode)
        if writable:
            os.chown(path, GUEST_USER, GUEST_USER)

    os.mkdir(root)
    owned(root, 0o700 if writable else 0o555)
    remaining = size
    while remaining:
        if remaining < ENTRY.size:
            raise ValueError("invalid Linux directory record")
        path_size, kind, file_size = ENTRY.unpack(read_exact(stream, ENTRY.size))
        remaining -= ENTRY.size
        if not 0 < path_size < 4096 or path_size + file_size > remaining:
            raise ValueError("invalid Linux directory record size")
        path = os.path.join(root, *safe_parts(read_exact(stream, path_size).decode("utf-8")))
        if kind == 0 and file_size == 0:
            os.mkdir(path)
            owned(path, 0o700 if writable else 0o555)
        elif kind == 1:
            with open(path, "xb", buffering=0) as file:
                copy_exact(stream, file, file_size)
            owned(path, 0o600 if writable else 0o444)
        else:
            raise ValueError("invalid Linux directory entry type")
        remaining -= path_size + file_size


def collect_tree(root, stream):
    def record(path, kind, size):
        safe_parts(path)
        encoded = path.encode("utf-8")
        write_all(stream, ENTRY.pack(len(encoded), kind, size))
        write_all(stream, encoded)

    def walk(parent, prefix):
        with os.scandir(parent) as children:
            for child in children:
                path = prefix + child.name
                if child.is_dir(follow_symlinks=False):
                    fd = os.open(child.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                    try:
                        record(path, 0, 0)
                        walk(fd, path + "/")
                    finally:
                        os.close(fd)
                elif child.is_file(follow_symlinks=False):
                    fd = os.open(child.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                    with os.fdopen(fd, "rb", buffering=0) as file:
                        info = os.fstat(fd)
                        if not stat.S_ISREG(info.st_mode):
                            raise ValueError("project directory contains a non-regular file")
                        record(path, 1, info.st_size)
                        copy_exact(file, stream, info.st_size)
                        if file.read(1):
                            raise ValueError("a project file changed while being read")
                else:
                    raise ValueError("project directory accepts regular files and directories only")

    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        start = stream.tell()
        walk(fd, "")
        return stream.tell() - start
    finally:
        os.close(fd)


def prepare_workspace(on_disk):
    if on_disk:
        subprocess.run(["/sbin/mke2fs", "-t", "ext4", "-q", "-F", "-m", "0",
                        "-O", "^has_journal", "-E", "lazy_itable_init=1,nodiscard", "/dev/vdc"], check=True)
        subprocess.run(["/bin/busybox", "mount", "-t", "ext4", "-o", "nosuid,nodev", "/dev/vdc", "/work"], check=True)
    else:
        subprocess.run(["/bin/busybox", "mount", "-t", "tmpfs", "-o", "size=24m,nosuid,nodev", "tmpfs", "/work"], check=True)
    os.chmod("/work", 0o1777)


def drop_privileges():
    os.setgroups([])
    os.setgid(GUEST_USER)
    os.setuid(GUEST_USER)
    resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))


def run_captured(program, env):
    capture = CapturedOutput()
    with subprocess.Popen(program, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env=env, preexec_fn=drop_privileges, start_new_session=True) as process:
        pipes = {process.stdout.fileno(): "stdout", process.stderr.fileno(): "stderr"}
        try:
            done = os.pidfd_open(process.pid)
            try:
                while True:
                    ready, _, _ = select.select([done, *pipes], [], [])
                    if done in ready:
                        break
                    for fd in ready:
                        data = os.read(fd, 65536)
                        if data:
                            capture.append(pipes[fd], data)
                        else:
                            del pipes[fd]
            finally:
                os.close(done)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        # A detached writer must not hold the receipt open after the command exits.
        for fd, name in pipes.items():
            remaining = pending_bytes(fd)
            while remaining:
                data = os.read(fd, remaining)
                capture.append(name, data)
                remaining -= len(data)
        return capture.receipt(process.wait())


def run_job(request, disk):
    program = {"shell": ["/bin/sh"], "python": ["/usr/bin/python3", "-B"]}[request["language"]]
    project = request.get("projectBytes")
    mounts = request.get("mountBytes")
    for length in (project, mounts):
        if length is not None and (type(length) is not int or length < 0):
            raise ValueError("invalid Linux directory stream length")
    if TREE_OFFSET + (project or 0) + (mounts or 0) > disk.seek(0, os.SEEK_END):
        raise ValueError("Linux directory stream exceeds the exchange disk")
    prepare_workspace(project is not None or mounts is not None)
    os.chdir("/work")
    env = {"PATH": "/usr/bin:/bin", "HOME": "/work", "TMPDIR": "/work", "LANG": "C.UTF-8"}
    disk.seek(TREE_OFFSET)
    if project is not None:
        restore_tree(disk, project, "project", writable=True)
        env["TINYBOT_PROJECT_DIR"] = "/work/project"
    if mounts is not None:
        restore_tree(disk, mounts, "mounts", writable=False)
        env["TINYBOT_MOUNTS_DIR"] = "/work/mounts"
    with open("task", "x", encoding="utf-8") as script:
        script.write(request["source"])
    if "input" in request:
        with open("input", "xb") as target:
            target.write(binascii.a2b_base64(request["input"], strict_mode=True))
    receipt = run_captured(program + ["task"], env)
    exit_code = receipt["exitCode"]
    if exit_code == 0 and request.get("collect"):
        fd = os.open("output", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as output:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise ValueError("output must be a regular file")
            data = output.read(FILE_LIMIT + 1)
            if len(data) > FILE_LIMIT:
                raise ValueError("output exceeds 1 MiB")
            receipt["artifact"] = binascii.b2a_base64(data, newline=False).decode("ascii")
    if exit_code == 0 and project is not None:
        disk.seek(TREE_OFFSET)
        receipt["projectBytes"] = collect_tree("project", disk)
    return receipt


def main():
    subprocess.run(["/bin/busybox", "mount", "--make-rprivate", "/"], check=True)
    subprocess.run(["/bin/busybox", "mount", "-t", "proc", "proc", "/proc"], check=True)
    with open("/dev/vdb", "r+b", buffering=0) as disk:
        try:
            result = run_job(load_request(disk), disk)
        except Exception as error:
            result = {"error": str(error)}
        store_result(disk, result)


if __name__ == "__main__":
    main()
