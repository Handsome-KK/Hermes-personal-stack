#!/bin/bash
# Hermes 主 Provider / Model 快速切换 v2
# 设计原则:
#   1. 切换前自动备份 config.yaml (带时间戳)
#   2. curl 预检目标 provider 端点 (容错)
#   3. 互斥: 目标 provider 写真 key, 其他 provider api_key=__DISABLED__
#   4. 原子写入 + yaml 语法校验
#   5. 打印 git-style diff (- / +)
#   6. hms restore [file] 一键恢复
#
# 用法:
#   hms                       # 显示当前配置 + 可用预设
#   hms <alias>               # 切到预设
#   hms show                  # 显示当前
#   hms list                  # 列出所有 provider/model
#   hms backups               # 列出备份
#   hms restore [file]        # 恢复 (默认最新)
#   hms vault                 # 显示金库状态 (key 是否齐全)
#
# 切换后请在 Hermes 里 /reset 或重启会话生效

set -euo pipefail

CONFIG="$HOME/.hermes/config.yaml"
VAULT="$HOME/.hermes/private/hms_keys.yaml"
BACKUP_DIR="$HOME/.hermes/backups"
mkdir -p "$BACKUP_DIR"

# ─── 预设别名 ────────────────────────────────────────
# 格式: alias|provider|model
declare -a PRESETS=(
  # ── 火山 Agent Plan (volc-*) ─ base_url: ark.cn-beijing.volces.com/api/plan/v3
  "volc-auto|volcengine-agent-plan|auto"
  "volc-glm|volcengine-agent-plan|glm-latest"
  "volc-glm5|volcengine-agent-plan|glm-5.2"
  "volc-ds-flash|volcengine-agent-plan|deepseek-v4-flash"
  "volc-ds-pro|volcengine-agent-plan|deepseek-v4-pro"
  "volc-minimax|volcengine-agent-plan|minimax-m3"
  "volc-doubao-pro|volcengine-agent-plan|doubao-seed-2.0-pro"
  "volc-doubao-code|volcengine-agent-plan|doubao-seed-2.0-code"
  "volc-doubao-mini|volcengine-agent-plan|doubao-seed-2.0-mini"
  "volc-doubao-lite|volcengine-agent-plan|doubao-seed-2.0-lite"
  "volc-kimi|volcengine-agent-plan|kimi-k2.6"
  # ── DeepSeek 官方 (ds-*) ─ base_url: api.deepseek.com/v1
  "ds-flash|deepseek|deepseek-v4-flash"
  "ds-pro|deepseek|deepseek-v4-pro"
  # ── Z.AI / GLM 官方 (zai-*) ─ base_url: open.bigmodel.cn/api/paas/v4
  "zai-glm|zai|glm-4.6"
  "zai-glm5|zai|glm-4.5"
  # ── OpenRouter 聚合 (or-*) ─ base_url: openrouter.ai/api/v1
  "or-gpt|openrouter|openai/gpt-4o-mini"
  "or-claude|openrouter|anthropic/claude-3.5-sonnet"
  "or-ds|openrouter|deepseek/deepseek-v4-flash"
)

