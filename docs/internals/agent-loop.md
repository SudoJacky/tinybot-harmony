# 轮次、流式与重试

这一页说明一次运行（run）如何开始与收尾、模型-工具循环怎样推进、流式（streaming）数据如何分帧，以及在什么条件下重试（retry）、什么条件下立即失败。持久化细节见[会话与持久化](/internals/session)，协议差异见[模型服务与凭据](/internals/providers)。

## 运行的生命周期

`AgentRuntime` 拥有单个活动任务，从预检直到最终持久化。禁止重入由 `this.active` 保证：已有任务时 `run()` 直接抛错“Agent 正在执行，请等待本轮结束。”

```text
run(request, hooks)
  1  拒绝重入；创建 ActiveRun（id 递增、Cancellation、idle Promise）
  2  冻结 config、工具选择与消息副本；校验工具选择
  3  providers.bind() → BoundModel；若配置了执行闸门则包成 ControlledModel
  4  emit run_start
  5  hooks.checkpoint()                 首条用户消息落盘
  6  hooks.prepare(cancellation)        工作区补齐、后台生成标题
  7  hooks.prepareContext(...)          可选，压缩等预处理
  8  phase = executing → runAgentLoop()
  9  status = complete | stopped | failed
 10  phase = finalizing；emit run_finishing；hooks.checkpoint()
 11  emit run_end；清空 active；释放闸门；resolve idle
```

| 输入 | 默认 | 约束 |
| --- | --- | --- |
| `maxSteps` | `MAX_AGENT_STEPS` = 200 | 调用方可降低为 1–200，越界抛错 |
| `contextOnly` | `false` | 为真时只执行上下文准备（标题、压缩），不进入模型/工具循环 |
| `toolExecution` | 未指定 | 传给工具批次；未指定时按工具定义决定顺序或并发 |
| `usageOrigin` | 未指定 | 用量账本的会话、轮次、用途归属 |

收尾顺序是固定的：`run_finishing` 之后仍会执行一次检查点；这次保存失败会把状态改为 `failed`，但不会跳过后面的 `run_end` 与清理。活动槽位在 `finally` 中清空，因此下一个任务不会与最终持久化重叠。

## 订阅、abort 与 waitForIdle

| 成员 | 行为 |
| --- | --- |
| `subscribe(listener)` | 同步回调，返回取消订阅函数；事件带运行状态、步骤、工具调用 ID 与增量文本 |
| `abort()` | 无活动任务、已在 `finalizing` 或已取消时不做任何事；否则取消信号并 emit `run_stopping` |
| `acceptsSteering` | 有活动任务、未进入 `finalizing`、未被取消时为真 |
| `waitForIdle()` | 返回当前任务的收尾 Promise；无任务时立即完成 |
| `fork()` | 共享 provider、凭据、用量、校验器与闸门，但拥有独立的活动槽位；标题、记忆与团队员工使用它 |

事件类型是循环事件加运行事件：`run_start`、`step_start`、`text_delta`、`reasoning_delta`、`model_end`、`tool_start`、`tool_end`、`step_end`、`request_retry`、`run_stopping`、`run_finishing`、`run_end`。`SessionService` 只转发 `sessionId` 匹配的事件，迟到的回调不会改写已结束的回答。

执行闸门（`ExecutionGate`）让外部资源在任何模型请求与工具调用前后排队；原生组装把 `BrowserSession` 作为闸门传入。闸门在运行结束时 `release()`。

## 模型-工具循环

`runAgentLoop()` 不访问 ViewModel、凭据、注册表或 UI，只依赖绑定的 `ModelSession`、工具、取消信号与观察者。

```text
对每一轮 round（0 .. maxSteps-1）：
  等待闸门 → cancellation.check()
  读取一条追加指令；只接受 steer 模式
  definitions = tools.definitions()
  prepareRequest(definitions, 待发消息, cancellation, 恢复标记)
       → 指令段 + 历史投影 + 待发消息；必要时先压缩
  新建 step 并追加到 turn.steps → emit step_start
  若有追加指令：consume(id) 与 checkpoint 同一次完成
  requestWithRetry(model.stream)
       正文增量写 step/turn；推理增量写 step.reasoningContent
  成功后以模型返回值覆盖正文（最终消息为权威）
  校验工具调用：数量、ID 唯一、格式
  无工具调用 → beforeFinish / 后续指令 / 结束
  末轮仍有工具 → 全部标为未执行并抛错
  executeToolBatch(step, ...)
  重复调用提醒 → 刷新工具结果 → messages.push(stepMessages)
  emit step_end
finally：interruptTools(turn.steps)
```

