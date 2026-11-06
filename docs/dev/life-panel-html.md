# Life Panel 交互卡片

Life Panel 支持原生 v1 卡片和 HTML v2 卡片。两者使用同一套看板引用、数据源、刷新任务、运行记录与备份机制。HTML 复用交互预览和小程序的沙箱渲染器。

## 使用方式

- 看板顶部的 **AI 修改** 可以描述新增或修改需求，点击 **生成并验证** 即可在看板内执行。看板说明、卡片引用、视口宽度和已有错误作为独立上下文送入模型；专属编辑对话可继续多轮修改。已有草稿、附件或正在运行的对话不会被覆盖。
- 卡片菜单的 **用 AI 修改卡片** 会指定已有卡片，避免把修改做成另一个副本。
- **添加** 可以复用已有卡片。同一卡片出现在多个看板时，共享数据与用户状态。
- **调整布局** 显示左上角移动把手和右下角尺寸把手。长按标题也可开始拖动；卡片抬升、跟随手指，其他卡片预览让位。缩放时宽度连续跟手，松手后按 S/M/L 栏位吸附，HTML 视口高度可在 200–800 vp 调整；其他卡片自动避让。位置顺序、尺寸按看板保存。
- 点击卡片标题或展开按钮进入大视图。交互数据通过存储接口保留；未保存的 DOM 状态不能依赖页面重新打开后仍然存在。
- **全部刷新** 与卡片内的刷新按钮使用同一套数据源任务。自动任务仍受前台运行限制，不承诺应用退出后的定时执行。

当前布局是响应式瀑布流，不是可层叠的无限画布。桌面悬浮窗、Python 执行和元素批注不属于本次实现。

## 发布 HTML

先读取 `get_life_panel_catalog`。在当前会话工作区写入自包含 HTML，例如 `counter.html`，以及 `counter.panel.json`：

```json
{
  "version": 2,
  "title": "今日进度",
  "size": "M",
  "nodes": [],
  "data": { "total": 0 },
  "dataSchema": { "type": "object", "properties": { "total": { "type": "number" } }, "required": ["total"] },
  "checks": [{ "action": "text", "selector": "#total", "value": "0" }],
  "source": { "type": "workspace-json", "path": "metrics.json" }
}
```

先调用 `validate_life_panel`。上例的 `text` 检查假定文件数据也是 0；实际应按真实来源声明检查。交互卡片必须验证主要操作；纯展示卡片可用 `checks: []`，结果会注明未覆盖交互。修复返回的诊断并重新验证后，再调用 `publish_life_panel`：

```json
{
  "path": "counter.panel.json",
  "htmlPath": "counter.html",
  "requestId": "daily-counter-1"
}
```

可追加 `boardId` / `boardWorkspaceId` 固定到已有看板；更新卡片时传入原来的 `panelId` / `workspaceId` 和刚读取的 `configRevision` 作为 `expectedRevision`。更新默认保留当前任务数据与用户状态，只有显式 `replaceData: true` 才替换数据。新建使用稳定的 `requestId`，重试不会重复创建；固定到看板失败会返回已发布 ID 供修复。HTML 被嵌入发布快照，不依赖源文件日后继续存在。已有预览或小程序的 HTML 可以复用，但新卡片有独立的用户数据，不能当作原小程序的共享存储引用。

也可以在 v2 定义中直接提供 `view`，格式为现有 `WebUiSpec`。v1 必须使用非空原生 `nodes`；v2 必须使用空 `nodes` 和 HTML 视图，不允许混用。

验证与发布都执行同一条检查链：

1. 校验定义、输入参数和数据结构，并试运行配置的数据源。
2. 在半宽、全宽沙箱中检查启动、横向溢出、控件标签。
3. 执行声明的 `click` / `input` / `select` / `text` / `stored` 检查，再用检查产生的状态重新打开页面。
4. 通过后才写入卡片；任何失败返回阶段、文件或数据路径、视口宽度、失败检查项及修复提示。

检查只能修改隔离的内存状态副本，不会修改真实打卡记录。启动写入被拒绝；检查中的按钮不能运行真实刷新任务，数据源单独验证。需要登录的来源可显式 `checkSource: false` 延后检查，但返回结果会标记未验证，不应声称通过。

