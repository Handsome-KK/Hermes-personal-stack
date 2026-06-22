# hms — Hermes Model Switch

> ⚠️ **这是一个 showcase 仓库**，不是开箱即用的产品。
> 它把一段日常工具的设计/实现/产品思考完整摆出来供阅读。
> 直接 `git clone` 是跑不起来的——依赖具体一个人的 `~/.hermes/` 目录结构和私有金库。
> 想拿走改成自己的版本，欢迎；下面有完整的产品文档 + 源码 + 复盘。

---

## 一句话

> **380 行 bash + 一个 YAML 金库，把"在 4 家大模型 provider 之间切换"从 30 秒手改压到 3 秒一行命令——但永远不替你按那个按钮。**

```
$ hms volc-glm
━━━ 切换: → volcengine-agent-plan :: glm-latest ━━━
✓ 备份: config-20260622-001311.yaml
→ 探测端点 (5s 超时)...
✓ 端点可达 (HTTP 401)

━━━ diff (脱敏) ━━━
- provider: deepseek
+ provider: volcengine-agent-plan
- default: deepseek-v4-flash
+ default: glm-latest
- api_key: sk-aaa...bbb
+ api_key: ark-aaa...bbb

✓ config.yaml 已原子更新
⚠  当前会话仍跑旧模型, /reset 或重启
   切错? → hms restore
```

---

## 为什么写它

在本地跑 Hermes Agent 同时挂了 4 家 provider，每天要切 5~10 次模型。手改 `config.yaml` 单次 30 秒、出错率 10%、恢复成本 5 分钟——但最贵的代价是 **"懒得切→用次优模型"**。

工具的目标不是省时间，是把"切换"从一个**小工程**变成一个**日常动作**，让你重新拥有那些原本因为麻烦而放弃的选项。

完整的痛点分析和决策推理：[`docs/02-opportunity-assessment.md`](docs/02-opportunity-assessment.md)

---

## 设计原则（八条）

| # | 原则 | 怎么落地 |
|---|------|---------|
| 1 | 能撤销 | 改之前自动备份；`hms restore` 一行回 |
| 2 | 凭证与配置分离 | 真 key 住金库 `~/.hermes/private/hms_keys.yaml`（chmod 600） |
| 3 | 互斥 | 切到 A，其余 provider 的真 key 全部翻成 `__DISABLED__` |
| 4 | 三态语义 | 真 key / `__DISABLED__` / `__NEEDS_KEY__` |
| 5 | 预检容错 | curl 探测目标 `/models`，4xx 都算端点活着；只有 000 才中止 |
| 6 | 校验后落盘 | 临时文件 → load 校验 → 原子 `replace` |
| 7 | 可见性 | git-style diff + 自动脱敏 |
| 8 | **绝不替人决策** | 不自动 fallback；切换永远是显式人类动作 |

第 8 条是红线。详见 [`docs/03-PRD.md`](docs/03-PRD.md) §5 设计决策表。

---

## 产品文档（按阅读路径）

| # | 文档 | 给谁看 |
|---|---|---|
| 01 | [PRFAQ — 新闻稿 + 10 个 FAQ](docs/01-PRFAQ.md) | 想 30 秒看懂这是什么的人 |
| 02 | [Opportunity Assessment — 机会评估 + RICE](docs/02-opportunity-assessment.md) | 想看怎么判断"该不该做"的人 |
| 03 | [PRD — 产品需求文档](docs/03-PRD.md) | 想看产品定义 + 设计决策的人 |
| 04 | [Roadmap — Now/Next/Later + 不做的事](docs/04-roadmap.md) | 想看作者怎么对自己说"不"的人 |
| 05 | [GTM Plan — 上线计划](docs/05-gtm-plan.md) | 想看 Tier 3 silent showcase 怎么发的人 |
| 06 | [Launch Recap — 上线复盘](docs/06-launch-recap.md) | 想看"预测 vs 实际"和踩坑的人 |

**推荐阅读顺序**：
- 想看故事 → 01 → 06 → 03
- 想看决策 → 02 → 03 → 04
- 想看代码 → README → `src/hms.sh` → 03

---

## 源码

```
.
├── src/hms.sh                       # 主程序 (380 行 bash)
├── examples/
│   ├── config.example.yaml          # Hermes 主配置的样子
│   └── vault.example.yaml           # 金库的样子
├── docs/                            # 7 份产品文档（见上表）
├── README.md
└── LICENSE                          # MIT
```

---

## 它不做的事 (有意为之)

- ❌ 自动 fallback / 自动切 provider
- ❌ 热替换当前会话的模型（必须 /reset 或重启）
- ❌ 改 `providers.<name>.base_url`
- ❌ 发请求消费 token（预检走免费的 `/models` 端点）
- ❌ 管 `fallback_model` 配置（那是另一套机制）
- ❌ 接受外部贡献（fork 自己改）

完整"不做清单"和理由：[`docs/04-roadmap.md`](docs/04-roadmap.md) §❌

---

## License

MIT — 拿走改、抄进自己的脚本里、做成 brew 包，都行。
预设别名、金库格式，你都可以重新设计。
