[English](./README.md) | **简体中文**

# 亲手搭一个自己的 AI 助手 —— 基于 Hermes Agent

> 自部署、多渠道、会自我进化——接了自定义 MCP、写了飞书原生渲染、铺了定时简报管线。

这份仓库记录了我在 [Hermes Agent](https://hermes-agent.nousresearch.com/) 上搭建私人 AI 助手的完整工程——终端、即时通讯、定时任务全覆盖，包括我顺手修的上游质量的补丁。

---

## 这项目是干嘛的

我想要一个能满足以下条件的 AI 助手：

- 无论在哪都能用：终端、手机 IM、后台定时任务
- 跨会话持有真正的长期记忆 & 技能（不是每次从头聊）
- 能操作真实的 shell + 浏览器，而不只是聊天
- 定时推送带**富文本渲染**的简报（表格、卡片、附件），而不是 Markdown 源码

Hermes Agent 在出厂阶段已经给了七成功力。这个仓库装的是剩下的三成——配置、MCP 集成、渲染修复、还有把它变成每天在手边跑的生产助手的工程胶水。

---

## 技术栈

| 层 | 组件 |
|---|---|
| 智能体核心 | Hermes Agent（开源） |
| 主力模型 | 火山引擎 Ark Agent Plan（`plan/v3` 接口） |
| 路由 | [hms](./hms/)——多供应商互斥切换器（380 行 bash） |
| 搜索后端 | Tavily · SerpAPI · 火山引擎 `askecho-search-infinity` MCP |
| IM 网关 | Telegram · 飞书（双向） |
| 图像生成 | 豆包 Seedream（火山引擎） |
| 语音 | Edge TTS / 兼容 OpenAI 的供应商 |
| 存储 | 本地 SQLite 会话数据库 · 飞书云盘 · 百度网盘 |
| 调度 | Hermes cron + macOS launchd 守护 |

---

## 我在上面造了什么

### 1. 多后端 web 搜索路由

配置了三个独立搜索通道，按优先级排序：

```
exa → parallel → firecrawl → tavily → xai → brave-free → ddgs
```

Tavily 是自动选定的后端；火山引擎 `askecho-search-infinity` 注册为 MCP 服务器处理中文搜索；SerpAPI 通过终端可调用的 HTTP 后备提供原生 Google 结果。每个通道都经过真实流量验证——当付费后端配置好后，智能体不会偷偷回落到底层的免费 DDGS。

### 2. 飞书交互式卡片渲染——上游补丁

**问题：** Hermes 的飞书适配器检测到 Markdown 表格后会强制走纯文本通道，因为飞书 `post` 类型的 `md` 元素不渲染管道表格。结果是每份带表格的简报到达时都是一坨 `|---|` 源码。

**修复：** 编写了一个卡片构建器，检测 Markdown 表格块后通过飞书 schema 2.0 交互式卡片 API 路由，使用原生 `table` 组件，保留表头、对齐和分页。表格周边的正文保留为 `markdown` 元素，布局完全在客户端还原。

```python
# gateway/platforms/feishu.py — _build_outbound_payload（修复后）
if _MARKDOWN_TABLE_RE.search(content):
    card_payload = _build_table_card_payload(content)
    if card_payload is not None:
        return "interactive", card_payload
    # 畸形表格→回落纯文本（仍可见，不空）
    return "text", json.dumps({"text": content}, ensure_ascii=False)
if _MARKDOWN_HINT_RE.search(content):
    return "post", _build_markdown_post_payload(content)
return "text", json.dumps({"text": content}, ensure_ascii=False)
```

新增的辅助函数（`_parse_markdown_table_block`、`_build_table_card_elements`、`_build_table_card_payload`）处理管道表格解析、对齐标记（`:---`、`---:`、`:---:`）、正文混排、以及 100 字卡片预览摘要。在真实网关上通过多表格简报验证了端到端。

这个补丁是候选上游 PR。

### 3. 一键简报发布管线

一条 244 行的发布脚本，功能链：

1. 接收一篇 Markdown 简报
2. 通过 OAuth 上传到飞书云盘
3. 转为原生 `docx` 云端文档
4. 向目标会话推送 schema 2.0 交互式卡片，附「查看完整简报」按钮可深度链接到文档中

每天盘前和收盘后通过 cron 调度执行。

### 4. Cron 模式打通

两个踩过的坑:

- **Cron 中的审批拦截：** Hermes 默认 `approvals.cron_mode = deny` 会在 cron 任务执行到一半时静默等待人类审批，直接杀死任务。修复：在 `config.yaml` 中显式设置 `approvals.cron_mode: auto_allow`。
- **CLI 参数中的 emoji 干扰：** emoji 里嵌入的变化选择器-16（VS-16）字节被内部命令白名单子系统（Tirith）拦截，导致执行卡死。修复：emoji 只放在 Markdown 正文内，CLI 标志（`--title`、`--subtitle`）保持纯 ASCII。

### 5. macOS launchd 守护

写了一个 `gateway-supervisor.sh` 每 30 秒轮询一次，网关退出即自动重启，绕开了 macOS 26+ 对用户级代理有问题的 `launchctl bootstrap` 行为。

### 6. `hms`——带回滚安全的多供应商切换器

一条 380 行的 bash CLI，在 `config.yaml` 中精准切换当前 LLM 供应商，无需重启 Hermes 也不用手改 YAML。

**为什么做它：** 我并行维护 4 个供应商（火山引擎 Ark / DeepSeek / Z.AI / OpenRouter）。手动切换一次大约 30 秒，每天换 5+ 次，且有大约 10% 的 YAML 损坏率，每次恢复要花 5 分钟。`hms volc-glm` 只需 3 秒完成同样的操作，零损坏风险。

**安全链：**

```
备份 → 保险库密钥加载 → curl 预检 → 原子写 → git 风格 diff
```

每次切换都会创建带时间戳的备份。接口探测是宽松的（HTTP 200/4xx 都视为存活——401 来自错误认证头也能证明 DNS + TLS + 网关正常）。互斥机制：只有当前活动的供应商持有真正的密钥，其他全部填 `__DISABLED__`，这样意外的路由会直接报错。

**硬规则：** `hms` 永不自动回滚。供应商切换始终是显式的人为操作。如果火山引擎被限流了，你手动跑 `hms ds-flash` 切到 DeepSeek——工具不会替你做决定。

→ 完整的产品级文档（PRFAQ、PRD、路线图、GTM、发布回顾）在 [`hms/`](./hms/) 目录里。仅供展示——只为 n=1（我）搭建，不支持 pip 安装。

---

## 配置骨架

你的 `~/.hermes/config.yaml` 大致长这样（密钥已脱敏，你的可能不一样）：

```yaml
agent:
  provider: volcengine-agent-plan

custom_providers:
  volcengine-agent-plan:
    base_url: https://ark.cn-beijing.volces.com/api/plan/v3
    api_key: <ARK_API_KEY>

mcp:
  servers:
    askecho-search-infinity:
      command: uvx
      args:
        - --from
        - git+https://github.com/volcengine/mcp-server#subdirectory=server/mcp_server_askecho_search_infinity
        - mcp-server-askecho-search-infinity
      env:
        ASK_ECHO_SEARCH_INFINITY_API_KEY: <SEARCH_KEY>

approvals:
  cron_mode: auto_allow
```

外加凭据在 `~/.hermes/.env`（chmod 600）里：

```bash
TAVILY_API_KEY=<已脱敏>
SERPAPI_API_KEY=<已脱敏>
VOLCENGINE_ARK_SEARCH_KEY=<已脱敏>
FEISHU_APP_ID=<已脱敏>
FEISHU_APP_SECRET=<已脱敏>
```

---

## 对我来说这东西为什么值得

我把它看作一本**可运行的知识库**，而不是工具仓库：

- 真实的 LLM 智能体架构（模型路由、工具腰线、prompt 缓存纪律）
- MCP 服务集成模式
- IM 网关适配器内部机制（飞书那个古怪的 payload 管线让我学到了很多）
- 生产级 cron 模式的坑——单次 demo 永远暴露不出来的问题

如果你也在基于 Hermes 搭建自己的智能体——或者正在评估 Agent 技术栈——这里的补丁和笔记或许能帮你少熬几个半夜。

---

## 路线图

- [ ] 将飞书表格卡片补丁作为 PR 提交到上游
- [ ] Discord 原生渲染表格内容，与飞书对等
- [ ] 配一个专门存研究笔记的长期记忆 hindsight bank
- [ ] 将简报发布管线开源为可复用的 Hermes 插件
- [ ] hms：在 README 上加 asciinema 的 demo GIF

---

## 仓库结构

```
.
├── README.md                          # 英文版
├── README.zh-CN.md                    # 中文版
├── docs/
│   └── blog-post.md                   # 长文：设计决策 + 经验教训
├── patches/
│   └── 0001-feishu-render-markdown-tables-as-native-cards.patch
│                                      # 173 行 unified diff：上文所述的上游级修复
├── hms/                               # 多供应商切换器（参考上文第 6 节）
│   ├── README.md                      # 快速开始 + 安全链
│   ├── src/hms.sh                     # 380 行 bash CLI
│   ├── examples/                      # 配置 + 保险库布局（占位文件）
│   └── docs/                          # 7 篇产品文档套装：PRFAQ → 发布回顾
└── LICENSE                            # MIT
```

用下面命令验证补丁可以干净地在上游 Hermes Agent 上应用：

```bash
git apply --check patches/0001-feishu-render-markdown-tables-as-native-cards.patch
```

---

## 致谢

- [Hermes Agent](https://hermes-agent.nousresearch.com/) —— Nous Research
- 火山引擎 Ark Agent Plan —— 提供了模型与搜索基础设施
- 飞书开放平台文档 —— schema 2.0 卡片规范一旦找到了其实是写得不错的

---

*深夜敲出来的，一人一点修，慢慢磨成现在这样。*