# Tinybot 系统提示词

提示词集中维护在 `entry/src/main/ets/model/SystemPrompt.ets`。参考本地 pi 源码 `packages/coding-agent/src/core/system-prompt.ts`（`6f1072cc0`）的分层结构，自行编写适合手机助手的内容，不继承 pi 的终端、编程或文档访问能力。

上游参考：[pi system-prompt.ts](https://github.com/earendil-works/pi/blob/6f1072cc0/packages/coding-agent/src/core/system-prompt.ts)。

## 组成

1. `DEFAULT_SYSTEM_PROMPT`：身份、主动执行、核验、沟通风格。设置页可编辑。默认按用户消息语言回答，支持中文和英文；界面语言切换不改写用户提示词。
2. `runtimeInstructions`：每次请求附加工作区范围、工具使用和执行限制。网页章节仅在启用网页读取时加入。实际工具定义是能力依据，员工受限工具也必须遵守这个边界。
3. `skillCatalog`：沿用已有逻辑，按启用状态和显式选择附加 Skills 目录，需要时读取正文。
4. `CHAT_TEAM_INSTRUCTIONS`：只对开启团队模式的聊天主 Agent 附加，涵盖按需招募、路径分工、事件等待、交接核验和最终整合。
5. `teamWorkerInstructions`：员工任务范围和内部交接要求。仅聊天团队员工需要 `team_complete_task`；旧团队执行路径不虚构此工具。

主 Agent 和员工共用基础风格与工作区边界。员工不继承主 Agent 的招募指令。记忆、会话分支说明和任务上下文仍由现有调用方追加。

## 升级与验证

加载旧数据时，只将两个曾发布的默认提示词精确匹配升级；自定义内容（包括空白内容）保留。提示词不会因 UI 中英文切换而被翻译。

`SystemPrompt.test.ets` 覆盖旧版本迁移、自定义内容保留、条件章节组合和员工交接差异。全套测试：`scripts/test.ps1 -StudioPath 'D:\DevEco Studio'`。这些测试验证组装行为；真实模型执行仍受模型能力、上下文和工具结果影响。
