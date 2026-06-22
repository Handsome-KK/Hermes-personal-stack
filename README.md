# Building My Own AI Assistant on Hermes Agent

> Self-hosted, multi-channel, self-improving — extended with custom MCP integrations,
> Feishu native rendering, and scheduled brief pipelines.

This repo documents how I extended [Hermes Agent](https://hermes-agent.nousresearch.com/)
into a personal AI assistant that runs across CLI, IM gateways, and scheduled cron jobs —
including upstream-quality patches I wrote along the way.

---

## What this is

I wanted a single AI agent that could:

- Run anywhere I am (terminal, mobile IM, scheduled background jobs)
- Hold real long-term memory + skills across sessions
- Drive a real shell + browser, not just chat
- Push structured briefings on a schedule with **rich rendering** (tables, cards, attachments) — not Markdown source code

Hermes Agent (by Nous Research) gives you 70% of that out of the box. This repo is the
remaining 30% — the configuration, the MCP integrations, the rendering fixes, and the
operational glue that turns it into a daily-driver assistant.

---

## Stack

| Layer            | Component                                              |
|------------------|--------------------------------------------------------|
| Agent core       | Hermes Agent (open source)                             |
| Primary model    | Volcengine Ark Agent Plan (`plan/v3` endpoint)         |
| Provider routing | [hms](./hms/) — multi-provider mutex-switcher (380 lines bash) |
| Search backends  | Tavily · SerpAPI · Volcengine `askecho-search-infinity` MCP |
| IM gateways      | Telegram · Feishu (Lark) — bidirectional               |
| Image gen        | Doubao Seedream (Volcengine)                           |
| Voice            | Edge TTS / OpenAI-compatible providers                 |
| Storage          | Local SQLite session DB · Feishu Drive · Baidu Netdisk |
| Scheduling       | Hermes cron + macOS launchd supervisor                 |

---

## What I built on top

### 1. Multi-backend web search routing
Configured three independent search channels with priority ordering:

```
exa → parallel → firecrawl → tavily → xai → brave-free → ddgs
```

Tavily is the auto-selected backend; Volcengine `askecho-search-infinity` is registered
as an MCP server for Chinese-language queries; SerpAPI is wired as a terminal-callable
HTTP fallback for raw Google results. Each channel was real-traffic verified — the
agent doesn't silently fall back to free DDGS when paid backends are configured.

### 2. Feishu interactive card rendering — upstream patch
**Problem:** Hermes' Feishu adapter detected Markdown tables and force-routed them
to plain text, because Feishu's `post`-type `md` element doesn't render pipe tables.
Result: every briefing with a table arrived as raw `|---|` source code.

**Fix:** Wrote a card builder that detects Markdown table blocks and routes them
through Feishu's schema 2.0 interactive card API with native `table` components,
preserving headers, alignment, and pagination. Prose around the tables stays as
`markdown` elements, so the layout is fully reconstructed client-side.

```python
# gateway/platforms/feishu.py — _build_outbound_payload (after fix)
if _MARKDOWN_TABLE_RE.search(content):
    card_payload = _build_table_card_payload(content)
    if card_payload is not None:
        return "interactive", card_payload
    # malformed table → fall through to plain text (still visible, never empty)
    return "text", json.dumps({"text": content}, ensure_ascii=False)
if _MARKDOWN_HINT_RE.search(content):
    return "post", _build_markdown_post_payload(content)
return "text", json.dumps({"text": content}, ensure_ascii=False)
```

The new helpers (`_parse_markdown_table_block`, `_build_table_card_elements`,
`_build_table_card_payload`) handle pipe-table parsing, alignment markers
(`:---`, `---:`, `:---:`), prose interleaving, and a 100-char summary for the card
preview. Verified end-to-end by sending a multi-table briefing through the live gateway.

This patch is a candidate upstream PR.

### 3. One-shot brief publish pipeline
A 244-line publish script that:

1. Takes a Markdown briefing file
2. Uploads to Feishu Drive via OAuth
3. Converts to native `docx` cloud doc
4. Pushes a schema 2.0 interactive card to a target chat with an "Open full briefing"
   button that deep-links into the doc

Used for daily pre-market and post-close briefs delivered on a cron schedule.

### 4. Cron-mode hardening
Two pitfalls discovered and worked around:

- **Approval interception in cron:** Hermes' default `approvals.cron_mode = deny` silently
  kills cron jobs mid-execution waiting for human approval. Fix: explicit
  `approvals.cron_mode: auto_allow` in `config.yaml`.
- **Emoji in CLI args:** Variation-selector-16 (VS-16) bytes embedded in emojis
  trigger an internal command-allowlist subsystem ("Tirith") and stall execution.
  Fix: keep emoji confined to Markdown body content; CLI flags (`--title`,
  `--subtitle`) stay pure ASCII.

### 5. macOS launchd supervisor
Wrote a `gateway-supervisor.sh` that polls every 30s and respawns the gateway if
it exits, working around macOS 26+'s broken `launchctl bootstrap` for user agents.

### 6. `hms` — multi-provider switcher with rollback safety
A 380-line bash CLI for surgically swapping the active LLM provider in `config.yaml`
without restarting Hermes or hand-editing YAML.

**Why it exists:** I run 4 providers in parallel (Volcengine Ark / DeepSeek /
Z.AI / OpenRouter). Hand-switching takes ~30s per swap, 5+ swaps a day, with a
~10% YAML-corruption rate that costs 5 minutes to recover. `hms volc-glm` does
the same thing in 3 seconds with zero corruption risk.

**Safety chain:**

```
backup → vault key load → curl preflight → atomic write → git-style diff
```

Every switch creates a timestamped backup. Endpoint probes are tolerant
(HTTP 200/4xx all count as alive — 401 from a bogus auth header still proves
DNS + TLS + gateway are up). Mutex enforcement: only the active provider holds
a real key; others get `__DISABLED__` so accidental routing fails loudly.

**Hard rule:** `hms` never falls back automatically. Provider switching is
always an explicit human action. If Volcengine is rate-limited, *you* run
`hms ds-flash` to move to DeepSeek — the tool will not decide for you.

→ Full PM-style writeup (PRFAQ, PRD, roadmap, GTM, launch recap) lives in
[`hms/`](./hms/). Showcase-only — built for n=1 (me), not pip-installable.

---

## Configuration shape

Your `~/.hermes/config.yaml` ends up looking roughly like this (secrets redacted,
yours will differ):

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

Plus credentials in `~/.hermes/.env` (chmod 600):

```bash
TAVILY_API_KEY=<redacted>
SERPAPI_API_KEY=<redacted>
VOLCENGINE_ARK_SEARCH_KEY=<redacted>
FEISHU_APP_ID=<redacted>
FEISHU_APP_SECRET=<redacted>
```

---

## Why this matters (to me)

I treat this less as a tool repo and more as a **working knowledge base** of:

- Real LLM agent architecture (model routing, tool waist, prompt cache discipline)
- MCP server integration patterns
- IM gateway adapter internals (Feishu's quirky payload pipeline taught me a lot)
- Production cron-mode pitfalls that single-shot demos never surface

If you're building your own agent on Hermes — or evaluating Agent stacks in general —
the patches and notes here may save you a few late nights.

---

## Roadmap

- [ ] Submit Feishu table-card patch upstream as a PR
- [ ] Add Discord native-rendering parity for table content
- [ ] Wire a long-term memory hindsight bank dedicated to research notes
- [ ] Open-source the brief-publish pipeline as a reusable Hermes plugin
- [ ] hms: asciinema demo GIF for the README

---

## Repo layout

```
.
├── README.md                          # this file
├── docs/
│   └── blog-post.md                   # long-form write-up: design decisions + lessons learned
├── patches/
│   └── 0001-feishu-render-markdown-tables-as-native-cards.patch
│                                      # 173-line unified diff: the upstream-quality fix referenced above
├── hms/                               # multi-provider switcher (see section 6 above)
│   ├── README.md                      # quickstart + safety chain
│   ├── src/hms.sh                     # 380-line bash CLI
│   ├── examples/                      # config + vault layout (placeholders)
│   └── docs/                          # 7-doc PM bundle: PRFAQ → recap
└── LICENSE                            # MIT
```

Read the patch with:

```bash
git apply --check patches/0001-feishu-render-markdown-tables-as-native-cards.patch
```

against an upstream Hermes Agent checkout to verify it applies cleanly.

---

## Acknowledgements

- [Hermes Agent](https://hermes-agent.nousresearch.com/) by Nous Research
- Volcengine Ark Agent Plan for the model + search infrastructure
- Feishu Open Platform docs (the schema 2.0 card spec is excellent once you find it)

---

*Built late at night, one bug fix at a time.*
