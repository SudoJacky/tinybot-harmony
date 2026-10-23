# 运行诊断与性能

诊断分两条通道：数值化的性能埋点（instrumentation），以及只含白名单字段的分级运行日志。两者共用单调时钟与序号，可以一起导出为时间线。这页说明开发者模式如何开启、日志如何脱敏、采集了什么、慢资源探测放在哪里，以及如何验证这些行为。

## 开发者模式与采集开关

入口在“设置 → 关于 Tinybot”：连续点击版本号 7 次，相邻间隔不超过 2 秒，再输入源码内置的固定开发者密码。密码不写入日志、Preferences 或备份；连续输错 5 次暂停尝试 30 秒，关闭密码弹层会清空输入。这只是本地功能入口，不是身份认证，也不提升系统权限。

| 状态 | 保存位置 | 进程重启后 |
| --- | --- | --- |
| 开发者入口已解锁 | `tinybot-developer` Preferences 的 `enabled` | 保留入口 |
| 是否正在采集 | 仅内存与 `AppStorage` | 不自动开始 |
| 日志等级 | 内存，默认 `info` | 恢复 `info` |

首次开启会立即开始采集，并在开发者页显示入口。关闭开发者模式会清除解锁标记、停止采集；再次使用必须重新解锁。开始采集时注册系统事件观察者、启动 250 ms 定时器并立即采样一次；停止时结束 CPU Profile、注销观察者、清理定时器与帧回调，并冲刷一次日志。

## 分级日志

业务代码统一调用 `Diagnostics.log(level, module, event, fields?, error?)`。等级为 `debug`、`info`、`warn`、`error`，默认 `info`，可在开发者页切换。

| 行为 | 说明 |
| --- | --- |
| 采集期 | 达到阈值的日志进入 1000 条环形缓冲，并计入等级计数 |
| 低于阈值 | 不进入缓冲；`filtered` 只统计实际进入接口的调用 |
| 未采集 | Debug/Info 只做状态与等级检查；Warn/Error 仍输出到系统 HiLog |
| 名称未知 | 模块或事件不在目录中时拒绝并计数，不写缓冲 |
| 输出失败 | 不替换业务异常，`sinkFailures` 在开发者页和导出中可见 |

`acceptsLog(level)` 供高频调用点在构造字段前提前返回。以 Web 加载为例：

```ts
if (Diagnostics.acceptsLog('debug')) {
  Diagnostics.log('debug', 'web', 'load_start', { instanceId: this.instanceId, chars: host.length });
}
Diagnostics.log('error', 'network', 'request_failed', { code: error.code }, error);
```

接口本身也会再次检查，调用者不必依赖前置门控保证正确性。只有 `NativeDiagnosticLog` 适配器可以写 HiLog，它与采集缓冲收到同一份脱敏数据。沙箱用户程序的 `console` 输出属于工具结果，不并入应用诊断日志。

## 名称与字段白名单

`DiagnosticLog.ets` 维护模块、事件、数值字段、布尔字段、字符串枚举与引用字段的目录，所有输出都经同一层脱敏（redaction）。新增日志必须先登记，事件名不能拼接正文或自由文本。

| 字段类型 | 处理 |
| --- | --- |
| 数值 | 必须有限；NaN、Infinity 丢弃 |
| 布尔 | 必须是布尔值 |
| 字符串枚举 | 只保留目录中的值，其余替换为 `[redacted]` |
| 引用 ID | 每次采集重新编号为 `ref-N`，映射容量 512，超出后遮蔽 |
| 未知键 | 直接忽略；单条最多检查 48 个键 |
| 错误 | 只保留允许的数值错误码或符号错误码，并归纳为固定 `errorKind` |

异常正文与堆栈从不导出。`errorKind` 按取消、超时、权限、存储、解析、网络等固定分类，分类失败为 `unknown`；模型名、字体列表、浏览器 URL、文件路径和可任意填写的名称都不写入。`scripts/test-unified-logging.cjs` 会检查业务代码不再直接导入 HiLog，并验证所有固定调用点已登记。

## 采集的指标

性能事件只带固定事件名与有限数值，不复制可变对象。主要分类如下：