# 颜色
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[0;34m'; C='\033[0;36m'; N='\033[0m'

# ─── helpers ─────────────────────────────────────────

py() { python3 "$@"; }

show_current() {
  echo -e "${B}━━━ 当前 Hermes 主模型配置 ━━━${N}"
  py - <<EOF
import yaml
with open("$CONFIG") as f: c = yaml.safe_load(f)
m = c.get("model", {})
print(f"  provider : {m.get('provider')}")
print(f"  model    : {m.get('default')}")
print(f"  base_url : {m.get('base_url')}")
key = m.get("api_key", "")
masked = f"{key[:14]}...{key[-6:]}" if len(key) > 24 else key
print(f"  api_key  : {masked}")
print()
print("  ─── providers 互斥状态 ───")
for p, cfg in c.get("providers", {}).items():
    k = cfg.get("api_key", "")
    status = "🟢 ACTIVE" if k and not k.startswith("__") else ("⚫ DISABLED" if k == "__DISABLED__" else "🟡 NEEDS_KEY")
    print(f"  {p:30s} {status}")
EOF
}

list_presets() {
  echo -e "${B}━━━ 可用预设 ━━━${N}"
  printf "  ${C}%-14s${N} %-25s %s\n" "ALIAS" "PROVIDER" "MODEL"
  printf "  %-14s %-25s %s\n" "─────" "────────" "─────"
  local last_prov=""
  for p in "${PRESETS[@]}"; do
    IFS='|' read -r alias prov model <<< "$p"
    if [ "$prov" != "$last_prov" ]; then
      echo -e "  ${Y}── $prov ──${N}"
      last_prov="$prov"
    fi
    printf "  ${G}%-14s${N} %-25s %s\n" "$alias" "$prov" "$model"
  done
}

list_all_models() {
  echo -e "${B}━━━ config.yaml 已注册 ━━━${N}"
  py - <<EOF
import yaml
with open("$CONFIG") as f: c = yaml.safe_load(f)
for pname, pcfg in c.get("providers", {}).items():
    k = pcfg.get("api_key", "")
    tag = "🟢" if k and not k.startswith("__") else ("⚫" if k=="__DISABLED__" else "🟡")
    print(f"\n  {tag} [{pname}]  {pcfg.get('base_url','-')}")
    for m in pcfg.get("models", []):
        mid = m.get("id") if isinstance(m, dict) else m
        ctx = m.get("context_length", "") if isinstance(m, dict) else ""
        print(f"      • {mid}" + (f"  (ctx={ctx})" if ctx else ""))
EOF
}

list_backups() {
  echo -e "${B}━━━ 备份列表 (最新在上) ━━━${N}"
  ls -t "$BACKUP_DIR"/config-*.yaml 2>/dev/null | head -20 | while read f; do
    sz=$(stat -f%z "$f")
    printf "  %s  %5d bytes\n" "$(basename "$f")" "$sz"
  done || echo "  (无备份)"
}

vault_status() {
  echo -e "${B}━━━ 金库 (真实 key 存放) ━━━${N}"
  echo "  路径: $VAULT"
  if [ ! -f "$VAULT" ]; then
    echo -e "  ${R}✗ 金库不存在!${N}"
    return 1
  fi
  py - <<EOF
import yaml
with open("$VAULT") as f: v = yaml.safe_load(f) or {}
for p, k in v.items():
    if not k or k.startswith("__"):
        print(f"  🟡 {p:30s} {k}  (需要补 key)")
    else:
        masked = f"{k[:10]}...{k[-4:]}" if len(k)>18 else k
        print(f"  🟢 {p:30s} {masked}")
EOF
}

backup_config() {
  local ts=$(date +%Y%m%d-%H%M%S)
  local dest="$BACKUP_DIR/config-$ts.yaml"
  cp "$CONFIG" "$dest"
  ln -sf "$dest" "$BACKUP_DIR/latest.yaml"
  echo "$dest"
}

probe_endpoint() {
  local base_url="$1" api_key="$2"
  # 容错: 5s 超时, 任何 HTTP 响应都算"端点存在"
  local code url
  url="${base_url%/}/models"
  code=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 5 \
    -H "Authorization: Bearer ${api_key}" \
    "$url" 2>/dev/null || echo "000")
  echo "$code"
}

apply_switch() {
  local target_provider="$1" target_model="$2"
  local ts=$(date +%Y%m%d-%H%M%S)

  echo -e "${Y}━━━ 切换: → $target_provider :: $target_model ━━━${N}\n"

  # 1. 备份
  local backup_file
  backup_file=$(backup_config)
  echo -e "${G}✓${N} 备份: $(basename "$backup_file")"

  # 2. 读取目标 provider 的真实 key (从金库)
  if [ ! -f "$VAULT" ]; then
    echo -e "${R}✗ 金库 $VAULT 不存在${N}"; exit 1
  fi
  local real_key
  real_key=$(py - <<EOF
import yaml
with open("$VAULT") as f: v = yaml.safe_load(f) or {}
print(v.get("$target_provider", ""))
EOF
)
  if [ -z "$real_key" ] || [[ "$real_key" == __* ]]; then
    echo -e "${R}✗ 金库里 $target_provider 的 key 缺失 (当前值: $real_key)${N}"
    echo -e "${Y}   编辑 $VAULT 补 key 后再试${N}"
    exit 1
  fi

  # 3. 从 config 读 base_url
  local base_url
  base_url=$(py - <<EOF
import yaml
with open("$CONFIG") as f: c = yaml.safe_load(f)
print(c["providers"]["$target_provider"]["base_url"])
EOF
)
  echo -e "${G}✓${N} 目标: $base_url"

  # 4. 容错预检 (探测端点)
  echo -e "${Y}→${N} 探测端点 (5s 超时)..."
  local code
  code=$(probe_endpoint "$base_url" "$real_key")
  case "$code" in
    200|400|401|403|404)
      echo -e "${G}✓${N} 端点可达 (HTTP $code)"
      ;;
    000)
      echo -e "${R}✗ 端点不通 (DNS/网络/超时)${N}"
      echo -e "${Y}   已 abort, config.yaml 未改动${N}"
      exit 1
      ;;
    *)
      echo -e "${Y}⚠ 异常响应 HTTP $code, 继续切换 (你自己判断)${N}"
      ;;
  esac

  # 5. 改 config (Python 原子写 + 校验 + 打印 diff)
  py - <<EOF
import yaml, difflib, shutil, sys
from pathlib import Path

cfg = Path("$CONFIG")
old_text = cfg.read_text()
with open(cfg) as f: c = yaml.safe_load(f)

target_provider = "$target_provider"
target_model = "$target_model"
real_key = """$real_key"""
base_url = "$base_url"

