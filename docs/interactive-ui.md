# 聊天中的交互回答

模型可将普通文字与 `tinybot-ui` JSONL 界面组合在同一条回答中。完整记录到达后逐步渲染原生组件；界面闭合后开放交互。简单问题仍适合直接用文字回答。

协议和模型指引分别位于 `model/InteractiveUi.ets` 与 `model/InteractiveUiInstructions.ets`。这是 Tinybot 自己的客户端协议，不依赖特定模型或 ChatGPT 私有接口。

## 按文件发布预览

生成的 SVG、HTML 或较大的界面应先写入工作区，再调用 `publish_preview({"path":"pelican.svg","title":"Pelican"})`。支持 `.svg`、`.html` 和不带代码围栏的 `.jsonl`；前两者由客户端序列化为一个 Web 节点，JSONL 则使用完整的 `begin` / `node` / `action` / `end` 记录。JSONL 中的 `node.data` 仍用 `JSON.stringify` 序列化；无须保存交互状态时，空 `state: {}` 合法。

工具只读取一次文件，校验协议并运行现有设备 Web 启动检查，通过后把该快照随工具记录保存。之后修改或删除文件不会改变已发布预览；重启、分支和状态操作均使用快照。模型只收到路径、标题和发布结果，不收到完整预览内容，也不应在最终回答中再次抄写 JSON。下载、分享和导出文件仍用 `present_files`。

HTML 必须自包含，沿用 Web 沙箱的网络、文件和设备权限限制；需要原生控件、声明状态、独立 `js` 或 Three.js 时，使用 JSONL。启动检查失败或取消不会发布预览。解析错误指出文件（工具调用时）、surface、JSONL 行和嵌套 `node.data` 字段；引擎提供偏移时同时给出字符位置，否则保留错误及有界片段，不猜测位置或把语法错误归因于空状态。修复源文件后再次发布即可。

## 失败后的局部修复

恢复指引使用英文，按结构化错误类型选择，不匹配本地化错误文案。`publish_preview` 保留 `PREVIEW_INVALID` / `fix_preview_file`，并在 `details` 中提供 `category`、文件 `path` / `version`、`location`、有界 `excerpt` 和 `repair.instruction` / `repair.retry`。重试参数保留原始路径及可选标题，不包含完整源码。

| 类型 | 恢复动作 |
| --- | --- |
| `JSON_SYNTAX` | 区分外层 JSONL 与嵌套 `node.data`，读取出错位置，用 `edit_file` 局部修正转义后重新发布。 |
| `INVALID_FIELD` | 按字段和约束修改，例如 `node.data.height` 必须是 200–800 的数值。 |
| `WEB_STARTUP_FAILED` | 检查启动错误和堆栈；宿主或设备能力不可用时先解决该条件，不反复改写有效源码。 |
| 文件版本过期、未读取、匹配缺失或不唯一 | 保留原文件，重新读取，选取有足够上下文且唯一的 `oldText`。 |

行号从 1 开始。嵌套 JSON 的 `character` 是解码后 `node.data` 内的位置，由 `characterScope` 标明，不能直接当作源文件列号。`locationScope` 区分 `jsonl_source` 与 SVG/HTML 自动生成的 `generated_wrapper`；不把包装记录的行号冒充 HTML/SVG 文件行号。

普通聊天直接输出的 `tinybot-ui` 校验失败后，会按 surface 把原始 JSONL 保存到工作区 `preview-repairs/<唯一ID>-<surface>.jsonl`，在持久化的错误报告中提供每个已保存文件的路径、版本及 `publish_preview` 重试调用。Agent 读取这些文件并局部修改即可，无须重新抄写整段回答。去掉外层 Markdown 围栏不改变 JSONL 内容；如果只是缺少闭合围栏，暂存文件可直接发布。该回答的所有 surface 均未发布，修复后要分别发布仍需展示的 surface。

只读模式不暂存文件；超过 8 个 surface 或保存失败会明确报告原因，部分保存只返回实际成功的路径。取消不触发模型重试。团队成员的直接输出目前沿用诊断恢复；已有文件的 `publish_preview` 错误指引与普通聊天一致。恢复报告随会话保存、重启后可重放；原始失败回答也保留，不在此处做上下文裁剪。Web 启动检查只覆盖启动，不保证后续所有交互正确。

