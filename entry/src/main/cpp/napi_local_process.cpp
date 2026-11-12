#include "napi/native_api.h"
#include "local_process.h"

#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <unistd.h>

namespace {
using namespace tinybot;

struct Job {
    std::string id;
    std::string directory;
    LocalRequest request;
    LocalReceipt receipt;
    std::atomic<bool> cancelled{false};
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
};
std::mutex mutex;
Job *active = nullptr;

bool ReadText(napi_env env, napi_value value, std::string &text, size_t limit)
{
    size_t bytes = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &bytes) != napi_ok || bytes > limit) { return false; }
    text.resize(bytes + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, text.data(), text.size(), &copied) != napi_ok || copied != bytes) {
        return false;
    }
    text.resize(bytes);
    return true;
}

bool ValidDirectory(const std::string &directory)
{
    constexpr char prefix[] = "/data/storage/el1/bundle/";
    return directory.compare(0, sizeof(prefix) - 1, prefix) == 0 &&
        directory.find("..") == std::string::npos && directory.find('\0') == std::string::npos;
}

napi_value Available(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value arg;
    std::string directory;
    const bool available = napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) == napi_ok && argc == 1 &&
        ReadText(env, arg, directory, 512) && ValidDirectory(directory) &&
        access((directory + "/tinybot-node").c_str(), X_OK) == 0 &&
        access((directory + "/tinybot-sh").c_str(), X_OK) == 0 && LocalProcessSupported();
    napi_value result;
    napi_get_boolean(env, available, &result);
    return result;
}

void Release(Job *job)
{
    std::lock_guard<std::mutex> lock(mutex);
    if (active == job) { active = nullptr; }
}

void Execute(napi_env, void *data)
{
    auto &job = *static_cast<Job *>(data);
    try { job.receipt = RunLocalProcess(job.directory, job.request, job.cancelled); }
    catch (const std::exception &failure) {
        std::snprintf(job.receipt.error.data(), job.receipt.error.size(), "%s", failure.what());
    }
}

const char *StatusName(const LocalReceipt &receipt)
{
    switch (receipt.status) {
        case LocalStatus::Exited: return receipt.exitCode == 0 ? "ok" : "failed";
        case LocalStatus::Timeout: return "timeout";
        case LocalStatus::Cancelled: return "cancelled";
        case LocalStatus::Signalled:
        case LocalStatus::Failed: return "failed";
    }
    return "failed";
}

bool PutText(napi_env env, napi_value target, const char *key, const char *value, size_t length)
{
    napi_value text;
    return napi_create_string_utf8(env, value, length, &text) == napi_ok &&
        napi_set_named_property(env, target, key, text) == napi_ok;
}

bool PutInt(napi_env env, napi_value target, const char *key, int32_t value)
{
    napi_value number;
    return napi_create_int32(env, value, &number) == napi_ok && napi_set_named_property(env, target, key, number) == napi_ok;
}

bool ToValue(napi_env env, const LocalReceipt &receipt, napi_value &result)
{
    napi_value truncated;
    return napi_create_object(env, &result) == napi_ok &&
        PutText(env, result, "status", StatusName(receipt), NAPI_AUTO_LENGTH) &&
        PutText(env, result, "error", receipt.error.data(), NAPI_AUTO_LENGTH) &&
        PutText(env, result, "stdout", receipt.out.data.data(), receipt.out.size) &&
        PutText(env, result, "stderr", receipt.err.data.data(), receipt.err.size) &&
        PutInt(env, result, "durationMs", receipt.durationMs) &&
        (receipt.status != LocalStatus::Exited || PutInt(env, result, "exitCode", receipt.exitCode)) &&
        (receipt.status != LocalStatus::Signalled || PutInt(env, result, "signal", receipt.signal)) &&
        napi_get_boolean(env, receipt.out.truncated || receipt.err.truncated, &truncated) == napi_ok &&
        napi_set_named_property(env, result, "outputTruncated", truncated) == napi_ok;
}

void Complete(napi_env env, napi_status status, void *data)
{
    std::unique_ptr<Job> job(static_cast<Job *>(data));
    Release(job.get());
    napi_value result;
    if (status == napi_ok && ToValue(env, job->receipt, result)) {
        napi_resolve_deferred(env, job->deferred, result);
    } else {
        napi_value message;
        napi_create_string_utf8(env, "Cannot return local process receipt", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &result);
        napi_reject_deferred(env, job->deferred, result);
    }
    napi_delete_async_work(env, job->work);
}

napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 7;
    napi_value args[7];
    auto job = std::make_unique<Job>();
    std::string runtime, source, input;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 6 ||
        !ReadText(env, args[0], job->id, 128) || job->id.empty() ||
        !ReadText(env, args[1], job->directory, 512) || !ValidDirectory(job->directory) ||
        !ReadText(env, args[2], runtime, 5) || (runtime != "node" && runtime != "shell") ||
        !ReadText(env, args[3], source, LOCAL_SOURCE_LIMIT) || source.empty() || source.find('\0') != std::string::npos ||
        !ReadText(env, args[4], input, LOCAL_INPUT_LIMIT) ||
        napi_get_value_int32(env, args[5], &job->request.timeoutMs) != napi_ok ||
        job->request.timeoutMs < 1 || job->request.timeoutMs > LOCAL_TIMEOUT_LIMIT_MS) {
        napi_throw_type_error(env, nullptr, "Invalid local process arguments");
        return nullptr;
    }
    job->request.runtime = runtime == "node" ? LocalRuntime::Node : LocalRuntime::Shell;
    std::memcpy(job->request.source.data(), source.data(), source.size());
    std::memcpy(job->request.input.data(), input.data(), input.size());
    job->request.inputSize = input.size();
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (active) { napi_throw_error(env, "BUSY", "A local command is still running"); return nullptr; }
        active = job.get();
    }
    napi_value promise, name;
    if (napi_create_promise(env, &job->deferred, &promise) != napi_ok ||
        napi_create_string_utf8(env, "TinybotLocalProcess", NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_create_async_work(env, nullptr, name, Execute, Complete, job.get(), &job->work) != napi_ok ||
        napi_queue_async_work(env, job->work) != napi_ok) {
        if (job->work) { napi_delete_async_work(env, job->work); }
        Release(job.get());
        napi_throw_error(env, nullptr, "Cannot schedule local process");
        return nullptr;
    }
    job.release();
    return promise;
}

napi_value Cancel(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value arg;
    std::string id;
    if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok || argc != 1 ||
        !ReadText(env, arg, id, 128)) {
        napi_throw_type_error(env, nullptr, "Expected a local execution id");
        return nullptr;
    }
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (active && active->id == id) { active->cancelled.store(true, std::memory_order_relaxed); }
    }
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}
}

void InstallLocalProcess(napi_env env, napi_value exports)
{
    napi_property_descriptor properties[] = {
        {"localProcessAvailable", nullptr, Available, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runLocalProcess", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelLocalProcess", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
}
