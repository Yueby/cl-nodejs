#!/bin/bash
set -e

# ================== 配置区域 ==================
# 固定隧道填写token，不填默认为临时隧道
ARGO_TOKEN=""

# 单端口模式 UDP 协议选择: hy2 (默认) 或 tuic
SINGLE_PORT_UDP="hy2"

# Clash Meta 订阅名称（显示在客户端中）
SUBSCRIPTION_NAME="MySub"

# ================== CF 优选域名列表 ==================
CF_DOMAINS=(
    "isp.qzz.io"
    "cdn.2020111.xyz"
    "cloudflare.czkcdn.cn"
    "cloudflare.182682.xyz"
    "cdn.9889888.xyz"
    "cf.cdn.saas.fis.ink"
    "cfyx.tencentapp.cn"
    "www.cnae.top"
    "cf.090227.xyz"
    "cf.877774.xyz"
    "cf.130519.xyz"
    "cf.008500.xyz"
    "store.ubi.com"
    "saas.sin.fan"
)

# ================== 切换到脚本目录 ==================
cd "$(dirname "$0")"
export FILE_PATH="${PWD}/.npm"

rm -rf "$FILE_PATH"
mkdir -p "$FILE_PATH"

# ================== 获取公网 IP ==================
echo "[网络] 获取公网 IP..."
PUBLIC_IP=$(curl -s --max-time 5 ipv4.ip.sb || curl -s --max-time 5 api.ipify.org || echo "")
[ -z "$PUBLIC_IP" ] && echo "[错误] 无法获取公网 IP" && exit 1
echo "[网络] 公网 IP: $PUBLIC_IP"