## 原生能力

- `column`、`card`、`row` 组合内容；行的实际可用宽度小于 400vp 时单列，达到 400vp 后两列。隐藏的节点不占位置。
- 文字、Markdown、HTTPS 图片、图表、表格、指标与声明式图形可以和控件混排。
- `input`、`number`、`select`、`toggle`、`slider` 支持输入和参数调整。
- `segmented` 用于分区切换，绑定字符串；接受 2–6 个不重复选项，每项最多 24 个字符。窄屏可横向滚动，长选项或大量选项应使用 `select`。
- `stepper` 使用原生减/加按钮调整数值，必须指定 `min`、`max`，`step` 默认 1。到边界时按钮禁用，结果不会越界。
- `checkbox` 绑定布尔值，适合任务清单；可以通过计算动作汇总已完成数量，再用 `progress` 展示进度。`toggle` 更适合持续生效的设置。
- 所有节点可通过 `visibleKey` / `visibleValue` 控制显示，配合分段选择实现分页、分步说明和条件表单。

例如：

```json
{"op":"begin","version":1,"title":"人数调整","state":{"people":4,"each":30}}
{"op":"node","node":{"id":"people","kind":"stepper","text":"参加人数","bind":"people","min":1,"max":12,"action":"calculate"}}
{"op":"node","node":{"id":"result","kind":"heading","text":"每人 {{each}} 元"}}
{"op":"node","node":{"id":"copy","kind":"button","text":"复制结果","action":"copyResult"}}
{"op":"action","action":{"id":"calculate","kind":"compute","code":"input.each = Math.round(120 / input.people * 100) / 100; return input;"}}
{"op":"action","action":{"id":"copyResult","kind":"copy","text":"{{people}} 人，每人 {{each}} 元。"}}
{"op":"end"}
```

模型实际输出时使用 `tinybot-ui` 语言标记，而不是上例文档使用的 `json`。

## 动作与状态

输入提交后，`compute` 在既有 QuickJS 沙箱执行，`set` 更新指定字段，`reset` 恢复初始值；这些动作不会请求模型。状态按消息和界面保存，重启可恢复，创建会话分支时独立复制。计算必须返回相同字段和类型的完整状态，越界、保存失败或计算错误会明确显示。

`copy` 只能由明确的按钮触发：其 `text` 模板可使用当前状态字段，复制的是替换后的纯文本；成功提示“已复制”，失败显示错误。它不读取剪贴板、不请求模型、不改变会话状态，也不会在渲染、重启或输入变化时自动执行。

`submit` 按钮明确表示发送或继续对话，将当前输入作为独立用户事件交给模型，保留输入框内未发送的草稿。

## Web 场景与边界

复杂 HTML/CSS 界面、Canvas 动画、模拟和 Three.js 场景可以放在 `web` 节点中。整个界面完整生成后，才在隔离 ArkWeb iframe 执行。Web 无网络、文件、设备权限、外部依赖加载或本地存储权限；只通过状态桥保存声明过的字段。普通 Markdown 与原生节点不会执行 HTML 或脚本。

没有原生地图/地理服务组件，也没有自动图片检索与素材选择链路。图片须使用已提供或核实的 HTTPS 地址；不能把示意图当作真实地图，不能虚构图表来源。模型生成质量仍依赖所选模型，本地协议和提示词不能替代模型训练。

## 验证

构建 HAP 后运行：

```text
node scripts/test-interactive-ui.cjs
node scripts/test-interactive-ui-renderer.cjs
node scripts/test-preview-publication.cjs
```

需将 `DEVECO_STUDIO_HOME` 指向本机 DevEco Studio。上述测试覆盖协议、持久化及真实编译后的控件回调，预览测试还通过实际 SessionService / AgentRuntime / 文件工具验证“大输入失败 → 暂存 → 读取 → 小范围替换 → 再发布”，并覆盖只读、保存失败、取消及编辑冲突。真机验收应覆盖分段切换、步进、勾选、复制、窄屏布局和重启恢复；固定输入验证客户端行为，不等于模型生成质量评测。