| 分类 | 实际记录 |
| --- | --- |
| Markdown | 全量源字符数、变更起点与块数；增量解析、行内解析、Span、代码高亮与表格宽度计算耗时 |
| 渲染 | 活跃文档/分组数；分组更新、分批挂载耗时与进度；可见性与淡入时钟次数 |
| 布局与滚动 | 分组实测宽高、消息高度变化、自动跟随触发；单位为 vp |
| 网络 | 请求耗时、首段正文延迟、接收字节、正文增量数/字符数、协议解码与状态投影耗时；HTTP 状态、失败与取消标记 |
| 工具 | 操作 ID、轮次、参数/结果字符数、执行耗时、失败/取消状态；不含参数或结果正文 |
| 会话 | 上下文估算、会话发布、ViewModel 投影、存盘前序列化、文件写入（含 fsync）耗时 |
| Web | 实例创建与释放、活动数量、代次、`loadData` 耗时、ready 事件 |
| 资源 | HiDebug 当前进程 PSS+SwapPss、RSS、VSS、私有/共享脏页；UI VM 堆；进程 CPU 与占用最高的 32 个线程 |
| 主线程 | 250 ms 定时器迟到时间；可选的 displaySync 回调间隔与目标 Vsync 周期 |
| 系统 | MAIN_THREAD_JANK、APP_FREEZE、APP_CRASH、RESOURCE_OVERLIMIT 的固定名称与允许的数值字段 |

所有耗时使用系统启动单调时钟，不随校时变化。字符数使用 ArkTS `string.length`（UTF-16 码元），网络字节单独统计。

事件环最多 12000 条，覆盖计数显式展示；全程聚合统计独立保留，最多 128 类指标。分位数是固定直方图的上界（0.1、0.5、1、2、4、8、16.7、33.4、50、100、250、500、1000、5000、30000、∞），均值、最大值、次数为实际采集值。关闭“详细事件时间线”后，未标记 `always` 的事件只增加 `omitted`；耗时达到 16.7 ms 的慢操作、资源与系统事件仍会保留。

## PerformanceProbe 与 taskpool

资源采样不在 UI 线程执行。`PerformanceProbe.ets` 用 `@Concurrent` 导出 `collectPerformanceResources()`，由 `DeveloperDiagnostics.sample()` 通过 `taskpool.execute()` 调用：

```text
UI 线程                           taskpool 工作线程
hidebug.getAppVMMemoryInfo()  ─┐
taskpool.execute(probe)       ─┼→ hidebug.getAppNativeMemInfoAsync()
                              │  hidebug.getCpuUsage() * 100
                              │  getAppThreadCpuUsage() → 前 32 个线程
结果返回，检查代次与前后台  ←──┘
```

- VM 堆必须在 UI VM 读取，工作线程只负责慢 IPC 与 smaps 采集。
- 探测失败时各字段为 `-1` 并带系统错误码，不把失败样本当零值补入统计。
- `sampling` 标记阻止重入；异步结果返回后检查采集会话与前台状态，旧任务不会污染下一次采集。
- `diagnostics.resourceProbe` 记录工作线程排队、探测与返回的总耗时；采样任务自身的消耗也计入被测进程。
- CPU API 使用平台原始口径乘 100，不与不同分母的外部工具直接比较。

## 滚动日志与联合导出

每 5 秒（20 个 250 ms tick）异步追加一批 JSONL；进入后台、停止采集和导出前也会冲刷。每份日志约 4 MiB 时轮转，保留当前 `performance-current.jsonl` 与前一份 `performance-previous.jsonl`，单批数据可能让文件略超阈值。写入处理短写；失败通过诊断状态与 `diagnostics.error` 报告。进程异常退出可能丢失最后约 5 秒，这不是同步崩溃日志。

“停止并导出”先停止采集并等待落盘，再序列化 schema 2 诊断包：

| 字段 | 内容 |
| --- | --- |
| `application` / `platform` / `clock` | 应用信息、平台、单调时钟说明 |
| `definitions` | 各指标口径与限制的固定说明 |
| `capture` | 全程统计、性能事件与运行日志快照 |
| `traceEvents` | 性能事件与日志按共享序号合并的 Chrome Trace 事件 |
| `journal` / `previousJournal` | 两份 JSONL 原文 |
| `diagnosticError` | 当前诊断错误标记 |

