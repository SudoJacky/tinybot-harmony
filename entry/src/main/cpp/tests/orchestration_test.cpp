#include "sandbox.h"
#include <cstdlib>
#include <deque>
#include <iostream>
#include <thread>

using namespace tinybot;
void Check(bool ok, const char *name) {
    if (!ok) { std::cerr << "FAIL " << name << std::endl; std::exit(1); }
    std::cout << "PASS " << name << std::endl;
}
struct Host : ToolHost {
    int count = 0;
    int maxQueued = 0;
    int waitMs = 0;
    bool reverseReplies = false;
    std::deque<ToolReply> replies;
    void Submit(int id, const std::string &name, const std::string &arguments) override {
        count++;
        replies.push_back({id, name == "fail" ? "permission denied" : (arguments == "{}" ? "7" : arguments), name == "fail"});
        maxQueued = std::max(maxQueued, static_cast<int>(replies.size()));
    }
    bool Wait(ToolReply &reply) override {
        if (waitMs > 0) { std::this_thread::sleep_for(std::chrono::milliseconds(25)); waitMs -= 25; return false; }
        if (replies.empty()) { return false; }
        if (reverseReplies) { reply = replies.back(); replies.pop_back(); }
        else { reply = replies.front(); replies.pop_front(); }
        return true;
    }
};
ExecutionResult Run(const std::string &source, Host &host) {
    Budget budget;
    return Orchestrate(source, R"([{"name":"read"},{"name":"fail"}])", budget, host);
}
int main() {
    Host host;
    auto result = Run("const a = await tools.read({}); return a + await tools.read({});", host);
    Check(result.status == "ok" && result.resultJson == "14" && host.count == 2, "dependent async tools");
    Host parallel;
    result = Run("return await Promise.all([tools.read({n:1}),tools.read({n:2})]);", parallel);
    Check(result.status == "ok" && result.resultJson == "[{\"n\":1},{\"n\":2}]" && parallel.maxQueued == 2, "parallel tool dispatch and JSON results");
    Host failures;
    result = Run("return (await Promise.allSettled([tools.read({}),tools.fail({})])).map(x=>x.status);", failures);
    Check(result.status == "ok" && result.resultJson == "[\"fulfilled\",\"rejected\"]", "explicit partial failure");
    Host completion; completion.reverseReplies = true;
    result = Run(R"(
        const outcomes = [];
        for await (const r of as_settled([tools.read({n:1}), tools.read({n:2})])) {
            outcomes.push([r.index, r.value.n]);
        }
        return outcomes;
    )", completion);
    Check(result.status == "ok" && result.resultJson == "[[1,2],[0,1]]", "as_settled uses host completion order");
    Host keyed;
    result = Run(R"(
        const results = [];
        await stream_settled(new Map([['good', tools.read({})], ['bad', tools.fail({})]]), async r => {
            const extra = await tools.read({});
            results.push([r.index, r.status, r.status === 'fulfilled' ? r.value + extra : String(r.reason)]);
        });
        return results;
    )", keyed);
    Check(result.status == "ok" && result.resultJson == "[[\"good\",\"fulfilled\",14],[\"bad\",\"rejected\",\"Error: permission denied\"]]",
        "stream_settled preserves Map keys and awaits callbacks with nested tools");
    Host pure;
    result = Run(R"(
        const results = [];
        await stream_settled([], () => { throw Error('empty callback'); });
        await stream_settled([3, Promise.reject('bad'), Promise.resolve(5)], r => {
            results.push([r.index, r.status, r.status === 'fulfilled' ? r.value : r.reason]);
        });
        return results;
    )", pure);
    Check(result.status == "ok" && result.resultJson == "[[0,\"fulfilled\",3],[1,\"rejected\",\"bad\"],[2,\"fulfilled\",5]]",
        "settled helpers support empty inputs, values and already settled promises");
    result = Run("await stream_settled([1], async () => { throw Error('callback failed'); });", pure);
    Check(result.status == "error" && result.error.find("callback failed") != std::string::npos, "callback errors propagate");
    result = Run("await stream_settled([], 1);", pure);
    Check(result.status == "error" && result.error.find("requires a callback") != std::string::npos, "invalid stream callback rejected");
    result = Run("for await (const r of as_settled(null)) {}", pure);
    Check(result.status == "error", "non iterable input rejected");
    result = Run("text('hello'); text({total:42}); text(undefined); return 42;", pure);
    Check(result.status == "ok" && result.stdoutText == "hello\n{\"total\":42}\nundefined\n" && result.resultJson == "42",
        "text records strings and JSON without replacing return result");
    result = Run("text('x'.repeat(40000)); return 1;", pure);
    Check(result.status == "ok" && result.logsTruncated && result.stdoutText.size() == MAX_LOG_BYTES,
        "text shares bounded console output");
    result = Run("const x = {}; x.self = x; text(x);", pure);
    Check(result.status == "error", "text serialization errors propagate");
    Host early;
    result = Run("for await (const r of as_settled([tools.read({}),tools.read({})])) break; return 1;", early);
    Check(result.status == "error" && result.error.find("Await every") != std::string::npos,
        "early iterator exit cannot hide pending host work");
    Host drained;
    result = Run("const jobs = [tools.read({}),tools.read({})]; for await (const r of as_settled(jobs)) break; return await Promise.all(jobs);", drained);
    Check(result.status == "ok" && result.resultJson == "[7,7]", "iterator close does not cancel jobs and caller can drain them");
    Host rejected;
    result = Run("await tools.fail({}); return 1;", rejected);
    Check(result.status == "error" && result.error.find("permission denied") != std::string::npos, "uncaught tool error");
    Host forgotten;
    result = Run("tools.read({}); return 1;", forgotten);
    Check(result.status == "error" && result.error.find("Await every") != std::string::npos, "unawaited host operation rejected");
    Host delayed; delayed.waitMs = 2100;
    result = Run("return await tools.read({});", delayed);
    Check(result.status == "ok" && result.durationMs >= 2100, "host wait excluded from computation budget");
    Host loops;
    result = Run("await tools.read({}); while(true) {}", loops);
    Check(result.status == "timeout", "infinite loop after await interrupted");
    Host jobs;
    result = Run("while(true) { await Promise.resolve(); }", jobs);
    Check(result.status == "timeout", "infinite microtasks interrupted");
    Host noHost;
    result = Run("return [typeof fetch,typeof require,typeof setTimeout,typeof tools.missing];", noHost);
    Check(result.status == "ok" && result.resultJson == "[\"undefined\",\"undefined\",\"undefined\",\"undefined\"]", "no ambient host capabilities");
    result = Run("return await new Promise(()=>{});", noHost);
    Check(result.status == "error", "unresolvable promise fails without hanging");
    result = Run("Promise.reject(new Error('lost')); return 1;", noHost);
    Check(result.status == "error" && result.error.find("lost") != std::string::npos, "unhandled rejection is not hidden");
    Host budget;
    result = Run("for(let i=0;i<33;i++) await tools.read({}); return 1;", budget);
    Check(result.status == "error" && budget.count == 32, "nested call budget");
    Host cancelled; cancelled.waitMs = 1000; Budget signal;
    std::thread stop([&] { std::this_thread::sleep_for(std::chrono::milliseconds(60)); signal.cancelled.store(true); });
    result = Orchestrate("return await tools.read({});", R"([{"name":"read"}])", signal, cancelled); stop.join();
    Check(result.status == "cancelled" && result.durationMs < 500, "cancel while host tool pending");
    Host serialization;
    result = Run("return {toJSON(){tools.read({}); return 1;}};", serialization);
    Check(result.status == "error" && serialization.count == 0, "serialization cannot start host effects");
    Host recovery;
    for (int i = 0; i < 100; i++) { result = Run("return await tools.read({});", recovery); Check(result.status == "ok", "fresh runtime recovery"); }
}
