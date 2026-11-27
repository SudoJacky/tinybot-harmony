"""Expose one unprivileged shell on the private QEMU serial connection."""
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import termios
import tty

HEADER = struct.Struct("<BH")
SIZE = struct.Struct("<HH")
WINDOW = struct.Struct("HHHH")
INPUT = 1
RESIZE = 2
CHUNK = 16384
QUEUE = 256 * 1024


def handle_frames(pending, output, resize):
    while len(pending) >= HEADER.size:
        kind, size = HEADER.unpack_from(pending)
        if kind == INPUT and 0 < size <= CHUNK:
            pass
        elif kind != RESIZE or size != SIZE.size:
            raise ValueError("invalid Linux console frame")
        end = HEADER.size + size
        if len(pending) < end:
            return
        if kind == INPUT:
            output.extend(pending[HEADER.size:end])
        else:
            columns, rows = SIZE.unpack_from(pending, HEADER.size)
            if not 2 <= columns <= 500 or not 2 <= rows <= 300:
                raise ValueError("invalid Linux console dimensions")
            resize(columns, rows)
        del pending[:end]


def shell(serial):
    os.close(serial)
    os.chdir("/work")
    os.setgroups([])
    os.setgid(65534)
    os.setuid(65534)
    os.execve("/bin/sh", ["sh", "-i"], {
        "PATH": "/usr/bin:/bin", "HOME": "/work", "TMPDIR": "/work",
        "TERM": "xterm-256color", "LANG": "C.UTF-8", "PS1": "\\w $ ",
    })


def relay(serial, master, pid):
    frames = bytearray()
    to_shell = bytearray()
    to_host = bytearray(b"TBC1")
    shell_closed = False
    shell_exited = False

    def resize(columns, rows):
        fcntl.ioctl(master, termios.TIOCSWINSZ, WINDOW.pack(rows, columns, 0, 0))

    while not shell_closed or to_host:
        reads = []
        writes = []
        if not shell_closed:
            if len(to_shell) < QUEUE:
                reads.append(serial)
            if len(to_host) < QUEUE:
                reads.append(master)
            if to_shell:
                writes.append(master)
        if to_host:
            writes.append(serial)
        readable, writable, _ = select.select(reads, writes, [], 0.1)
        if not shell_closed and not shell_exited:
            shell_exited = os.waitpid(pid, os.WNOHANG)[0] == pid
        if shell_exited and master in reads and master not in readable:
            shell_closed = True
        for fd in writable:
            target = to_host if fd == serial else to_shell
            try:
                del target[:os.write(fd, target)]
            except BlockingIOError:
                pass
            except OSError as error:
                if fd != master or error.errno != errno.EIO:
                    raise
                shell_closed = True
        for fd in readable:
            try:
                data = os.read(fd, CHUNK)
            except BlockingIOError:
                continue
            except OSError as error:
                if fd != master or error.errno != errno.EIO:
                    raise
                data = b""
            if fd == master:
                to_host.extend(data)
                shell_closed = not data
            elif not data:
                return
            elif not shell_closed:
                frames.extend(data)
                handle_frames(frames, to_shell, resize)


def main():
    serial = os.open("/dev/ttyAMA0", os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        tty.setraw(serial)
        pid, master = pty.fork()
        if pid == 0:
            try:
                shell(serial)
            finally:
                os._exit(127)
        try:
            os.set_blocking(master, False)
            fcntl.ioctl(master, termios.TIOCSWINSZ, WINDOW.pack(24, 80, 0, 0))
            relay(serial, master, pid)
        finally:
            os.close(master)
            try:
                os.killpg(pid, signal.SIGHUP)
            except ProcessLookupError:
                pass
    finally:
        os.close(serial)


if __name__ == "__main__":
    main()
