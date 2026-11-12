#include "local_process.h"

#include <AbilityKit/native_child_process.h>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <fcntl.h>
#include <memory>
#include <poll.h>
#include <signal.h>
#include <stdexcept>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

namespace tinybot {
namespace {
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;

class Fd {
public:
    explicit Fd(int value) : value_(value) {}
    ~Fd() { Close(); }
    Fd(const Fd &) = delete;
    Fd &operator=(const Fd &) = delete;
    int Get() const { return value_; }
    void Close()
    {
        if (value_ >= 0) { close(value_); value_ = -1; }
    }
private:
    int value_;
};

void SetError(LocalReceipt &receipt, const char *operation, int code)
{
    std::snprintf(receipt.error.data(), receipt.error.size(), "%s (code %d)", operation, code);
}

class ProcessGroup {
public:
    explicit ProcessGroup(pid_t pid) : pid_(pid) {}
    ~ProcessGroup() { if (pid_ > 0) { int status; Stop(status); } }
    ProcessGroup(const ProcessGroup &) = delete;
    ProcessGroup &operator=(const ProcessGroup &) = delete;

    int Stop(int &status)
    {
        // Keep the leader unreaped until after signalling so its PID cannot be reused.
        kill(-pid_, SIGKILL);
        kill(pid_, SIGKILL);
        pid_t result;
        do { result = waitpid(pid_, &status, 0); } while (result < 0 && errno == EINTR);
        pid_ = -1;
        return result < 0 ? errno : 0;
    }
private:
    pid_t pid_;
};

bool Drain(Fd &fd, LocalStream &stream)
{
    char buffer[4096];
    // Return to polling regularly even if a process continuously writes output.
    for (int chunk = 0; chunk < 32; ++chunk) {
        const ssize_t bytes = read(fd.Get(), buffer, sizeof(buffer));
        if (bytes < 0 && errno == EINTR) { continue; }
        if (bytes < 0 && errno == EAGAIN) { return true; }
        if (bytes < 0) { return false; }
        if (bytes == 0) { fd.Close(); return true; }
        const size_t stored = std::min(static_cast<size_t>(bytes), stream.data.size() - stream.size);
        std::memcpy(stream.data.data() + stream.size, buffer, stored);
        stream.size += stored;
        stream.truncated = stream.truncated || stored < static_cast<size_t>(bytes);
    }
    return true;
}

bool WriteInput(int fd, const LocalRequest &request)
{
    size_t offset = 0;
    while (offset < request.inputSize) {
        const ssize_t written = write(fd, request.input.data() + offset, request.inputSize - offset);
        if (written < 0 && errno == EINTR) { continue; }
        if (written <= 0) { return false; }
        offset += written;
    }
    return lseek(fd, 0, SEEK_SET) == 0;
}

struct ExecFailure { const char *stage; int code; };

[[noreturn]] void ExecError(int fd, const char *stage)
{
    // Only the supervisor fork can see this pipe. Successful exec closes it.
    const ExecFailure error{stage, errno};
    ssize_t written;
    do { written = write(fd, &error, sizeof(error)); } while (written < 0 && errno == EINTR);
    _exit(126);
}

[[noreturn]] void ExecCommand(const char *path, char *const argv[], char *const env[],
    int input, int output, int errors, int setup, int cpuSeconds, pid_t supervisor)
{
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0) { ExecError(setup, "tie command to isolated worker"); }
    if (getppid() != supervisor) { _exit(126); }
    if (setpgid(0, 0) != 0) { ExecError(setup, "setpgid"); }
    if (dup2(input, STDIN_FILENO) < 0 || dup2(output, STDOUT_FILENO) < 0 ||
        dup2(errors, STDERR_FILENO) < 0) { ExecError(setup, "redirect standard streams"); }
    constexpr int setupFd = 3;
    if (setup != setupFd && dup3(setup, setupFd, O_CLOEXEC) < 0) { ExecError(setup, "redirect setup pipe"); }
    // Close appspawn and supervisor descriptors before loading any user code.
    if (syscall(SYS_close_range, 4u, ~0u, 0u) != 0) { ExecError(setupFd, "close inherited descriptors"); }
    const rlimit cpu{static_cast<rlim_t>(cpuSeconds), static_cast<rlim_t>(cpuSeconds)};
    const rlimit noCore{0, 0};
    const rlimit fileSize{32 * 1024 * 1024, 32 * 1024 * 1024};
    const rlimit processes{64, 64};
    if (setrlimit(RLIMIT_CPU, &cpu) != 0 || setrlimit(RLIMIT_CORE, &noCore) != 0 ||
        setrlimit(RLIMIT_FSIZE, &fileSize) != 0 || setrlimit(RLIMIT_NPROC, &processes) != 0) {
        ExecError(setupFd, "set command resource limits");
    }
    sigset_t signals;
    sigemptyset(&signals);
    struct sigaction action{};
    action.sa_handler = SIG_DFL;
    if (sigemptyset(&action.sa_mask) != 0 || sigaction(SIGPIPE, &action, nullptr) != 0 ||
        sigprocmask(SIG_SETMASK, &signals, nullptr) != 0) { ExecError(setupFd, "reset command signals"); }
    if (chdir("/") != 0) { ExecError(setupFd, "set command directory"); }
    execve(path, argv, env);
    ExecError(setupFd, "exec packaged runtime");
}

bool ValidRequest(const LocalRequest &request)
{
    return (request.runtime == LocalRuntime::Node || request.runtime == LocalRuntime::Shell) &&
        request.timeoutMs > 0 && request.timeoutMs <= LOCAL_TIMEOUT_LIMIT_MS &&
        request.source.front() != '\0' && request.source.back() == '\0' && request.inputSize <= request.input.size();
}

bool SetNonblocking(int fd)
{
    const int flags = fcntl(fd, F_GETFL);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

void RunCommand(int owner, const std::string &directory, LocalRequest &request, LocalReceipt &receipt)
{
    const bool node = request.runtime == LocalRuntime::Node;
    std::string path = directory + (node ? "/tinybot-node" : "/tinybot-sh");
    std::string pathEnv = "PATH=" + directory + ":/system/bin";
    char jitless[] = "--jitless";
    char noAddons[] = "--no-addons";
    char eval[] = "-e";
    char command[] = "-c";
    char home[] = "HOME=/";
    char lang[] = "LANG=C.UTF-8";
    char *nodeArgs[] = {path.data(), jitless, noAddons, eval, request.source.data(), nullptr};
    char *shellArgs[] = {path.data(), command, request.source.data(), nullptr};
    char *env[] = {pathEnv.data(), home, lang, nullptr};
    Fd input(memfd_create("tinybot-stdin", MFD_CLOEXEC));
    if (input.Get() < 0 || !WriteInput(input.Get(), request)) {
        SetError(receipt, "prepare stdin", errno);
        return;
    }
    int pipes[2];
    if (pipe2(pipes, O_CLOEXEC) != 0) { SetError(receipt, "create stdout pipe", errno); return; }
    Fd out(pipes[0]), outWrite(pipes[1]);
    if (pipe2(pipes, O_CLOEXEC) != 0) { SetError(receipt, "create stderr pipe", errno); return; }
    Fd err(pipes[0]), errWrite(pipes[1]);
    if (pipe2(pipes, O_CLOEXEC) != 0) { SetError(receipt, "create exec status pipe", errno); return; }
    Fd setup(pipes[0]), setupWrite(pipes[1]);
    if (!SetNonblocking(out.Get()) || !SetNonblocking(err.Get()) || !SetNonblocking(setup.Get())) {
        SetError(receipt, "configure command pipes", errno);
        return;
    }
    struct sigaction action{};
    action.sa_handler = SIG_DFL;
    if (sigemptyset(&action.sa_mask) != 0 || sigaction(SIGCHLD, &action, nullptr) != 0) {
        SetError(receipt, "enable command reaping", errno);
        return;
    }
    const auto deadline = Clock::now() + std::chrono::milliseconds(request.timeoutMs);
    const pid_t supervisor = getpid();
    const pid_t pid = fork();
    if (pid < 0) { SetError(receipt, "fork command in isolated worker", errno); return; }
    if (pid == 0) {
        ExecCommand(path.c_str(), node ? nodeArgs : shellArgs, env, input.Get(),
            outWrite.Get(), errWrite.Get(), setupWrite.Get(), (request.timeoutMs + 999) / 1000 + 1, supervisor);
    }
    ProcessGroup group(pid);
    outWrite.Close();
    errWrite.Close();
    setupWrite.Close();
    bool exited = false;
    for (;;) {
        siginfo_t info{};
        if (waitid(P_PID, pid, &info, WEXITED | WNOHANG | WNOWAIT) != 0) {
            if (errno == EINTR) { continue; }
            SetError(receipt, "observe command exit", errno);
            break;
        }
        if (info.si_pid == pid) { exited = true; break; }
        if (Clock::now() >= deadline) { receipt.status = LocalStatus::Timeout; break; }
        pollfd events[] = {{owner, POLLIN, 0}, {out.Get(), POLLIN, 0}, {err.Get(), POLLIN, 0}};
        if (poll(events, 3, 25) < 0) {
            if (errno == EINTR) { continue; }
            SetError(receipt, "poll command output", errno);
            break;
        }
        if (events[0].revents) { receipt.status = LocalStatus::Cancelled; break; }
        if ((events[1].revents && !Drain(out, receipt.out)) || (events[2].revents && !Drain(err, receipt.err))) {
            SetError(receipt, "read command output", errno);
            break;
        }
    }
    int status = 0;
    const int waitError = group.Stop(status);
    if (waitError != 0) {
        SetError(receipt, "reap command", waitError);
        receipt.status = LocalStatus::Failed;
        return;
    }
    if ((out.Get() >= 0 && !Drain(out, receipt.out)) || (err.Get() >= 0 && !Drain(err, receipt.err))) {
        SetError(receipt, "drain command output", errno);
        receipt.status = LocalStatus::Failed;
        return;
    }
    if (!exited) { return; }
    ExecFailure failure{};
    ssize_t bytes;
    do { bytes = read(setup.Get(), &failure, sizeof(failure)); } while (bytes < 0 && errno == EINTR);
    if (bytes == sizeof(failure)) { SetError(receipt, failure.stage, failure.code); }
    else if (bytes != 0) { SetError(receipt, "read exec status", bytes < 0 ? errno : EIO); }
    else if (WIFEXITED(status)) { receipt.status = LocalStatus::Exited; receipt.exitCode = WEXITSTATUS(status); }
    else if (WIFSIGNALED(status)) { receipt.status = LocalStatus::Signalled; receipt.signal = WTERMSIG(status); }
    else { SetError(receipt, "unexpected command status", status); }
}

using Config = std::unique_ptr<Ability_ChildProcessConfigs, decltype(&OH_Ability_DestroyChildProcessConfigs)>;

template <typename Function> Function ChildProcessApi(const char *name)
{
    return reinterpret_cast<Function>(dlsym(RTLD_DEFAULT, name));
}

void StopWorker(int32_t pid)
{
    const auto killWorker = ChildProcessApi<decltype(&OH_Ability_KillChildProcess)>("OH_Ability_KillChildProcess");
    if (killWorker) { killWorker(pid); }
}

bool WaitForWorker(Fd &connection, int32_t pid, const LocalRequest &request, const std::atomic<bool> &cancelled,
    LocalReceipt &receipt)
{
    const auto deadline = Clock::now() + std::chrono::milliseconds(request.timeoutMs) + 2s;
    if (send(connection.Get(), &request, sizeof(request), MSG_NOSIGNAL | MSG_DONTWAIT) != sizeof(request)) {
        SetError(receipt, "send command to isolated worker", errno);
        return false;
    }
    for (;;) {
        if (cancelled.load(std::memory_order_relaxed)) {
            // Half-close so the worker observes cancellation and can still return its cleanup receipt.
            shutdown(connection.Get(), SHUT_WR);
        }
        pollfd ready{connection.Get(), POLLIN, 0};
        const int count = poll(&ready, 1, 25);
        if (count < 0 && errno != EINTR) { SetError(receipt, "poll isolated worker", errno); return false; }
        if (count > 0) {
            LocalReceipt reply;
            const ssize_t size = recv(connection.Get(), &reply, sizeof(reply), MSG_TRUNC | MSG_DONTWAIT);
            if (size == sizeof(reply) && reply.out.size <= reply.out.data.size() &&
                reply.err.size <= reply.err.data.size() && reply.error.back() == '\0') {
                receipt = reply;
                return true;
            }
            SetError(receipt, "isolated worker closed without a complete receipt", size < 0 ? errno : EIO);
            return false;
        }
        if (Clock::now() >= deadline) {
            SetError(receipt, "isolated worker did not return its cleanup receipt", pid);
            return false;
        }
    }
}
} // namespace

bool LocalProcessSupported()
{
    const auto supported = ChildProcessApi<decltype(&OH_Ability_IsNativeChildProcessSupported)>(
        "OH_Ability_IsNativeChildProcessSupported");
    return supported && supported();
}

LocalReceipt RunLocalProcess(const std::string &libraryDir, const LocalRequest &request,
    const std::atomic<bool> &cancelled)
{
    LocalReceipt receipt;
    if (cancelled.load(std::memory_order_relaxed)) { receipt.status = LocalStatus::Cancelled; return receipt; }
    if (!LocalProcessSupported() || !ValidRequest(request)) {
        SetError(receipt, "local process unsupported or invalid request", EINVAL);
        return receipt;
    }
    int sockets[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sockets) != 0) {
        SetError(receipt, "create worker connection", errno);
        return receipt;
    }
    Fd connection(sockets[0]), worker(sockets[1]);
    Config config(OH_Ability_CreateChildProcessConfigs(), OH_Ability_DestroyChildProcessConfigs);
    const auto setUid = ChildProcessApi<decltype(&OH_Ability_ChildProcessConfigs_SetIsolationUid)>(
        "OH_Ability_ChildProcessConfigs_SetIsolationUid");
    if (!config || !setUid) { SetError(receipt, "create isolated worker configuration", ENOTSUP); return receipt; }
    auto status = OH_Ability_ChildProcessConfigs_SetIsolationMode(config.get(), NCP_ISOLATION_MODE_ISOLATED);
    if (status == NCP_NO_ERROR) { status = setUid(config.get(), true); }
    if (status != NCP_NO_ERROR) { SetError(receipt, "configure isolated worker", status); return receipt; }
    char fdName[] = "command";
    NativeChildProcess_Fd fd{fdName, worker.Get(), nullptr};
    std::string directory = libraryDir;
    NativeChildProcess_Args args{directory.data(), {&fd}};
    int32_t pid = -1;
    status = OH_Ability_StartNativeChildProcessWithConfigs("libtinybot_sandbox.so:TinybotLocalProcessMain",
        args, config.get(), &pid);
    worker.Close();
    if (status != NCP_NO_ERROR) { SetError(receipt, "start isolated worker", status); return receipt; }
    if (!WaitForWorker(connection, pid, request, cancelled, receipt)) {
        connection.Close();
        StopWorker(pid);
    }
    return receipt;
}

