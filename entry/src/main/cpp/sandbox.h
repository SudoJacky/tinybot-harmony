#pragma once
#include <atomic>
#include <chrono>
#include <cstddef>
#include <string>
#include <vector>

namespace tinybot {
constexpr size_t MAX_LOG_BYTES = 32 * 1024;
constexpr size_t MEMORY_BYTES = 32 * 1024 * 1024;
constexpr int TIMEOUT_MS = 2000;

struct Budget {
    std::atomic_bool cancelled{false};
    std::chrono::steady_clock::time_point started = std::chrono::steady_clock::now();
    bool memoryExceeded = false;
    bool timedOut = false;
};

struct ToolReply { int id; std::string value; bool error = false; };
// The engine owns all JS values on its worker thread. The host exchanges JSON only.
class ToolHost {
public:
    virtual ~ToolHost() = default;
    virtual void Submit(int id, const std::string &name, const std::string &arguments) = 0;
    virtual bool Wait(ToolReply &reply) = 0;
};

struct ExecutionResult {
    std::string status = "ok";
    std::string stdoutText;
    std::string stderrText;
    std::string resultJson = "null";
    std::string error;
    bool logsTruncated = false;
    bool resultTruncated = false;
    long long durationMs = 0;
    std::string ToJson() const;
};

// Synchronous core; callers must run it off the UI thread. Only cancellation is cross-thread.
ExecutionResult ExecuteCode(const std::string &source, const std::string &inputJson, Budget &budget);
ExecutionResult Orchestrate(const std::string &source, const std::string &catalogJson, Budget &budget, ToolHost &host);
}
