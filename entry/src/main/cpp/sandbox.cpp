#include "sandbox.h"
#include "orchestration_helpers.h"
#include "quickjs.h"
#include <algorithm>
#include <cstdlib>
#include <limits>
#include <stdexcept>

namespace tinybot {
namespace {
// Count requested allocations, including our headers, and latch allocation failures even if
// JavaScript catches the resulting exception. Allocator bookkeeping outside these blocks is
// not a process RSS limit.
struct alignas(std::max_align_t) Allocation { size_t size; };
void *Allocate(JSMallocState *state, size_t size)
{
    auto &budget = *static_cast<Budget *>(state->opaque);
    const size_t limit = std::min(state->malloc_limit, MEMORY_BYTES);
    if (size > limit || sizeof(Allocation) > limit - size ||
        state->malloc_size > limit - size - sizeof(Allocation)) {
        budget.memoryExceeded = true;
        return nullptr;
    }
    auto *block = static_cast<Allocation *>(std::malloc(sizeof(Allocation) + size));
    if (!block) { budget.memoryExceeded = true; return nullptr; }
    block->size = size;
    state->malloc_size += sizeof(Allocation) + size;
    state->malloc_count++;
    return block + 1;
}
void Free(JSMallocState *state, void *ptr)
{
    if (!ptr) { return; }
    auto *block = static_cast<Allocation *>(ptr) - 1;
    state->malloc_size -= sizeof(Allocation) + block->size;
    state->malloc_count--;
    std::free(block);
}
size_t UsableSize(const void *ptr)
{
    return ptr ? (static_cast<const Allocation *>(ptr) - 1)->size : 0;
}
void *Reallocate(JSMallocState *state, void *ptr, size_t size)
{
    if (!ptr) { return Allocate(state, size); }
    if (!size) { Free(state, ptr); return nullptr; }
    auto *block = static_cast<Allocation *>(ptr) - 1;
    const size_t oldSize = block->size;
    const size_t limit = std::min(state->malloc_limit, MEMORY_BYTES);
    if (size > limit || state->malloc_size - oldSize > limit - size) {
        static_cast<Budget *>(state->opaque)->memoryExceeded = true;
        return nullptr;
    }
    block = static_cast<Allocation *>(std::realloc(block, sizeof(Allocation) + size));
    if (!block) { static_cast<Budget *>(state->opaque)->memoryExceeded = true; return nullptr; }
    block->size = size;
    state->malloc_size = state->malloc_size - oldSize + size;
    return block + 1;
}
int Interrupt(JSRuntime *, void *opaque)
{
    auto &budget = *static_cast<Budget *>(opaque);
    if (std::chrono::steady_clock::now() - budget.started >= std::chrono::milliseconds(TIMEOUT_MS)) {
        budget.timedOut = true;
    }
    return budget.cancelled.load(std::memory_order_relaxed) || budget.timedOut || budget.memoryExceeded;
}
size_t Utf8Prefix(const char *text, size_t length, size_t limit)
{
    size_t end = std::min(length, limit);
    if (end < length) {
        while (end && (static_cast<unsigned char>(text[end]) & 0xc0) == 0x80) { end--; }
    }
    return end;
}
void AppendLog(ExecutionResult &result, std::string &target, const char *text, size_t length)
{
    const size_t remaining = MAX_LOG_BYTES - result.stdoutText.size() - result.stderrText.size();
    const size_t count = Utf8Prefix(text, length, remaining);
    target.append(text, count);
    result.logsTruncated = result.logsTruncated || count < length;
}
JSValue Log(JSContext *ctx, JSValueConst, int argc, JSValueConst *argv, int stream)
{
    auto &result = *static_cast<ExecutionResult *>(JS_GetContextOpaque(ctx));
    auto &target = stream ? result.stderrText : result.stdoutText;
    for (int i = 0; i < argc; i++) {
        if (result.stdoutText.size() + result.stderrText.size() >= MAX_LOG_BYTES) {
            result.logsTruncated = true;
            break;
        }
        if (i) { AppendLog(result, target, " ", 1); }
        size_t length = 0;
        const char *text = JS_ToCStringLen(ctx, &length, argv[i]);
        if (!text) { return JS_EXCEPTION; }
        AppendLog(result, target, text, length);
        JS_FreeCString(ctx, text);
    }
    AppendLog(result, target, "\n", 1);
    return JS_UNDEFINED;
}
void CaptureError(JSContext *ctx, ExecutionResult &result)
{
    result.status = "error";
    JSValue exception = JS_GetException(ctx);
    size_t length = 0;
    // Coercion can execute user code, so the same interrupt and memory budget remain installed.
    const char *text = JS_ToCStringLen(ctx, &length, exception);
    result.error = text ? std::string(text, Utf8Prefix(text, length, 4096)) : "JavaScript execution failed";
    if (text) { JS_FreeCString(ctx, text); }
    JS_FreeValue(ctx, exception);
}
bool InstallConsole(JSContext *ctx, ExecutionResult &result)
{
    JS_SetContextOpaque(ctx, &result);
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue console = JS_NewObject(ctx);
    const char *names[] = {"log", "info", "warn", "error"};
    bool ok = !JS_IsException(console);
    for (int i = 0; ok && i < 4; i++) {
        ok = JS_SetPropertyStr(ctx, console, names[i],
            JS_NewCFunctionMagic(ctx, Log, names[i], 1, JS_CFUNC_generic_magic, i >= 2)) >= 0;
    }
    if (ok) { ok = JS_SetPropertyStr(ctx, global, "console", console) >= 0; }
    else { JS_FreeValue(ctx, console); }
    JS_FreeValue(ctx, global);
    return ok;
}
void Run(JSContext *ctx, const std::string &source, const std::string &inputJson, ExecutionResult &result)
{
    if (!InstallConsole(ctx, result)) { CaptureError(ctx, result); return; }
    JSValue input = JS_ParseJSON(ctx, inputJson.c_str(), inputJson.size(), "input.json");
    if (JS_IsException(input)) { CaptureError(ctx, result); return; }
    const std::string wrapped = "(function(input) {\n'use strict';\n" + source + "\n})";
    JSValue function = JS_Eval(ctx, wrapped.c_str(), wrapped.size(), "execute_code.js", JS_EVAL_TYPE_GLOBAL);
    JSValue value = JS_IsException(function) ? JS_EXCEPTION : JS_Call(ctx, function, JS_UNDEFINED, 1, &input);
    JS_FreeValue(ctx, function);
    JS_FreeValue(ctx, input);
    if (JS_IsException(value)) { CaptureError(ctx, result); return; }
    if (JS_PromiseState(ctx, value) >= 0 || JS_IsJobPending(JS_GetRuntime(ctx))) {
        result.status = "unsupported_async";
        result.error = "Only synchronous code is supported; promises and queued jobs are not executed";
    } else if (!JS_IsUndefined(value)) {
        JSValue json = JS_JSONStringify(ctx, value, JS_UNDEFINED, JS_UNDEFINED);
        if (JS_IsException(json)) { CaptureError(ctx, result); }
        else if (JS_IsUndefined(json)) {
            result.status = "error"; result.error = "Return a JSON-serializable value";
        } else {
            size_t length = 0;
            const char *text = JS_ToCStringLen(ctx, &length, json);
            if (!text) { CaptureError(ctx, result); }
            else {
                result.resultJson.assign(text, length);
                JS_FreeCString(ctx, text);
            }
        }
        JS_FreeValue(ctx, json);
    }
    JS_FreeValue(ctx, value);
    if (result.status == "ok" && JS_IsJobPending(JS_GetRuntime(ctx))) {
        result.status = "unsupported_async";
        result.error = "Result serialization queued asynchronous work";
    }
}
struct PendingTool { int id; JSValue resolve; JSValue reject; };
struct AsyncState {
    ToolHost &host;
    std::vector<std::string> names;
    std::vector<PendingTool> pending;
    std::vector<JSValue> rejected;
    int calls = 0;
    bool accepting = true;
};
void TrackRejection(JSContext *ctx, JSValueConst promise, JSValueConst, JS_BOOL handled, void *opaque)
{
    auto &state = *static_cast<AsyncState *>(opaque);
    auto found = std::find_if(state.rejected.begin(), state.rejected.end(), [&](JSValue value) {
        return JS_VALUE_GET_PTR(value) == JS_VALUE_GET_PTR(promise);
    });
    if (handled && found != state.rejected.end()) { JS_FreeValue(ctx, *found); state.rejected.erase(found); }
    else if (!handled && found == state.rejected.end()) { state.rejected.push_back(JS_DupValue(ctx, promise)); }
}
JSValue InvokeTool(JSContext *ctx, JSValueConst, int argc, JSValueConst *argv, int index)
{
    auto &state = *static_cast<AsyncState *>(JS_GetRuntimeOpaque(JS_GetRuntime(ctx)));
    if (!state.accepting || state.calls >= 32) { return JS_ThrowInternalError(ctx, "Tool dispatch closed or 32-call budget exceeded"); }
    if (argc != 1 || !JS_IsObject(argv[0]) || JS_IsArray(ctx, argv[0])) {
        return JS_ThrowTypeError(ctx, "Pass one tool arguments object");
    }
    JSValue json = JS_JSONStringify(ctx, argv[0], JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json)) { return json; }
    size_t size = 0;
    const char *raw = JS_ToCStringLen(ctx, &size, json);
    if (!raw) { JS_FreeValue(ctx, json); return JS_EXCEPTION; }
    std::string arguments(raw, size);
    JS_FreeCString(ctx, raw); JS_FreeValue(ctx, json);
    if (size > 96 * 1024) { return JS_ThrowRangeError(ctx, "Tool arguments exceed 96 KiB"); }
    JSValue resolving[2];
    JSValue promise = JS_NewPromiseCapability(ctx, resolving);
    if (JS_IsException(promise)) { return promise; }
    const int id = ++state.calls;
    state.pending.push_back({id, resolving[0], resolving[1]});
    try { state.host.Submit(id, state.names.at(index), arguments); }
    catch (const std::exception &error) {
        state.pending.pop_back(); JS_FreeValue(ctx, resolving[0]); JS_FreeValue(ctx, resolving[1]); JS_FreeValue(ctx, promise);
        return JS_ThrowInternalError(ctx, "%s", error.what());
    }
    return promise;
}
void RunAsync(JSContext *ctx, const std::string &source, const std::string &catalogJson,
    Budget &budget, ToolHost &host, ExecutionResult &result)
{
    AsyncState state{host, {}, {}, {}, 0, true};
    JSRuntime *runtime = JS_GetRuntime(ctx);
    JS_SetRuntimeOpaque(runtime, &state);
    JS_SetHostPromiseRejectionTracker(runtime, TrackRejection, &state);
    JSValue root = JS_UNDEFINED;
    const auto wallStart = std::chrono::steady_clock::now();
    do {
        if (!InstallConsole(ctx, result)) { CaptureError(ctx, result); break; }
        JSValue catalog = JS_ParseJSON(ctx, catalogJson.c_str(), catalogJson.size(), "tools.json");
        if (JS_IsException(catalog)) { CaptureError(ctx, result); break; }
        JSValue lengthValue = JS_GetPropertyStr(ctx, catalog, "length");
        uint32_t length = 0; JS_ToUint32(ctx, &length, lengthValue); JS_FreeValue(ctx, lengthValue);
        JSValue tools = JS_NewObjectProto(ctx, JS_NULL);
        bool valid = JS_IsArray(ctx, catalog) && length <= 64;
        for (uint32_t i = 0; valid && i < length; i++) {
            JSValue item = JS_GetPropertyUint32(ctx, catalog, i);
            JSValue nameValue = JS_GetPropertyStr(ctx, item, "name");
            const char *name = JS_ToCString(ctx, nameValue);
            valid = name && name[0];
            if (valid) {
                state.names.emplace_back(name);
                valid = JS_SetPropertyStr(ctx, tools, name, JS_NewCFunctionMagic(ctx, InvokeTool, name, 1, JS_CFUNC_generic_magic, i)) >= 0;
            }
            if (name) { JS_FreeCString(ctx, name); }
            JS_FreeValue(ctx, nameValue); JS_FreeValue(ctx, item);
        }
        JSValue global = JS_GetGlobalObject(ctx);
        int toolsSet = JS_SetPropertyStr(ctx, global, "tools", tools);
        int catalogSet = JS_SetPropertyStr(ctx, global, "ALL_TOOLS", catalog);
        JS_FreeValue(ctx, global);
        if (!valid || toolsSet < 0 || catalogSet < 0) { result.status = "error"; result.error = "Invalid tool catalog"; break; }
        JSValue helpers = JS_Eval(ctx, ORCHESTRATION_HELPERS, sizeof(ORCHESTRATION_HELPERS) - 1,
            "orchestration_helpers.js", JS_EVAL_TYPE_GLOBAL);
        if (JS_IsException(helpers)) { CaptureError(ctx, result); break; }
        JS_FreeValue(ctx, helpers);
        const std::string wrapped = "(async function() {\n'use strict';\n" + source + "\n})()";
        root = JS_Eval(ctx, wrapped.c_str(), wrapped.size(), "orchestrate.js", JS_EVAL_TYPE_GLOBAL);
        if (JS_IsException(root)) { CaptureError(ctx, result); break; }
        while (!Interrupt(runtime, &budget)) {
            if (std::chrono::steady_clock::now() - wallStart >= std::chrono::seconds(120)) {
                result.status = "timeout"; result.error = "Orchestration exceeded 120 seconds"; break;
            }
            if (JS_IsJobPending(runtime)) {
                JSContext *jobContext = nullptr;
                if (JS_ExecutePendingJob(runtime, &jobContext) < 0) { CaptureError(jobContext ? jobContext : ctx, result); break; }
                continue;
            }
            const int status = JS_PromiseState(ctx, root);
            if (status == JS_PROMISE_REJECTED) {
                JS_Throw(ctx, JS_PromiseResult(ctx, root)); CaptureError(ctx, result); break;
            }
            if (status == JS_PROMISE_FULFILLED) {
                if (!state.pending.empty()) { result.status = "error"; result.error = "Await every tool call before returning"; break; }
                if (!state.rejected.empty()) {
                    JS_Throw(ctx, JS_PromiseResult(ctx, state.rejected.front())); CaptureError(ctx, result); break;
                }
                state.accepting = false;
                JSValue value = JS_PromiseResult(ctx, root);
                JSValue json = JS_IsUndefined(value) ? JS_NULL : JS_JSONStringify(ctx, value, JS_UNDEFINED, JS_UNDEFINED);
                JS_FreeValue(ctx, value);
                if (JS_IsException(json)) { CaptureError(ctx, result); }
                else if (JS_IsUndefined(json)) { result.status = "error"; result.error = "Return a JSON-serializable value"; }
                else if (!JS_IsNull(json)) {
                    size_t size = 0; const char *raw = JS_ToCStringLen(ctx, &size, json);
                    if (!raw) { CaptureError(ctx, result); }
                    else if (size > 1024 * 1024) { result.status = "error"; result.error = "Result exceeds 1 MiB"; }
                    else { result.resultJson.assign(raw, size); }
                    if (raw) { JS_FreeCString(ctx, raw); }
                }
                JS_FreeValue(ctx, json);
                if (JS_IsJobPending(runtime)) { result.status = "error"; result.error = "Result serialization must not schedule async work"; }
                break;
            }
            if (state.pending.empty()) { result.status = "error"; result.error = "Unresolved promise has no pending host tool"; break; }
            ToolReply reply;
            const auto waitStart = std::chrono::steady_clock::now();
            const bool received = host.Wait(reply);
            budget.started += std::chrono::steady_clock::now() - waitStart; // I/O wait is not script execution time.
            if (!received) { continue; }
            auto pending = std::find_if(state.pending.begin(), state.pending.end(), [&](const PendingTool &item) { return item.id == reply.id; });
            if (pending == state.pending.end()) { result.status = "error"; result.error = "Unknown tool response"; break; }
            JSValue value;
            if (reply.value.size() > 1024 * 1024) { reply.error = true; reply.value = "Tool result exceeds 1 MiB; read a smaller range"; }
            if (reply.error) {
                value = JS_NewError(ctx);
                JS_SetPropertyStr(ctx, value, "message", JS_NewStringLen(ctx, reply.value.data(), reply.value.size()));
            } else {
                value = JS_ParseJSON(ctx, reply.value.c_str(), reply.value.size(), "tool-result.json");
                if (JS_IsException(value)) {
                    JS_FreeValue(ctx, JS_GetException(ctx));
                    value = JS_NewStringLen(ctx, reply.value.data(), reply.value.size());
                }
            }
            JSValue settled = JS_Call(ctx, reply.error ? pending->reject : pending->resolve, JS_UNDEFINED, 1, &value);
            JS_FreeValue(ctx, value); JS_FreeValue(ctx, pending->resolve); JS_FreeValue(ctx, pending->reject);
            state.pending.erase(pending);
            if (JS_IsException(settled)) { CaptureError(ctx, result); break; }
            JS_FreeValue(ctx, settled);
        }
    } while (false);
    JS_SetHostPromiseRejectionTracker(runtime, nullptr, nullptr);
    for (auto &pending : state.pending) { JS_FreeValue(ctx, pending.resolve); JS_FreeValue(ctx, pending.reject); }
    for (auto value : state.rejected) { JS_FreeValue(ctx, value); }
    JS_FreeValue(ctx, root);
    JS_SetRuntimeOpaque(runtime, nullptr);
}
std::string Quote(const std::string &text)
{
    const char hex[] = "0123456789abcdef";
    std::string out = "\"";
    for (unsigned char c : text) {
        if (c == '"' || c == '\\') { out += '\\'; out += c; }
        else if (c < 32) { out += "\\u00"; out += hex[c >> 4]; out += hex[c & 15]; }
        else { out += c; }
    }
    return out + '"';
}
}

