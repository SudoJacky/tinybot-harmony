#include <napi/native_api.h>
#include "linux_engine.h"
#include <atomic>
#include <thread>
#include <AbilityKit/native_child_process.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>

void InstallLinuxFiles(napi_env env, napi_value exports);

namespace {
struct Job {
    std::string id, dir, diagnostics, error;
    int32_t timeoutSeconds = 0;
    int32_t memoryMiB = 0;
    int parent = -1, child = -1;
    bool interactive = false;
    napi_async_work work = nullptr;
    napi_deferred result = nullptr;
    ~Job() { if (parent >= 0) close(parent); if (child >= 0) close(child); }
};
std::mutex gate;
Job *active = nullptr;

bool StringArg(napi_env env, napi_value value, std::string &out)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length == 0 || length > 1024) return false;
    out.resize(length + 1);
    if (napi_get_value_string_utf8(env, value, out.data(), out.size(), &length) != napi_ok) return false;
    out.resize(length);
    return out.find('\0') == std::string::npos;
}

bool MemoryArg(napi_env env, napi_value value, int32_t &memory)
{
    double number;
    if (napi_get_value_double(env, value, &number) != napi_ok || !std::isfinite(number) ||
        number < 192 || number > LinuxMemoryLimitMiB() || std::floor(number) != number) return false;
    memory = static_cast<int32_t>(number);
    return true;
}

napi_value MemoryLimit(napi_env env, napi_callback_info)
{
    const auto maximum = LinuxMemoryLimitMiB();
    if (maximum < 192) {
        napi_throw_error(env, nullptr, "Insufficient device memory for the Linux sandbox");
        return nullptr;
    }
    napi_value result;
    napi_create_int32(env, maximum, &result);
    return result;
}

void Execute(napi_env, void *data)
{
    auto &job = *static_cast<Job *>(data);
    char name[] = "control";
    NativeChildProcess_Fd control{name, job.child, nullptr};
    auto parameters = std::to_string(job.memoryMiB) + "\n" + job.dir;
    NativeChildProcess_Args args{parameters.data(), {&control}};
    int32_t pid = 0;
    const auto *entry = job.interactive ? "libtinybot_linux_child.so:RunLinuxConsole" : "libtinybot_linux_child.so:RunLinuxGuest";
    int rc = OH_Ability_StartNativeChildProcess(entry, args, {}, &pid);
    close(job.child);
    job.child = -1;
    if (rc != NCP_NO_ERROR) { job.error = "Starting native Linux child failed: " + std::to_string(rc); return; }

    using Clock = std::chrono::steady_clock;
    auto deadline = Clock::now() + std::chrono::seconds(job.timeoutSeconds);
    while (true) {
        auto remaining = job.interactive ? -1 : std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
        if (!job.interactive && remaining <= 0) {
            if (!job.error.empty()) return;
            job.error = "Linux job exceeded " + std::to_string(job.timeoutSeconds) + " seconds";
            shutdown(job.parent, SHUT_WR);
            deadline = Clock::now() + std::chrono::seconds(5);
            continue;
        }
        pollfd event{job.parent, POLLIN, 0};
        int ready = poll(&event, 1, static_cast<int>(remaining));
        if (ready < 0 && errno == EINTR) continue;
        if (!ready) continue;
        if (ready < 0) { job.error = std::strerror(errno); return; }
        char bytes[1024];
        ssize_t count = recv(job.parent, bytes, sizeof(bytes), 0);
        if (!count) return;
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { job.error = std::strerror(errno); return; }
        job.diagnostics.append(bytes, count);
        if (job.diagnostics.size() > 4096) job.diagnostics.erase(0, job.diagnostics.size() - 4096);
    }
}

void Complete(napi_env env, napi_status status, void *data)
{
    std::unique_ptr<Job> job(static_cast<Job *>(data));
    { std::lock_guard<std::mutex> lock(gate); active = nullptr; }
    napi_value value;
    if (status != napi_ok && job->error.empty()) job->error = "Linux worker did not complete";
    if (job->interactive && job->error.empty() &&
        (job->diagnostics.find("QEMU exit ") != std::string::npos || job->diagnostics.find("Loading TCI:") != std::string::npos)) {
        job->error = "Linux console failed";
    }
    if (!job->error.empty()) {
        const auto message = job->error + " " + job->diagnostics;
        napi_create_string_utf8(env, message.c_str(), message.size(), &value);
        napi_value error;
        napi_create_error(env, nullptr, value, &error);
        napi_reject_deferred(env, job->result, error);
    } else {
        napi_create_string_utf8(env, job->diagnostics.c_str(), job->diagnostics.size(), &value);
        napi_resolve_deferred(env, job->result, value);
    }
    napi_delete_async_work(env, job->work);
}

