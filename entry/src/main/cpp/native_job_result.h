#pragma once
#include <exception>
#include <string>

namespace tinybot {
// Exceptions cannot escape an N-API worker callback. Preserve their cause for Complete().
struct NativeJobResult {
    std::string output;
    std::string error;

    template <typename Operation> void Execute(Operation operation)
    {
        try { output = operation(); }
        catch (const std::exception &failure) { error = std::string(failure.what()).substr(0, 4096); }
        catch (...) { error = "Unknown native exception"; }
    }

    const char *FailureCode(int status) const
    {
        if (!error.empty()) { return "NATIVE_EXCEPTION"; }
        return status == 0 && output.empty() ? "NATIVE_EMPTY_RESULT" : "NATIVE_NAPI_FAILED";
    }

    std::string FailureMessage(const char *operation, const std::string &id, int status) const
    {
        const std::string reason = !error.empty() ? error : status != 0 ? "N-API operation failed" :
            output.empty() ? "Native worker returned no result" : "Cannot create JavaScript result";
        return std::string(operation) + " failed [execution=" + id + ", napiStatus=" + std::to_string(status) + "]: " + reason;
    }
};
}
