# 新增工具

工具是模型能做的事：一个工具类同时决定“模型看得见的 schema”和“执行路由”，两者来自同一份目录，不存在单独放行或单独隐藏的开关。

## 先确定归属

| 问题 | 影响 |
| --- | --- |
| 属于内置组还是可选能力 | `model/ToolGroups.ets` 的 `TOOL_GROUPS` 与 `TOOL_CAPABILITIES` |
| 是否只读 | 只读组在“只读模式”下仍可执行；写入组会被 `RuleTools` 拦截 |
| 是否默认直接可见 | 所有已启用且获授权工具默认直接提供；无需加入额外白名单 |
| 是否需要逐次审批 | 需要时走 `ToolApproval`，参考 `InteractionTools` 与 `McpTools` |

## 1. 实现工具类

工具类实现 `AgentTools`（定义在 `services/AgentLoop.ets`）：

```ts
export interface AgentTools {
  definitions(): ToolDefinition[]
  execute(call: ToolCall, cancellation: Cancellation, context?: ToolInvocationContext): Promise<string>
  beforeFinish?(cancellation: Cancellation): Promise<string | undefined>
}
```

`definitions()` 返回给模型的工具定义；`execute()` 返回字符串回执，失败时抛 `ToolFailure`。`beforeFinish()` 用于在模型准备结束时追加一条续跑指令；目前内置实现该钩子的是聊天团队（`ChatTeamTools`），其余包装层只做转发。

`ToolDefinition` 的关键字段：

| 字段 | 作用 |
| --- | --- |
| `function.name` | 工具名，`^[A-Za-z0-9_-]{1,64}$`；同名工具会被 `ToolSet` 拒绝 |
| `function.description` | 模型路由依据；写清“何时用、何时不用” |
| `function.parameters` | JSON Schema；数组、对象、枚举和范围都要显式声明 |
| `executionMode` | `sequential` 会让同一批响应中的所有工具按顺序执行 |
| `promptSnippet`、`promptGuidelines` | 仅进入系统提示词的本地说明，不会序列化进 provider schema |

硬限制：单步最多 8 个工具调用（`MAX_TOOL_CALLS`），单次参数最多 96 KB（`MAX_TOOL_ARGUMENTS`，`execute_code` 例外），单轮最多 200 次模型请求。

## 2. 参数与失败

```ts
const args = parseToolArguments(call.function.arguments) as MyArgs
if (!args.path) {
  throw new ToolFailure('INVALID_ARGUMENTS', t('缺少 path 参数。'), 'fix_arguments')
}
```

- `parseToolArguments` 只做 JSON 解析；类型、范围和必填要自己校验。
- `ToolFailure(code, message, recovery, details?)` 的 `code` 稳定、可诊断，`recovery` 描述建议动作；两者都不授权自动重试。
- HTTP 错误用 `toolHttpFailure(status, message, service)` 归类，不要靠匹配本地化文案。
- 已有领域回执需要保留时抛 `ToolResultError`，它会在原 JSON 上补充 `error`、`code`、`recovery`。

错误码表见[回执与错误](/reference/receipts)。

## 3. 登记权限与能力

在 `model/ToolGroups.ets` 里把工具名加入对应组：

```ts
{ id: 'workspace-read', readOnly: true, tools: ['list_files', 'read_file', 'my_lookup'] }
```

- 只读模式由 `RuleTools` 依据 `readOnly` 判定；没有登记进任何组的工具不会被只读模式拦截。
- 需要出现在“自定义能力”设置里，就同时加入 `TOOL_CAPABILITIES`；`OPTIONAL_TOOL_NAMES` 会自动派生。
- 迁移旧配置时注意 `MANAGED_TOOL_NAMES`：记忆与 Skills 由助手设置和 Skills 页面管理，不走会话开关。

## 4. 组装进工具目录

在 `services/NativeSessionService.ets` 的 `tools()` 中把新组加入 `groups`，位置决定目录顺序：

```ts
const groups: AgentTools[] = [new WorkspaceTools(new NativeWorkspaceFiles(root)), /* ... */ new MyTools()]
return new RuleTools(new ToolSet(groups), productivity?.options?.readOnly === true)
```

`ToolSet` 会拒绝重复工具名，并按目录顺序拍平 schema；未启用的工具在执行时返回 `TOOL_UNAVAILABLE`。

## 5. 决定可见性

默认情况下工具启用并通过权限过滤后立即提供完整 schema，没有额外的按需加载白名单，也不存在需要登记的“常驻工具”列表。`ToolCatalog` 会按名称稳定排序；维护稳定的定义，避免普通调用改变声明集，用能力开关、只读与角色规则控制可用性。

## 6. 提示词与 UI 呈现

- 工具的行为约束写在 `promptSnippet` / `promptGuidelines`，不要塞进 `description` 以外的位置；组装顺序见[系统提示词与上下文](/internals/prompt)。
- 工具在聊天里的标题来自 `model/ToolPresentation.ets`；分类与分组展示在 `model/ProcessPresentation.ets`。
- 需要展开/折叠的详细回执由 `views/` 下的工具详情组件渲染，回执结构要与分页、失败状态兼容。

## 7. 测试

| 验证 | 命令或位置 |
| --- | --- |
| schema 合法、Chat Completions / Responses / Anthropic 请求结构 | `node scripts/test-tool-schemas.cjs` |
| 完整目录、稳定排序、权限撤销 | `node scripts/test-tool-catalog.cjs` |
| 目录即权限、只读拦截 | `ToolSet.test.ets` 或新增单测 |
| 自定义能力开关 | `node scripts/test-custom-tools.cjs` |

单测用可控的假工具验证参数校验与回执，不依赖真机和模型密钥。

## 检查清单

1. 工具名唯一、符合字符集，描述说清适用与不适用场景。
2. 参数有 `required` 与边界，错误走 `ToolFailure`。
3. 已登记 `TOOL_GROUPS`，并按需登记 `TOOL_CAPABILITIES`。
4. 已在 `NativeSessionService.tools()` 组装。
5. 确认排序与 `ToolCatalog` 的稳定目录一致，不依赖调用顺序。
6. 回执能被 `ToolPresentation` 渲染，长文本支持分页。
7. 词条已加入双语 JSON 并通过 `build-locales.cjs --check`。
8. 相关脚本与单测通过。
