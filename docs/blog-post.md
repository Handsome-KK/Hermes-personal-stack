# 我用 Hermes Agent 给自己造了一个 AI 助理:从配置到自定义补丁

> 这不是一篇"教程",是一份"作业本"。一个独立开发者把 Hermes Agent 改造成日用 AI 助理过程中,踩过的坑、写过的补丁、做过的取舍。

---

## 起点

2026 年的"AI 助理"已经卷成红海,大模型套壳产品层出不穷。但作为一个想真正把 AI 嵌进自己工作流的人,我对市面上 90% 的产品都不满意:

- ChatGPT / Claude 的官方 App:好用但封闭,没法接我自己的工具链
- 各家 Agent 框架:LangChain / AutoGen / CrewAI,概念漂亮但工程化粗糙,没有"我每天用得起来"的成品形态
- 一票"AI 助理"创业产品:本质上是订阅制套壳,接的是 OpenAI,死的是公司,跟着一起死的是我两年的对话历史

我要的是 **能跑在我自己机器上、跟我跨多个聊天平台、记得住我说过的话、可以被我改源码的 Agent**。

去年偶然刷到 Nous Research 开源的 [Hermes Agent](https://hermes-agent.nousresearch.com/),对上眼了。

## 为什么是 Hermes

Hermes 不是又一个 Agent 框架,它是一个 **personal AI agent 的完整产品形态**:

| 维度 | 设计 |
|------|------|
| 部署 | 同一个 Agent core 跑在 CLI / 消息网关 / TUI / 桌面 App |
| 平台覆盖 | 自带 ~20 个消息平台 adapter(Telegram / Discord / Slack / 飞书 / 企微 / 微信公众号…) |
| 跨会话学习 | memory + skills 双层,memory 是事实,skills 是程序性知识 |
| 工具 | 真实 terminal、真实 browser、真实 file system,不是沙盒 fake |
| 扩展 | plugins + skills + MCP,核心保持窄腰 |
| 调度 | 内置 cron,可以让 Agent "每天早上 8:30 给我做一份简报" |

最打动我的是它一条架构原则:**核心保持窄腰,能力都在边缘**。新功能优先以 skill / plugin / MCP 形式出现,而不是塞进核心 tool schema —— 因为每加一个 core tool,所有对话每次 API 调用都要带它过去,prompt cache 失效,成本直接乘倍。这是工程师写出来的设计,不是 PM 写出来的设计。

---

## 我做的 5 件事

下面这 5 件事按顺序,每件都解决了一个具体的"用得不爽"。

### 1. 多 backend 联网搜索路由

Hermes 的 `web_search` 工具支持多个 backend(Exa / Parallel / Firecrawl / Tavily / SerpAPI / Brave / DDGS),会按优先级自动选择已配置 API Key 的那个。我配了三条独立通道:

| 通道 | 入口 | 用途 |
|------|------|------|
| Tavily | `web_search` 自动 backend(优先级最高的可用项) | 默认通用搜索,语义优先 |
| Volcengine `askecho-search-infinity` | MCP server | 中文资讯/财经类 |
| SerpAPI | terminal + HTTP 直调 | 需要原生 Google 结果(知识图谱、地图) |

**踩到的坑**:即使 API Key 都配好了,如果你不主动测一次,Agent 实际调用时可能因为 LLM 的"省力倾向"直接走 DDGS 免费版,后台用量永远是 0。解决办法是在 memory 里写明"这三条通道是付费的,'查一下/搜资料'必须主动走它们,不要 fallback 到 DDGS"。

### 2. 飞书表格渲染 — 一个上游补丁

这是整个折腾过程中最有成就感的一件事。

**问题症状**:每次让 Agent 推送带 Markdown 表格的简报到飞书,收到的全是源码:

```
| 类别 | 事件 | 影响 |
|------|------|------|
| 利多 | xxx | xxx |
```

**定位**:翻 `gateway/platforms/feishu.py`,找到 `_build_outbound_payload`:

```python
if _MARKDOWN_TABLE_RE.search(content):
    text_payload = {"text": content}
    return "text", json.dumps(text_payload, ensure_ascii=False)
```

注释自我合理化说"Feishu post-type 'md' elements do not render markdown tables"。这话本身没错 —— 飞书的 `post` 类型富文本里 `md` 元素确实不渲染 pipe 表格。但这条注释错过了一个事实:**飞书的 interactive card(schema 2.0)有原生 `table` 组件,渲染体验比 Markdown 表格还好**(支持表头底色、对齐、分页、列宽)。

**做的事**:
1. 写一个 `_parse_markdown_table_block` —— 把 pipe 表格解析成 header / rows / 对齐方向
2. 写一个 `_build_table_card_elements` —— 散文段落 + 表格交错地拆成 elements 数组,prose 用 `markdown` 元素,表格用 `table` 元素
3. 写一个 `_build_table_card_payload` —— 包成 schema 2.0 卡片
4. `_build_outbound_payload` 改路由:检测到表格 → 走 `interactive`;malformed → fallback 到 plain text(不留空消息)

**验证**:发了一份多表格 + 散文 + 引用的混合简报,客户端原生渲染,排版完整。

**意外收获**:`schema: "2.0"` 这条规范在飞书官方文档里藏得挺深,但写得非常完整。一旦找到,后面所有富文本场景都能受益。

这个补丁我打算清理后提 PR 到上游。

### 3. 一键发布管线:Markdown → 飞书云文档 + 卡片

简报内容如果很长,直接发卡片不合适(超长会被截断,且无法编辑)。我写了一个 244 行的 Python 脚本,做这件事:

1. 接受一份 Markdown 简报文件
2. 通过飞书 OAuth 上传到 Drive 根目录
3. 调 `import` API 转成原生 `docx` 云文档
4. 推一张 schema 2.0 interactive card 到目标聊天,卡片正文是简报"速览",底部带"打开完整简报"按钮直跳云文档

效果:卡片即时可读,完整内容在云文档里可编辑、可分享、可批注。完美匹配"日常推送 + 偶尔深读"的双轨需求。

### 4. Cron 模式两个深坑

`hermes cron` 让你把任何 Agent prompt 注册成定时任务。听起来美好,实际有两个坑必须知道:

**坑 1:审批拦截**

Hermes 默认 `approvals.cron_mode = deny`,意思是 cron 中触发的任何"敏感操作"(写文件、调外部 API)会等人确认。但 cron 是无人值守的 —— 永远等不到确认,任务静默失败。

修:`config.yaml` 里加 `approvals.cron_mode: auto_allow`。代价是你必须真的相信你的 cron prompt 不会做坏事(写测试、Code review)。

**坑 2:Emoji 触发审批黑洞**

某次我把 cron 任务的 `--title "📊 开盘前简报"` 直接塞 emoji,任务一直卡死。debug 半天才发现:emoji 里的 Variation Selector 16(VS-16, U+FE0F)字节会触发一个内部命令白名单子系统(代号 "Tirith")的异常审批分支。

修:CLI 参数严格 ASCII,emoji 全部下沉到 Markdown 文件正文里。

这两个坑我都补到了 skill 文件里,下次自己/别人遇到不会再花一个晚上 debug。

### 5. macOS launchd supervisor

macOS 26+ 的 `launchctl bootstrap` 对用户级 LaunchAgent 经常翻车,Hermes gateway 偶尔会因为网络抖动或飞书 long-poll 断连而退出,退出后没人拉起来。

写了一个 30 行的 supervisor shell 脚本,每 30 秒检查一次 gateway 进程是否还在,不在就立刻重启,日志写到 `~/.hermes/logs/gateway-supervisor.log`。

启动方式:登录项加一个 `nohup ./gateway-supervisor.sh &`,从此不再操心。

---

## 一些更深的体会

折腾完这一轮,我对 LLM Agent 的认识比之前清晰很多。几条:

### 「核心窄腰」不是教条,是省钱

每加一个 core tool,所有对话每次 API 调用都要把它的 schema 发过去。轻则浪费 token,重则破坏 prompt cache(模型每次都要重新理解你的工具集)。Hermes 把这条原则贯彻得相当严格:新能力优先以 CLI 命令 + skill、MCP server、plugin 形式出现,核心 tool schema 几乎不增长。

我自己写补丁的时候被这条原则约束了好几次。**在 Hermes 上做扩展,先问的不是"我要写在哪",而是"这真的需要进核心吗"**。

### Skills 是 Agent 的程序性记忆

memory 存事实(你叫什么、住哪、API key 是多少),skills 存"做某件事的步骤"。区别像声明性记忆 vs 程序性记忆。

skills 的妙处是:Agent 用过一次后,**遇到坑会主动 patch skill**,下次自己不会再踩。我现在 `~/.hermes/skills/` 下有 ~30 个 skills,每个都是一次"踩坑 → 总结 → 固化"的产物。

### MCP 比想象中重要

Model Context Protocol 是 Anthropic 推的规范,本质是"让 LLM 调用任意外部工具的标准 interface"。Hermes 把 MCP 作为一等公民集成,意味着我可以把任何 MCP server 接进来当 tool 用,不用改 Agent 核心代码。

这就是窄腰架构的胜利:能力扩张全部发生在边缘。

### 工程化品质决定了能不能日用

很多 Agent 框架的 demo 看着炫,真要 24×7 跑起来,处处是 edge case:进程挂了没人拉、cron 静默失败、IM 连接断了不重连、token 超限直接报错…… 这些都不是"设计问题",是"工程化品质问题"。

Hermes 在这层下了真功夫。我用了几个月,真出问题的时候,99% 都能在源码里找到清晰的处理逻辑(哪怕逻辑本身需要改)。这种"可调试性"是日用的前提。

---

## 写在最后

这套配置 + 补丁,目前是我最满意的"独立开发者 AI 工作流"。它不替代 Claude / ChatGPT 的对话体验,但它替代了我大量"需要 AI 帮忙但开 App 太重"的场景:

- 半夜忽然想起的事,一句话发飞书,Agent 处理完回我一张卡片
- 早上 8:30 自动推一份昨夜全球市场简报到飞书
- 想搜资料,直接 Telegram 一句"查一下 X",走的是付费 Tavily,而不是 DDGS 兜底
- 想给一个 Markdown 文档,自动转成飞书云文档同时推卡片通知

如果你也在折腾自己的 Agent,或者在评估 Agent 框架,推荐看看 Hermes。**它给的不是一个"产品",是一套"我自己造产品"的脚手架**,而且脚手架本身已经能日用。

补丁和配置我会陆续整理到 GitHub,链接在简介。

*写于一个深夜的折腾之后。*