几个容易忽略的细节：

- 每一步都先进入 `turn.steps`，界面因此能看到“正在请求模型”的阶段；上下文溢出的请求以 `requestError` 保留现场，但不当作模型输出回放，其他请求失败会终止本轮。
- 模型返回的最终文本会覆盖流式累积的 `step.content`，避免增量丢失或重复。
- 工具调用 ID 在本轮内必须唯一，重复 ID 会终止本轮。
- 没有工具调用但存在追加指令或团队交接（`beforeFinish`）时，循环继续而不是结束。
- 最后一步若仍要求工具，会把该批工具标为 `cancelled` 并说明“已达到本轮 N 次模型调用上限”，不执行。

固定上限：

| 项目 | 值 | 位置 |
| --- | --- | --- |
| 单任务模型调用 | 200 | `MAX_AGENT_STEPS` |
| 单次响应的工具数量 | 8 | `MAX_TOOL_CALLS` |
| 单工具参数 | 96 KiB（`execute_code` 除外） | `MAX_TOOL_ARGUMENTS` |
| 单步推理内容 | 1 MiB | `MAX_REASONING_CONTENT` |
| 单帧 / 缓冲 | 1 MiB 字符 | 各流解析器 |
| 连接超时 | 15 秒 | `ProtocolProvider` |
| 流空闲超时 | 120 秒，每次非空数据重置 | `STREAM_IDLE_TIMEOUT_MS` |

## SSE 分帧与工具参数组装

`ChatStream` 自己维护缓冲区，因此分块边界可以落在任意字节上，包括 CRLF 中间：

1. `push(text)` 追加到 `pending`；缓冲超过 1 MiB 直接报错。
2. 逐行扫描：去掉行尾 `\r`；空行触发一次 `dispatch()`；以 `data:` 开头的行去掉前缀与一个可选空格后进入当前帧，帧累计超过 1 MiB 报错。
3. `dispatch()` 把多行 `data:` 用换行拼成负载；`[DONE]` 只置结束标记；其余按 JSON 解析。
4. 只处理 `choice.index === 0`；`delta.content` 与 `delta.reasoning_content` 必须是字符串；`finish_reason` 只能出现一次，之后任何正文、推理或工具片段都会报错。
5. `finish()` 要求已收到结束标记、结束原因为 `stop` 或 `tool_calls`、缓冲与帧都已清空；`length` 与 `content_filter` 给出专门提示，其余情况视为回答不完整。
6. 工具调用按 `index` 累积：`id`、`function.name`、`function.arguments` 都是分片拼接；索引必须连续，`type` 只能是 `function`；ID 上限 128 字符、名称上限 64 字符、参数上限 96 KiB（`execute_code` 除外）。
7. 结束原因与工具调用必须一致：`tool_calls` 却没有任何调用、或反之，都报错；既无工具又无正文同样报错。

Responses 与 Anthropic 共用 `EventFrames` 的分帧逻辑，但完成语义各自实现：

| 解析器 | 结束判定 | 文本权威来源 | 额外保留 |
| --- | --- | --- | --- |
| `ChatStream` | `[DONE]` + `finish_reason` | 累积正文，结束后整体返回 | 推理文本 |
| `ResponsesStream` | `response.completed` | 最终 `response.output`，必须与流式文本一致 | 推理摘要分段去重 |
| `AnthropicStream` | `message_stop` + 白名单结束原因 + 所有内容块关闭 | 累积正文 | 完整有序内容块（含签名的思考） |

## 重试策略

`requestWithRetry()` 只重试当前这一次模型请求，不重试外层工具批次，也不重放已完成步骤。

| 情况 | 是否重试 | 依据 |
| --- | --- | --- |
| HTTP 408 / 429 / 500 / 502 / 503 / 504 | 是 | `httpProviderError()` 返回 `TransientProviderError`，额度类错误码除外 |
| NetworkKit 错误码 2300005、2300006、2300007、2300028、2300052、2300056 | 是 | `ProtocolProvider` 标记为 `transport` |
| 流空闲超过 120 秒 | 是 | `TransientProviderError('timeout')` |
| 其余 HTTP（含 400、401、403、404、413、422） | 否 | 鉴权、参数或额度问题重试无意义；明确表示上下文溢出的 400/413/422 走单独恢复 |
| 流式 JSON、结构、完整性错误 | 否 | 说明协议或服务异常 |
| 上下文溢出 | 单独恢复 | `ContextOverflowError` 走压缩后重试一次 |

