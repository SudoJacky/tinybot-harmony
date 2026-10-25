import { defineConfig } from 'vitepress'

const mirror = process.env.DOCS_TARGET === 'sudotinybot'

export default defineConfig({
  lang: 'zh-CN',
  title: 'Tinybot',
  description: '运行在 HarmonyOS 上的个人 AI Agent',
  base: mirror ? '/docs/' : '/tinybot-harmony/',
  cleanUrls: false,
  srcExclude: ['local/**', 'distribution/**', 'README.md'],
  markdown: {
    lineNumbers: true,
    theme: { light: 'github-light', dark: 'github-dark' }
  },
  sitemap: { hostname: mirror ? 'https://sudotinybot.cn/docs/' : 'https://sudojacky.github.io/tinybot-harmony/' },
  head: mirror ? [['link', { rel: 'stylesheet', href: '/docs/mirror.css' }]] : [],
  themeConfig: {
    logo: '/logo.svg',
    siteTitle: 'Tinybot',
    outline: { level: [2, 3], label: '本页目录' },
    nav: [
      ...(mirror ? [{ text: '返回官网', link: 'https://sudotinybot.cn/' }] : []),
      { text: '开始', link: '/getting-started/install', activeMatch: '/getting-started/' },
      { text: '指南', link: '/guide/', activeMatch: '/guide/' },
      { text: '架构', link: '/internals/overview', activeMatch: '/internals/' },
      { text: '参考', link: '/reference/tools', activeMatch: '/reference/' },
      { text: '开发', link: '/dev/setup', activeMatch: '/dev/' },
      { text: '设计', link: '/ui/liquid-toggle', activeMatch: '/ui/' }
    ],
    sidebar: {
      '/getting-started/': [
        {
          text: '开始使用',
          items: [
            { text: '安装与首次启动', link: '/getting-started/install' },
            { text: '第一次对话', link: '/getting-started/first-chat' }
          ]
        }
      ],
      '/guide/': [
        {
          text: '使用指南',
          items: [
            { text: '指南总览', link: '/guide/' },
            { text: '对话与消息', link: '/guide/chat' },
            { text: '文件与工作区', link: '/guide/files' },
            { text: '项目与共享工作区', link: '/guide/projects' }
          ]
        },
        {
          text: '能力',
          items: [
            { text: '模型服务与上下文', link: '/guide/models' },
            { text: '网页、搜索与 Skills', link: '/guide/web-and-skills' },
            { text: '团队协作', link: '/guide/teams' },
            { text: '语音输入', link: '/guide/speech' },
            { text: '云备份', link: '/guide/cloud-backup' }
          ]
        },
        {
          text: '其他',
          items: [
            { text: '设置、外观与用量', link: '/guide/settings' },
            { text: '隐私与用户协议', link: '/guide/privacy' },
            { text: '常见问题', link: '/guide/troubleshooting' }
          ]
        }
      ],
      '/internals/': [
        {
          text: '总览',
          items: [
            { text: '架构总览', link: '/internals/overview' },
            { text: '代码地图', link: '/internals/code-map' }
          ]
        },
        {
          text: '运行内核',
          items: [
            { text: '会话与持久化', link: '/internals/session' },
            { text: '轮次、流式与重试', link: '/internals/agent-loop' },
            { text: '模型服务与凭据', link: '/internals/providers' },
            { text: '系统提示词与上下文', link: '/internals/prompt' }
          ]
        },
        {
          text: '能力',
          items: [
            { text: '工具注册与执行', link: '/internals/tools' },
            { text: '审批、权限与沙箱', link: '/internals/permissions' },
            { text: '工作区与文件', link: '/internals/workspace' },
            { text: '交互预览与 Web UI', link: '/internals/preview' },
            { text: '运行诊断与性能', link: '/internals/diagnostics' }
          ]
        }
      ],
      '/reference/': [
        {
          text: '参考',
          items: [
            { text: '工具参考', link: '/reference/tools' },
            { text: '回执与错误', link: '/reference/receipts' },
            { text: '设置项', link: '/reference/settings' },
            { text: '磁盘布局', link: '/reference/storage' },
            { text: '词条与本地化', link: '/reference/locales' }
          ]
        }
      ],
      '/dev/': [
        {
          text: '开发手册',
          items: [
            { text: '环境、构建与签名', link: '/dev/setup' },
            { text: '测试与冒烟验证', link: '/dev/testing' },
            { text: '新增工具', link: '/dev/add-tool' },
            { text: '新增模型服务', link: '/dev/add-provider' },
            { text: '词条维护', link: '/dev/i18n' },
            { text: '文档站维护', link: '/dev/docs' },
            { text: '发布清单', link: '/dev/release' }
          ]
        }
      ],
      '/ui/': [
        {
          text: '交互与动效',
          items: [
            { text: '推理强度', link: '/ui/reasoning-effort' },
            { text: '滑动操作行', link: '/ui/swipe-rows' },
            { text: '分段选择动效', link: '/ui/segmented-motion' },
            { text: 'LiquidToggle', link: '/ui/liquid-toggle' }
          ]
        }
      ]
    },
    search: {
      provider: 'local',
      options: { translations: { button: { buttonText: '搜索文档', buttonAriaLabel: '搜索文档' } } }
    },
    editLink: {
      pattern: 'https://github.com/SudoJacky/tinybot-harmony/edit/main/docs/:path',
      text: '在 GitHub 上编辑此页'
    },
    lastUpdated: { text: '最后更新于' },
    docFooter: { prev: '上一页', next: '下一页' },
    darkModeSwitchLabel: '外观',
    sidebarMenuLabel: '菜单',
    returnToTopLabel: '回到顶部',
    outlineTitle: '本页目录',
    socialLinks: [{ icon: 'github', link: 'https://github.com/SudoJacky/tinybot-harmony' }],
    footer: {
      message: '基于 Apache-2.0 许可发布',
      copyright: 'Copyright © Tinybot'
    }
  }
})
