# PRD: hms — Hermes Model Switch v1.0

**Status**: Shipped
**Author**: KK / Alex (PM hat)
**Last Updated**: 2026-06-22
**Version**: 1.0.0
**Stakeholders**: KK (Eng + Design + PM + Customer 一人多角); Hermes Agent runtime as upstream dependency.

---

## 1. Problem Statement（问题陈述）

我们在解决什么具体的用户痛点？

> **一个同时挂多家 LLM provider 的本地 agent 重度用户，需要在多个 provider × 模型 之间手动切换，但当前没有任何工具完整覆盖"备份 + 互斥 + 预检 + diff + 回滚"五件套，全靠手改 YAML，单次成本低但乘以频次后注意力损耗严重。**

**谁遇到这个问题、频率如何、不解决的代价**：
- 用户：KK（Hermes Agent 重度用户，agent + 简报 + 交易研究全部在本地跑）
- 频率：日均 5~10 次手动切换
- 出错率：~10%（YAML 缩进、key 粘错位、互斥忘了关）
- 不解决的代价：
  1. 时间直接损耗 3~15 min/天
  2. 凭证泄露风险（手编辑→误 commit）
  3. **决策质量隐性下降**——"懒得切"导致用次优模型，这是最贵的代价

### Evidence

| 信号类型 | 内容 |
|---|---|
| Behavioral | 一周内 47 次手改 config，4 次找备份，1 次 YAML 崩坏 |
| Self-Interview | "想试一下豆包，但懒得改 config，算了用 GLM 凑合"（关键引用） |
| Competitive | sed 脚本 / direnv / keychain 都不能完整覆盖五件套 |

---

## 2. Goals & Success Metrics（目标与成功指标）

| Goal | Metric | Current Baseline | Target | Measurement Window |
|---|---|---|---|---|
| 降低单次切换耗时 | 平均完成 1 次切换的秒数 | ~30s | **≤ 5s** | 上线后 1 周日常使用 |
| 消除切换出错 | 切换后 Hermes 无法启动的次数 | 1 次/周 | **0 次/月** | 上线后 30 天 |
| 缩短错误恢复 | 切错到回到工作状态的时间 | ~5 min | **≤ 10s** | 出错时观测 |
| 解放模型选择 | "懒得切→用次优模型"事件 | 高频（自报） | **趋近于 0**（自报） | 上线后 2 周自我观察 |
| 凭证泄露风险 | key 被 commit 暂存区拦截的次数 | ~1/月 | **0/月** | 上线后 90 天 |

---

## 3. Non-Goals（不做的事）

明确说明本次迭代**不会**涉及的内容——这部分和"做什么"一样重要。

- ❌ **不做自动 fallback**（哪怕当前 provider 限流也不自动切到下一家）
  → 理由：模型决定输出质量，自动切=偷换底层，调试不可还原
- ❌ **不做热替换**（切换之后当前 Hermes 会话不立即生效）
  → 理由：Hermes 启动时加载 config，热替换需要改 Hermes 内核，超出范围
- ❌ **不改 `providers.<name>.base_url`**
  → 理由：base_url 是 provider 出厂参数，不是切换变量
- ❌ **不做 fallback_model 配置管理**
  → 理由：那是 Hermes 自己的另一套机制，职责边界要清晰
- ❌ **不做网页/TUI 界面**
  → 理由：CLI 已经够快，引入 UI = 引入更多依赖和故障面
- ❌ **不做跨机金库同步**
  → 理由：超出"工具"范畴，进入"密钥管理服务"范畴
- ❌ **不接受外部贡献**
  → 理由：showcase 项目，预设别名是个人偏好，不适合社区化

---

## 4. User Personas & Stories

### Primary Persona

**Name**: KK Garfield
**Description**: macOS 重度用户 / Hermes Agent 自托管 / CFD 交易研究 / 同时挂 4 家 LLM provider / 日均 5~10 次模型切换 / 直接、无废话、讨厌"自动决策"。

### 核心用户故事

#### Story 1: 早上想用 GLM 跑日常对话

> 作为 KK，我想在 5 秒内把当前 provider 切到 volcengine-agent-plan + glm-latest，以便不打断我的工作流就开始用上 GLM。

**Acceptance Criteria**:
- [x] Given 当前 provider=A, when 执行 `hms volc-glm`, then config.yaml 被原子更新到目标 provider/model
- [x] 切换前自动备份 config 到 `~/.hermes/backups/config-<timestamp>.yaml`
- [x] 端点预检：HTTP 200/400/401/403/404 算"端点活着"；000 中止
- [x] 命令完成时间 ≤ 5s（含 5s 预检超时）
- [x] 互斥：仅目标 provider 持有真 key，其他 provider 的真 key 被翻成 `__DISABLED__`
- [x] 占位 `__NEEDS_KEY__` 不被覆盖

#### Story 2: 切错了立刻回滚

> 作为 KK，我想在切到 Z.AI 发现限流后，5 秒内回到上一个能用的 provider，以便不丢失当前工作上下文。

**Acceptance Criteria**:
- [x] Given 刚执行过一次切换, when 执行 `hms restore`, then 恢复到最新备份
- [x] restore 之前再自动备份当前 config（防止"撤销了还想撤回去"）
- [x] 命令完成 ≤ 2s

#### Story 3: 看金库里 key 状态

