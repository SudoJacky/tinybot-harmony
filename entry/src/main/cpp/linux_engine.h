#pragma once
#include <dlfcn.h>
#include <stdexcept>
#include <string>
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

inline int RunLinuxEngine(LinuxEngineEntry entry, const std::string &dir, bool embedded)
{
    std::vector<std::string> options = {
        "tinybot-linux", "-no-user-config", "-nodefaults",
        "-machine", "virt,gic-version=2", "-accel", "tcg,thread=single,tb-size=32",
        "-cpu", "max,sve=off", "-m", "192", "-smp", "1", "-display", "none",
        "-serial", "none", "-monitor", "none", "-nic", "none",
        "-kernel", dir + "/kernel", "-append", "root=/dev/vda ro rootwait init=/linux-init panic=1",
        "-drive", "if=none,id=root,format=qcow2,readonly=on,file=" + dir + "/root.qcow2",
        "-device", "virtio-blk-pci,drive=root,addr=4",
        "-drive", "if=none,id=job,format=raw,file=" + dir + "/exchange",
        "-device", "virtio-blk-pci,drive=job,addr=5"
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