次数与节奏：首次请求为第 0 次尝试；失败后最多再试 2 次，等待 1000 ms 与 2000 ms。已达 2 次或该步已登记工具调用时直接抛出。

每次重试会：

- 丢弃本次未完成的正文与推理（`step.content = ''`、`step.reasoningContent = ''`），并用未出错的步骤重新拼接整轮正文。
- 记录一条 `RequestRetry`（序号、延迟、错误码、是否等待中）并通知界面，重试原因单独显示。
- 在进入等待前保存一次状态，等待结束后再保存一次；任一次保存失败都不会发出下一次请求。
- 旧尝试的迟到增量由 `acceptingText` 标志丢弃，取消后同样不再写入。

## 取消信号

每次运行创建一个 `Cancellation`，贯穿准备、凭据读取、网络、工具与等待：

| 位置 | 行为 |
| --- | --- |
| `BoundModel.stream()` | 读取密钥前后各检查一次 |
| `ProtocolProvider` | 注册 `onCancel`，取消时以 `RunCancelledError` 结束请求并 `destroy()` |
| `retryDelay()` | 监听取消，清除定时器并拒绝等待 |
| `runAgentLoop` | 每轮开始、请求前后、工具批次前后检查 |
| `executeToolBatch` | 开始前检查；已启动的工具允许执行完并保存结果 |
| `SessionService.runTask` | 取消时同时停止团队执行 |

取消让运行以 `stopped` 收尾，而不是 `failed`；已提交的写入保留，不自动回滚。

## 工具结果缺失与中断

工具状态取值为 `pending`、`running`、`complete`、`failed`、`cancelled`、`interrupted`。运行被中断时 `interruptTools()` 做确定性映射：

| 中断时状态 | 结束状态 | 回执内容 |
| --- | --- | --- |
| `pending`（从未开始） | `cancelled` | `NOT_EXECUTED`，本轮已中断，此工具未执行 |
| `running`（可能已有副作用） | `interrupted` | `OUTCOME_UNKNOWN`，再次写入前先检查工作区 |

历史回放时：

- 有工具调用或追加指令的回答会保留工具结果，即使回答没有完成；未完成的正文被排除。
- 回答状态不是 `complete` 时追加一条系统可见说明：“上轮执行已中断。已接收的追加指令和以上工具结果仍保留；不要假设文件操作已经回滚。”
- UI 校验失败时，该步工具直接标为 `cancelled` 并附 `NOT_EXECUTED`，不会执行。
- 运行结束前 `finally` 总会调用 `interruptTools(turn.steps)`，因此不会留下永久 `running` 的记录。

## 上下文溢出的恢复

模型服务明确报告输入超过窗口时（错误码 `context_length_exceeded`、`context_window_exceeded`，或 `prompt is too long: N tokens > M maximum`）：

1. 该步标记 `requestError = 'context_overflow'`，保留现场并保存检查点。
2. 若此前没有恢复过、不是最后一轮、且提供了 `prepareRequest`，则带上恢复标记进入下一轮。
3. `RequestContext.prepare()` 在恢复模式下压缩较早历史（保留量不超过历史的一半），然后重新请求一次。
4. 关闭自动压缩、没有可压缩轮次或恢复后仍溢出时，直接失败并提示压缩历史、缩小任务或提高窗口。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/services/AgentRuntime.ets` | 运行生命周期、绑定、订阅、abort、waitForIdle、收尾检查点 |
| `entry/src/main/ets/services/AgentLoop.ets` | 模型/工具循环、步数上限、事件与检查点调用 |
| `entry/src/main/ets/services/ToolExecution.ets` | 工具批次调度、意图与结果检查点、中断映射 |
| `entry/src/main/ets/services/ChatStream.ets` | Chat Completions 分帧、工具参数组装、完整性校验 |
| `entry/src/main/ets/services/providers/EventStreams.ets` | Responses 与 Anthropic 流解析 |
| `entry/src/main/ets/services/providers/ProtocolProvider.ets` | 网络请求、空闲超时、取消与错误分类 |
| `entry/src/main/ets/services/RequestRetry.ets` | 重试次数、延迟、丢弃未完成输出 |
| `entry/src/main/ets/services/Cancellation.ets` | 取消信号 |
| `entry/src/main/ets/model/Agent.ets` | 步骤结构、上限常量、`stepMessages`、`interruptTools` |
| `entry/src/main/ets/model/Conversation.ets` | `requestHistory()` 的历史回放规则 |