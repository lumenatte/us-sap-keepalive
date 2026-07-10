#!/bin/bash
set -u

LOG=/tmp/komari.log
echo "=== Container Started at $(date) ===" > "$LOG"

AGENT_BIN="/usr/local/bin/komari-agent"
SERVER_DOMAIN="nezha.eluke.dpdns.org"
KOMARI_PORT="25774"

XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/etc/xray/config.json"

# 节点相关参数，从环境变量读取，方便通过 cf set-env 修改而不用重新 build 镜像
UUID="${UUID:-171753f8-6cb0-4c50-8267-c076832c113b}"
DOMAIN="${DOMAIN:-SG-Azure.cfapps.ap21.hana.ondemand.com}"
WS_PATH="${WS_PATH:-/lumenatte}"
REMARK="${REMARK:-dev-SG-Azure}"
LISTEN_PORT="${PORT:-8080}"   # CF 会自动注入 PORT，容器内必须监听这个端口

# ==========================================
# 下载函数：带超时 + 重试，避免 SAP BTP 出口慢时一次失败就放弃
# ==========================================
download_agent() {
    local max_retries=10
    local attempt=1
    while [ $attempt -le $max_retries ]; do
        echo "[$(date)] Downloading komari-agent, attempt ${attempt}/${max_retries}..." >> "$LOG"
        curl -L --connect-timeout 30 --max-time 1800 \
             "https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-linux-amd64" \
             -o /tmp/komari-agent 2>> "$LOG"

        if [ -s /tmp/komari-agent ]; then
            mv /tmp/komari-agent "$AGENT_BIN"
            chmod +x "$AGENT_BIN"
            echo "[$(date)] Download succeeded." >> "$LOG"
            return 0
        fi

        echo "[$(date)] Attempt ${attempt} failed, retrying in 10s..." >> "$LOG"
        attempt=$((attempt + 1))
        sleep 10
    done
    return 1
}

if [ ! -x "$AGENT_BIN" ]; then
    download_agent || echo "[$(date)] ERROR: all download attempts failed." >> "$LOG"
fi

# ==========================================
# 生成 xray VLESS+WS 节点配置
# CF 边缘节点负责 443 端口的 TLS 卸载，容器内部只需要监听 PORT，跑纯 WS（不加密）
# ==========================================
generate_xray_config() {
    mkdir -p /etc/xray
    cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${LISTEN_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "level": 0 }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom" }
  ]
}
EOF
    echo "[$(date)] xray config generated at $XRAY_CONFIG" >> "$LOG"
}

# ==========================================
# 打印可直接导入客户端的 vless:// 链接
# ==========================================
print_vless_link() {
    LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=${WS_PATH}#${REMARK}"
    {
        echo "===================== VLESS 节点链接 ====================="
        echo "$LINK"
        echo "==========================================================="
    } >> "$LOG"
}

if [ -z "${KOMARI_TOKEN:-}" ]; then
    echo "Warning: KOMARI_TOKEN is not set." >> "$LOG"
fi

trap 'echo "[$(date)] Caught TERM, shutting down..." >> "'"$LOG"'"; kill -9 0' TERM

# ==========================================
# komari-agent 守护循环
# ==========================================
run_agent_forever() {
    while true; do
        if [ -z "${KOMARI_TOKEN:-}" ]; then
            sleep 30
            continue
        fi
        if [ ! -x "$AGENT_BIN" ]; then
            echo "[$(date)] Binary missing, re-downloading..." >> "$LOG"
            download_agent
        fi
        echo "[$(date)] Starting komari-agent..." >> "$LOG"
        "$AGENT_BIN" -e "http://${SERVER_DOMAIN}:${KOMARI_PORT}" -t "${KOMARI_TOKEN}" >> "$LOG" 2>&1
        EXIT_CODE=$?
        echo "[$(date)] komari-agent exited (code ${EXIT_CODE}), restarting in 5s..." >> "$LOG"
        sleep 5
    done
}

# ==========================================
# xray 守护循环
# ==========================================
run_xray_forever() {
    generate_xray_config
    print_vless_link
    while true; do
        echo "[$(date)] Starting xray..." >> "$LOG"
        "$XRAY_BIN" run -config "$XRAY_CONFIG" >> "$LOG" 2>&1
        EXIT_CODE=$?
        echo "[$(date)] xray exited (code ${EXIT_CODE}), restarting in 5s..." >> "$LOG"
        sleep 5
    done
}

run_agent_forever &
AGENT_LOOP_PID=$!
echo "Agent supervisor loop started, PID: ${AGENT_LOOP_PID}" >> "$LOG"

run_xray_forever &
XRAY_LOOP_PID=$!
echo "Xray supervisor loop started, PID: ${XRAY_LOOP_PID}" >> "$LOG"

wait -n