napi_value StartJob(napi_env env, napi_callback_info info, bool interactive)
{
    size_t argc = 4;
    napi_value argv[4], promise, label;
    auto job = std::make_unique<Job>();
    job->interactive = interactive;
    double timeoutSeconds = 0;
    if (napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr) != napi_ok || argc != 4 ||
        !StringArg(env, argv[0], job->id) || !StringArg(env, argv[1], job->dir) ||
        napi_get_value_double(env, argv[2], &timeoutSeconds) != napi_ok ||
        (timeoutSeconds != 30 && timeoutSeconds != 60 && timeoutSeconds != 120) ||
        !MemoryArg(env, argv[3], job->memoryMiB)) {
        napi_throw_type_error(env, nullptr, "Expected Linux job id, private directory, timeout and memory profile");
        return nullptr;
    }
    job->timeoutSeconds = static_cast<int32_t>(timeoutSeconds);
    std::lock_guard<std::mutex> lock(gate);
    if (active) { napi_throw_error(env, nullptr, "A Linux guest is already running"); return nullptr; }
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) < 0) {
        napi_throw_error(env, nullptr, std::strerror(errno)); return nullptr;
    }
    job->parent = pair[0]; job->child = pair[1];
    if (napi_create_promise(env, &job->result, &promise) != napi_ok ||
        napi_create_string_utf8(env, "Linux guest", NAPI_AUTO_LENGTH, &label) != napi_ok ||
        napi_create_async_work(env, nullptr, label, Execute, Complete, job.get(), &job->work) != napi_ok ||
        napi_queue_async_work(env, job->work) != napi_ok) {
        if (job->work) napi_delete_async_work(env, job->work);
        napi_throw_error(env, nullptr, "Could not schedule Linux guest"); return nullptr;
    }
    active = job.release();
    return promise;
}

napi_value Start(napi_env env, napi_callback_info info) { return StartJob(env, info, false); }
napi_value StartConsole(napi_env env, napi_callback_info info) { return StartJob(env, info, true); }

// Phone applications can embed one VM. QMP resets the guest between jobs.
std::atomic<bool> embeddedStarted{false};
napi_value StartEmbedded(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value parameters[2], value;
    std::string dir;
    int32_t memory = 0;
    if (napi_get_cb_info(env, info, &argc, parameters, nullptr, nullptr) != napi_ok || argc != 2 ||
        !StringArg(env, parameters[0], dir) || !MemoryArg(env, parameters[1], memory)) {
        napi_throw_type_error(env, nullptr, "Expected a private VM directory and memory profile"); return nullptr;
    }
    if (embeddedStarted.exchange(true)) { napi_throw_error(env, nullptr, "Linux VM already started"); return nullptr; }
    try {
        auto entry = LoadLinuxEngine();
        std::thread([entry, dir, memory]() { RunLinuxEngine(entry, dir, memory, true); }).detach();
    } catch (const std::exception &error) {
        embeddedStarted = false;
        napi_throw_error(env, nullptr, error.what()); return nullptr;
    }
    napi_get_undefined(env, &value);
    return value;
}

napi_value Cancel(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value value;
    std::string id;
    if (napi_get_cb_info(env, info, &argc, &value, nullptr, nullptr) == napi_ok && argc && StringArg(env, value, id)) {
        std::lock_guard<std::mutex> lock(gate);
        if (active && active->id == id) shutdown(active->parent, SHUT_WR);
    }
    napi_get_undefined(env, &value);
    return value;
}
}

void InstallLinux(napi_env env, napi_value exports)
{
    napi_property_descriptor methods[] = {
        {"startLinux", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startLinuxConsole", nullptr, StartConsole, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelLinux", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startEmbeddedLinux", nullptr, StartEmbedded, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"linuxMemoryLimit", nullptr, MemoryLimit, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods);
    InstallLinuxFiles(env, exports);
}
