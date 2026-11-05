# Life Panel 交互卡片

Life Panel 支持原生 v1 卡片和 HTML v2 卡片。两者使用同一套看板引用、数据源、刷新任务、运行记录与备份机制。HTML 复用交互预览和小程序的沙箱渲染器。

## 使用方式

- 看板顶部的 **AI 修改** 可以描述新增或修改需求，然后继续到对话。输入框只显示修改要求和看板名称，当前看板说明与卡片引用作为独立上下文随草稿保存并送入模型；发送前仍可编辑。
- 卡片菜单的 **用 AI 修改卡片** 会指定已有卡片，避免把修改做成另一个副本。
- **添加** 可以复用已有卡片。同一卡片出现在多个看板时，共享数据与用户状态。
- **调整布局** 显示左上角移动把手和右下角尺寸把手。宽度按 S/M/L 栏位吸附，HTML 视口高度可在 200–800 vp 调整；其他卡片自动避让。位置顺序、尺寸按看板保存。
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
  "source": { "type": "workspace-json", "path": "metrics.json" }
}
```

调用 `publish_life_panel`：

```json
{
  "path": "counter.panel.json",
  "htmlPath": "counter.html"
}
```

可追加 `boardId` / `boardWorkspaceId` 固定到已有看板；更新卡片时传入原来的 `panelId` / `workspaceId`。HTML 被嵌入发布快照，不依赖源文件日后继续存在。已有预览或小程序的 HTML 可以复用，但新卡片有独立的用户数据，不能当作原小程序的共享存储引用。

也可以在 v2 定义中直接提供 `view`，格式为现有 `WebUiSpec`。v1 必须使用非空原生 `nodes`；v2 必须使用空 `nodes` 和 HTML 视图，不允许混用。

发布前会在真机沙箱中检查启动。检查读取用户状态的副本，禁止写入或触发任务；启动失败不会替换已发布卡片。运行时错误仍会显示在卡片上。

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

`context` 包含 `data`、`title`、`status`（ready/running/failed）、`canRefresh` 和 `locale`。数据变化通过消息桥下发，不为每次刷新重载 HTML。`refresh()` 执行已配置的数据源，不能选择其他卡片、路径或请求参数；无数据源、后台或预检视图会拒绝调用。

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

使用媒体查询适配半宽卡片，按钮保留足够的触控面积；复杂界面可在大视图中使用。高度调整会改变 HTML 视口，内容可自行响应式排版。离屏视图会释放并重新加载，持续计时应保存起始时间而非只依赖内存中的计数器；动画使用 `tinybot.animate`。

验证覆盖协议解析、发布失败保留旧版本、并发保存、任务刷新与用户状态分离、看板尺寸边界、备份恢复、真实浏览器消息桥及 Mate 70 Pro+ 的发布/点击/刷新/缩放/换位/重新打开流程。
