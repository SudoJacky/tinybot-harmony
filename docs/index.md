---
layout: home

hero:
  name: Tinybot
  text: 运行在 HarmonyOS 上的 AI Agent
  tagline: 把模型、工具、项目工作区、团队与预览收进手机与平板；这份文档讲清它怎么用，也讲清它怎么实现。
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
  - title: 从预览到小程序
    details: 一次性图表用交互预览，需要长期打开并保存数据时收藏为本地小程序；两者都不联网，也都不继承浏览器会话。
    link: /guide/files#小程序收藏
    linkText: 了解小程序
---
