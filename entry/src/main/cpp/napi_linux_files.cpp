#include <napi/native_api.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits.h>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>

namespace {
constexpr double MAX_SAFE_OFFSET = 9007199254740991.0;

class File {
public:
    explicit File(int descriptor) : descriptor_(descriptor)
    {
        if (descriptor_ < 0) throw std::runtime_error(std::strerror(errno));
    }
    ~File() { close(descriptor_); }
    File(const File &) = delete;
    File &operator=(const File &) = delete;
    int Get() const { return descriptor_; }
private:
    int descriptor_;
};

struct Snapshot {
    std::string path, prefix, error;
    std::unique_ptr<File> disk;
    uint64_t start = 0, offset = 0, capacity = 0;
    std::atomic<bool> cancelled{false};
    napi_async_work work = nullptr;
    napi_deferred result = nullptr;
};

std::mutex snapshotGate;
Snapshot *activeSnapshot = nullptr;

void Write(Snapshot &snapshot, const void *data, size_t length)
{
    if (length > snapshot.capacity - snapshot.offset) throw std::runtime_error("Linux exchange disk is full");
    const auto *source = static_cast<const uint8_t *>(data);
    while (length > 0) {
        if (snapshot.cancelled) throw std::runtime_error("Linux directory snapshot cancelled");
        const auto count = pwrite(snapshot.disk->Get(), source, length, static_cast<off_t>(snapshot.offset));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) throw std::runtime_error(std::strerror(errno));
        if (count == 0) throw std::runtime_error("Incomplete Linux directory snapshot");
        source += count;
        length -= count;
        snapshot.offset += count;
    }
}

// V3 tree record: little-endian path length, entry type, file size, followed by UTF-8 path and file bytes.
void Record(Snapshot &snapshot, const std::string &path, uint8_t type, uint64_t size)
{
    std::array<uint8_t, 13> header{};
    auto pathLength = static_cast<uint32_t>(path.size());
    for (int index = 0; index < 4; ++index) header[index] = (pathLength >> (index * 8)) & 0xff;
    header[4] = type;
    for (int index = 0; index < 8; ++index) header[5 + index] = (size >> (index * 8)) & 0xff;
    Write(snapshot, header.data(), header.size());
    Write(snapshot, path.data(), path.size());
}

bool ValidComponent(const std::string &name)
{
    return !name.empty() && name != "." && name != ".." && std::none_of(name.begin(), name.end(), [](unsigned char c) {
        return c < 32 || c == 127 || c == '/' || c == '\\';
    });
}

