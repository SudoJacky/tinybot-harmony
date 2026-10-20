# 原生 LiquidToggle

设置页和助手配置里的开关共用一个原生开关：`entry/src/main/ets/common/LiquidToggle.ets`，它是 Bencho Liquid Toggle 的 ArkUI 改编，不依赖 React、Framer Motion、WebView 或 SVG 滤镜。

## 交互

- 点击切换；拖动时滑块随手指位移，并随速度拉伸。
- 松手后由弹簧回位，动画中途可以再次拖动，从当前位置接管。
- 拖动只预览状态，松手后才通知调用方保存；取消手势回到已提交状态。
- 外部状态更新优先于正在进行的手势；保存失败的回滚仍由调用方负责。
- 保留原生 Button 的焦点与激活行为，并提供 SWITCH 读屏角色和选中状态。

保留原实现的单一实体滑块、横向拉伸与纵向等面积压缩、位移和缩放分层设计。弹簧默认参数为 mass 0.9、damping 21.5、stiffness 170。

## 参数

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `isOn` | `false` | 外部控制的开关状态 |
| `disabled` | `false` | 禁用点击和拖动 |
| `label` | 空字符串 | 读屏标签；调用方应提供设置名称 |
| `compId` | 空字符串 | UI 自动化标识 |
| `speed` | `50` | 回位速度，范围 0–100 |
| `stretch` | `36` | 拉伸强度，范围 0–100；0 关闭形变 |
| `onChange` | 空回调 | 点击或拖动松手改变状态时触发一次 |

轨道 52 × 28 vp，滑块 22 vp，触摸区域高 48 vp。滑块行程由轨道宽度、滑块大小和边距计算，缩小外观时仍保留完整拖动范围。

## 视觉与资源

颜色使用应用的 `accent`、`on_accent`、`surface_variant`、`text_tertiary`，自动匹配明暗主题。动画使用原生 animator 帧回调，停止后不保留定时器；组件退出时取消动画。

## 验证

`node scripts/test-liquid-toggle.cjs` 检查整个速度范围的弹簧收敛、动画打断连续性和形变边界。触摸竞争、读屏和设置持久化需在设备上验证。

来源：用户提供的 Bencho Liquid Toggle 源码；MIT 许可见 <https://bencho.dev/licence> 及应用内 `THIRD_PARTY_NOTICES.txt`。

## 代码入口

| 路径 | 职责 |
| --- | --- |
| `entry/src/main/ets/common/LiquidToggle.ets` | 开关组件、手势与弹簧动画 |
| `entry/src/main/ets/common/Widgets.ets` | `SwitchRow` 等公共表单行 |
| `scripts/test-liquid-toggle.cjs` | 弹簧收敛与形变边界验证 |
