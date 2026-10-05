# 输入框推理强度

输入框工具栏以当前档位文字作为按钮，点击打开分档滑块，不显示闪电图标。卡片顶部仅保留当前档位、模型和重置按钮，
不再显示左上角闪电；拖动时同步预览滑块、输入框档位文字与最高档粒子效果，松手后仅保存一次。
保存期间保持目标档位，等已保存状态接管；父组件刷新不重置拖动位置，失败才回退并提示。
预览不写入会话设置，关闭弹层时丢弃未提交预览，切换会话或模型后不沿用。配色跟随应用主题。
档位直接显示 API 原始名称，按协议和已知模型筛选，不把不同协议强行映射为固定四档。

| 协议 | 请求字段 | 标准档位（实际可用子集取决于模型） |
| --- | --- | --- |
| OpenAI Chat Completions | `reasoning_effort` | `none`、`minimal`、`low`、`medium`、`high`、`xhigh`、`max` |
| OpenAI Responses | `reasoning.effort` | 同上 |
| Anthropic Messages | `output_config.effort` | `low`、`medium`、`high`、`xhigh`、`max` |

例如 GPT-5.2 提供 `none/low/medium/high/xhigh`，Claude Opus 4.6 提供
`low/medium/high/max`，Claude Opus 4.5 提供 `low/medium/high`。
已知不支持 effort 的模型隐藏入口。无法识别的网关别名显示该协议的完整候选集，
是否接受仍取决于服务端模型；模型能力规则需要随厂商版本更新。

明确选中当前模型最高档位时，输入框底部显示与消息气泡同色的绿色柔光和 24 个漂移粒子，
每轮漂移为 6 秒。柔光及档位底色复用 `user_bubble`，文字使用 `on_accent_container`，
粒子使用同色系的 `accent` 保持可见性，统一使用应用的浅色/深色主题资源。
最高档按模型计算，可能是 `high`、`xhigh` 或 `max`；
默认继承状态、较低档位和已归档会话不启用效果。布局、输入、发送和滑块操作保持不变。
`common/ComposerGlow.ets` 是依据视觉参考独立实现的原生 Canvas 装饰，没有复制 React Bits
组件代码，也没有引入 React、motion 或图标依赖。装饰不参与点击与无障碍导航，
离开可见区域或组件销毁时取消动画，绘制更新限制在约 30 fps。

选择保存在当前会话的 `reasoningEffort` 字段中。默认档清除此覆盖值，继续使用
助手设置里该模型的默认强度；未配置时由服务决定。切换到其他模型时清除覆盖，
重新选择同一模型则保留。新会话使用默认，分支继承来源会话的选择。

「默认」是应用内继承状态，不会作为字符串 `default` 发送给 API。助手设置也使用
相同的模型档位列表。过时或不兼容的已保存设置在构造请求时回退到默认。

Anthropic 已知支持 adaptive thinking 的模型在明确选择 effort 时附加
`thinking: { type: "adaptive" }`。Opus 4.5 仅发送 effort，不自行猜测 `budget_tokens`。
旧模型的思考预算是另一个参数，本滑块不将它伪装成 effort。未知别名不自动启用 adaptive。
输出 token 上限沿用原有配置。

Responses 对支持推理的模型请求 `reasoning.summary: "auto"`，独立于 effort；默认档不强制
指定 effort，切换档位也不覆盖 summary。已知非推理模型（如 GPT-4.1）不附加该参数；未知
网关别名沿用现有推理能力判断，是否支持摘要取决于服务端。

Responses 解析 `response.reasoning_summary_text.delta` 和 `response.reasoning_text.delta`，
将收到的可显示文字传给过程区。按输出项及段落分别累积，`*.done` 与 `response.completed`
中的完整文本只补齐尚未收到的后缀，避免重复显示；仅在最终结果返回的摘要也会显示并保存。
思考文字写入每步的 `reasoningContent`，重新打开会话后仍可展开查看，不混入最终回答。
`encrypted_content` 不作为正文，也不会将可见摘要伪造成 Responses 原生推理输入。
OpenAI 返回的是思考摘要，不是内部原始思考 token；服务端未返回可显示文字时，只保留执行状态。

Anthropic 流式响应解析 `thinking_delta` 和 `signature_delta`，思考文本进入现有过程展示。
完整、有序的原生内容块（包括签名和 `redacted_thinking`）独立保存，工具调用续轮原样回传，
避免把签名思考块丢失或重建。签名及加密内容不显示在正文，也不会发送到 OpenAI 协议。
未完成流、无签名思考块和超限记录会被拒绝。

自动路由或团队工作者选择其他模型时，使用那个模型自己的设置，当前会话覆盖不跨模型传递。
生成过程中禁止修改，避免改变已经运行的任务。保存失败时保留原值并提示错误。

实现位置：

- `views/ReasoningEffortPicker.ets`：原生 Slider 弹出卡片。
- `views/ChatPanel.ets`：输入框入口。
- `services/SessionService.ets`：原子保存、模型隔离和请求配置。
- `model/Conversation.ets`：持久化字段校验。
- `model/ReasoningEffort.ets`：协议和模型档位规则。
- `services/providers/ReasoningRequest.ets`：三个协议的参数序列化。
- `model/AnthropicContent.ets`、`services/providers/EventStreams.ets`：原生思考块校验与流式解析。

`SessionService.test.ets` 验证请求参数、重启恢复、默认值恢复、会话和模型隔离、
保存失败回滚、无效值及不支持协议的拒绝、自动路由隔离。
`ReasoningEffort.test.ets` 验证模型档位、三种请求格式、分片流、签名/加密内容的
持久化和工具续轮回传、异常记录拒绝。合成协议测试不代表已完成真实 Anthropic 服务验证。
Responses 的分段、完成快照去重、最终摘要、纯文本推理、加密内容隔离和异常片段也有覆盖。
`scripts/test-productivity-native.cjs` 使用实际 Provider、模型绑定、Agent 循环、过程视图模型和
文件存储验证 Responses 思考文本在回答前可见、完成后不重复、重新加载后仍可展开；不代表
已验证所有模型服务或兼容网关的实际返回行为。

参考官方文档：

- [OpenAI reasoning](https://developers.openai.com/api/docs/guides/reasoning)
- [Responses 思考摘要流式事件](https://developers.openai.com/api/reference/resources/responses/streaming-events#response.reasoning_summary_text.delta)
- [Anthropic effort](https://platform.claude.com/docs/en/build-with-claude/effort)
- [Anthropic thinking tool workflows](https://platform.claude.com/docs/en/build-with-claude/thinking-tool-workflows)