void PackFile(Snapshot &snapshot, int parent, const std::string &name, const std::string &path)
{
    File file(openat(parent, name.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
    struct stat info;
    if (fstat(file.Get(), &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0) {
        throw std::runtime_error("The mounted entry is not a regular file");
    }
    uint64_t remaining = info.st_size;
    Record(snapshot, path, 1, remaining);
    std::array<uint8_t, 128 * 1024> chunk;
    while (remaining > 0) {
        const auto count = read(file.Get(), chunk.data(), std::min<uint64_t>(chunk.size(), remaining));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) throw std::runtime_error("A mounted file changed while being read");
        Write(snapshot, chunk.data(), static_cast<size_t>(count));
        remaining -= count;
    }
    uint8_t tail;
    ssize_t count;
    do { count = read(file.Get(), &tail, 1); } while (count < 0 && errno == EINTR);
    if (count != 0) throw std::runtime_error("A mounted file changed while being read");
}

void Walk(Snapshot &snapshot, int parent, const std::string &prefix)
{
    const auto listingFd = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (listingFd < 0) throw std::runtime_error(std::strerror(errno));
    std::unique_ptr<DIR, decltype(&closedir)> directory(fdopendir(listingFd), closedir);
    if (!directory) {
        close(listingFd);
        throw std::runtime_error("Could not list the mounted directory");
    }
    while (true) {
        if (snapshot.cancelled) throw std::runtime_error("Linux directory snapshot cancelled");
        errno = 0;
        const auto *item = readdir(directory.get());
        if (!item) {
            if (errno != 0) throw std::runtime_error(std::strerror(errno));
            return;
        }
        const std::string name(item->d_name);
        if (name == "." || name == "..") continue;
        const auto path = prefix + name;
        if (!ValidComponent(name) || path.size() >= PATH_MAX) throw std::runtime_error("Invalid Linux snapshot path");
        struct stat info;
        if (fstatat(parent, name.c_str(), &info, AT_SYMLINK_NOFOLLOW) != 0) {
            throw std::runtime_error(std::strerror(errno));
        }
        if (S_ISDIR(info.st_mode)) {
            File nested(openat(parent, name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
            Record(snapshot, path, 0, 0);
            Walk(snapshot, nested.Get(), path + "/");
        } else if (S_ISREG(info.st_mode)) {
            PackFile(snapshot, parent, name, path);
        } else {
            throw std::runtime_error("Mounted directories must contain only directories and regular files");
        }
    }
}

void Execute(napi_env, void *data)
{
    auto &snapshot = *static_cast<Snapshot *>(data);
    try {
        File root(open(snapshot.path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
        Record(snapshot, snapshot.prefix, 0, 0);
        Walk(snapshot, root.Get(), snapshot.prefix + "/");
    } catch (const std::exception &error) { snapshot.error = error.what(); }
}

void Complete(napi_env env, napi_status status, void *data)
{
    std::unique_ptr<Snapshot> snapshot(static_cast<Snapshot *>(data));
    { std::lock_guard<std::mutex> lock(snapshotGate); activeSnapshot = nullptr; }
    napi_value value;
    if (status == napi_ok && snapshot->error.empty() &&
        napi_create_double(env, static_cast<double>(snapshot->offset - snapshot->start), &value) == napi_ok) {
        napi_resolve_deferred(env, snapshot->result, value);
    } else {
        const auto message = snapshot->error.empty() ? "Could not complete the Linux directory snapshot" : snapshot->error;
        napi_value text, error;
        napi_create_string_utf8(env, message.c_str(), message.size(), &text);
        napi_create_error(env, nullptr, text, &error);
        napi_reject_deferred(env, snapshot->result, error);
    }
    napi_delete_async_work(env, snapshot->work);
}

bool ReadString(napi_env env, napi_value value, std::string &result)
{
    char text[PATH_MAX];
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length == 0 || length >= sizeof(text) ||
        napi_get_value_string_utf8(env, value, text, sizeof(text), &length) != napi_ok || std::strlen(text) != length) return false;
    result.assign(text, length);
    return true;
}

napi_value Pack(napi_env env, napi_callback_info info)
{
    size_t count = 4;
    napi_value args[4], promise, label;
    double offset = 0;
    int32_t descriptor = -1;
    auto snapshot = std::make_unique<Snapshot>();
    if (napi_get_cb_info(env, info, &count, args, nullptr, nullptr) != napi_ok || count != 4 ||
        !ReadString(env, args[0], snapshot->path) || snapshot->path[0] != '/' ||
        !ReadString(env, args[1], snapshot->prefix) || !ValidComponent(snapshot->prefix) ||
        napi_get_value_int32(env, args[2], &descriptor) != napi_ok ||
        napi_get_value_double(env, args[3], &offset) != napi_ok || !std::isfinite(offset) ||
        offset < 0 || offset > MAX_SAFE_OFFSET || std::floor(offset) != offset) {
        napi_throw_type_error(env, nullptr, "Invalid Linux directory snapshot arguments");
        return nullptr;
    }
    try { snapshot->disk = std::make_unique<File>(fcntl(descriptor, F_DUPFD_CLOEXEC, 0)); }
    catch (const std::exception &error) { napi_throw_error(env, nullptr, error.what()); return nullptr; }
    struct stat disk;
    if (fstat(snapshot->disk->Get(), &disk) != 0 || !S_ISREG(disk.st_mode) || disk.st_size < 0 || offset > disk.st_size) {
        napi_throw_error(env, nullptr, "Invalid Linux exchange disk");
        return nullptr;
    }
    snapshot->offset = snapshot->start = static_cast<uint64_t>(offset);
    snapshot->capacity = static_cast<uint64_t>(disk.st_size);
    std::lock_guard<std::mutex> lock(snapshotGate);
    if (activeSnapshot) { napi_throw_error(env, nullptr, "A Linux snapshot is already running"); return nullptr; }
    if (napi_create_promise(env, &snapshot->result, &promise) != napi_ok ||
        napi_create_string_utf8(env, "Linux directory snapshot", NAPI_AUTO_LENGTH, &label) != napi_ok ||
        napi_create_async_work(env, nullptr, label, Execute, Complete, snapshot.get(), &snapshot->work) != napi_ok ||
        napi_queue_async_work(env, snapshot->work) != napi_ok) {
        if (snapshot->work) napi_delete_async_work(env, snapshot->work);
        napi_throw_error(env, nullptr, "Could not schedule the Linux directory snapshot");
        return nullptr;
    }
    activeSnapshot = snapshot.release();
    return promise;
}

napi_value CancelPack(napi_env env, napi_callback_info)
{
    std::lock_guard<std::mutex> lock(snapshotGate);
    if (activeSnapshot) activeSnapshot->cancelled = true;
    napi_value value;
    napi_get_undefined(env, &value);
    return value;
}

napi_value Capacity(napi_env env, napi_callback_info info)
{
    size_t count = 1;
    napi_value argument, value;
    std::string path;
    struct statvfs storage;
    if (napi_get_cb_info(env, info, &count, &argument, nullptr, nullptr) != napi_ok || count != 1 ||
        !ReadString(env, argument, path) || statvfs(path.c_str(), &storage) != 0) {
        napi_throw_error(env, nullptr, "Could not measure Linux sandbox storage");
        return nullptr;
    }
    const auto size = static_cast<double>(storage.f_blocks) * storage.f_frsize;
    if (size < 16 * 1024 * 1024 || size > MAX_SAFE_OFFSET) {
        napi_throw_error(env, nullptr, "Unsupported Linux sandbox storage capacity");
        return nullptr;
    }
    napi_create_double(env, size, &value);
    return value;
}
}

void InstallLinuxFiles(napi_env env, napi_value exports)
{
    napi_property_descriptor methods[] = {
        {"packLinuxDirectory", nullptr, Pack, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelLinuxDirectory", nullptr, CancelPack, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"linuxStorageBytes", nullptr, Capacity, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods);
}
