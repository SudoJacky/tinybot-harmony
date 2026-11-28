# Offline Linux tool for Tinybot Harmony

`run_linux` boots an ARM64 Alpine guest using QEMU's TCG interpreter (TCI). The shipped native library interprets translated guest instructions. The loader accepts only the TCI library. The agent can select this tool through the existing code calculation capability when the current ABI includes the runtime. Global read-only mode removes it from the catalog.

## Build the optional assets

Use an x86-64 Linux build host or WSL. The engine build uses the HarmonyOS native SDK sysroot and libraries with the host's Clang, LLD, LLVM utilities, GCC, make, pkg-config, Python, Meson and Ninja. The guest build requires curl, tar, e2fsprogs, qemu-img and `qemu-aarch64-static` from `qemu-user-static`. It uses the guest’s own Python to compile bytecode before packaging. Run the guest step as root in a build container or via sudo so apk can restore package ownership. Allow access to the upstream source archives and Alpine package mirror.

```sh
export OHOS_NDK=/path/to/openharmony/native
bash scripts/linux-runtime/build-engine.sh aarch64
bash scripts/linux-runtime/build-engine.sh x86_64
sudo bash scripts/linux-runtime/build-guest.sh
```

The second engine is for x86-64 emulators. The scripts stage the libraries under `entry/libs/<ABI>/` and the kernel and `root-v5-shell.qcow2` under `entry/src/main/resources/rawfile/linux/`. Rebuild the guest image after changing the guest scripts. Build the entry HAP with the project's normal DevEco SDK and local signing configuration. A clean checkout builds the existing QuickJS tool without those assets. The engine build cache defaults to `~/tinybot-tci-build` and can be moved with `TCI_BUILD_DIR`.

The engine script pins the [HiSH QEMU fork](https://github.com/harmoninux/qemu/tree/50ce7096eb6b338bee88a0960c543f93f1b16959) and checks its TCI build flag. The guest script verifies the [HiSH kernel release](https://github.com/harmoninux/linux-config/releases/tag/kernel-20260228) and installs signed packages from Alpine v3.22. Patch versions can change within that repository. For redistribution, retain the matching sources, build configuration and license notices for the kernel, emulator and packages.

## Run and verify

On the Linux build host, run `python3 scripts/linux-runtime/test-guest-console.py` to check how mixed keystrokes and cursor position reports affect pending terminal input.

In a chat with code calculation enabled, ask Tinybot to use `run_linux` to query a SQLite database from its private workspace. To run the example below, set `language` to `shell`, `inputPath` to `items.db`, and `outputPath` to `summary.csv`.

```sh
sqlite3 -header -csv input 'select sum(n) as total from items' > output
```

The tool also accepts Python source. It reports the program's exit code and separate stdout and stderr, capped at 16 KiB each. In the shared shell, the terminal shows output as it arrives. Excess output is drained without filling the guest filesystem. A nonzero exit reaches the agent as a failed tool result. Each job can import one file and create one new file, each up to 1 MiB. The guest has a read-only root and runs offline. The shared shell starts as root in its own user and mount namespaces. Workspace-mode jobs run as an unprivileged user. Each tool call has its own receipt.

In Settings → Tools and permissions → Sandbox management, choose a 30, 60 or 120 second timeout. Guest RAM can be set to 192, 256 or 384 MiB or an integer from 192 MiB to half of the device's physical RAM. Run a warm-up manually or opt in to warm-up when the app opens. Warm-up starts the app’s single Linux guest and its interactive shell in the background. On-demand use starts the same guest on first access. Phones embed it in the app process, while tablets and 2-in-1 devices use one managed native child. Memory changes take effect after relaunch. Disabling Linux pauses the guest.

Enable the persistent directory for the active project to save regular files and directories in `/work/project` after successful jobs. Use the system folder picker to attach local folders to the active project or conversation. Each workspace-mode task receives fresh read-only snapshots under `/work/mounts/<name>`. Directory data is streamed through sparse disks, so available device storage determines capacity. The workspace import and export permissions also apply to these features.

Open the Linux Console from the browser launcher or the **Open terminal** button in Sandbox management. Copy uses the selection when present and otherwise copies the visible terminal screen. Scroll up to read history and tap the down arrow to return to live output. It connects to the app’s persistent sandbox root shell. Navigating away, disconnecting the view, or backgrounding the app preserves the working directory, environment and running commands while the app process lives. Typing `exit` starts a new shell in the same guest. By default, shell source from chat is sourced by this same shell, sharing its PID, current directory, variables and functions. Python runs as a child of the shell. A partial input line or another foreground command returns BUSY. File transfers and explicit `session: "workspace"` tasks use a private working directory and PID namespace within the same guest. Select workspace mode to use a project directory or mounted folders. Ending the app process releases the guest.

For on-device tests, configure a separate test bundle name, use a signing profile for that name, and install the `default` and `ohosTest` HAPs with test data. Removing a test module from an installation that holds real conversations can invalidate the application's HUKS keys and leave its encrypted database unreadable. Use only the signed `default` HAP for an in-place upgrade of a user's installation and verify that an existing conversation opens afterwards. See the [device test and release checklist](../../docs/dev/release.md).

The device suite exercises a Python exception, a binary SQLite round trip, cancellation of a job with a background process, and execution of a subsequent job. It also checks that an interactive shell preserves its working directory, receives terminal dimensions and interrupts a running command. Replace `TEST_BUNDLE` with the separate test bundle name and `DEVICE` with its HDC identifier.

```sh
hdc -t DEVICE shell aa test -b TEST_BUNDLE -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 240000 -w 240
```
