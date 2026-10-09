# Harness 代码沙箱

## 异步工具编排

`orchestrate` 接受 `{ "code": "异步 JavaScript 函数体" }`，在新的 QuickJS Runtime 中执行。
使用 `await tools.read_file({path: 'data.json'})` 调用当前 Agent 有权使用的工具，使用 `return`
交付 JSON 可序列化的汇总。工具返回值是解析后的 JSON；非 JSON 文本保持字符串。
`ALL_TOOLS` 提供本次可用工具的 `name`、`description` 和 `parameters`；`console` 日志沿用下文限制。

异步编排还提供以下全局函数，函数签名和限制随 `orchestrate` 工具说明一起交给 Agent：

| 函数 | 行为 |
| --- | --- |
| `text(value)` | 字符串原样写入 stdout，其他值先经 `JSON.stringify` 转换；undefined 记为 `undefined`，循环引用和 BigInt 抛错。与 console 共用 32 KiB 日志预算，截断时标记 `logsTruncated`。日志随最终回执返回，不实时推送，也不替代 `return`。 |
| `as_settled(iterableOrMap)` | 返回异步迭代器，按观察到的完成顺序产生 `{index, status: 'fulfilled', value}` 或 `{index, status: 'rejected', reason}`。普通迭代对象使用从 0 开始的位置，Map 使用原始键。支持普通值和 Promise，空集合立即结束。 |
| `stream_settled(iterableOrMap, emit)` | 按相同顺序执行并等待每次 `emit(outcome)`，返回 `Promise<void>`。回调异常向外传播；回调可以继续调用工具。 |

这些辅助函数只在 `orchestrate` 中提供。它们不会取消任务；提前退出迭代或捕获回调异常后，
仍需等待所有已启动的工具调用。失败的 `reason` 可能是 Error，汇总时使用 `String(reason)` 保留错误信息。
例如并发读取、处理部分失败并统一交付：

```javascript
const jobs = new Map(['a.json', 'b.json'].map(path => [path, tools.read_file({path})]));
const results = [];
await stream_settled(jobs, item => {
  results.push(item.status === 'fulfilled'
    ? {path: item.index, content: item.value.content}
    : {path: item.index, error: String(item.reason)});
});
text({completed: results.length});
return results;
```

```javascript
const results = await Promise.all([
  tools.read_file({path: 'a.json'}),
  tools.read_file({path: 'b.json'})
]);
const total = results.flatMap(item => JSON.parse(item.content)).reduce((a, b) => a + b, 0);
await tools.write_file({path: 'total.json', content: JSON.stringify({total})});
return {total, path: 'total.json'};
```

第一版开放工作区文件、网页、Skills、MCP 目录/调用和历史工具结果读取。工具目录取自当前 Agent
经过只读与员工权限过滤后的目录，子调用沿用原工具的参数校验、路径校验和 MCP 审批。
Team 控制、用户表单、图片/界面发布以及 `execute_code`/`orchestrate` 本身不作为嵌套工具开放。
普通直接调用仍可使用。编排并不自动启动员工或作语义判断；最终回答仍由 Agent 生成。

每次最多 32 个子调用，最多 4 个宿主工具同时执行；标为 sequential 的工具等待已有读取并阻止
后续调用越过。编排外层不占用团队工具通道，具体子调用才进入该通道。必须等待所有工具再返回；
遗漏 await 报错并取消、收拢已接纳调用，已经完成的写入不会撤销。工具失败使对应 Promise 拒绝，
可以用 `Promise.allSettled` 收集部分结果；持久化失败终止本次执行，不能被脚本 catch 隐藏。

运行预算为 32 MiB JS Runtime 分配、2 秒累计非等待时间、120 秒墙钟时间；解释器中断仍是协作式，
不是 OS 硬抢占。源码及每个子调用参数最多 96 KiB UTF-8，工具结果与最终返回值各最多 1 MiB。
超限明确报错；宿主已保存的完整工具回执不因此删除。最多同时接纳 4 个 Native 编排执行。
不提供文件、网络、模块、定时器或宿主对象的直接访问。

完整子调用保存在外层工具的 `children`，每个调用先保存意图再执行副作用，完成后保存回执。
模型常规上下文只接收外层汇总；子回执可以通过 `read_tool_result` 的 messageId/callId 读取，
也参与压缩时的文件操作证据汇总。工具详情页可查看每个子调用的参数、状态和结果。
停止会取消 Native 执行及宿主请求并等待清理；重启后未结束子调用标为中断，不自动重放脚本。
第一版没有跨调用 store/load、后台执行单元和 exec/wait 接口。

验证入口：`node scripts/test-orchestration.cjs`、`node scripts/test-request-context.cjs`，
以及 CMake 的 `orchestration_tests` / `ctest`。`scripts/orchestration-smoke-server.cjs`
提供仅监听 localhost:18769 的确定性模型夹具，供签名应用经过真实工具与 Node-API 链路进行设备验证。

## 同步纯计算

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

状态包括 `ok`、`error`、`timeout`、`cancelled`、`memory_limit`、`unsupported_async`。失败时 `result` 为 `null`。日志截断仍允许计算成功；结果完整返回，`resultTruncated` 保留兼容且始终为 false。用户停止会沿用 harness 的取消状态，不向下一轮模型提交结果。

## 能力与预算

| 项目 | 固定限制 |
| --- | --- |
| 源码 / JSON 输入 | 不再设置独立大小上限；仍受运行时内存与耗时预算约束 |
| 执行时间 | 从 Native 接收开始计 2000 ms，包含排队、解析、执行、结果序列化和错误转换 |
| Runtime 分配 | 32 MiB，分配失败锁存为终止状态，即使 JS 捕获异常也不算成功 |
| JavaScript 栈 | 512 KiB |
| stdout + stderr | 合计 32 KiB UTF-8，按完整码点截断 |
| 返回 JSON | 不再设置独立大小上限 |
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

HarmonyOS 使用 SDK 的 `ohos.toolchain.cmake` 交叉编译，加 `-DSANDBOX_DEVICE_TESTS=ON` 生成 `sandbox_tests`，可以通过 `devecocli device file send` 推送到测试设备运行。测试覆盖计算、输入隔离、宿主能力缺失、异常、Promise、日志洪水、大输入/源码/结果、内存膨胀、栈溢出、Atomics 阻塞、死循环、恶意 `toJSON` / `toString`、取消和故障后的重复执行。主机契约测试使用 Native mock，不能替代真实设备上的 Node-API 调用验证。

2026-10-04 验证：主机引擎测试及 Mate 90 Pro（x86_64 模拟器）27 项 Native 检查通过，含故障后连续 100 次执行；现有 219 项本地测试通过。模拟器真实聊天经模型工具调用、ArkTS、Node-API 到 QuickJS 完成求和（10）、死循环超时（约 2003 ms）及后续执行恢复（42）。构建同时包含 arm64-v8a 与 x86_64，最终安装与启动检查为 `Smoke: PASS`；尚未进行物理手机验证。
