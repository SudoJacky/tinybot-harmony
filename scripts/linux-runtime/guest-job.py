"""PID 1's helper. One read-only guest and one fixed-size exchange disk per job."""
import base64
import json
import os
import resource
import stat
import struct
import subprocess
import tempfile

HALF = 2 * 1024 * 1024
FILE_LIMIT = 1024 * 1024
LOG_LIMIT = 16 * 1024
HEADER = struct.Struct("<4sI")


def drop_privileges():
    os.setgroups([])
    os.setgid(65534)
    os.setuid(65534)
    resource.setrlimit(resource.RLIMIT_FSIZE, (4 * FILE_LIMIT, 4 * FILE_LIMIT))
    resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))


def run_job(request):
    program = {"shell": ["/bin/sh"], "python": ["/usr/bin/python3", "-B"]}[request["language"]]
    os.chdir("/work")
    with open("task", "x", encoding="utf-8") as script:
        script.write(request["source"])
    if "input" in request:
        with open("input", "xb") as target:
            target.write(base64.b64decode(request["input"], validate=True))
    with tempfile.TemporaryFile(dir="/work") as stdout, tempfile.TemporaryFile(dir="/work") as stderr:
        result = subprocess.run(program + ["task"], stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                env={"PATH": "/usr/bin:/bin", "HOME": "/work", "TMPDIR": "/work",
                                     "LANG": "C.UTF-8"}, preexec_fn=drop_privileges)
        receipt = {"exitCode": result.returncode, "truncated": False}
        for name, stream in [("stdout", stdout), ("stderr", stderr)]:
            stream.seek(0)
            data = stream.read(LOG_LIMIT + 1)
            receipt[name] = data[:LOG_LIMIT].decode("utf-8", "replace")
            receipt["truncated"] |= len(data) > LOG_LIMIT
    if result.returncode == 0 and request.get("collect"):
        fd = os.open("output", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as output:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise ValueError("output must be a regular file")
            data = output.read(FILE_LIMIT + 1)
            if len(data) > FILE_LIMIT:
                raise ValueError("output exceeds 1 MiB")
            receipt["artifact"] = base64.b64encode(data).decode("ascii")
    return receipt


def main():
    with open("/dev/vdb", "r+b", buffering=0) as disk:
        try:
            magic, size = HEADER.unpack(disk.read(HEADER.size))
            if magic != b"TBJ1" or not 0 < size <= HALF - HEADER.size:
                raise ValueError("invalid request frame")
            result = run_job(json.loads(disk.read(size)))
        except Exception as error:
            result = {"error": str(error)}
        data = json.dumps(result, ensure_ascii=False).encode()
        if len(data) > HALF - HEADER.size:
            raise ValueError("response exceeds exchange disk")
        disk.seek(HALF)
        disk.write(HEADER.pack(b"TBR1", len(data)) + data)
        os.fsync(disk.fileno())


if __name__ == "__main__":
    main()
