---
layout: home

hero:
  name: Tinybot
  text: 运行在 HarmonyOS 上的 AI Agent
  tagline: 把模型、工具、项目工作区、团队与预览收进手机、平板与 2in1；这份文档讲清它怎么用，也讲清它怎么实现。
  actions:
    - theme: brand
      text: 快速开始
      link: /getting-started/install
    - theme: alt
      text: 架构总览
      link: /internals/overview
    - theme: alt
      text: 工具参考
      link: /reference/tools

features:
  - title: 一套可读的架构
    details: 从 SessionService、AgentRuntime 到 Provider 与工具流水线，按子系统拆开讲，给出代码入口与不变量。
    link: /internals/overview
    linkText: 进入架构
  - title: 以源码为准的参考
    details: 工具参数、回执格式、错误码、设置项与磁盘布局，逐项对应 entry/src/main/ets 下的实现。
    link: /reference/tools
    linkText: 查看参考
  - title: 面向扩展的开发手册
    details: 新增工具、新增模型服务、维护词条与发布交付，都给出改动位置、验证命令和容易踩的边界。
    link: /dev/setup
    linkText: 开始开发
  - title: 从预览到生活看板
    details: 一次性图表用交互预览，需要长期打开与自动更新的内容放进生活看板；两者都不申请浏览器会话或外部目录权限。
    link: /guide/web-and-skills
    linkText: 了解能力边界
  - title: 图片生成与检查
    details: 为聊天服务配置图片模型后，用参考图生成或修改图片；结果带“AI生成”标记与 AIGC 元数据，可与参考图滑动对比，视觉模型可用 view_image 检查结果。
    link: /guide/chat#生成与编辑图片
    linkText: 了解图片生成
  - title: 大屏工作台与旁聊
    details: 平板与 2in1 共用工作表布局，提供命令面板、会话详情、拖动自动收起与布局记忆；旁聊复用主会话工作区做只读追问，并可带回主会话。
    link: /guide/desktop
    linkText: 了解大屏工作台
---
