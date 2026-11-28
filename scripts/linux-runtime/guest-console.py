"""Expose the sandbox root shell on the private QEMU serial connection."""
import errno
import fcntl
import os
import select
import struct
import sys
import time
import termios
import tty

HEADER = struct.Struct("<BH")
SIZE = struct.Struct("<HH")
WINDOW = struct.Struct("HHHH")
RUN_SHELL = 5
RUN_JOB = 3
CANCEL_JOB = 4
INPUT = 1
RESIZE = 2
CHUNK = 16384
QUEUE = 256 * 1024


def handle_frames(pending, input_data, resize, control):
    while len(pending) >= HEADER.size:
        kind, size = HEADER.unpack_from(pending)
        if not ((kind == INPUT and 0 < size <= CHUNK) or (kind == RESIZE and size == SIZE.size)
                or (kind in (RUN_JOB, CANCEL_JOB, RUN_SHELL) and size == 1)):
            raise ValueError("invalid Linux console frame")
        end = HEADER.size + size
        if len(pending) < end:
            return
        if kind == INPUT:
            input_data(pending[HEADER.size:end])
        elif kind == RESIZE:
            columns, rows = SIZE.unpack_from(pending, HEADER.size)
            if not 2 <= columns <= 500 or not 2 <= rows <= 300:
                raise ValueError("invalid Linux console dimensions")
            resize(columns, rows)
        else:
            control(kind)
        del pending[:end]


def shell(serial, mapped):
    os.close(serial)
    os.setgroups([])
    os.unshare(os.CLONE_NEWUSER | os.CLONE_NEWNS)
    # The PTY is still private here. Tell init the namespaces exist before
    # it writes their maps, and wait for explicit acknowledgement.
    os.write(1, b"N")
    if os.read(mapped, 1) != b"M":
        raise RuntimeError("Sandbox shell ID mapping failed")
    os.close(mapped)
    os.setresgid(0, 0, 0)
    os.setresuid(0, 0, 0)
    os.chdir("/work")
    os.execve("/bin/sh", ["sh", "-i"], {
        "PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "HOME": "/work", "TMPDIR": "/work",
        "USER": "root", "LOGNAME": "root", "TERM": "xterm-256color", "LANG": "C.UTF-8",
        "PS1": rf"\[\033[32m\]{os.uname().sysname}:\w#\[\033[0m\] ",
    })


def start_shell(serial, window):
    mapped, ack = os.pipe()
    try:
        pid, master = os.forkpty()
    except OSError:
        os.close(mapped)
        os.close(ack)
        raise
    if pid == 0:
        os.close(ack)
        try:
            shell(serial, mapped)
        finally:
            os._exit(127)
    os.close(mapped)
    try:
        if os.read(master, 1) != b"N":
            raise RuntimeError("Shell exited before creating its namespaces")
        # Inner root owns /work and the capture files as VM ID 65533.
        # Other shell IDs use a range disjoint from init and workspace jobs.
        for name in ("uid_map", "gid_map"):
            with open(f"/proc/{pid}/{name}", "w", encoding="ascii") as mapping:
                mapping.write("0 65533 1\n1 100000 65535\n")
        fcntl.ioctl(master, termios.TIOCSWINSZ, window)
        os.set_blocking(master, False)
        os.write(ack, b"M")
    except BaseException:
        os.close(master)
        os.close(ack)  # Release a child still waiting for its mapping.
        os.waitpid(pid, 0)
        raise
    os.close(ack)
    return pid, master


def kill_process(pid):
    import signal
    os.kill(pid, signal.SIGKILL)


def start_job():
    # Fork PID 1 of a private namespace. Killing this PID also kills detached
    # descendants. The console supervisor can wait for the entire job to end.
    original = os.open("/proc/self/ns/pid", os.O_RDONLY)
    try:
        os.unshare(os.CLONE_NEWPID)
        pid = -1
        try:
            pid = os.fork()
        finally:
            if pid != 0:
                os.setns(original, os.CLONE_NEWPID)
        if pid == 0:
            try:
                os.unshare(os.CLONE_NEWNS)
                # This single-threaded supervisor already has an initialized
                # interpreter. Give the worker the same clean descriptor table
                # it would inherit across exec, then load only its own job code.
                os.closerange(3, os.sysconf("SC_OPEN_MAX"))
                from linux_job import main as run_job
                run_job()
                os._exit(0)
            except BaseException:
                sys.excepthook(*sys.exc_info())
            finally:
                os._exit(125)
        try:
            return pid, os.pidfd_open(pid)
        except OSError:
            # A worker without a completion notification must not outlive this request.
            kill_process(pid)
            os.waitpid(pid, 0)
            raise
    finally:
        os.close(original)


def flush_disk(path):
    with open(path, "rb", buffering=0) as disk:
        fcntl.ioctl(disk, 0x1261)  # BLKFLSBUF, drop block cache before host access


def last_input_key(data):
    # Only the final editing key matters. Skip any complete cursor reports
    # following it without changing the bytes forwarded to the PTY.
    end = len(data)
    while end and data[end - 1] == ord("R"):
        start = data.rfind(b"\x1b[", 0, end)
        if start < 0:
            break
        row, _, col = data[start + 2:end - 1].partition(b";")
        if not row.isdigit() or not col.isdigit():
            break
        end = start
    return data[end - 1] if end else None


