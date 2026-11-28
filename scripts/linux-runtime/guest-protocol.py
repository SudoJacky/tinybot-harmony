"""Request framing and bounded output used by both guest execution modes."""
import fcntl
import json
import os
import struct
import termios

HALF = 2 * 1024 * 1024
LOG_LIMIT = 16 * 1024
HEADER = struct.Struct("<4sI")


class CapturedOutput:
    def __init__(self, discard_fd):
        self.discard_fd = discard_fd
        self.streams = {"stdout": bytearray(), "stderr": bytearray()}
        self.truncated = False

    def drain(self, fd, name, limit=65536):
        capture = self.streams[name]
        remaining = LOG_LIMIT - len(capture)
        if not remaining:
            # Keep the writer running without copying discarded pages into Python.
            count = os.splice(fd, self.discard_fd, limit)
            self.truncated |= count > 0
            return count, b""
        data = os.read(fd, limit)
        sample = data[:remaining]
        capture.extend(sample)
        self.truncated |= len(sample) < len(data)
        return len(data), sample

    def receipt(self, code):
        result = {name: data.decode("utf-8", "replace") for name, data in self.streams.items()}
        result.update(exitCode=code, truncated=self.truncated)
        return result


def pending_bytes(fd):
    return struct.unpack("i", fcntl.ioctl(fd, termios.FIONREAD, bytes(4)))[0]


def read_exact(stream, size):
    data = bytearray()
    while len(data) < size:
        chunk = stream.read(size - len(data))
        if not chunk:
            raise ValueError("truncated Linux directory stream")
        data.extend(chunk)
    return data


def write_all(stream, data):
    pending = memoryview(data)
    while pending:
        written = stream.write(pending)
        if not written:
            raise OSError("incomplete Linux directory stream")
        pending = pending[written:]


def load_request(disk):
    magic, size = HEADER.unpack(read_exact(disk, HEADER.size))
    if magic != b"TBJ3" or not 0 < size <= HALF - HEADER.size:
        raise ValueError("invalid request frame")
    return json.loads(read_exact(disk, size))


def store_result(disk, result):
    data = json.dumps(result, ensure_ascii=False).encode()
    if len(data) > HALF - HEADER.size:
        raise ValueError("response exceeds exchange disk")
    os.fsync(disk.fileno())
    disk.seek(HALF)
    write_all(disk, HEADER.pack(b"TBR3", len(data)) + data)
    os.fsync(disk.fileno())