导出包写到缓存目录后交给系统文件选择器或分享。时间线使用逻辑进程/线程分组，不冒充真实内核 TID；真实线程 ID 保留在资源事件的 `operationId` 中。导出的副本由用户管理，应用不会自动上传，也不会在正常模式持续生成日志。

CPU Profile 是单独操作：`hidebug.startJsCpuProfiling()` 最多运行 30 秒，进入后台或停止采集都会结束。文件写在 application `filesDir/tinybot-cpu.json`，单独导出，可用支持 Chrome CPU Profile 的工具查看。

“清除诊断数据”会停止采集，删除两份日志、缓存诊断包与 CPU Profile，并清空内存统计。

## 错误来源编号

开发者页与导出包中的 `diagnostics.error` 用固定编号标明来源：

| 编号 | 来源 |
| --- | --- |
| 1 | 偏好存储 |
| 2 | 移除系统事件订阅 |
| 3 | 资源探测 |
| 4 | 帧回调 |
| 5 | 订阅系统事件 |
| 6 | 日志文件写入 |
| 7 | CPU profiler |

停止采集后发生的错误还会写入导出元数据 `diagnosticError`。诊断页与导出使用同一份错误状态，避免只在其中一个位置可见。

## 性能验证脚本

每步的 `context.prefix` 和 `context.request_prefix` 日志记录 system/工具指纹、完整相同消息数、共享字符数及变化类别：`cold` 表示本轮尚无比较基线，`append` 表示消息是前次请求的追加扩展，其余为 `tools`、`system` 或 `history` 变化。指纹仅供诊断，实际比较使用原字符串；这些字段不表示服务端缓存命中，也不包含提示词或结果正文。

| 脚本 | 覆盖 |
| --- | --- |
| `node scripts/test-developer-diagnostics.cjs` | 关闭路径零开销、容量与分位数、解锁限制、失效异步结果、采样生命周期、可选帧回调、CPU profiler 停止、批量落盘、短写、轮转、失败重试、清除与导出 |
| `node scripts/test-unified-logging.cjs` | 前置门控不读字段/时钟、白名单与脱敏、引用编号、异常分类、HiLog 适配器、调用点登记 |
| `node scripts/test-prefix-cache.cjs` | 前缀扩展、快照落盘、跨轮及重载、权限撤销、压缩重准入、团队公共上下文与缓存配置 |
| `node scripts/test-settings-performance.cjs` | 真实会话与 ViewModel 下的设置保存、保存期间继续输入、标题请求不复制历史 |
| `node scripts/test-markdown-performance.cjs` | 增量 Markdown 与全量解析在每个到达边界的一致性、分块渲染 |
| `node scripts/test-usage-performance.cjs` | 10 万条用量记录的统计、分页、取消与事件循环响应 |
| `node scripts/load-diagnostics.cjs` | 原生测试共用的生产采集器与脱敏适配器 |

`test-developer-diagnostics.cjs` 同时包含在 `scripts/test.ps1` 中。帧率、native/GPU 调用栈、调度与多进程内存仍需 DevEco Profiler、HiTrace 或 SmartPerf，应用内数据不能替代这些工具。完整测试入口见[测试与冒烟验证](/dev/testing)。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/model/Diagnostics.ets` | 采集器、事件环、指标聚合、日志入口与开发者解锁门 |
| `entry/src/main/ets/model/DiagnosticLog.ets` | 模块/事件目录、字段白名单与脱敏 |
| `entry/src/main/ets/services/NativeDiagnosticLog.ets` | 唯一的 HiLog 输出适配器 |
| `entry/src/main/ets/services/DeveloperDiagnostics.ets` | 开关持久化、采样生命周期、滚动日志、导出与清除 |
| `entry/src/main/ets/services/PerformanceProbe.ets` | taskpool 中的原生内存、CPU 与线程探测 |
| `entry/src/main/ets/views/DeveloperPanel.ets` | 开发者页、等级切换、标记与导出操作 |
| `entry/src/main/ets/views/WebUiView.ets` | Web 实例与事件埋点示例 |
| `scripts/test-developer-diagnostics.cjs` | 采集与导出回归 |
| `scripts/test-unified-logging.cjs` | 日志门控、白名单与原生输出回归 |
