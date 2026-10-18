# 聊天中的交互预览

Agent 将普通 JavaScript、HTML 或 SVG 写入工作区，再调用 `publish_preview`。客户端在聊天消息中嵌入隔离的 ArkWeb 卡片，无需 Agent 编写 JSONL 或转义嵌套代码。

## 发布 JavaScript 和 Three.js

```js
publish_preview({ path: "scene.js", title: "旋转方块", library: "three", height: 400 })
```

`path` 是已有工作区文件的相对路径，支持 `.js`、`.html` 和 `.svg`。可选 `title` 最多 160 字符，默认文件名；`library` 为 `none`（默认）或 `three`；可选 `height` 为 200–800vp。

JS 在空白页面的异步函数中执行，支持 `await`，通过 `document.body` 创建 DOM、样式和 Canvas。JS 默认使用 400vp 固定视口，`html/body` 填满视口。HTML/SVG 默认按内容自适应高度（48–800vp），显式设置 `height` 则固定高度。HTML 也可选择内置库，库在页面脚本前加载。

`library: "three"` 注入内置 `THREE`（r186）和独立的 `OrbitControls`，无需 CDN 或 import。例如 `scene.js`：

```js
const canvas = document.createElement('canvas');
if (!canvas.getContext('webgl2')) throw new Error('This device does not support WebGL2');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
document.body.append(canvas);
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(50, 1, 0.1, 100);
camera.position.set(2, 2, 3);
const controls = new OrbitControls(camera, canvas);
const cube = new THREE.Mesh(new THREE.BoxGeometry(), new THREE.MeshNormalMaterial());
scene.add(cube);
new ResizeObserver(() => {
  const { width, height } = document.body.getBoundingClientRect();
  renderer.setSize(width, height);
  camera.aspect = width / height;
  camera.updateProjectionMatrix();
}).observe(document.body);
tinybot.animate((time) => {
  cube.rotation.y = time * 0.4;
  controls.update();
  renderer.render(scene, camera);
});
```

动画使用 `tinybot.animate`，离屏、聊天滚动或只读时暂停；事件处理可用 `tinybot.active` 判断是否允许输入。聊天滚动期间不创建新的 Web 视图，滚动停止后再稳定 200 ms 才加载当前可见预览；再次滑动会取消本次等待，资源读取完成后也会重新检查滚动状态。短暂离屏时保留并暂停已有实例，连续离屏 5 秒后释放，进入后台仍在 600 ms 后释放。局部变量和 DOM 状态在 Web 视图释放或重启后重新创建；文件接口不提供自定义持久化状态声明。

## 与独立浏览器分开

预览使用 `WebUiView` 和隔离 iframe，禁止网络、文件、存储、外部依赖、嵌套页面与设备权限；图片可使用 data/blob URL。普通消息里的 HTML/JS 代码块不执行。

`browser_open` 操作外部 HTTP/HTTPS 网页，使用独立 `BrowserSession` 和浏览器面板，遵守浏览器启用、控制权和用户接管规则。发布预览不会申请、获取或改变该会话，也不继承其网页存储或权限。

## 发布与错误

工具只读取一次文件，完成校验、设备 Web 启动检查和卡片截图后，将不可变内容快照与截图随工具记录保存。修改或删除源文件不会改变已发布预览；重新发布产生新版本。重启及会话分支使用保存的快照。下载、分享和导出文件仍用 `present_files`。

截图使用同一套聊天卡片和聊天宽度，最长边不超过 1600 像素，以 JPEG 附在工具结果后供模型检查。截图失败不发布；不支持图片的模型收到明确说明。启动检查包含初始动画回调，但不保证后续所有交互正确，截图也只代表一个画面。

失败返回 `PREVIEW_INVALID` / `fix_preview_file`，包含文件路径、版本、错误类别、诊断及重试参数。重试保留 `path/title/library/height`。`locationScope: generated_wrapper` 表示内部包装协议的位置，不能冒充原始 JS/HTML 文件行号；运行时错误附带浏览器堆栈。Agent 应读取源文件、局部修复后重发。设备能力或截图失败须先检查运行条件。

旧 `.jsonl` 发布返回 `UNSUPPORTED_PREVIEW_FORMAT`，直接输出 `tinybot-ui` 的回答也明确失败；不会暂存旧 JSONL 再建议无效重试。历史消息中的直接 JSONL 界面及 `.jsonl` 预览显示不支持格式的错误，不执行或迁移。内部卡片仍使用客户端生成的界面记录，这不是 Agent 的发布接口。

聊天滚动期间暂停 Web 预览渲染，不创建新的 Web 视图；滚动停止并稳定 200 ms 后才加载当前可见预览，再次滑动会取消本次等待，资源读取完成后也会重新检查滚动状态。短暂离屏时保留并暂停已有实例，连续离屏 5 秒后释放，进入后台仍在 600 ms 后释放。Web 视图释放或重启后，局部 JavaScript 变量与 DOM 重新创建；声明过的输入字段仍通过既有状态桥恢复。

## 验证

```text
node scripts/test-preview-publication.cjs
node scripts/test-preview-screenshot.cjs
node scripts/test-web-ui-preflight.cjs
node scripts/test-web-ui-browser.cjs
```

浏览器测试需 Playwright 和本机 Edge；`DEVECO_STUDIO_HOME` 指向 DevEco Studio。构建后运行 `test-preview-lifecycle.cjs` 与 `test-interactive-ui-renderer.cjs` 验证实际编译的卡片和生命周期。真实 ArkWeb 设备交互仍需设备验收。
