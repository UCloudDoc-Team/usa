#!/usr/bin/env bash
# OpenClaw 安全加固扫描脚本 v3


set -u
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

OC_HOME="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
WORKSPACE_DEFAULT="/root/.openclaw/workspace"
REPORT_DIR="/tmp/openclaw/security-reports"
mkdir -p "$REPORT_DIR"

DATE_STR=$(date +%F)
TIME_STR=$(date '+%F %T %Z')
REPORT_FILE="$REPORT_DIR/report-$DATE_STR-v3.txt"
SUMMARY="🛡️ OpenClaw 安全扫描简报 ($DATE_STR)\n\n"
SUGGESTIONS=()
WARNINGS=()
FAILS=0
WARNS=0
PASSES=0

append_pass() {
  PASSES=$((PASSES+1))
  SUMMARY+="$1\n"
}

append_warn() {
  WARNS=$((WARNS+1))
  WARNINGS+=("$1")
  SUMMARY+="$1\n"
}

append_fail() {
  FAILS=$((FAILS+1))
  WARNINGS+=("$1")
  SUMMARY+="$1\n"
}

add_suggestion() {
  SUGGESTIONS+=("$1")
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

print_section() {
  echo >> "$REPORT_FILE"
  echo "===== $1 =====" >> "$REPORT_FILE"
}

safe_stat_mode() {
  local p="$1"
  stat -c '%a' "$p" 2>/dev/null || echo "MISSING"
}

safe_cat_first_match() {
  local file="$1" pattern="$2"
  if [ -f "$file" ]; then
    grep -E "^[[:space:]]*$pattern" "$file" 2>/dev/null | tail -n 1
  fi
}

get_open_ports() {
  if have_cmd ss; then
    ss -lntp 2>/dev/null || true
  elif have_cmd netstat; then
    netstat -lntp 2>/dev/null || true
  fi
}

json_port_extract() {
  local f="$1"
  [ -f "$f" ] || return 0
  python3 - <<'PY' "$f" 2>/dev/null
import json,sys
p=sys.argv[1]
try:
    data=json.load(open(p,'r',encoding='utf-8'))
    gw=data.get('gateway',{})
    port=gw.get('port')
    if port is not None:
        print(port)
except Exception:
    pass
PY
}

systemd_env_extract() {
  local f="$1" key="$2"
  [ -f "$f" ] || return 0
  grep -E "^[[:space:]]*Environment=${key}=" "$f" 2>/dev/null | tail -n 1 | sed -E "s/^[^=]+=//"
}

systemd_exec_port_extract() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -E 'ExecStart=.*gateway --port ' "$f" 2>/dev/null | tail -n 1 | sed -E 's/.*gateway --port ([0-9]+).*/\1/'
}

SSHD_CONFIG="/etc/ssh/sshd_config"
SYSTEMD_USER_UNIT="$HOME/.config/systemd/user/openclaw-gateway.service"
SYSTEMD_SYSTEM_UNIT="/etc/systemd/system/openclaw-gateway.service"
OPENCLAW_JSON_ROOT="$OC_HOME/openclaw.json"
OPENCLAW_JSON_OPENCLAW="/home/openclaw/.openclaw/openclaw.json"

{
  echo "=== OpenClaw Security Audit Detailed Report v3 ==="
  echo "Generated at: $TIME_STR"
  echo "Host user: $(id -un 2>/dev/null || echo unknown)"
  echo "OC_HOME: $OC_HOME"
} > "$REPORT_FILE"

print_section "1. OpenClaw 原生安全审计"
if have_cmd openclaw; then
  if openclaw security audit --deep >> "$REPORT_FILE" 2>&1; then
    append_pass "1. 原生审计: ✅ 已执行 openclaw security audit --deep"
  else
    append_warn "1. 原生审计: ⚠️ 执行失败，请检查 openclaw CLI / token / 权限"
    add_suggestion "排查 openclaw security audit --deep 执行失败原因，确保后续巡检可用。"
  fi
else
  append_fail "1. 原生审计: ❌ 未发现 openclaw 命令"
  add_suggestion "确认 OpenClaw CLI 已安装且 PATH 可访问。"
fi

