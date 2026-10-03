# 原生 LiquidToggle

`entry/src/main/ets/common/LiquidToggle.ets` 是 Bencho Liquid Toggle 的 ArkUI 改编，
公共 `SwitchRow` 已接入，因此设置和助手配置里的开关共用同一交互。
不需要 React、Framer Motion、WebView 或 SVG 滤镜。

支持点击、水平拖动、速度驱动的滑块形变、弹簧回位，以及动画中途再次拖动。
保留原实现的单一实体滑块、横向拉伸与纵向等面积压缩、位移和缩放分层设计。
弹簧默认参数为 mass 0.9、damping 21.5、stiffness 170。

组件参数：

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `isOn` | `false` | 外部控制的开关状态 |
| `disabled` | `false` | 禁用点击和拖动 |
| `label` | 空字符串 | 读屏标签；调用方应提供设置名称 |
| `compId` | 空字符串 | UI 自动化标识 |
| `speed` | `50` | 回位速度，范围 0–100 |
| `stretch` | `36` | 拉伸强度，范围 0–100；0 关闭形变 |
| `onChange` | 空回调 | 点击或拖动松手改变状态时触发一次 |

轨道 52 × 28 vp，滑块 22 vp，触摸区域高 48 vp。滑块行程由轨道宽度、滑块大小和边距计算，
缩小外观时仍保留完整的拖动范围。颜色使用应用的
`accent`、`on_accent`、`surface_variant`、`text_tertiary`，自动匹配明暗主题。
控件保留原生 Button 的焦点和激活行为，并提供 SWITCH 读屏角色及选中状态。

拖动只预览状态，松手后才通知调用方保存；取消手势回到已提交状态。
外部状态更新优先于正在进行的手势，原有保存失败回滚仍由调用方负责。
动画使用原生 animator 帧回调，停止后不保留定时器；组件退出时取消动画。

`node scripts/test-liquid-toggle.cjs` 检查整个速度范围的弹簧收敛、动画打断连续性和形变边界。
触摸竞争、读屏和设置持久化需在设备上验证。

本次已通过 ArkTS 检查、应用构建、启动 smoke，以及 Mate 90 Pro 模拟器上的
双向拖动（含从轨道空白处起拖）和重启后设置持久化检查。
读屏播报和真机触感仍需人工体验。

来源：用户提供的 Bencho Liquid Toggle 源码；MIT 许可见
<https://bencho.dev/licence> 及应用内 `THIRD_PARTY_NOTICES.txt`。
