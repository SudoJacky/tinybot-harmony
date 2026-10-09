#include "sandbox.h"
#include "quickjs.h"
#include <algorithm>
#include <cstdlib>
#include <limits>

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

ExecutionResult ExecuteCode(const std::string &source, const std::string &inputJson, Budget &budget)
{
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
            if (ctx) { Run(ctx, source, inputJson, result); JS_FreeContext(ctx); }
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
    result.durationMs = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - budget.started).count();
    return result;
}

std::string ExecutionResult::ToJson() const
{
    return "{\"status\":" + Quote(status) + ",\"stdout\":" + Quote(stdoutText) +
        ",\"stderr\":" + Quote(stderrText) + ",\"result\":" + resultJson +
        ",\"error\":" + Quote(error) + ",\"logsTruncated\":" + (logsTruncated ? "true" : "false") +
        ",\"resultTruncated\":" + (resultTruncated ? "true" : "false") +
        ",\"durationMs\":" + std::to_string(durationMs) + "}";
}
}
