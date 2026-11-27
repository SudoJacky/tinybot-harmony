#pragma once
#include <dlfcn.h>
#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <unistd.h>
#include <vector>

using LinuxEngineEntry = int (*)(int, char **);

inline LinuxEngineEntry LoadLinuxEngine()
{
    void *library = dlopen("libqemu-system-aarch64-tci.so", RTLD_NOW | RTLD_LOCAL);
    if (!library) throw std::runtime_error(dlerror());
    auto entry = reinterpret_cast<LinuxEngineEntry>(dlsym(library, "qemu_system_entry"));
    if (!entry) throw std::runtime_error(dlerror());
    return entry;
}

inline int LinuxMemoryLimitMiB()
{
    const auto pages = sysconf(_SC_PHYS_PAGES);
    const auto pageSize = sysconf(_SC_PAGESIZE);
    if (pages <= 0 || pageSize <= 0) return 0;
    // Leave at least half of physical RAM for HarmonyOS and the host process.
    const auto halfMiB = static_cast<uint64_t>(pages) * static_cast<uint64_t>(pageSize) / (2 * 1024 * 1024);
    return static_cast<int>(std::min<uint64_t>(halfMiB, INT32_MAX));
}

inline bool LinuxMemorySupported(int memoryMiB)
{
    return memoryMiB >= 192 && memoryMiB <= LinuxMemoryLimitMiB();
}

inline int RunLinuxEngine(LinuxEngineEntry entry, const std::string &dir, int memoryMiB, bool embedded)
{
    const auto assets = dir.substr(0, dir.rfind('/')) + "/tinybot-linux-assets-v3";
    std::vector<std::string> options = {
        "tinybot-linux", "-no-user-config", "-nodefaults",
        "-machine", "virt,gic-version=2", "-accel", "tcg,thread=single,tb-size=32",
        "-cpu", "max,sve=off", "-m", std::to_string(memoryMiB), "-smp", "1", "-display", "none",
        "-serial", "none", "-monitor", "none", "-nic", "none",
        "-kernel", assets + "/kernel", "-append", "root=/dev/vda ro rootwait init=/linux-init panic=1",
        "-drive", "if=none,id=root,format=qcow2,readonly=on,file=" + assets + "/root-v3.qcow2",
        "-device", "virtio-blk-pci,drive=root,addr=4",
        "-drive", "if=none,id=job,format=raw,file=" + dir + "/exchange",
        "-device", "virtio-blk-pci,drive=job,addr=5",
        "-drive", "if=none,id=workspace,format=raw,file=" + dir + "/workspace",
        "-device", "virtio-blk-pci,drive=workspace,addr=6"
    };
    if (embedded) {
        options.insert(options.end(), {"-S", "-no-shutdown", "-qmp", "unix:" + dir + "/qmp,server=on,wait=off"});
    } else {
        options.push_back("-no-reboot");
    }
    std::vector<char *> argv;
    for (auto &option : options) argv.push_back(option.data());
    argv.push_back(nullptr);
    return entry(static_cast<int>(options.size()), argv.data());
}
