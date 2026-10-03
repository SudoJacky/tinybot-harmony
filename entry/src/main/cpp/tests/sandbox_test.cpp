#include "sandbox.h"
#include <cstdlib>
#include <iostream>
#include <pthread.h>

using namespace tinybot;
void Check(bool condition, const char *name)
{
    if (!condition) { std::cerr << "FAIL " << name << std::endl; std::exit(1); }
    std::cout << "PASS " << name << std::endl;
}
ExecutionResult Run(const std::string &code, const std::string &input = "null")
{
    Budget budget;
    return ExecuteCode(code, input, budget);
}
int main()
{
    auto result = Run("console.log('hello', input.label); console.warn('warn'); return {sum: input.values.reduce((a,b)=>a+b,0)};",
        "{\"label\":\"world\",\"values\":[2,3,5]}");
    Check(result.status == "ok" && result.resultJson == "{\"sum\":10}" && result.stdoutText == "hello world\n" &&
        result.stderrText == "warn\n", "input, result and console streams");
    Check(Run("globalThis.secret = 42; return 1;").status == "ok" &&
        Run("return typeof secret;").resultJson == "\"undefined\"", "fresh runtime per call");
    Check(Run("return [typeof fetch, typeof require, typeof process, typeof std, typeof os, typeof setTimeout];").resultJson ==
        "[\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\",\"undefined\"]", "no host capabilities");
    Check(Run("return (").status == "error", "syntax error");
    Check(Run("return input;", "invalid").status == "error", "invalid input JSON");
    Check(Run("const x={}; x.x=x; return x;").status == "error", "circular result");
    Check(Run("return 1n;").status == "error", "non JSON result");
    Check(Run("return Promise.resolve(1);").status == "unsupported_async", "promise result rejected");
    Check(Run("Promise.resolve().then(()=>{while(true){}}); return 1;").status == "unsupported_async", "pending jobs rejected without running");
    Check(Run("return import('std');").status == "unsupported_async", "module import unavailable");
    result = Run("for(let i=0;i<20000;i++){console.log('中文🙂');console.error('error');}return 7;");
    Check(result.status == "ok" && result.resultJson == "7" && result.logsTruncated &&
        result.stdoutText.size() + result.stderrText.size() <= MAX_LOG_BYTES, "combined UTF-8 log flood bounded");
    Check(Run("return '\"' + '\\n' + '\\\\';").ToJson().find("\"status\":\"ok\"") != std::string::npos, "escaped output envelope");
    result = Run("return 'x'.repeat(20000);");
    Check(result.status == "output_limit" && result.resultJson == "null" && result.resultTruncated, "oversized result discarded");
    result = Run("const data=[]; while(true){data.push(new Uint8Array(1024*1024));}");
    Check(result.status == "memory_limit", "allocation limit");
    Check(Run("try { new ArrayBuffer(128*1024*1024); } catch(e) {} return 1;").status == "memory_limit", "caught OOM remains terminal");
    result = Run("function recurse(){return recurse()+1;}return recurse();");
    Check(result.status == "error", "stack overflow contained");
    result = Run("Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);");
    Check(result.status == "error" && result.durationMs < 1500, "Atomics.wait cannot block");
    result = Run("while(true){}");
    Check(result.status == "timeout" && result.durationMs < 5000, "infinite loop interrupted");
    result = Run("return {toJSON(){while(true){}}};");
    Check(result.status == "timeout" && result.durationMs < 5000, "serialization shares deadline");
    result = Run("throw {toString(){while(true){}}};");
    Check(result.status == "timeout" && result.durationMs < 5000, "error coercion shares deadline");
    Budget cancelled;
    pthread_t stop;
    Check(pthread_create(&stop, nullptr, [](void *data) -> void * {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(40);
        while (std::chrono::steady_clock::now() < deadline) {}
        static_cast<Budget *>(data)->cancelled.store(true);
        return nullptr;
    }, &cancelled) == 0, "cancellation thread created");
    result = ExecuteCode("while(true){}", "null", cancelled);
    pthread_join(stop, nullptr);
    Check(result.status == "cancelled" && result.durationMs < 1500, "cross-thread cancellation");
    Budget early; early.cancelled.store(true);
    Check(ExecuteCode("while(true){}", "null", early).status == "cancelled", "cancellation before worker starts");
    Budget expired; expired.started -= std::chrono::seconds(3);
    Check(ExecuteCode("return 1;", "null", expired).status == "timeout", "queue delay consumes budget");
    Check(Run(std::string(MAX_SOURCE_BYTES + 1, ' ')).status == "error", "native source limit");
    Check(Run("return input;", std::string(MAX_INPUT_BYTES + 1, ' ')).status == "error", "native input limit");
    for (int i = 0; i < 100; i++) {
        result = Run("return 42;");
        if (result.status != "ok" || result.resultJson != "42") { Check(false, "recovery after failures"); }
    }
    Check(true, "100 fresh executions after failures");
}
