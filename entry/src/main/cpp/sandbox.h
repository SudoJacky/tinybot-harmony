#pragma once
#include <atomic>
#include <chrono>
#include <cstddef>
#include <string>

namespace tinybot {
constexpr size_t MAX_SOURCE_BYTES = 32 * 1024;
constexpr size_t MAX_INPUT_BYTES = 32 * 1024;
constexpr size_t MAX_LOG_BYTES = 32 * 1024;
constexpr size_t MAX_RESULT_BYTES = 16 * 1024;
constexpr size_t MEMORY_BYTES = 32 * 1024 * 1024;
constexpr int TIMEOUT_MS = 2000;

struct Budget {
    std::atomic_bool cancelled{false};
    std::chrono::steady_clock::time_point started = std::chrono::steady_clock::now();
    bool memoryExceeded = false;
    bool timedOut = false;
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
}
