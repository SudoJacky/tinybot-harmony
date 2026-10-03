# Harness 代码沙箱

`NativeSessionResources` 为聊天和团队提供 `execute_code`，支持纯计算 JavaScript。research、review 和全局只读模式均可使用；文件操作仍由原有工作区工具校验权限、路径和修改基线。

## 调用约定

```json
{
  "code": "console.log('rows', input.values.length); return {total: input.values.reduce((a,b) => a+b, 0)};",
  "input": "{\"values\":[2,3,5]}"
}
```

`code` 是严格模式同步函数体，通过 `input` 参数读取 JSON 副本，通过 `return` 返回 JSON 可序列化的值；`input` 参数本身是 JSON 编码字符串，省略时为 `null`。不返回值时结果为 `null`。JSON 标准转换适用，例如非有限数变为 `null`，对象内的 undefined 属性被省略；循环引用和 BigInt 报错。

```json
{
  "status": "ok",
  "stdout": "rows 3\n",
  "stderr": "",
  "result": {"total": 10},
  "error": "",
  "logsTruncated": false,
  "resultTruncated": false,
  "durationMs": 1
}
```

状态包括 `ok`、`error`、`timeout`、`cancelled`、`memory_limit`、`output_limit`、`unsupported_async`。失败时 `result` 为 `null`。日志截断仍允许计算成功；超大结果整体丢弃并标记 `resultTruncated`，不会把截断 JSON 作为有效结果返回。用户停止会沿用 harness 的取消状态，不向下一轮模型提交结果。

## 能力与预算

| 项目 | 固定限制 |
| --- | --- |
| 源码 / JSON 输入 | 各 32 KiB UTF-8，Native 桥再次校验 |
| 执行时间 | 从 Native 接收开始计 2000 ms，包含排队、解析、执行、结果序列化和错误转换 |
| Runtime 分配 | 32 MiB，分配失败锁存为终止状态，即使 JS 捕获异常也不算成功 |
| JavaScript 栈 | 512 KiB |
| stdout + stderr | 合计 32 KiB UTF-8，按完整码点截断 |
| 返回 JSON | 16 KiB UTF-8 |
| 错误文本 | 4 KiB UTF-8 |
| 并发 | 应用内最多一次；其他调用收到 busy 工具错误，不建立无界队列 |

只提供 JavaScript 内建功能与 `console.log/info/warn/error`。没有 `fetch`、文件系统、进程、Node.js、npm、定时器、模块加载器、宿主工具或密钥。禁用可阻塞的 `Atomics.wait`。Promise 返回值或待执行 job 会被拒绝；不调度异步 job。TS 转译、Python 和产物自动提交不在此版本内。

使用方式：`read_file` 获取数据 → `execute_code` 清洗、聚合或计算 → `write_file` 或已有展示工具处理结果。沙箱不直接嵌套调用 Team 工具通道。

## 生命周期与隔离边界

每次调用在 Native 异步工作线程新建 QuickJS Runtime 和 Context，同线程执行和销毁。执行 ID 由宿主生成。`Cancellation.onCancel()` 设置该任务的原子标志，引擎中断回调检查取消与单调时钟截止时间。ArkTS 等待 Native 返回并完成清理后才释放工具通道，不以 Promise.race 假装底层执行已经结束。团队串行通道因此可以在失败或停止后继续处理后续调用。

这是一层同进程解释器和宿主能力限制，不是操作系统进程沙箱。32 MiB 约束受跟踪的 Runtime 分配（含自定义分配头），不是整个应用 RSS；系统分配器元数据、Native/ArkTS 缓冲区和线程栈在其外。执行中断是协作检查，内建 C 运算和 Runtime 清理不是 OS 硬抢占，因此 2000 ms 不是严格墙钟上限。解释器漏洞或崩溃仍可能影响应用进程。需要更强边界时应新增具备进程或 WASM 隔离的后端，而不是给当前工具开放任意宿主权限。

引擎为随源码提交的 QuickJS 2026-06-04，不依赖构建时下载。来源、归档 SHA-256 和 MIT 授权在 `entry/src/main/cpp/third_party/quickjs/README.tinybot.md` 和 `LICENSE`。引擎 API 依据 [QuickJS 官方文档](https://bellard.org/quickjs/quickjs.html)。

## 验证

ArkTS 工具和 Native 适配器契约测试：

```powershell
node scripts/test-code-sandbox.cjs
devecocli check arkts entry/src/main/ets/services/CodeExecutionTools.ets entry/src/main/ets/services/NativeCodeExecutor.ets
devecocli build
```

真实引擎测试（需要 CMake、C/C++ 编译器和 pthread；Windows 可用 MinGW，旧 GCC 8 使用 Debug 避免其优化汇编问题）：

```powershell
cmake -S entry/src/main/cpp -B .cache/sandbox-host -G "MinGW Makefiles" -DCMAKE_BUILD_TYPE=Debug
cmake --build .cache/sandbox-host -j 4
ctest --test-dir .cache/sandbox-host --output-on-failure
```

HarmonyOS 使用 SDK 的 `ohos.toolchain.cmake` 交叉编译，加 `-DSANDBOX_DEVICE_TESTS=ON` 生成 `sandbox_tests`，可以通过 `devecocli device file send` 推送到测试设备运行。测试覆盖计算、输入隔离、宿主能力缺失、异常、Promise、日志洪水、输出溢出、内存膨胀、栈溢出、Atomics 阻塞、死循环、恶意 `toJSON` / `toString`、取消和故障后的重复执行。主机契约测试使用 Native mock，不能替代真实设备上的 Node-API 调用验证。

2026-10-04 验证：主机引擎测试及 Mate 90 Pro（x86_64 模拟器）27 项 Native 检查通过，含故障后连续 100 次执行；现有 219 项本地测试通过。模拟器真实聊天经模型工具调用、ArkTS、Node-API 到 QuickJS 完成求和（10）、死循环超时（约 2003 ms）及后续执行恢复（42）。构建同时包含 arm64-v8a 与 x86_64，最终安装与启动检查为 `Smoke: PASS`；尚未进行物理手机验证。
