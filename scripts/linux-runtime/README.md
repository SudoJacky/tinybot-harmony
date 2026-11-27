# Offline Linux tool for Tinybot Harmony

`run_linux` boots an ARM64 Alpine guest using QEMU's TCG interpreter (TCI). The shipped native library interprets translated guest instructions. The loader accepts only the TCI library. The agent can select this tool through the existing code calculation capability when the current ABI includes the runtime. Global read-only mode removes it from the catalog.

## Build the optional assets

Use an x86-64 Linux build host or WSL. The engine build uses the HarmonyOS native SDK sysroot and libraries with the host's Clang, LLD, LLVM utilities, GCC, make, pkg-config, Python, Meson and Ninja. The guest build requires curl, tar, e2fsprogs and qemu-img. Run the guest step as root in a build container or via sudo so apk can restore package ownership. Allow access to the upstream source archives and Alpine package mirror.

```sh
export OHOS_NDK=/path/to/openharmony/native
bash scripts/linux-runtime/build-engine.sh aarch64
bash scripts/linux-runtime/build-engine.sh x86_64
sudo bash scripts/linux-runtime/build-guest.sh
```

The second engine is for x86-64 emulators. The scripts stage the libraries under `entry/libs/<ABI>/` and the kernel and `root-console.qcow2` under `entry/src/main/resources/rawfile/linux/`. Build the entry HAP with the project's normal DevEco SDK and local signing configuration. A clean checkout builds the existing QuickJS tool without those assets. The engine build cache defaults to `~/tinybot-tci-build` and can be moved with `TCI_BUILD_DIR`.

The engine script pins the [HiSH QEMU fork](https://github.com/harmoninux/qemu/tree/50ce7096eb6b338bee88a0960c543f93f1b16959) and checks its TCI build flag. The guest script verifies the [HiSH kernel release](https://github.com/harmoninux/linux-config/releases/tag/kernel-20260228) and installs signed packages from Alpine v3.22. Patch versions can change within that repository. For redistribution, retain the matching sources, build configuration and license notices for the kernel, emulator and packages.

## Run and verify

In a chat with code calculation enabled, ask Tinybot to use `run_linux` to query a SQLite database from its private workspace. To run the example below, set `language` to `shell`, `inputPath` to `items.db`, and `outputPath` to `summary.csv`.

```sh
sqlite3 -header -csv input 'select sum(n) as total from items' > output
```

The tool also accepts Python source. It reports the program's exit code and separate stdout and stderr, capped at 16 KiB each. A nonzero exit reaches the agent as a failed tool result. Each job can import one file and create one new file, each up to 1 MiB. The guest has a read-only root, temporary working directory, unprivileged job user and no network device or host mount. Only one job can run at a time.

On phones, a thread in the app hosts a single VM configured with 192 MiB of guest RAM. QMP pauses and resets the machine after completion, timeout or cancellation. The next job boots the kernel again. The paused engine stays in the app process until it exits, and a native engine crash can affect that process. Tablets and 2-in-1 devices start a native child process for each job. The parent closes the control channel to cancel the child. Both modes bound batch jobs at 120 seconds.

The browser launcher also opens the Linux Console. It runs an interactive, unprivileged shell for the foreground session. Its working directory lives in the guest and is cleared at session end. The console and `run_linux` take turns using the runtime. Close the console, run `exit`, or tap Stop to release the runtime.

For on-device tests, configure a separate test bundle name, use a signing profile for that name, and install the `default` and `ohosTest` HAPs with test data. Removing a test module from an installation that holds real conversations can invalidate the application's HUKS keys and leave its encrypted database unreadable. Use only the signed `default` HAP for an in-place upgrade of a user's installation and verify that an existing conversation opens afterwards. See the [device test and release checklist](../../docs/dev/release.md).

The device suite exercises a Python exception, a binary SQLite round trip, cancellation of a job with a background process, and execution of a subsequent job. It also checks that an interactive shell preserves its working directory, receives terminal dimensions and interrupts a running command. Replace `TEST_BUNDLE` with the separate test bundle name and `DEVICE` with its HDC identifier.

```sh
hdc -t DEVICE shell aa test -b TEST_BUNDLE -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 240000 -w 240
```
