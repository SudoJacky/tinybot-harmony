#include "napi/native_api.h"
#include "sandbox.h"
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <unordered_map>

namespace {
struct Invocation { std::string job; int id; std::string name; std::string arguments; };
struct Job : tinybot::ToolHost {
    std::string id, source, catalog, output;
    tinybot::Budget budget;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    napi_threadsafe_function callback = nullptr;
    std::mutex mutex;
    std::condition_variable ready;
    std::deque<tinybot::ToolReply> replies;
    void Submit(int callId, const std::string &name, const std::string &arguments) override {
        auto request = std::make_unique<Invocation>(Invocation{id, callId, name, arguments});
        if (napi_call_threadsafe_function(callback, request.get(), napi_tsfn_nonblocking) != napi_ok) {
            throw std::runtime_error("Cannot dispatch host tool");
        }
        request.release();
    }
    bool Wait(tinybot::ToolReply &reply) override {
        std::unique_lock<std::mutex> lock(mutex);
        ready.wait_for(lock, std::chrono::milliseconds(25), [&] { return !replies.empty() || budget.cancelled.load(); });
        if (replies.empty()) { return false; }
        reply = std::move(replies.front()); replies.pop_front(); return true;
    }
};
std::mutex jobsMutex;
std::unordered_map<std::string, Job *> jobs;
bool Read(napi_env env, napi_value value, size_t limit, std::string &out) {
    size_t size = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &size) != napi_ok || size > limit) { return false; }
    out.resize(size + 1);
    if (napi_get_value_string_utf8(env, value, &out[0], out.size(), &size) != napi_ok) { return false; }
    out.resize(size); return true;
}
void Reply(const std::string &id, tinybot::ToolReply reply) {
    std::lock_guard<std::mutex> lock(jobsMutex);
    auto found = jobs.find(id);
    if (found == jobs.end()) { return; } // Late results never revive a finished execution.
    auto &job = *found->second;
    std::lock_guard<std::mutex> queueLock(job.mutex);
    if (job.replies.size() >= 32) { job.budget.cancelled.store(true); }
    else { job.replies.push_back(std::move(reply)); }
    job.ready.notify_one();
}
void CallJs(napi_env env, napi_value callback, void *, void *data) {
    std::unique_ptr<Invocation> request(static_cast<Invocation *>(data));
    if (!env || !callback) { return; }
    {
        std::lock_guard<std::mutex> lock(jobsMutex);
        auto found = jobs.find(request->job);
        if (found == jobs.end() || found->second->budget.cancelled.load()) { return; }
    }
    napi_value args[3], receiver, result;
    if (napi_create_int32(env, request->id, &args[0]) != napi_ok ||
        napi_create_string_utf8(env, request->name.c_str(), request->name.size(), &args[1]) != napi_ok ||
        napi_create_string_utf8(env, request->arguments.c_str(), request->arguments.size(), &args[2]) != napi_ok ||
        napi_get_undefined(env, &receiver) != napi_ok ||
        napi_call_function(env, receiver, callback, 3, args, &result) != napi_ok) {
        bool pending = false; napi_is_exception_pending(env, &pending);
        if (pending) { napi_get_and_clear_last_exception(env, &result); }
        Reply(request->job, {request->id, "Host tool callback failed", true});
    }
}
void Execute(napi_env, void *data) {
    auto &job = *static_cast<Job *>(data);
    try { job.output = tinybot::Orchestrate(job.source, job.catalog, job.budget, job).ToJson(); }
    catch (...) { job.output.clear(); }
    napi_release_threadsafe_function(job.callback, napi_tsfn_release);
}
void Complete(napi_env env, napi_status status, void *data) {
    std::unique_ptr<Job> job(static_cast<Job *>(data));
    { std::lock_guard<std::mutex> lock(jobsMutex); jobs.erase(job->id); }
    napi_value result;
    if (status == napi_ok && !job->output.empty() &&
        napi_create_string_utf8(env, job->output.c_str(), job->output.size(), &result) == napi_ok) {
        napi_resolve_deferred(env, job->deferred, result);
    } else {
        napi_value message; napi_create_string_utf8(env, "Native orchestration failed", NAPI_AUTO_LENGTH, &message);
        napi_create_error(env, nullptr, message, &result); napi_reject_deferred(env, job->deferred, result);
    }
    napi_delete_async_work(env, job->work);
}
napi_value Start(napi_env env, napi_callback_info info) {
    napi_value args[5]; size_t argc = 5;
    auto job = std::make_unique<Job>(); napi_valuetype callbackType;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 4 ||
        !Read(env, args[0], 128, job->id) || job->id.empty() || !Read(env, args[1], 96 * 1024, job->source) || job->source.empty() ||
        !Read(env, args[2], 256 * 1024, job->catalog) || napi_typeof(env, args[3], &callbackType) != napi_ok || callbackType != napi_function) {
        napi_throw_type_error(env, nullptr, "Expected execution id, code, catalog and callback"); return nullptr;
    }
    { std::lock_guard<std::mutex> lock(jobsMutex);
      if (jobs.size() >= 4 || jobs.count(job->id)) { napi_throw_error(env, nullptr, "Orchestrator busy (maximum 4 executions)"); return nullptr; }
      jobs[job->id] = job.get(); }
    napi_value promise, name;
    if (napi_create_promise(env, &job->deferred, &promise) != napi_ok ||
        napi_create_string_utf8(env, "TinybotOrchestrator", NAPI_AUTO_LENGTH, &name) != napi_ok ||
        napi_create_threadsafe_function(env, args[3], nullptr, name, 32, 1, nullptr, nullptr, nullptr, CallJs, &job->callback) != napi_ok ||
        napi_create_async_work(env, nullptr, name, Execute, Complete, job.get(), &job->work) != napi_ok ||
        napi_queue_async_work(env, job->work) != napi_ok) {
        if (job->callback) { napi_release_threadsafe_function(job->callback, napi_tsfn_abort); }
        if (job->work) { napi_delete_async_work(env, job->work); }
        { std::lock_guard<std::mutex> lock(jobsMutex); jobs.erase(job->id); }
        napi_throw_error(env, nullptr, "Cannot start orchestrator"); return nullptr;
    }
    job.release(); return promise;
}
napi_value Settle(napi_env env, napi_callback_info info) {
    napi_value args[5], result; size_t argc = 5; std::string id; tinybot::ToolReply reply;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 4 ||
        !Read(env, args[0], 128, id) || napi_get_value_int32(env, args[1], &reply.id) != napi_ok ||
        !Read(env, args[2], 1024 * 1024, reply.value) || napi_get_value_bool(env, args[3], &reply.error) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Invalid orchestration reply"); return nullptr;
    }
    Reply(id, std::move(reply)); napi_get_undefined(env, &result); return result;
}
napi_value Cancel(napi_env env, napi_callback_info info) {
    napi_value args[2], result; size_t argc = 2; std::string id;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1 || !Read(env, args[0], 128, id)) {
        napi_throw_type_error(env, nullptr, "Expected orchestration id"); return nullptr;
    }
    { std::lock_guard<std::mutex> lock(jobsMutex); auto found = jobs.find(id);
      if (found != jobs.end()) { found->second->budget.cancelled.store(true); found->second->ready.notify_one(); } }
    napi_get_undefined(env, &result); return result;
}
}
void InstallOrchestrator(napi_env env, napi_value exports) {
    napi_property_descriptor methods[] = {
        {"orchestrate", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"settle", nullptr, Settle, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelOrchestration", nullptr, Cancel, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, 3, methods);
}