print_section "2. 监听端口与公网暴露检查"
PORT_SNAPSHOT=$(mktemp)
get_open_ports > "$PORT_SNAPSHOT"
cat "$PORT_SNAPSHOT" >> "$REPORT_FILE"
if grep -Eq '[:.]18789[[:space:]]' "$PORT_SNAPSHOT"; then
  append_warn "2. 端口暴露: ⚠️ 检测到默认端口 18789 正在监听"
  add_suggestion "若无强依赖，避免默认端口 18789 直接暴露公网；建议改为高位非默认端口，并在安全组/防火墙中仅放行可信来源 IP。"
else
  append_pass "2. 端口暴露: ✅ 未见默认端口 18789 监听，或未监听 TCP"
fi

print_section "3. OpenClaw 端口配置一致性"
ROOT_JSON_PORT=$(json_port_extract "$OPENCLAW_JSON_ROOT")
OPENCLAW_JSON_PORT=$(json_port_extract "$OPENCLAW_JSON_OPENCLAW")
USER_UNIT_ENV_PORT=$(systemd_env_extract "$SYSTEMD_USER_UNIT" 'OPENCLAW_GATEWAY_PORT')
USER_UNIT_EXEC_PORT=$(systemd_exec_port_extract "$SYSTEMD_USER_UNIT")
SYS_UNIT_ENV_PORT=$(systemd_env_extract "$SYSTEMD_SYSTEM_UNIT" 'OPENCLAW_GATEWAY_PORT')
SYS_UNIT_EXEC_PORT=$(systemd_exec_port_extract "$SYSTEMD_SYSTEM_UNIT")
{
  echo "root openclaw.json port: ${ROOT_JSON_PORT:-N/A}"
  echo "/home/openclaw openclaw.json port: ${OPENCLAW_JSON_PORT:-N/A}"
  echo "user unit env port: ${USER_UNIT_ENV_PORT:-N/A}"
  echo "user unit exec port: ${USER_UNIT_EXEC_PORT:-N/A}"
  echo "system unit env port: ${SYS_UNIT_ENV_PORT:-N/A}"
  echo "system unit exec port: ${SYS_UNIT_EXEC_PORT:-N/A}"
} >> "$REPORT_FILE"
PORT_SET=$(printf '%s
' "$ROOT_JSON_PORT" "$OPENCLAW_JSON_PORT" "$USER_UNIT_ENV_PORT" "$USER_UNIT_EXEC_PORT" "$SYS_UNIT_ENV_PORT" "$SYS_UNIT_EXEC_PORT" | sed '/^$/d;/^N\/A$/d' | sort -u)
PORT_COUNT=$(printf '%s
' "$PORT_SET" | sed '/^$/d' | wc -l | xargs)
if [ "$PORT_COUNT" -gt 1 ]; then
  append_warn "3. 端口配置: ⚠️ 发现多处端口配置不一致"
  add_suggestion "统一 openclaw.json 与 systemd service 中的网关端口配置，避免实际监听端口与配置描述不一致。"
elif [ "$PORT_COUNT" -eq 1 ]; then
  append_pass "3. 端口配置: ✅ 主要配置中的端口值基本一致"
else
  append_warn "3. 端口配置: ⚠️ 未能提取到明确端口配置"
fi

print_section "4. 账户降权 / 服务运行身份"
SERVICE_USER="unknown"
if [ -f "$SYSTEMD_SYSTEM_UNIT" ]; then
  SERVICE_USER=$(grep -E '^User=' "$SYSTEMD_SYSTEM_UNIT" 2>/dev/null | tail -n1 | cut -d= -f2)
  echo "system unit user: $SERVICE_USER" >> "$REPORT_FILE"
fi
if pgrep -af 'openclaw-gateway|openclaw.*gateway' >> "$REPORT_FILE" 2>&1; then :; fi
RUN_AS_ROOT=0
if pgrep -u root -f 'openclaw-gateway|openclaw.*gateway' >/dev/null 2>&1; then
  RUN_AS_ROOT=1
fi
if [ "$RUN_AS_ROOT" -eq 1 ] || [ "$SERVICE_USER" = "root" ]; then
  append_warn "4. 账户降权: ⚠️ OpenClaw 可能仍以 root 身份运行"
  add_suggestion "建议将 OpenClaw 切换为专用低权限用户（如 openclaw）运行，并将修复动作放到单独变更窗口执行。"
else
  append_pass "4. 账户降权: ✅ 未发现明显的 root 身份运行迹象"
fi

print_section "5. 服务化与 systemd 管理"
if systemctl list-unit-files 2>/dev/null | grep -q '^openclaw-gateway.service'; then
  systemctl status openclaw-gateway.service --no-pager >> "$REPORT_FILE" 2>&1 || true
  append_pass "5. 服务化: ✅ 检测到 openclaw-gateway.service"
else
  append_warn "5. 服务化: ⚠️ 未检测到标准 systemd 服务单元 openclaw-gateway.service"
  add_suggestion "建议统一纳入 systemd 管理，便于审计、重启控制、日志收敛和权限隔离。"
fi
if have_cmd loginctl && id openclaw >/dev/null 2>&1; then
  loginctl show-user openclaw >> "$REPORT_FILE" 2>&1 || true
fi

print_section "6. SSH 安全基线"
if [ -f "$SSHD_CONFIG" ]; then
  grep -E '^(PermitRootLogin|PasswordAuthentication|ChallengeResponseAuthentication|UsePAM|AllowAgentForwarding|AllowTcpForwarding|X11Forwarding|Protocol)[[:space:]]+' "$SSHD_CONFIG" >> "$REPORT_FILE" 2>/dev/null || true
  PRL=$(awk '/^[[:space:]]*PermitRootLogin[[:space:]]+/ {print $2}' "$SSHD_CONFIG" 2>/dev/null | tail -n1)
  PA=$(awk '/^[[:space:]]*PasswordAuthentication[[:space:]]+/ {print $2}' "$SSHD_CONFIG" 2>/dev/null | tail -n1)
  CRA=$(awk '/^[[:space:]]*ChallengeResponseAuthentication[[:space:]]+/ {print $2}' "$SSHD_CONFIG" 2>/dev/null | tail -n1)
  APF=$(awk '/^[[:space:]]*AllowAgentForwarding[[:space:]]+/ {print $2}' "$SSHD_CONFIG" 2>/dev/null | tail -n1)
  ATF=$(awk '/^[[:space:]]*AllowTcpForwarding[[:space:]]+/ {print $2}' "$SSHD_CONFIG" 2>/dev/null | tail -n1)
  X11=$(awk '/^[[:space:]]*X11Forwarding[[:space:]]+/ {print $2}' "$SSHD_CONFIG" 2>/dev/null | tail -n1)
  [ "${PRL:-unset}" = "no" ] || add_suggestion "建议 SSH 配置 PermitRootLogin no。"
  [ "${CRA:-unset}" = "no" ] || add_suggestion "建议 SSH 配置 ChallengeResponseAuthentication no。"
  [ "${APF:-unset}" = "no" ] || add_suggestion "建议 SSH 配置 AllowAgentForwarding no。"
  [ "${ATF:-unset}" = "no" ] || add_suggestion "建议 SSH 配置 AllowTcpForwarding no。"
  [ "${X11:-unset}" = "no" ] || add_suggestion "建议 SSH 配置 X11Forwarding no。"
  if [ "${PRL:-unset}" = "no" ] && [ "${CRA:-unset}" = "no" ] && [ "${APF:-unset}" = "no" ] && [ "${ATF:-unset}" = "no" ] && [ "${X11:-unset}" = "no" ]; then
    append_pass "6. SSH 基线: ✅ 核心高风险项基本收敛"
  else
    append_warn "6. SSH 基线: ⚠️ 存在未收敛项，见建议列表"
  fi
  if [ "${PA:-unset}" != "no" ]; then
    add_suggestion "若已验证密钥登录可用，可考虑禁用 PasswordAuthentication 并改用密钥登录。"
  fi
else
  append_warn "6. SSH 基线: ⚠️ 未找到 /etc/ssh/sshd_config"
fi

print_section "7. SSH 登录与爆破痕迹"
FAILED_SSH=0
if have_cmd journalctl; then
  FAILED_SSH=$(journalctl -u sshd --since '24 hours ago' 2>/dev/null | grep -Ei 'Failed|Invalid' | wc -l | xargs)
fi
if [ "$FAILED_SSH" = "0" ]; then
  for LOGF in /var/log/auth.log /var/log/secure /var/log/messages; do
    if [ -f "$LOGF" ]; then
      FAILED_SSH=$(grep -Ei 'sshd.*(Failed|Invalid)' "$LOGF" 2>/dev/null | tail -n 2000 | wc -l | xargs)
      break
    fi
  done
fi
last -a -n 10 >> "$REPORT_FILE" 2>/dev/null || true
echo "Failed SSH attempts (24h heuristic): $FAILED_SSH" >> "$REPORT_FILE"
if [ "$FAILED_SSH" -gt 20 ]; then
  append_warn "7. SSH 爆破: ⚠️ 近24小时失败登录次数偏高 ($FAILED_SSH)"
  add_suggestion "建议结合安全组/IP 白名单、fail2ban 或 PAM faillock 策略限制 SSH 暴力尝试。"
else
  append_pass "7. SSH 爆破: ✅ 失败登录次数未见明显异常 ($FAILED_SSH)"
fi

print_section "8. PAM / faillock 密码锁定策略"
FAILLOCK_CONF="/etc/security/faillock.conf"
if [ -f "$FAILLOCK_CONF" ]; then
  grep -Ev '^[[:space:]]*#|^[[:space:]]*$' "$FAILLOCK_CONF" >> "$REPORT_FILE" 2>/dev/null || true
  DENY=$(awk -F= '/^[[:space:]]*deny[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2}' "$FAILLOCK_CONF" | tail -n1)
  UNLOCK=$(awk -F= '/^[[:space:]]*unlock_time[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2}' "$FAILLOCK_CONF" | tail -n1)
  FINT=$(awk -F= '/^[[:space:]]*fail_interval[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2}' "$FAILLOCK_CONF" | tail -n1)
  EVEN_ROOT=$(grep -Eq '^[[:space:]]*even_deny_root([[:space:]]|$)' "$FAILLOCK_CONF" && echo yes || echo no)
  if [ "${DENY:-}" = "5" ] && [ "${UNLOCK:-}" = "600" ] && [ "${FINT:-}" = "900" ]; then
    append_pass "8. faillock: ✅ 关键参数接近推荐值"
  else
    append_warn "8. faillock: ⚠️ 锁定策略未完全对齐推荐值"
    add_suggestion "建议在 /etc/security/faillock.conf 中评估 deny=5、unlock_time=600、fail_interval=900，并按风险偏好决定是否启用 even_deny_root。"
  fi
else
  append_warn "8. faillock: ⚠️ 未找到 /etc/security/faillock.conf"
  add_suggestion "建议通过 authselect 启用 with-faillock，并配置 /etc/security/faillock.conf。"
fi
if [ -f /etc/pam.d/system-auth ]; then
  grep faillock /etc/pam.d/system-auth >> "$REPORT_FILE" 2>/dev/null || true
fi
if [ -f /etc/pam.d/password-auth ]; then
  grep faillock /etc/pam.d/password-auth >> "$REPORT_FILE" 2>/dev/null || true
fi

print_section "9. 密码复杂度与老化策略"
PWQ="/etc/security/pwquality.conf"
LOGIN_DEFS="/etc/login.defs"
if [ -f "$PWQ" ]; then
  grep -E '^[[:space:]]*(minlen|dcredit|ucredit|lcredit|ocredit|usercheck|retry)[[:space:]]*=' "$PWQ" >> "$REPORT_FILE" 2>/dev/null || true
  MINLEN=$(awk -F= '/^[[:space:]]*minlen[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);print $2}' "$PWQ" | tail -n1)
  if [ -n "${MINLEN:-}" ] && [ "$MINLEN" -ge 12 ] 2>/dev/null; then
    append_pass "9. 密码复杂度: ✅ minlen 已达到 12+"
  else
    append_warn "9. 密码复杂度: ⚠️ 密码复杂度配置可能偏弱"
    add_suggestion "建议在 /etc/security/pwquality.conf 中评估 minlen=12、dcredit/ucredit/lcredit/ocredit=-1、usercheck=1、retry=3。"
  fi
else
  append_warn "9. 密码复杂度: ⚠️ 未找到 /etc/security/pwquality.conf"
fi
if [ -f "$LOGIN_DEFS" ]; then
  grep -E '^[[:space:]]*(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE)[[:space:]]+' "$LOGIN_DEFS" >> "$REPORT_FILE" 2>/dev/null || true
  PMAX=$(awk '/^[[:space:]]*PASS_MAX_DAYS[[:space:]]+/{print $2}' "$LOGIN_DEFS" | tail -n1)
  PMIN=$(awk '/^[[:space:]]*PASS_MIN_DAYS[[:space:]]+/{print $2}' "$LOGIN_DEFS" | tail -n1)
  PWARN=$(awk '/^[[:space:]]*PASS_WARN_AGE[[:space:]]+/{print $2}' "$LOGIN_DEFS" | tail -n1)
  if [ "${PMAX:-}" = "90" ] && [ "${PMIN:-}" = "7" ] && [ "${PWARN:-}" = "14" ]; then
    append_pass "9. 密码老化: ✅ 参数与推荐值一致"
  else
    append_warn "9. 密码老化: ⚠️ 参数未完全对齐推荐值"
    add_suggestion "建议在 /etc/login.defs 中评估 PASS_MAX_DAYS 90、PASS_MIN_DAYS 7、PASS_WARN_AGE 14。"
  fi
fi

print_section "10. 防火墙 / 安全组本机视角检查"
if have_cmd firewall-cmd; then
  firewall-cmd --state >> "$REPORT_FILE" 2>&1 || true
  firewall-cmd --list-all >> "$REPORT_FILE" 2>&1 || true
fi
if have_cmd ufw; then
  ufw status verbose >> "$REPORT_FILE" 2>&1 || true
fi
if have_cmd iptables; then
  iptables -S >> "$REPORT_FILE" 2>&1 || true
fi
append_pass "10. 防火墙检查: ✅ 已采集本机防火墙视角配置（云安全组需人工在云控制台复核）"
add_suggestion "请在云平台安全组/防火墙中确认：18789 或实际服务端口仅对白名单 IP 放行；脚本无法直接判断云侧访问源限制。"

print_section "11. OpenClaw 配置权限与基线完整性"
PERM_OC_ROOT=$(safe_stat_mode "$OPENCLAW_JSON_ROOT")
PERM_OC_OPENCLAW=$(safe_stat_mode "$OPENCLAW_JSON_OPENCLAW")
PERM_PAIRED_ROOT=$(safe_stat_mode "$OC_HOME/devices/paired.json")
PERM_SSHD=$(safe_stat_mode "$SSHD_CONFIG")
PERM_AUTH_KEYS=$(safe_stat_mode "$HOME/.ssh/authorized_keys")
{
  echo "perm root openclaw.json: $PERM_OC_ROOT"
  echo "perm /home/openclaw openclaw.json: $PERM_OC_OPENCLAW"
  echo "perm paired.json: $PERM_PAIRED_ROOT"
  echo "perm sshd_config: $PERM_SSHD"
  echo "perm authorized_keys: $PERM_AUTH_KEYS"
} >> "$REPORT_FILE"
BASELINE_FILE="$OC_HOME/.config-baseline.sha256"
if [ -f "$BASELINE_FILE" ]; then
  (cd "$OC_HOME" && sha256sum -c .config-baseline.sha256) >> "$REPORT_FILE" 2>&1 || true
fi
if [ "$PERM_OC_ROOT" = "600" ] || [ "$PERM_OC_OPENCLAW" = "600" ]; then
  append_pass "11. 配置权限: ✅ 至少一个 openclaw.json 权限为 600"
else
  append_warn "11. 配置权限: ⚠️ openclaw.json 权限未见 600"
  add_suggestion "建议将包含敏感配置的 openclaw.json 权限收敛为 600。"
fi

print_section "12. 已安装 Skill 清查"
if have_cmd openclaw; then
  openclaw skills list >> "$REPORT_FILE" 2>&1 || true
fi
ALLOW_BUNDLED_FOUND=0
for f in "$OPENCLAW_JSON_ROOT" "$OPENCLAW_JSON_OPENCLAW"; do
  if [ -f "$f" ] && grep -q '"allowBundled"' "$f" 2>/dev/null; then
    ALLOW_BUNDLED_FOUND=1
    echo "allowBundled found in $f" >> "$REPORT_FILE"
    grep -n 'allowBundled' "$f" >> "$REPORT_FILE" 2>/dev/null || true
  fi
done
if [ "$ALLOW_BUNDLED_FOUND" -eq 1 ]; then
  append_pass "12. Skill 白名单: ✅ 发现 allowBundled 配置痕迹"
else
  append_warn "12. Skill 白名单: ⚠️ 未发现 allowBundled 白名单配置"
  add_suggestion "建议在 openclaw.json 中为 skills.allowBundled 配置明确白名单，限制内置 Skill 的启用范围。"
fi
add_suggestion "新增 Skill 前建议执行五步审计：列文件、隔离下载、全文本正则扫描、红线模式检查、人工审批。"

print_section "13. Skill / MCP 完整性基线"
SKILL_DIR="$WORKSPACE_DEFAULT/skills"
MCP_DIR="$WORKSPACE_DEFAULT/mcp"
HASH_DIR="$OC_HOME/security-baselines"
mkdir -p "$HASH_DIR"
CUR_HASH="$HASH_DIR/skill-mcp-current.sha256"
BASE_HASH="$HASH_DIR/skill-mcp-baseline.sha256"
: > "$CUR_HASH"
for D in "$SKILL_DIR" "$MCP_DIR"; do
  if [ -d "$D" ]; then
    find "$D" -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null >> "$CUR_HASH" || true
  fi
done
if [ -s "$CUR_HASH" ]; then
  if [ -f "$BASE_HASH" ]; then
    if diff -u "$BASE_HASH" "$CUR_HASH" >> "$REPORT_FILE" 2>&1; then
      append_pass "13. Skill/MCP 基线: ✅ 与既有基线一致"
    else
      append_warn "13. Skill/MCP 基线: ⚠️ 检测到文件哈希变化"
      add_suggestion "如近期未授权调整 Skill/MCP，请人工复核变更来源、作者、权限需求和潜在外联行为。"
    fi
  else
    cp "$CUR_HASH" "$BASE_HASH"
    append_pass "13. Skill/MCP 基线: ✅ 已首次建立本地基线"
  fi
else
  append_pass "13. Skill/MCP 基线: ✅ 未发现 skills/mcp 文件或为空"
fi

print_section "14. 敏感信息与环境变量泄露扫描"
GW_PID=$(pgrep -f 'openclaw-gateway|openclaw.*gateway' | head -n 1 || true)
if [ -n "$GW_PID" ] && [ -r "/proc/$GW_PID/environ" ]; then
  strings "/proc/$GW_PID/environ" | grep -iE 'SECRET|TOKEN|PASSWORD|KEY' | awk -F= '{print $1"=(Hidden)"}' >> "$REPORT_FILE" 2>/dev/null || true
fi
SCAN_ROOT="$WORKSPACE_DEFAULT"
DLP_HITS=0
if [ -d "$SCAN_ROOT" ]; then
  H1=$(grep -RInE --exclude-dir=.git --exclude='*.png' --exclude='*.jpg' --exclude='*.jpeg' --exclude='*.gif' --exclude='*.webp' '\b0x[a-fA-F0-9]{64}\b' "$SCAN_ROOT" 2>/dev/null | wc -l | xargs)
  H2=$(grep -RInE --exclude-dir=.git --exclude='*.png' --exclude='*.jpg' --exclude='*.jpeg' --exclude='*.gif' --exclude='*.webp' '\b([a-z]{3,12}\s+){11}([a-z]{3,12})\b|\b([a-z]{3,12}\s+){23}([a-z]{3,12})\b' "$SCAN_ROOT" 2>/dev/null | wc -l | xargs)
  DLP_HITS=$((H1 + H2))
fi
echo "DLP hits (heuristic): $DLP_HITS" >> "$REPORT_FILE"
if [ "$DLP_HITS" -gt 0 ]; then
  append_warn "14. 敏感信息扫描: ⚠️ 检测到疑似敏感信息模式 ($DLP_HITS)"
  add_suggestion "请人工复核 workspace 中的疑似私钥/助记词/令牌痕迹，避免明文存放。"
else
  append_pass "14. 敏感信息扫描: ✅ 未发现明显私钥/助记词模式"
fi

print_section "15. 运行日志与异常登录分析"
if systemctl status openclaw-gateway.service --no-pager >> "$REPORT_FILE" 2>&1; then :; fi
if have_cmd journalctl; then
  journalctl -u openclaw-gateway.service -n 200 --no-pager >> "$REPORT_FILE" 2>&1 || true
fi
for LOGF in /tmp/openclaw/openclaw-*.log; do
  [ -f "$LOGF" ] && tail -n 100 "$LOGF" >> "$REPORT_FILE" 2>/dev/null || true
  break
done
append_pass "15. 日志分析: ✅ 已采集 OpenClaw 服务日志与部分系统登录线索"
add_suggestion "建议持续关注 runtime.log / journalctl / /var/log/secure 中的异常访问、报错和异常来源 IP。"

print_section "16. 日志留存策略"
CRON_LOG_ROTATE=0
grep -R "find /tmp/openclaw -name '.*\\.log'.*-mtime +7 -delete\|find /tmp/openclaw -name '\*\.log' -mtime \+7 -delete" /etc/crontab /etc/cron* 2>/dev/null >> "$REPORT_FILE" && CRON_LOG_ROTATE=1 || true
if [ "$CRON_LOG_ROTATE" -eq 1 ]; then
  append_pass "16. 日志留存: ✅ 发现日志7天清理相关配置痕迹"
else
  append_warn "16. 日志留存: ⚠️ 未发现明确的 7 天日志清理策略"
  add_suggestion "建议评估日志留存周期与轮转策略，避免日志无限增长占满磁盘。"
fi

print_section "17. 资源与大文件异常"
if have_cmd df; then df -h / >> "$REPORT_FILE" 2>&1 || true; fi
LARGE_FILES=$(find / -xdev -type f -size +100M -mtime -1 2>/dev/null | wc -l | xargs)
echo "Large files >100M modified in 24h: $LARGE_FILES" >> "$REPORT_FILE"
append_pass "17. 资源检查: ✅ 已完成磁盘与大文件快照采集"

print_section "18. 版本与漏洞运营建议"
if have_cmd openclaw; then
  openclaw --help > /dev/null 2>&1 || true
fi
append_pass "18. 漏洞运营: ✅ 已提示版本与漏洞运营关注项"
add_suggestion "请定期核对 OpenClaw 版本并关注 CNNVD / 官方公告，避免已知 RCE / 提权 / 路径遍历风险长期暴露。"

print_section "19. 云侧 / 韧性 / 恢复建议（仅建议）"
append_pass "19. 恢复韧性: ✅ 已生成云侧与灾备建议"
add_suggestion "建议建立 config/记忆/运行结果/日志的定期备份与异地加密备份策略；脚本无法代替云平台镜像、快照、对象存储备份。"
add_suggestion "如有条件，建议启用主机入侵检测/告警能力，并制定分钟级恢复预案。"

print_section "20. 文档要求但脚本不自动修改的项目汇总"
{
  echo "以下项目本脚本只做扫描与建议，不自动修改："
  echo "- systemd 服务迁移/账户降权"
  echo "- SSH 与 PAM 配置改写"
  echo "- 密码策略与老化参数"
  echo "- 防火墙/安全组策略调整"
  echo "- allowBundled 白名单收敛"
  echo "- 日志清理 cron / 备份策略"
} >> "$REPORT_FILE"
append_pass "20. 修改边界: ✅ 已遵守“只扫描不改动”要求"

{
  echo
  echo "===== 整改建议清单 ====="
  if [ ${#SUGGESTIONS[@]} -eq 0 ]; then
    echo "当前未生成新增建议。"
  else
    i=1
    for s in "${SUGGESTIONS[@]}"; do
      echo "$i. $s"
      i=$((i+1))
    done
  fi
  echo
  echo "===== 统计 ====="
  echo "PASS=$PASSES"
  echo "WARN=$WARNS"
  echo "FAIL=$FAILS"
} >> "$REPORT_FILE"

SUMMARY+="\n📊 统计: PASS=$PASSES / WARN=$WARNS / FAIL=$FAILS\n"
SUMMARY+="📝 详细报告: $REPORT_FILE\n"

if [ ${#SUGGESTIONS[@]} -gt 0 ]; then
  SUMMARY+="\n建议摘录:\n"
  i=1
  for s in "${SUGGESTIONS[@]}"; do
    SUMMARY+="- $s\n"
    [ $i -ge 8 ] && break
    i=$((i+1))
  done
fi

echo -e "$SUMMARY"
exit 0
