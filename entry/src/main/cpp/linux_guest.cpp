#include <AbilityKit/native_child_process.h>
#include "linux_engine.h"
#include <sys/socket.h>
#include <unistd.h>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

extern "C" __attribute__((visibility("default"))) void RunLinuxGuest(NativeChildProcess_Args args)
{
    int channel = -1;
    for (auto *item = args.fdList.head; item != nullptr; item = item->next) {
        if (item->fdName && std::strcmp(item->fdName, "control") == 0) channel = item->fd;
    }
    if (channel < 0 || !args.entryParams) return;
    const std::string params(args.entryParams);
    const auto divider = params.find('\n');
    if (divider == std::string::npos) return;
    const auto memory = std::atoi(params.c_str());
    if (!LinuxMemorySupported(memory)) return;
    const auto directory = params.substr(divider + 1);
    std::thread([channel]() {
        char byte;
        while (read(channel, &byte, 1) < 0 && errno == EINTR) {}
        _exit(125); // Cancellation or closing the parent also stops all guest descendants.
    }).detach();

    if (dup2(channel, STDERR_FILENO) < 0) return;
    try {
        int status = RunLinuxEngine(LoadLinuxEngine(), directory, memory);
        if (status) dprintf(channel, "QEMU exit %d", status);
        _exit(status);
    } catch (const std::exception &error) {
        dprintf(channel, "Loading TCI: %s", error.what());
    }
}
