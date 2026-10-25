# 环境、构建与签名

这页给出从干净克隆到真机运行的完整路径，以及本地签名、华为账号配置和应用图标导出。

## 前置条件

- DevEco Studio，API 26 SDK。编译始终使用 API 26 SDK；`compatibleSdkVersion` 为 `6.0.0(20)`，产物可在 HarmonyOS 6（API 20）与 HarmonyOS 7（API 26）上安装。
- DevEco CLI（`devecocli`），真机调试还需要华为开发者账号。
- Node.js 用于仓库内的 `scripts/*.cjs` 验证脚本。

若 `devecocli` 不在 PATH，可用 `& "$env:APPDATA\npm\devecocli.cmd"` 代替。

## 首次配置与构建

`build-profile.json5` 含本机签名信息，已被忽略；版本库只保留 `build-profile.template.json5`。

```powershell
# 首次克隆时创建本机配置；已有文件时不要覆盖
if (-not (Test-Path build-profile.json5)) { Copy-Item build-profile.template.json5 build-profile.json5 }

devecocli check arkts     # ArkTS 静态检查
devecocli build           # 构建 HAP
.\scripts\test.ps1       # 词条检查 + 原生适配测试 + Hypium 单测
```

`scripts/test.ps1` 优先读取 `DEVECO_STUDIO_HOME`，默认使用 `C:\Program Files\Huawei\DevEco Studio`。测试内容见[测试与冒烟验证](/dev/testing)。

修改 SDK 或模块配置时，需要同步更新 `build-profile.template.json5`，否则其他人克隆后构建结果不一致。

## 真机调试与本地签名

未配置签名时，构建产物是 `entry/build/default/outputs/default/entry-default-unsigned.hap`。真机流程：

```powershell
devecocli device list
devecocli auth login
devecocli signature generate
devecocli run --device <设备名称或序列号>
```

`signature generate` 会修改 `build-profile.json5` 并在本机保存签名材料。该文件不进入版本库，工程当前也不自动生成发布签名；正式发布签名与上传步骤见[发布清单](/dev/release)。

## 华为账号配置

入口模块 `module.json5` 的模块级 `metadata` 配置公开的 `client_id`，值为 AppGallery Connect 中该 HarmonyOS 应用的 Client ID，不使用 Client Secret。调试包和发布包须分别在华为平台配置实际签名证书的 SHA-256 指纹，并核对包名 `com.sudojacky.tinybot`；配置生效时间以平台提示为准。普通登录不申请手机号、头像或其他用户资料权限。

`node scripts/test-huawei-account.cjs` 验证实际账号服务、安全存储以及 SessionService/ProviderRegistry 路径：登录成功/取消、错误码脱敏、重启恢复、账号切换、退出与迟到回调、存储失败及未登录请求拦截。真机仍需验证平台配置、用户主动登录、重启恢复、退出后拦截与重新登录；该接入不代表实名审核已通过。

参考：[Account Kit](https://developer.huawei.com/consumer/cn/sdk/account-kit)、[系统账号状态查询与登录事件](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V14/account-login-state-V14)。

## 应用图标

HarmonyOS 图标源文件为 `assets/app-icon.svg`：背景铺满正方形，不预裁圆角、不加外边距或外框，内部 Logo 沿用原有比例。应用与桌面入口引用 `tinybot_layered_icon`，由系统合成前景、背景并裁切外形。启动窗口、关于页和交付素材使用同源合成 PNG；模块的 `dark/media/tinybot_icon.png` 按深色启动背景与正文色生成，由系统资源匹配选择。资源均为 1024×1024；只修改本项目源文件，不覆盖桌面版图标。

修改源文件后，在项目根目录重新导出（渲染工具仅安装在忽略的缓存目录）：

```powershell
npm install --prefix .cache/icon-tools --no-save --package-lock=false --ignore-scripts @resvg/resvg-js@2.6.2
node scripts/build-app-icons.cjs .cache/icon-tools/node_modules/@resvg/resvg-js
```

## 目录约定

| 路径 | 说明 |
| --- | --- |
| `entry/src/main/ets/` | 应用源码，分层见[代码地图](/internals/code-map) |
| `entry/src/test/` | Hypium 本地单元测试，不依赖真机和模型密钥 |
| `scripts/` | 构建、验证与交付脚本（Node.js） |
| `locales/` | 双语词条，见[词条维护](/dev/i18n) |
| `skills/` | 内置 Skill 文本源，改动后需重新打包 |
| `docs/` | 本文件站源码（VitePress），见[文档站维护](/dev/docs) |
| `docs/local/`、`docs/distribution/` | 本机资料与交付材料，不进入站点构建 |
| `build-profile.template.json5` | 不含签名的构建配置模板 |
| `oh_modules/`、`entry/build/` | 依赖与构建产物，不提交 |

## 常见构建问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 构建提示缺少 `build-profile.json5` | 新克隆未生成本机配置 | 从模板复制，不要提交 |
| `devecocli` 找不到 | 未加入 PATH | 用完整路径或 `npm i -g` 后重启终端 |
| 安装到真机失败、提示签名不一致 | 覆盖安装的包签名不同 | 使用相同签名覆盖升级，或卸载后重装（会清数据） |
| ArkTS 检查通过但运行崩溃 | 运行期才暴露的原生能力问题 | 查看 HiLog 与应用内开发者诊断，见[运行诊断与性能](/internals/diagnostics) |
