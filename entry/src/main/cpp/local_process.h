#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <string>

namespace tinybot {
constexpr size_t LOCAL_SOURCE_LIMIT = 16 * 1024;
constexpr size_t LOCAL_INPUT_LIMIT = 32 * 1024;
constexpr size_t LOCAL_STREAM_LIMIT = 16 * 1024;
constexpr int LOCAL_TIMEOUT_LIMIT_MS = 60'000;

enum class LocalRuntime : int32_t { Node, Shell };
enum class LocalStatus : int32_t { Failed, Exited, Signalled, Timeout, Cancelled };

struct LocalRequest {
    LocalRuntime runtime = LocalRuntime::Node;
    int32_t timeoutMs = 0;
    uint32_t inputSize = 0;
    std::array<char, LOCAL_SOURCE_LIMIT + 1> source{};
    std::array<char, LOCAL_INPUT_LIMIT> input{};
};

struct LocalStream {
    uint32_t size = 0;
    bool truncated = false;
    std::array<char, LOCAL_STREAM_LIMIT> data{};
};

struct LocalReceipt {
    LocalStatus status = LocalStatus::Failed;
    int32_t exitCode = -1;
    int32_t signal = 0;
    int32_t durationMs = 0;
    std::array<char, 256> error{};
    LocalStream out;
    LocalStream err;
};

LocalReceipt RunLocalProcess(const std::string &libraryDir, const LocalRequest &request,
    const std::atomic<bool> &cancelled);
bool LocalProcessSupported();
}