声明检查不能证明所有交互都正确。实际运行中的未处理异常会显示在卡片上并持久化到 `get_life_panel` 的 `task` 部分；**让 AI 修复** 会把错误带入编辑流程。成功发布新定义后清除旧运行错误。本轮没有增加版本恢复。

## 数据与交互

```js
function render(context) {
  document.querySelector('#total').textContent = context.data.total;
}
render(tinybot.panel.context);
const unsubscribe = tinybot.panel.onUpdate(render);

document.querySelector('#refresh').onclick = async () => {
  try {
    await tinybot.panel.refresh();
  } catch (error) {
    document.querySelector('#status').textContent = error.message;
  }
};
```

`context` 包含 `data`、`title`、`status`（ready/running/failed）、`canRefresh` 、`locale`、`inputs`、`theme` 和主题 `tokens`。数据变化通过消息桥下发，不为每次刷新重载 HTML。`refresh()` 执行已配置的数据源。可以声明 `inputs: {symbol: {type: "string", default: "A", options: ["A", "B"]}}`，再调用 `refresh({symbol: "B"})`。API/json-url 的 `source.query` 将固定查询名映射到输入名，例如 `{ticker: "symbol"}`；Agent 来源会收到输入和数据结构要求。输入经过类型及枚举验证，不能改变端点、认证或选择其他卡片；无数据源、后台或预检视图会拒绝调用。

数据获取由已有 API、工作区 JSON、邮件或 Agent 数据源负责。HTML 无网络、文件、模型或系统执行权限。只在用户操作中触发刷新，不在初始化、定时器或 `onUpdate` 中循环刷新。

用户操作与任务数据分别保存：

```js
let snapshot = await tinybot.storage.load();
document.querySelector('#add').onclick = async () => {
  try {
    snapshot = await tinybot.storage.save(
      { count: (snapshot.value?.count || 0) + 1 },
      snapshot.revision
    );
    document.querySelector('#count').textContent = snapshot.value.count;
  } catch (error) {
    document.querySelector('#status').textContent = error.message;
  }
};
```

保存值须为 JSON 对象、数组或 null，大小不超过 256 KiB。保存必须携带读取或上次保存返回的 revision；并发修改、定义已替换或卡片归档会明确拒绝旧视图写入。冲突后重新读取并让用户决定，不静默覆盖。

## 移动端适配

看板中的纵向手势优先滚动画布；展开卡片后优先滚动内部内容。使用媒体查询适配半宽卡片，按钮保留足够的触控面积；复杂界面可在大视图中使用。高度调整会改变 HTML 视口，内容可自行响应式排版。离屏视图会释放并重新加载，持续计时应保存起始时间而非只依赖内存中的计数器；动画使用 `tinybot.animate`。

验证覆盖协议解析、发布失败保留旧版本、并发保存、任务刷新与用户状态分离、看板尺寸边界、备份恢复、真实浏览器消息桥及 Mate 70 Pro+ 的发布/点击/刷新/缩放/换位/重新打开流程。

## 检查示例

```json
[
  { "action": "click", "selector": "#reset" },
  { "action": "text", "selector": "#count", "value": "0" },
  { "action": "stored", "path": "/count", "expected": 0 }
]
```

检查应设置可预期的测试值，避免假定用户原有计数为 0；`text` 和 `stored` 断言最多等待 2 秒以覆盖异步操作。每个候选最多 12 项。选择器必须匹配一个可见元素。使用 `get_life_panel_catalog({section:"html"})` 获取可直接改造的 HTML 和定义模板。

`dataSchema` 是有界 JSON Schema 子集，支持基本类型、对象属性、必填字段、数组 items、枚举及数值上下限。每次刷新都会校验输出，失败保留旧数据并记录错误路径。主题使用 `--tinybot-text`、`--tinybot-surface`、`--tinybot-accent`；控件具有按压和焦点反馈，并遵循减少动态效果的系统设置。

## 本轮验证（2026-11-06）

Debug 构建、103 项回归、浏览器沙箱检查和发布参数隔离的定向复测通过。Mate 70 Pro+ 实测了看板内直接提交、故意选择器错误 → Agent 修复 → 双宽度 7 项检查 → 发布、原 ID 更新保留计数、长按抬升换位、连续缩放及紧凑布局、HTML 区域滚动画布、重新打开后的布局与状态持久化。运行时错误回传、参数化来源、并发与旧 revision 拒绝另有自动化覆盖；这些检查不等于穷尽所有生成卡片的交互。
