# Go-to-Market Plan: hms v1.0

**Launch Date**: 2026-06-22
**Launch Tier**: **3 (Silent showcase)** — 不是商业发布，是个人作品集陈列
**PM Owner**: KK
**Marketing DRI**: KK
**Eng DRI**: KK

> Tier 3 ≠ 不重要。它意味着：
> - 不做新闻稿轰炸、不做付费推广
> - 但内容质量、消息一致性、回滚预案标准 = Tier 1
> - 因为这是作品集，被看见时只有一次第一印象

---

## 1. What We're Launching（我们在发布什么）

`hms` v1.0 ——本地大模型工作站的多 provider 切换器。**作为 showcase 仓库公开**，不是开箱即用产品。

**它解决的用户问题**：
> 同时挂多家 LLM provider 的 agent 重度用户，切换 provider 单次 30 秒、出错率 10%、恢复成本 5 分钟，总损耗在乘以频次后变得严重——但更隐蔽的代价是"懒得切→用次优模型"。

**它**展示的设计理念**：
1. 工具不替人做决策（不自动 fallback）
2. 凭证与配置分离 + 三态语义
3. 临时文件→校验→原子 replace 的崩溃安全
4. 4xx 也算"端点活着"的宽松预检
5. 单文件 + 零运行时依赖的克制

---

## 2. Target Audience（目标受众）

| Segment | Size | Why They Care | Channel to Reach |
|---|---|---|---|
| **同好型受众**：本地跑 agent / 多 provider 切换的 LLM 重度用户 | 小众但精准 | 一眼能看出"这就是我要的" | X (en+zh), Hacker News (silent post), 知乎 |
| **观察型受众**：产品经理 / 工程师，看作品集和方法论 | 中等 | "一个产品经理视角下的 380 行 bash" | 朋友圈, 知乎 |
| **被启发型受众**：在写类似 internal tool 的人 | 长尾 | "我也想给自己的工作流写一个" | GitHub 自然流量, 搜索 |
| ❌ **不做**：商业付费用户、企业级用户 | — | 这是 showcase 不是 product | — |

---

## 3. Core Value Proposition（核心价值主张）

### One-liner（对外）

> "在 4 家 LLM provider 之间切换的 380 行 bash——把切错代价从 5 分钟压到 5 秒，永远不替你按那个按钮。"

### Messaging by audience

| Audience | Their Language for the Pain | Our Message | Proof Point |
|---|---|---|---|
| **LLM 工程师** | "每次切 provider 都得手改 config，烦" | 380 行 bash 干掉所有琐碎，包含备份/预检/互斥/diff/回滚 | README 的命令示范 |
| **产品经理** | "想看一个真实的小产品是怎么思考的" | 这个 repo 不只是代码，还附带 PRFAQ + 机会评估 + PRD + 路线图 + GTM | docs/ 目录的 6 份文档 |
| **被启发型用户** | "我也有类似痛点，但不知道值不值得写" | RICE 评分给你看：一人产品按使用频次乘起来就是 ROI 答案 | `02-opportunity-assessment.md` |
| **安全意识强的人** | "你这 key 怎么管？" | 金库分离 + chmod 600 + 自动脱敏 + 三态语义 | `03-PRD.md` 设计决策表 |

### 一致的 hook（所有平台共用）

> **"它不替你做决策，只替你抹掉琐碎。"**
> （这一句是产品定位的灵魂——任何文案出现这一句即对齐。）

---

## 4. Launch Checklist

### Engineering
- [x] 代码 chmod +x 并验证 `bash -n` 语法通过
- [x] 真实 key/url 100% 占位符化扫描通过
- [x] `.gitignore` 拦截 `hms_keys.yaml` / `config.yaml` / `backups/`
- [x] LICENSE (MIT) 已添加
- [ ] gh CLI 认证（KK 手动 `gh auth login`）
- [ ] 公开仓库创建（仓库名 KK 决定）
- [ ] 首次 push 后 review 仓库公开页面，确认无残留凭证

### Product
- [x] README 明确"showcase 不开箱即用"定位
- [x] PRFAQ 完整覆盖 10 个 FAQ
- [x] 设计原则 8 条嵌入 README + PRD + RECAP
- [x] 三套示例配置（占位符版本）

### Marketing / Content
- [x] X 中文版（≤240 字）
- [x] X 英文版（≤280 字）
- [x] 朋友圈短文案
- [x] 知乎长文版本
- [x] GitHub release note
- [ ] 朋友圈配图（可选，等 KK 决定要不要做）
- [ ] 知乎首图（可选）

### Customer Support
- N/A（一人产品）

---

## 5. Success Criteria

> Tier 3 silent showcase 的成功 ≠ 多少 star，而是**消息一致性 + 内容质量 + 长期 SEO**。

| Timeframe | Metric | Target | Owner |
|---|---|---|---|
| Day 0 | 仓库公开后 24h 内残留凭证 / 安全事件 | 0 | KK |
| Week 1 | 自己再次切换时是否信任 hms（不回退到手改） | 100% | KK |
| Month 1 | 收到 ≥ 1 条"看了 README 学到东西"的反馈 | ≥ 1 | KK |
| Month 3 | 自己加新 alias / 修小 bug 时是否仍按原设计原则 | 是 | KK |
| Month 6 | 是否被搜索/链接引用 ≥ 3 次 | ≥ 3 | KK |
| Year 1 | 自己还在用 hms（没被替代） | 是 | KK |

**主观指标**：
- ✅ 看完文档的人会说"这是个认真做的小项目"
- ✅ 看完 RECAP 的人会想"这件事我也能干"
- ✅ 看完 PRD 的人会理解"为什么不自动 fallback"

---

## 6. Rollback & Contingency

**Rollback trigger（公开发布层）**:
- 残留真实凭证被发现 → 立即 force-push 历史清理 + 吊销暴露 key + 全部 issue 通知
- 公关风险（不太可能，但 hold for paranoia）→ private 仓库

**Rollback owner**: KK
**Rollback runbook**:
```bash
# 撤回到 private
gh repo edit <user>/<repo> --visibility private --accept-visibility-change-consequences

# 吊销 key（如果残留）
# 在各 provider console 手动 revoke

# 重写历史
git filter-repo --invert-paths --path-glob '*hms_keys.yaml*'
git push --force-with-lease
```

**Communication plan if rollback**:
- 朋友圈/X 文案撤回 + 简短致歉（如果已发出）
- 不做更多说明，silent rollback

---

## 7. Post-Launch（上线后 7 天内必做）

- [ ] Day 1: 自己当作初次见到的人 review README，找别扭的地方
- [ ] Day 3: 检查 GitHub Insights，看流量来源
- [ ] Day 7: 写一份"上线第一周自我观察"日记，作为下一版输入

> Tier 3 不意味着 "fire and forget"——这是给自己一年后看的作品，值得 7 天的 follow-up。
