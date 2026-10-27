#include "../native_job_result.h"
#include <cstdlib>
#include <iostream>
#include <stdexcept>

void Check(bool condition, const char *name)
{
    if (!condition) { std::cerr << "FAIL " << name << std::endl; std::exit(1); }
    std::cout << "PASS " << name << std::endl;
}

int main()
{
    tinybot::NativeJobResult success;
    success.Execute([]() { return "{\"status\":\"ok\"}"; });
    Check(success.error.empty() && success.output == "{\"status\":\"ok\"}", "successful JSON remains unchanged");
    tinybot::NativeJobResult failed;
    failed.Execute([]() -> std::string { throw std::runtime_error("Cannot dispatch host tool"); });
    const std::string detail = failed.FailureMessage("Native orchestration", "job-7", 0);
    Check(failed.output.empty() && detail.find("Cannot dispatch host tool") != std::string::npos &&
        detail.find("job-7") != std::string::npos && std::string(failed.FailureCode(0)) == "NATIVE_EXCEPTION",
        "native exception cause and execution ID survive the worker boundary");
    tinybot::NativeJobResult unknown;
    unknown.Execute([]() -> std::string { throw 42; });
    Check(unknown.error == "Unknown native exception", "unknown exceptions fail explicitly");
    tinybot::NativeJobResult empty;
    empty.Execute([]() { return std::string(); });
    Check(std::string(empty.FailureCode(0)) == "NATIVE_EMPTY_RESULT", "empty output is not successful execution");
    Check(std::string(success.FailureCode(9)) == "NATIVE_NAPI_FAILED" &&
        success.FailureMessage("Native sandbox execution", "job-8", 9).find("napiStatus=9") != std::string::npos,
        "N-API failures retain their status");
}
