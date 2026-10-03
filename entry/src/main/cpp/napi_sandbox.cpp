#include "napi/native_api.h"
#include "sandbox.h"
#include <memory>
#include <mutex>

namespace {
struct Job {
    std::string id;
    std::string source;
    std::string input;
    tinybot::Budget budget;
    std::string output;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
};
std::mutex activeMutex;
Job *active = nullptr; // Owned by the async work until Complete; always accessed under activeMutex.

bool ReadString(napi_env env, napi_value value, size_t limit, std::string &out)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length > limit) { return false; }
    out.resize(length + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, &out[0], out.size(), &copied) != napi_ok || copied != length) { return false; }
    out.resize(length);
    return true;
}
void Release(Job *job)
{
    std::lock_guard<std::mutex> lock(activeMutex);
    if (active == job) { active = nullptr; }
}
void Execute(napi_env, void *data)
{
    auto *job = static_cast<Job *>(data);
    try { job->output = tinybot::ExecuteCode(job->source, job->input, job->budget).ToJson(); }
    catch (...) { job->output.clear(); }
}
void Complete(napi_env env, napi_status status, void *data)
{
    std::unique_ptr<Job> job(static_cast<Job *>(data));
    Release(job.get()); // Runtime destruction finishes before another execution is admitted.
    napi_value result = nullptr;
    if (status == napi_ok && !job->output.empty() &&
        napi_create_string_utf8(env, job->output.c_str(), job->output.size(), &result) == napi_ok) {
        napi_resolve_deferred(env, job->deferred, result);
    } else {
        napi_value message = nullptr;
        napi_create_string_utf8(env, "Native sandbox execution failed", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &result);
        napi_reject_deferred(env, job->deferred, result);
    }
    napi_delete_async_work(env, job->work);
}
napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4];
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 3) {
        napi_throw_type_error(env, nullptr, "Expected id, source and JSON input strings"); return nullptr;
    }
    auto job = std::make_unique<Job>();
    if (!ReadString(env, args[0], 128, job->id) || job->id.empty() ||
        !ReadString(env, args[1], tinybot::MAX_SOURCE_BYTES, job->source) || job->source.empty() ||
        !ReadString(env, args[2], tinybot::MAX_INPUT_BYTES, job->input)) {
        napi_throw_type_error(env, nullptr, "Invalid sandbox input or byte limit exceeded"); return nullptr;
    }
    {
        std::lock_guard<std::mutex> lock(activeMutex);
        if (active) { napi_throw_error(env, nullptr, "Code sandbox is busy; retry after the active execution finishes"); return nullptr; }
        active = job.get();
    }
    napi_value promise = nullptr;
    napi_value name = nullptr;
    if (napi_create_promise(env, &job->deferred, &promise) != napi_ok ||
        napi_create_string_utf8(env, "TinybotCodeSandbox", NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_create_async_work(env, nullptr, name, Execute, Complete, job.get(), &job->work) != napi_ok ||
        napi_queue_async_work(env, job->work) != napi_ok) {
        if (job->work) { napi_delete_async_work(env, job->work); }
        Release(job.get());
        napi_throw_error(env, nullptr, "Cannot schedule code sandbox"); return nullptr;
    }
    job.release();
    return promise;
}
napi_value Cancel(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value arg;
    std::string id;
    if (napi_get_cb_info(env, info, &argc, &arg, nullptr, nullptr) != napi_ok || argc != 1 || !ReadString(env, arg, 128, id)) {
        napi_throw_type_error(env, nullptr, "Expected an execution id"); return nullptr;
    }
    {
        std::lock_guard<std::mutex> lock(activeMutex);
        if (active && active->id == id) { active->budget.cancelled.store(true, std::memory_order_relaxed); }
    }
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}
napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor properties[] = {
        {"execute", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancel", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, 2, properties);
    return exports;
}
napi_module module = {1, 0, nullptr, Init, "tinybot_sandbox", nullptr, {0}};
}
extern "C" __attribute__((constructor)) void RegisterTinybotSandbox()
{
    napi_module_register(&module);
}
