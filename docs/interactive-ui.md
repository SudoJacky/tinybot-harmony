# 聊天中的交互回答

模型可将普通文字与 `tinybot-ui` JSONL 界面组合在同一条回答中。完整记录到达后逐步渲染原生组件；界面闭合后开放交互。简单问题仍适合直接用文字回答。

协议和模型指引分别位于 `model/InteractiveUi.ets` 与 `model/InteractiveUiInstructions.ets`。这是 Tinybot 自己的客户端协议，不依赖特定模型或 ChatGPT 私有接口。

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
```

需将 `DEVECO_STUDIO_HOME` 指向本机 DevEco Studio。上述测试覆盖协议、持久化及真实编译后的控件回调。真机验收应覆盖分段切换、步进、勾选、复制、窄屏布局和重启恢复；固定输入验证客户端行为，不等于模型生成质量评测。