def main():
    serial = os.open("/dev/ttyAMA0", os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    tty.setraw(serial)
    window = WINDOW.pack(24, 80, 0, 0)
    shell_pid, master = start_shell(serial, window)
    frames, to_shell, to_host = bytearray(), bytearray(), bytearray()
    job = job_done = shared = None
    background = set()
    ready = editing = False
    last_input = 0.0
    sys.path.insert(0, "/")  # Only init's read-only image contains these modules.

    def resize(columns, rows):
        nonlocal window
        window = WINDOW.pack(rows, columns, 0, 0)
        fcntl.ioctl(master, termios.TIOCSWINSZ, window)

    def input_data(data):
        nonlocal editing, last_input
        if shared is not None and data == b"\x03":
            shared.stop(shell_pid)
            return
        # ash asks for the cursor position at each prompt. A terminal's CSI
        # row;col R reply does not edit the current input line.
        key = last_input_key(data)
        if key is not None:
            editing = key not in (3, 4, 10, 13)
            last_input = time.monotonic()
        to_shell.extend(data)

    def idle_prompt():
        return (not to_shell and not editing and os.tcgetpgrp(master) == shell_pid
                and not termios.tcgetattr(master)[3] & termios.ICANON)

    def output(data):
        for offset in range(0, len(data), CHUNK):
            part = data[offset:offset + CHUNK]
            to_host.extend(HEADER.pack(INPUT, len(part)) + part)

    def finish_shared(shell_exit=None):
        nonlocal shared
        try:
            result = shared.result(output, shell_exit)
            if not result:
                return
            flush_disk("/dev/vdb")
            to_host.extend(HEADER.pack(RUN_JOB, 1) + bytes([0]))
        except (ValueError, OSError) as error:
            task_error(error)
        shared.close(background)
        shared = None

    def task_error(error):
        from linux_protocol import store_result
        with open("/dev/vdb", "r+b", buffering=0) as disk:
            store_result(disk, {"error": str(error)})
        flush_disk("/dev/vdb")
        to_host.extend(HEADER.pack(RUN_JOB, 1) + bytes([0]))

    def control(kind):
        nonlocal job, job_done, shared
        if kind == CANCEL_JOB:
            if job is not None:
                kill_process(job)
            elif shared is not None:
                shared.stop(shell_pid)
            return
        if job is not None or shared is not None:
            raise RuntimeError("job already active")
        flush_disk("/dev/vdb")
        if kind == RUN_JOB:
            try:
                job, job_done = start_job()
            except OSError as error:
                task_error(error)
        elif not idle_prompt() or time.monotonic() - last_input < 0.12:
            reason = 2 if editing else (3 if to_shell or time.monotonic() - last_input < 0.12 else 4)
            to_host.extend(HEADER.pack(RUN_JOB, 1) + bytes([reason]))
        else:
            from linux_shell_task import ShellTask
            try:
                shared = ShellTask()
                to_shell.extend(shared.command)
            except (ValueError, OSError, KeyError) as error:
                task_error(error)

    while True:
        if not ready and idle_prompt():
            to_host[:0] = b"TBC2"
            ready = True
        reads = ([serial] if len(to_shell) < QUEUE else []) + ([master] if len(to_host) < QUEUE else [])
        if shared is not None:
            reads.extend(shared.pipes)
            reads.append(shared.status_fd)
        if job_done is not None:
            reads.append(job_done)
        reads.extend(background)
        writes = ([serial] if ready and to_host else []) + ([master] if to_shell else [])
        check_exit = not ready or (shared is not None and shared.cancelled_at is not None)
        readable, writable, _ = select.select(reads, writes, [], 0.05 if check_exit else None)
        for fd in writable:
            target = to_host if fd == serial else to_shell
            try:
                del target[:os.write(fd, target)]
            except BlockingIOError:
                pass
            except OSError as error:
                if fd != master or error.errno != errno.EIO:
                    raise
                to_shell.clear()
        for fd in readable:
            if fd == job_done:
                _, status = os.waitpid(job, 0)
                os.close(job_done)
                job = job_done = None
                flush_disk("/dev/vdc")
                flush_disk("/dev/vdb")
                to_host.extend(HEADER.pack(RUN_JOB, 1) + bytes([0 if status == 0 else 1]))
                continue
            if fd in background:
                if not os.read(fd, 65536):
                    os.close(fd)
                    background.remove(fd)
                continue
            if fd not in (serial, master):
                # Reading the PTY may already have completed and closed this task.
                if shared is not None and fd in shared.pipes:
                    shared.drain(fd, output)
                elif shared is not None and fd == shared.status_fd:
                    finish_shared()
                continue
            try:
                data = os.read(fd, CHUNK)
            except BlockingIOError:
                continue
            except OSError as error:
                if fd != master or error.errno != errno.EIO:
                    raise
                data = b""
            if fd == serial:
                if not data:
                    raise EOFError("Linux serial disconnected")
                frames.extend(data)
                handle_frames(frames, input_data, resize, control)
            elif data:
                if shared is not None:
                    finish_shared()
                output(data)
            else:
                os.close(master)
                _, status = os.waitpid(shell_pid, 0)
                if shared is not None:
                    finish_shared(os.waitstatus_to_exitcode(status))
                editing = False
                to_shell.clear()
                shell_pid, master = start_shell(serial, window)
        if shared is not None and shared.cancelled_at is not None:
            if idle_prompt():
                finish_shared(130)
            elif time.monotonic() - shared.cancelled_at > 2:
                kill_process(shell_pid)
        # As init, also reap orphaned interactive subprocesses.
        while True:
            child = os.waitid(os.P_ALL, 0, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            if not child or child.si_pid in (shell_pid, job):
                break
            os.waitpid(child.si_pid, 0)


if __name__ == "__main__":
    main()