# ================== CF 优选：5次平均测速 ==================
select_best_cf_domain() {
    local res_file="${FILE_PATH}/cf_latency.res"
    : > "$res_file"
    
    # 并发测试所有域名
    for domain in "${CF_DOMAINS[@]}"; do
        (
            total_time=0
            success_count=0
            
            # 连续测速 5 次
            for i in {1..5}; do
                # connect-timeout 1.2s
                t=$(curl -s -w "%{time_connect}" -o /dev/null --connect-timeout 1.2 "https://$domain" 2>/dev/null)
                
                if [[ "$t" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "$t" != "0.000000" ]; then
                    total_time=$(awk "BEGIN {print $total_time + $t}")
                    success_count=$((success_count + 1))
                fi
                
                # 间隔 0.5 秒
                sleep 0.5
            done
            
            # 至少成功1次才计算
            if [ "$success_count" -gt 0 ]; then
                avg_time=$(awk "BEGIN {print $total_time / $success_count}")
                echo "$avg_time $domain" >> "$res_file"
            fi
        ) &
    done
    wait
    
    # 输出 Top 3 到 stderr，格式转换为 ms
    if [ -s "$res_file" ]; then
        echo -e "\n🏆 优选测速 Top 3 (平均延迟):" >&2
        # 使用 awk 将秒转换为毫秒并格式化输出
        sort -n "$res_file" | head -n 3 | awk '{printf "   [%s----%.2fms]\n", $2, $1*1000}' >&2
        echo "" >&2
    fi
    
    # 排序取第一名返回给变量
    local best=$(sort -n "$res_file" 2>/dev/null | head -n 1 | awk '{print $2}')
    rm -f "$res_file"
    
    if [ -n "$best" ]; then echo "$best"; else echo "${CF_DOMAINS[0]}"; fi
}

echo "[CF优选] 正在进行高精度测速 (Sample: 5x, Interval: 0.5s)..."
BEST_CF_DOMAIN=$(select_best_cf_domain)
echo "[CF优选] 最终选择: $BEST_CF_DOMAIN"

# ================== 获取端口 ==================
[ -n "$SERVER_PORT" ] && PORTS_STRING="$SERVER_PORT" || PORTS_STRING=""
read -ra AVAILABLE_PORTS <<< "$PORTS_STRING"
PORT_COUNT=${#AVAILABLE_PORTS[@]}
[ $PORT_COUNT -eq 0 ] && echo "[错误] 未找到端口" && exit 1
echo "[端口] 发现 $PORT_COUNT 个: ${AVAILABLE_PORTS[*]}"

# ================== 端口分配逻辑 ==================
if [ $PORT_COUNT -eq 1 ]; then
    UDP_PORT=${AVAILABLE_PORTS[0]}
    TUIC_PORT=""
    HY2_PORT=""
    [[ "$SINGLE_PORT_UDP" == "tuic" ]] && TUIC_PORT=$UDP_PORT || HY2_PORT=$UDP_PORT
    REALITY_PORT=""
    HTTP_PORT=${AVAILABLE_PORTS[0]}
    SINGLE_PORT_MODE=true
else
    TUIC_PORT=${AVAILABLE_PORTS[0]}
    HY2_PORT=${AVAILABLE_PORTS[1]}
    REALITY_PORT=${AVAILABLE_PORTS[0]}
    HTTP_PORT=${AVAILABLE_PORTS[1]}
    SINGLE_PORT_MODE=false
fi

ARGO_PORT=8081

# ================== UUID ==================
UUID_FILE="${FILE_PATH}/uuid.txt"
[ -f "$UUID_FILE" ] && UUID=$(cat "$UUID_FILE") || { UUID=$(cat /proc/sys/kernel/random/uuid); echo "$UUID" > "$UUID_FILE"; }
echo "[UUID] $UUID"

# ================== 架构检测 & 下载 ==================
ARCH=$(uname -m)
[[ "$ARCH" == "aarch64" ]] && BASE_URL="https://arm64.ssss.nyc.mn" || BASE_URL="https://amd64.ssss.nyc.mn"
[[ "$ARCH" == "aarch64" ]] && ARGO_ARCH="arm64" || ARGO_ARCH="amd64"

SB_FILE="${FILE_PATH}/sb"
ARGO_FILE="${FILE_PATH}/cloudflared"

download_file() {
    local url=$1 output=$2
    [ -x "$output" ] && return 0
    echo "[下载] $output..."
    curl -L -sS --max-time 60 -o "$output" "$url" && chmod +x "$output" && echo "[下载] $output 完成" && return 0
    echo "[下载] $output 失败" && return 1
}

download_file "${BASE_URL}/sb" "$SB_FILE"
download_file "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARGO_ARCH}" "$ARGO_FILE"

# ================== Reality 密钥 ==================
if [ "$SINGLE_PORT_MODE" = false ]; then
    echo "[密钥] 检查中..."
    KEY_FILE="${FILE_PATH}/key.txt"
    if [ -f "$KEY_FILE" ]; then
        private_key=$(grep "PrivateKey:" "$KEY_FILE" | awk '{print $2}')
        public_key=$(grep "PublicKey:" "$KEY_FILE" | awk '{print $2}')
    else
        output=$("$SB_FILE" generate reality-keypair)
        echo "$output" > "$KEY_FILE"
        private_key=$(echo "$output" | awk '/PrivateKey:/ {print $2}')
        public_key=$(echo "$output" | awk '/PublicKey:/ {print $2}')
    fi
    echo "[密钥] 已就绪"
fi

# ================== 证书生成 ==================
echo "[证书] 生成中..."
# 优先使用 OpenSSL 生成标准证书
if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "${FILE_PATH}/private.key" -out "${FILE_PATH}/cert.pem" -days 3650 -subj "/CN=www.bing.com" >/dev/null 2>&1
else
    # 备用
    printf -- "-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEIM4792SEtPqIt1ywqTd/0bYidBqpYV/+siNnfBYsdUYsoAoGCCqGSM49\nAwEHoUQDQgAE1kHafPj07rJG+HboH2ekAI4r+e6TL38GWASAnngZreoQDF16ARa/\nTsyLyFoPkhTxSbehH/OBEjHtSZGaDhMqQ==\n-----END EC PRIVATE KEY-----\n" > "${FILE_PATH}/private.key"

    printf -- "-----BEGIN CERTIFICATE-----\nMIIBejCCASGgAwIBAgIUFWeQL3556PNJLp/veCFxGNj9crkwCgYIKoZIzj0EAwIw\nEzERMA8GA1UEAwwIYmluZy5jb20wHhcNMjUwMTAxMDEwMTAwWhcNMzUwMTAxMDEw\nMTAwWjATMREwDwYDVQQDDAhiaW5nLmNvbTBZMBMGByqGSM49AgEGCCqGSM49AwEH\nA0IABNZB2nz49O6yRvh26B9npACOK/nuky9/BlgEgJ54Ga3qEAxdegEWv07Mi8ha\nD5IU8Um3oR/zgRIx7UmRmg4TKkOjUzBRMB0GA1UdDgQWBBTV1cFID7UISE7PLTBR\nBfGbgrkMNzAfBgNVHSMEGDAWgBTV1cFID7UISE7PLTBRBfGbgrkMNzAPBgNVHRMB\nAf8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCIARDAJvg0vd/ytrQVvEcSm6XTlB+\neQ6OFb9LbLYL9Zi+AiB+foMbi4y/0YUQlTtz7as9S8/lciBF5VCUoVIKS+vX2g==\n-----END CERTIFICATE-----\n" > "${FILE_PATH}/cert.pem"
fi
echo "[证书] 已就绪"

# ===== ISP =====
ISP="Node"
if [ "$CURL_AVAILABLE" = true ]; then
    JSON_DATA=$(curl -s --max-time 2 -H "Referer: https://speed.cloudflare.com/" https://speed.cloudflare.com/meta 2>/dev/null)
    if [ -n "$JSON_DATA" ]; then
        ORG=$(echo "$JSON_DATA" | sed -n 's/.*"asOrganization":"\([^"]*\)".*/\1/p')
        CITY=$(echo "$JSON_DATA" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
        if [ -n "$ORG" ] && [ -n "$CITY" ]; then
            ISP="${ORG}-${CITY}"
        fi
    fi
fi
[ -z "$ISP" ] && ISP="Node"

# ================== 生成订阅 ==================
generate_sub() {
    local argo_domain="$1"
    > "${FILE_PATH}/list.txt"
    
    # TUIC (UDP)
    [ -n "$TUIC_PORT" ] && echo "tuic://${UUID}:admin@${PUBLIC_IP}:${TUIC_PORT}?sni=www.bing.com&alpn=h3&congestion_control=bbr&allowInsecure=1#TUIC-${ISP}" >> "${FILE_PATH}/list.txt"
    
    # HY2 (UDP)
    [ -n "$HY2_PORT" ] && echo "hysteria2://${UUID}@${PUBLIC_IP}:${HY2_PORT}/?sni=www.bing.com&insecure=1#Hysteria2-${ISP}" >> "${FILE_PATH}/list.txt"
    
    # Reality (TCP)
    [ -n "$REALITY_PORT" ] && echo "vless://${UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.nazhumi.com&fp=chrome&pbk=${public_key}&type=tcp#Reality-${ISP}" >> "${FILE_PATH}/list.txt"
    
    # Argo VLESS
    [ -n "$argo_domain" ] && echo "vless://${UUID}@${BEST_CF_DOMAIN}:443?encryption=none&security=tls&sni=${argo_domain}&type=ws&host=${argo_domain}&path=%2F${UUID}-vless#Argo-${ISP}" >> "${FILE_PATH}/list.txt"

    cat "${FILE_PATH}/list.txt" > "${FILE_PATH}/sub.txt"
}

# ================== HTTP 服务器脚本 ==================
cat > "${FILE_PATH}/server.js" <<JSEOF
const http = require('http');
const fs = require('fs');
const port = process.argv[2] || 8080;
const bind = process.argv[3] || '0.0.0.0';

// 动态生成 Clash Meta YAML 配置
function generateClashYaml() {
    const tuicPort = '${TUIC_PORT}';
    const hy2Port = '${HY2_PORT}';
    const realityPort = '${REALITY_PORT}';
    const publicIp = '${PUBLIC_IP}';
    const uuid = '${UUID}';
    const isp = '${ISP}';
    const bestCf = '${BEST_CF_DOMAIN}';
    const publicKey = '${public_key}';
    const subName = '${SUBSCRIPTION_NAME}';
    
    // 获取 Argo 域名
    let argoDomain = '';
    try {
        const log = fs.readFileSync('${FILE_PATH}/argo.log', 'utf8');
        const match = log.match(/https:\\/\\/[a-zA-Z0-9-]+\\.trycloudflare\\.com/);
        if (match) argoDomain = match[0].replace('https://', '');
    } catch(e) {}
    
    let yaml = \`mixed-port: 7890
allow-lan: true
bind-address: '*'
mode: rule
log-level: info
ipv6: false
unified-delay: true
tcp-concurrent: true
global-client-fingerprint: chrome

proxies:
\`;
    
    // TUIC 节点
    if (tuicPort) {
        yaml += \`  - name: "TUIC-\${isp}-\${subName}"
    type: tuic
    server: \${publicIp}
    port: \${tuicPort}
    uuid: \${uuid}
    password: admin
    alpn:
      - h3
    disable-sni: false
    sni: www.bing.com
    skip-cert-verify: true
    congestion-control: bbr
    udp-relay-mode: native

\`;
    }
    
    // Hysteria2 节点
    if (hy2Port) {
        yaml += \`  - name: "Hysteria2-\${isp}-\${subName}"
    type: hysteria2
    server: \${publicIp}
    port: \${hy2Port}
    password: \${uuid}
    sni: www.bing.com
    skip-cert-verify: true
    alpn:
      - h3

\`;
    }
    
    // Reality 节点
    if (realityPort && publicKey) {
        yaml += \`  - name: "Reality-\${isp}-\${subName}"
    type: vless
    server: \${publicIp}
    port: \${realityPort}
    uuid: \${uuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: www.nazhumi.com
    skip-cert-verify: false
    reality-opts:
      public-key: \${publicKey}
      short-id: ""
    client-fingerprint: chrome

\`;
    }
    
    // Argo VLESS 节点
    if (argoDomain) {
        yaml += \`  - name: "Argo-\${isp}-\${subName}"
    type: vless
    server: \${bestCf}
    port: 443
    uuid: \${uuid}
    network: ws
    tls: true
    udp: true
    skip-cert-verify: true
    servername: \${argoDomain}
    ws-opts:
      path: /\${uuid}-vless
      headers:
        Host: \${argoDomain}

\`;
    }
    
    // 代理组
    yaml += \`proxy-groups:
  - name: "手动选择"
    type: select
    proxies:
      - 自动选择
\`;
    
    if (tuicPort) yaml += \`      - TUIC-\${isp}-\${subName}\\n\`;
    if (hy2Port) yaml += \`      - Hysteria2-\${isp}-\${subName}\\n\`;
    if (realityPort) yaml += \`      - Reality-\${isp}-\${subName}\\n\`;
    if (argoDomain) yaml += \`      - Argo-\${isp}-\${subName}\\n\`;
    
    yaml += \`
  - name: "自动选择"
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    proxies:
\`;
    
    if (tuicPort) yaml += \`      - TUIC-\${isp}-\${subName}\\n\`;
    if (hy2Port) yaml += \`      - Hysteria2-\${isp}-\${subName}\\n\`;
    if (realityPort) yaml += \`      - Reality-\${isp}-\${subName}\\n\`;
    if (argoDomain) yaml += \`      - Argo-\${isp}-\${subName}\\n\`;
    
    yaml += \`
rules:
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,手动选择
\`;
    
    return yaml;
}

http.createServer((req, res) => {
    const url = req.url.toLowerCase();
    
    // Clash Meta 格式订阅（动态生成）
    if (url.includes('/clash') || url.includes('/meta')) {
        res.writeHead(200, {
            'Content-Type': 'text/yaml; charset=utf-8',
            'Content-Disposition': 'attachment; filename=' + encodeURIComponent('${SUBSCRIPTION_NAME}') + '.yaml',
            'Profile-Update-Interval': '24',
            'Profile-Title': encodeURIComponent('${SUBSCRIPTION_NAME}')
        });
        try { 
            res.end(generateClashYaml()); 
        } catch(e) { 
            res.end('error: ' + e.message); 
        }
    }
    // 原始文本格式订阅
    else if (url.includes('/sub') || url.includes('/${UUID}')) {
        res.writeHead(200, {
            'Content-Type': 'text/plain; charset=utf-8',
            'Content-Disposition': 'attachment; filename=sub.txt'
        });
        try { 
            res.end(fs.readFileSync('${FILE_PATH}/sub.txt', 'utf8')); 
        } catch(e) { 
            res.end('error: ' + e.message); 
        }
    }
    // 首页：显示订阅链接
    else if (url === '/' || url === '') {
        res.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'});
        const html = \`<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>订阅服务</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; }
        h1 { color: #333; }
        .link-box { background: #f5f5f5; padding: 15px; margin: 10px 0; border-radius: 5px; }
        .link-box h3 { margin-top: 0; color: #555; }
        code { background: #e8e8e8; padding: 5px 10px; border-radius: 3px; display: block; margin: 10px 0; word-break: break-all; }
        .copy-btn { background: #4CAF50; color: white; border: none; padding: 8px 15px; border-radius: 3px; cursor: pointer; }
        .copy-btn:hover { background: #45a049; }
    </style>
</head>
<body>
    <h1>🚀 代理订阅服务</h1>
    
    <div class="link-box">
        <h3>📱 Clash Meta 订阅</h3>
        <p>适用于: Clash Meta / Clash Verge / Clash.Meta</p>
        <code id="clash-link">http://${PUBLIC_IP}:${HTTP_PORT}/clash</code>
        <button class="copy-btn" onclick="copy('clash-link')">复制链接</button>
    </div>
    
    <div class="link-box">
        <h3>📄 通用订阅 (原始格式)</h3>
        <p>适用于: V2Ray / V2RayN / Shadowrocket 等</p>
        <code id="sub-link">http://${PUBLIC_IP}:${HTTP_PORT}/sub</code>
        <button class="copy-btn" onclick="copy('sub-link')">复制链接</button>
    </div>
    
    <div class="link-box">
        <h3>ℹ️ 节点信息</h3>
        <p>UUID: <code style="display:inline">${UUID}</code></p>
    </div>
    
    <script>
        function copy(id) {
            const text = document.getElementById(id).textContent;
            
            // 创建临时 textarea 元素
            const textarea = document.createElement('textarea');
            textarea.value = text;
            textarea.style.position = 'fixed';
            textarea.style.opacity = '0';
            document.body.appendChild(textarea);
            
            // 选中文本
            textarea.select();
            textarea.setSelectionRange(0, 99999); // 移动端兼容
            
            // 执行复制
            try {
                const successful = document.execCommand('copy');
                if (successful) {
                    alert('✅ 已复制到剪贴板！');
                } else {
                    alert('❌ 复制失败，请手动复制');
                }
            } catch (err) {
                alert('❌ 复制失败: ' + err);
            }
            
            // 清理
            document.body.removeChild(textarea);
        }
    </script>
</body>
</html>\`;
        res.end(html);
    }
    else { 
        res.writeHead(404); 
        res.end('404 Not Found'); 
    }
}).listen(port, bind, () => console.log('HTTP on ' + bind + ':' + port));
JSEOF

# ================== 启动 HTTP 订阅服务 ==================
echo "[HTTP] 启动订阅服务 (端口 $HTTP_PORT)..."
node "${FILE_PATH}/server.js" $HTTP_PORT 0.0.0.0 &
HTTP_PID=$!
sleep 1
echo "[HTTP] 订阅服务已启动"

# ================== 生成 sing-box 配置 ==================
echo "[CONFIG] 生成配置..."

INBOUNDS=""

# TUIC (UDP)
if [ -n "$TUIC_PORT" ]; then
    INBOUNDS="{
        \"type\": \"tuic\",
        \"tag\": \"tuic-in\",
        \"listen\": \"::\",
        \"listen_port\": ${TUIC_PORT},
        \"users\": [{\"uuid\": \"${UUID}\", \"password\": \"admin\"}],
        \"congestion_control\": \"bbr\",
        \"tls\": {
            \"enabled\": true,
            \"alpn\": [\"h3\"],
            \"certificate_path\": \"${FILE_PATH}/cert.pem\",
            \"key_path\": \"${FILE_PATH}/private.key\"
        }
    }"
fi

# HY2 (UDP)
if [ -n "$HY2_PORT" ]; then
    [ -n "$INBOUNDS" ] && INBOUNDS="${INBOUNDS},"
    INBOUNDS="${INBOUNDS}{
        \"type\": \"hysteria2\",
        \"tag\": \"hy2-in\",
        \"listen\": \"::\",
        \"listen_port\": ${HY2_PORT},
        \"users\": [{\"password\": \"${UUID}\"}],
        \"tls\": {
            \"enabled\": true,
            \"alpn\": [\"h3\"],
            \"certificate_path\": \"${FILE_PATH}/cert.pem\",
            \"key_path\": \"${FILE_PATH}/private.key\"
        }
    }"
fi

# VLESS Reality (TCP)
if [ -n "$REALITY_PORT" ]; then
    INBOUNDS="${INBOUNDS},{
        \"type\": \"vless\",
        \"tag\": \"vless-reality-in\",
        \"listen\": \"::\",
        \"listen_port\": ${REALITY_PORT},
        \"users\": [{\"uuid\": \"${UUID}\", \"flow\": \"xtls-rprx-vision\"}],
        \"tls\": {
            \"enabled\": true,
            \"server_name\": \"www.nazhumi.com\",
            \"reality\": {
                \"enabled\": true,
                \"handshake\": {\"server\": \"www.nazhumi.com\", \"server_port\": 443},
                \"private_key\": \"${private_key}\",
                \"short_id\": [\"\"]
            }
        }
    }"
fi

# VLESS for Argo
INBOUNDS="${INBOUNDS},{
    \"type\": \"vless\",
    \"tag\": \"vless-argo-in\",
    \"listen\": \"127.0.0.1\",
    \"listen_port\": ${ARGO_PORT},
    \"users\": [{\"uuid\": \"${UUID}\"}],
    \"transport\": {
        \"type\": \"ws\",
        \"path\": \"/${UUID}-vless\"
    }
}"

cat > "${FILE_PATH}/config.json" <<CFGEOF
{
    "log": {"level": "warn"},
    "inbounds": [${INBOUNDS}],
    "outbounds": [{"type": "direct", "tag": "direct"}]
}
CFGEOF
echo "[CONFIG] 配置已生成"

# ================== 启动 sing-box ==================
echo "[SING-BOX] 启动中..."
"$SB_FILE" run -c "${FILE_PATH}/config.json" &
SB_PID=$!
sleep 2

if ! kill -0 $SB_PID 2>/dev/null; then
    echo "[SING-BOX] 启动失败"
    head -n 2 "${FILE_PATH}/private.key"
    "$SB_FILE" run -c "${FILE_PATH}/config.json"
    exit 1
fi
echo "[SING-BOX] 已启动 PID: $SB_PID"

# ================== [修复] Argo 隧道 ==================
ARGO_LOG="${FILE_PATH}/argo.log"
ARGO_DOMAIN=""

echo "[Argo] 启动隧道 (HTTP2模式)..."
"$ARGO_FILE" tunnel --edge-ip-version auto --protocol http2 --no-autoupdate --url http://127.0.0.1:${ARGO_PORT} > "$ARGO_LOG" 2>&1 &
ARGO_PID=$!

for i in {1..30}; do
    sleep 1
    ARGO_DOMAIN=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$ARGO_LOG" 2>/dev/null | head -1 | sed 's|https://||')
    [ -n "$ARGO_DOMAIN" ] && break
done
[ -n "$ARGO_DOMAIN" ] && echo "[Argo] 域名: $ARGO_DOMAIN" || echo "[Argo] 获取域名失败"

# ================== 生成订阅 ==================
generate_sub "$ARGO_DOMAIN"

# ================== 确定订阅链接 ==================
SUB_URL="http://${PUBLIC_IP}:${HTTP_PORT}/sub"
CLASH_URL="http://${PUBLIC_IP}:${HTTP_PORT}/clash"

# ================== 输出结果 ==================
echo ""
echo "==================================================="
if [ "$SINGLE_PORT_MODE" = true ]; then
    echo "模式: 单端口 (${SINGLE_PORT_UDP^^} + Argo)"
    echo ""
    echo "代理节点:"
    [ -n "$HY2_PORT" ] && echo "  - HY2 (UDP): ${PUBLIC_IP}:${HY2_PORT}"
    [ -n "$TUIC_PORT" ] && echo "  - TUIC (UDP): ${PUBLIC_IP}:${TUIC_PORT}"
    [ -n "$ARGO_DOMAIN" ] && echo "  - Argo (WS): ${ARGO_DOMAIN}"
else
    echo "模式: 多端口 (TUIC + HY2 + Reality + Argo)"
    echo ""
    echo "代理节点:"
    echo "  - TUIC (UDP): ${PUBLIC_IP}:${TUIC_PORT}"
    echo "  - HY2 (UDP): ${PUBLIC_IP}:${HY2_PORT}"
    echo "  - Reality (TCP): ${PUBLIC_IP}:${REALITY_PORT}"
    [ -n "$ARGO_DOMAIN" ] && echo "  - Argo (WS): ${ARGO_DOMAIN}"
fi
echo ""
echo "订阅链接:"
echo "  - Clash Meta: $CLASH_URL"
echo "  - 通用订阅: $SUB_URL"
echo "  - 管理页面: http://${PUBLIC_IP}:${HTTP_PORT}/"
echo "==================================================="
echo ""

# ================== 保持运行 ==================
wait $SB_PID