ExecutionResult Execute(const std::string &source, const std::string &inputJson, Budget &budget, ToolHost *host)
{
    const auto wallStart = budget.started;
    ExecutionResult result;
    if (source.empty()) {
        result.status = "error"; result.error = "Source is required";
    } else if (!Interrupt(nullptr, &budget)) {
        const JSMallocFunctions allocator = {Allocate, Free, Reallocate, UsableSize};
        JSRuntime *runtime = JS_NewRuntime2(&allocator, &budget);
        if (runtime) {
            JS_SetMemoryLimit(runtime, MEMORY_BYTES);
            JS_SetMaxStackSize(runtime, 512 * 1024);
            JS_SetCanBlock(runtime, false); // Atomics.wait must never block the worker.
            JS_SetInterruptHandler(runtime, Interrupt, &budget);
            JSContext *ctx = JS_NewContext(runtime);
            if (ctx) {
                if (host) { RunAsync(ctx, source, inputJson, budget, *host, result); }
                else { Run(ctx, source, inputJson, result); }
                JS_FreeContext(ctx);
            }
            else { result.status = "error"; result.error = "Cannot create JavaScript context"; }
            // No standard library, module loader, native handles or pending-job pump is installed.
            JS_FreeRuntime(runtime);
        } else { result.status = "error"; result.error = "Cannot create JavaScript runtime"; }
    }
    Interrupt(nullptr, &budget);
    if (budget.cancelled.load(std::memory_order_relaxed)) { result.status = "cancelled"; result.error = "Execution cancelled"; }
    else if (budget.timedOut) { result.status = "timeout"; result.error = "Execution exceeded 2000 ms"; }
    else if (budget.memoryExceeded) { result.status = "memory_limit"; result.error = "Runtime allocation limit exceeded"; }
    if (result.status != "ok") { result.resultJson = "null"; }
    result.durationMs = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - wallStart).count();
    return result;
}

ExecutionResult ExecuteCode(const std::string &source, const std::string &inputJson, Budget &budget)
{ return Execute(source, inputJson, budget, nullptr); }
ExecutionResult Orchestrate(const std::string &source, const std::string &catalogJson, Budget &budget, ToolHost &host)
{ return Execute(source, catalogJson, budget, &host); }

std::string ExecutionResult::ToJson() const
{
    return "{\"status\":" + Quote(status) + ",\"stdout\":" + Quote(stdoutText) +
        ",\"stderr\":" + Quote(stderrText) + ",\"result\":" + resultJson +
        ",\"error\":" + Quote(error) + ",\"logsTruncated\":" + (logsTruncated ? "true" : "false") +
        ",\"resultTruncated\":" + (resultTruncated ? "true" : "false") +
        ",\"durationMs\":" + std::to_string(durationMs) + "}";
}
}