> 作为 KK，我想用一行命令看金库里哪些 provider 已经有 key、哪些占位待补，以便决定下一次试什么。

**Acceptance Criteria**:
- [x] `hms vault` 一次性列出所有 provider 的 key 状态
- [x] 三态颜色化：🟢 真 key、🟡 占位 (`__NEEDS_KEY__`)、🔴 缺失
- [x] 真 key 显示前 14 + 后 4 字符，中间脱敏

#### Story 4: 列出当前 config 知道的所有 provider/model

> 作为 KK，我想看 config 里注册的所有 provider 和它们的模型，以便决定加哪个 alias。

**Acceptance Criteria**:
- [x] `hms list` 按 provider 分组列出所有 model
- [x] 标识当前活跃的 provider/model

---

## 5. Solution Overview（方案概述）

`hms` 是一个 380 行 bash 脚本（内嵌 python3 处理 YAML），定位为 Hermes Agent 配置的**外科手术工具**：只修改 `model.*` 和 `providers.*.api_key`，不碰其他字段。

**主流程（apply_switch）**：

```
hms <alias>
  ↓
[1] 备份当前 config → 时间戳文件 + latest 软链
  ↓
[2] 从金库读取目标 provider 的真 key
  ↓
[3] 解析 alias → 目标 (provider, model, base_url)
  ↓
[4] curl 预检目标 base_url/models（5s 超时 + 假授权头）
      ↓
      └─ HTTP 000 → 中止
      └─ HTTP 2xx/4xx → 继续
  ↓
[5] Python: 读 config → 修改 model.* → 互斥处理 api_key →
    写临时文件 → 重新 load 校验 → 原子 replace
  ↓
[6] 打印 git-style diff（key 自动脱敏）
  ↓
[7] 提示 /reset 或重启 + restore 入口
```

### Key Design Decisions

| Decision | 选择 | 取舍 |
|---|---|---|
| 凭证存储 | 单独 YAML 金库 + chmod 600 | 放弃了 keychain 集成；获得了零运行时依赖 |
| 配置写入策略 | 临时文件 → 校验 → 原子 replace | 放弃了直接 sed in-place；获得了崩溃安全 |
| 预检判定 | 4xx 也算"端点活着" | 放弃了"严格 200 通过"；获得了不浪费真 key 配额的预检 |
| 互斥逻辑 | 只翻真 key，`__NEEDS_KEY__` 跳过 | 放弃了简单粗暴的 "全部 DISABLED"；获得了占位语义保护 |
| 范围克制 | 只动 `model.*` 和 `api_key`，不动 base_url | 放弃了"一键改 provider 出厂参数"；获得了职责清晰 |
| 别名管理 | 硬编码在脚本里 | 放弃了外部配置文件；获得了单文件部署 + 零层级 |
| 决策权 | 不自动 fallback | 放弃了"挂了自动切"便利性；获得了人类显式控制权 |

---

## 6. Technical Considerations（技术考量）

### Dependencies

| 依赖 | 用途 | Owner | Timeline Risk |
|---|---|---|---|
| bash 3.2+ | 主程序 | macOS 自带 | Low |
| python3 + PyYAML | YAML 解析/写入/diff | macOS 自带 / pip | Low |
| curl | 端点预检 | 系统自带 | Low |
| Hermes Agent | 配置消费方 | 上游 | Med — config schema 变更会破坏 hms |

### Known Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Hermes 上游改 config schema | Medium | High | hms 只改两个字段，schema 变化时只需补丁两处 |
| macOS bash 3.2 兼容 | Low | Medium | 已在测试中规避（不用 mapfile 等 4 特性） |
| 金库文件被偷 | Low | High | chmod 600 + 假设本地 fs 是可信边界（接受） |
| 预检误判（端点 5xx） | Low | Low | 5xx 默认放行（端点活着但出问题），不中止 |

### Open Questions
- [x] 是否支持自定义 alias？→ **延后到 P2**（决策：先看一年使用模式再说）
- [x] 是否做 diff-only 模式（看 diff 不真切）？→ **延后到 P2**

---

## 7. Launch Plan（发布计划）

| Phase | Date | Audience | Success Gate |
|---|---|---|---|
| Internal alpha | 2026-06-21 | 自己（手工跑核心 4 个命令） | 切换 + restore + vault + list 全部通过 |
| Beta | 2026-06-22 | 自己（连续 24h 真实日常使用） | 0 次回退到手改 / 0 次 YAML 崩坏 |
| GA (showcase) | 2026-06-22 | 公开 GitHub showcase 仓库 | 文档完备 + 凭证全部占位 + README 明确"展示型" |

**Rollback Criteria**: 单日内发生 YAML 崩坏或互斥失败 → 回退到 v0（手改 + 简单 sed 备份），重新设计。
（**实际未触发**）

---

## 8. Appendix

- `docs/01-PRFAQ.md` — 新闻稿 + FAQ
- `docs/02-opportunity-assessment.md` — 机会评估 + RICE
- `docs/04-roadmap.md` — Now/Next/Later 路线图
- `docs/05-gtm-plan.md` — GTM 简报
- `docs/06-launch-recap.md` — 上线复盘（30/60/90 天度量框架）
- `src/hms.sh` — 主程序源码
- `examples/config.example.yaml` — Hermes 配置长这样
- `examples/vault.example.yaml` — 金库长这样