extern "C" __attribute__((visibility("default"))) void TinybotLocalProcessMain(NativeChildProcess_Args args)
{
    auto *fd = args.fdList.head;
    if (!fd || !fd->fdName || std::strcmp(fd->fdName, "command") != 0 || fd->fd < 3) { return; }
    Fd connection(fd->fd);
    LocalReceipt receipt;
    const auto start = Clock::now();
    LocalRequest request;
    pollfd ready{connection.Get(), POLLIN, 0};
    const int count = poll(&ready, 1, 5000);
    const ssize_t received = count > 0 ? recv(connection.Get(), &request, sizeof(request), MSG_TRUNC | MSG_DONTWAIT) : -1;
    if (!args.entryParams || args.entryParams[0] != '/' || received != sizeof(request) || !ValidRequest(request)) {
        SetError(receipt, "read command request", EINVAL);
    } else {
        try { RunCommand(connection.Get(), args.entryParams, request, receipt); }
        catch (const std::exception &error) {
            receipt.status = LocalStatus::Failed;
            std::snprintf(receipt.error.data(), receipt.error.size(), "%s", error.what());
        }
    }
    receipt.durationMs = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count();
    send(connection.Get(), &receipt, sizeof(receipt), MSG_NOSIGNAL | MSG_DONTWAIT);
}
} // namespace tinybot