# --- 互斥: 翻转 api_key ---
for p, pcfg in c.get("providers", {}).items():
    if p == target_provider:
        pcfg["api_key"] = real_key
    else:
        # 只翻转真实 key, NEEDS_KEY 状态保留
        cur = pcfg.get("api_key", "")
        if cur and cur != "__NEEDS_KEY__":
            pcfg["api_key"] = "__DISABLED__"

# --- 改 model 段 ---
c.setdefault("model", {})
c["model"]["provider"] = target_provider
c["model"]["default"] = target_model
c["model"]["base_url"] = base_url
c["model"]["api_key"] = real_key

# --- 序列化到临时文件 ---
tmp = cfg.with_suffix(".yaml.tmp")
with open(tmp, "w") as f:
    yaml.safe_dump(c, f, allow_unicode=True, sort_keys=False)

# --- 校验: 重新 load 一次, 失败立刻 abort ---
try:
    with open(tmp) as f: yaml.safe_load(f)
except Exception as e:
    tmp.unlink()
    print(f"\x1b[0;31m✗ YAML 校验失败: {e}\x1b[0m")
    sys.exit(1)

new_text = tmp.read_text()

# --- 打印 git-style diff (脱敏 key) ---
def mask(line):
    if "api_key" in line and "ark-" in line or "sk-" in line:
        # 把 key 截断
        import re
        return re.sub(r'(api_key:\s*)(\S{14})\S+(\S{4})', r'\1\2...\3', line)
    return line

old_lines = [mask(l) for l in old_text.splitlines(keepends=True)]
new_lines = [mask(l) for l in new_text.splitlines(keepends=True)]

diff = list(difflib.unified_diff(
    old_lines, new_lines,
    fromfile="config.yaml (before)",
    tofile="config.yaml (after)",
    n=1,
))
print()
print("\x1b[0;34m━━━ diff (脱敏) ━━━\x1b[0m")
for line in diff:
    if line.startswith("+++") or line.startswith("---"):
        print(f"\x1b[1;37m{line.rstrip()}\x1b[0m")
    elif line.startswith("+"):
        print(f"\x1b[0;32m{line.rstrip()}\x1b[0m")
    elif line.startswith("-"):
        print(f"\x1b[0;31m{line.rstrip()}\x1b[0m")
    elif line.startswith("@@"):
        print(f"\x1b[0;36m{line.rstrip()}\x1b[0m")
    else:
        print(line.rstrip())

# --- 原子替换 ---
tmp.replace(cfg)
print()
print("\x1b[0;32m✓ config.yaml 已原子更新\x1b[0m")
EOF

  echo
  show_current
  echo
  echo -e "${Y}⚠  当前会话仍跑旧模型, 在 Hermes 里 /reset 或重启${N}"
  echo -e "${C}   切错? → hms restore${N}"
}

apply_restore() {
  local src="${1:-}"
  if [ -z "$src" ]; then
    src="$BACKUP_DIR/latest.yaml"
    if [ ! -e "$src" ]; then
      echo -e "${R}✗ 无最新备份链接${N}"; exit 1
    fi
    # 解软链
    src=$(readlink "$src" 2>/dev/null || echo "$src")
  else
    # 允许只给文件名
    if [ ! -f "$src" ] && [ -f "$BACKUP_DIR/$src" ]; then
      src="$BACKUP_DIR/$src"
    fi
  fi
  if [ ! -f "$src" ]; then
    echo -e "${R}✗ 备份文件不存在: $src${N}"; exit 1
  fi
  # 校验 yaml
  py -c "import yaml; yaml.safe_load(open('$src'))" || { echo -e "${R}✗ 备份本身 YAML 损坏!${N}"; exit 1; }
  # 先备份当前再恢复
  local pre_restore
  pre_restore=$(backup_config)
  echo -e "${Y}→ 当前 config 已先备份: $(basename "$pre_restore")${N}"
  cp "$src" "$CONFIG"
  echo -e "${G}✓ 已恢复自: $(basename "$src")${N}"
  echo
  show_current
}

# ─── 主入口 ──────────────────────────────────────────
cmd="${1:-show}"

case "$cmd" in
  show|"")
    show_current; echo; list_presets
    ;;
  list|ls)
    list_all_models
    ;;
  presets)
    list_presets
    ;;
  backups)
    list_backups
    ;;
  vault)
    vault_status
    ;;
  restore)
    apply_restore "${2:-}"
    ;;
  -h|--help|help)
    sed -n '2,21p' "$0" | sed 's/^# \?//'
    echo
    list_presets
    ;;
  *)
    found=""
    for p in "${PRESETS[@]}"; do
      IFS='|' read -r alias prov model <<< "$p"
      if [ "$alias" = "$cmd" ]; then
        found="yes"
        apply_switch "$prov" "$model"
        break
      fi
    done
    if [ -z "$found" ]; then
      echo -e "${R}✗ 未知预设: $cmd${N}\n"
      list_presets
      exit 1
    fi
    ;;
esac
