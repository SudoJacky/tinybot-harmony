#include <AbilityKit/native_child_process.h>
#include "linux_engine.h"
#include <sys/socket.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <string>
#include <thread>

namespace {
void Run(NativeChildProcess_Args args, bool interactive)
{
    int channel = -1;
    for (auto *item = args.fdList.head; item != nullptr; item = item->next) {
        if (item->fdName && std::strcmp(item->fdName, "control") == 0) channel = item->fd;
    }
    if (channel < 0 || !args.entryParams) return;
    std::thread([channel]() {
        char byte;
        while (read(channel, &byte, 1) < 0 && errno == EINTR) {}
        _exit(125); // Cancellation or closing the parent also stops all guest descendants.
    }).detach();

    if (dup2(channel, STDERR_FILENO) < 0) return;
    try {
        int status = RunLinuxEngine(LoadLinuxEngine(), args.entryParams, false, interactive);
        if (status) dprintf(channel, "QEMU exit %d", status);
        _exit(status);
    } catch (const std::exception &error) {
        dprintf(channel, "Loading TCI: %s", error.what());
    }
}
}

// AppSpawn starts a fresh process for each VM.
extern "C" __attribute__((visibility("default"))) void RunLinuxGuest(NativeChildProcess_Args args)
{
    Run(args, false);
}

extern "C" __attribute__((visibility("default"))) void RunLinuxConsole(NativeChildProcess_Args args)
{
    Run(args, true);
}
