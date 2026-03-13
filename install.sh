#!/bin/bash
set -e

# ========= 颜色定义 =========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ========= root 检查 =========
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 运行${NC}"
  exit 1
fi

# ========= 选择安装类型 =========
echo -e "${GREEN}==================================================${NC}"
echo -e "${GREEN}请选择要安装的节点类型：${NC}"
echo -e "${GREEN}==================================================${NC}"
echo "1) VLESS + Reality+vison（无需域名，伪装网站）"
echo "2) VMess + WebSocket + TLS（需要域名、申请证书）"
echo "3) 两种节点共存（VLESS+Reality 和 VMess+WS+TLS）"
echo ""
read -p "请选择 [1-3] (默认: 1): " INSTALL_TYPE
INSTALL_TYPE=${INSTALL_TYPE:-1}

# ========= 安装必需的软件包 =========
echo -e "${GREEN}安装必需的软件包...${NC}"
apt update
apt install -y curl socat lsof unzip openssl

# ========= 检查并启用 BBR + FQ（所有类型都启用） =========
echo -e "${GREEN}>>> 检查 BBR + FQ 状态...${NC}"

CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
CURRENT_QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "")

if [[ "$CURRENT_CC" == "bbr" && "$CURRENT_QDISC" == "fq" ]]; then
  echo -e "${GREEN}BBR + FQ 已启用，跳过设置${NC}"
else
  echo -e "${YELLOW}未启用 BBR + FQ，正在设置...${NC}"

  modprobe tcp_bbr || true

  cat > /etc/sysctl.d/99-xray-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  sysctl --system
fi

echo -e "${GREEN}当前拥塞控制算法: $(sysctl -n net.ipv4.tcp_congestion_control)${NC}"
echo -e "${GREEN}当前队列算法    : $(sysctl -n net.core.default_qdisc)${NC}"

# ========= 安装 Xray =========
echo -e "${GREEN}安装 Xray...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 检查 Xray 是否成功安装
if ! command -v xray &> /dev/null; then
  echo -e "${RED}Xray 安装失败，请手动检查错误日志。${NC}"
  exit 1
fi
echo -e "${GREEN}Xray 安装成功！${NC}"

# ========= 根据安装类型执行不同逻辑 =========
if [ "$INSTALL_TYPE" -eq 1 ]; then
  # ========= 仅 VLESS + Reality 安装 =========
  
  # ========= 端口设置 =========
  read -p "请输入 Xray Reality 端口（默认 443，不懂就回车）: " INPUT_PORT
  if [ -z "$INPUT_PORT" ]; then
    XRAY_PORT=443
  else
    XRAY_PORT=$INPUT_PORT
  fi

  # ========= Reality 域名设置 =========
  read -p "请输入 Reality 伪装域名（默认 www.icloud.com，不懂就回车）: " INPUT_DOMAIN
  if [ -z "$INPUT_DOMAIN" ]; then
    DEST_DOMAIN="www.icloud.com"
    SERVER_NAME="www.icloud.com"
  else
    DEST_DOMAIN="$INPUT_DOMAIN"
    SERVER_NAME="$INPUT_DOMAIN"
  fi

  # ========= 生成 UUID 和 Reality 密钥 =========
  UUID=$(xray uuid)
  
  KEYS=$(xray x25519)
  PRIVATE_KEY=$(echo "$KEYS" | grep '^PrivateKey:' | cut -d':' -f2 | tr -d ' ')
  PUBLIC_KEY=$(echo "$KEYS" | grep '^Password:' | cut -d':' -f2 | tr -d ' ')

  SHORT_ID_LEN_BYTES=$((RANDOM % 6 + 3))
  SHORT_ID=$(openssl rand -hex "$SHORT_ID_LEN_BYTES")
  SHORT_IDS_JSON="[\"\", \"$SHORT_ID\"]"

  # ========= 生成 Xray 配置（VLESS Reality） =========
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "dns": {"servers": ["8.8.8.8", "1.1.1.1"]},
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
      {"type": "field", "ip": ["geoip:cn"], "outboundTag": "block"},
      {"type": "field", "port": "443", "network": "udp", "outboundTag": "block"},
      {"type": "field", "network": "udp,tcp", "outboundTag": "direct"}
    ]
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST_DOMAIN:443",
          "xver": 0,
          "serverNames": ["$SERVER_NAME"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": $SHORT_IDS_JSON
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {"protocol": "blackhole", "tag": "block"},
    {"protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}, "tag": "direct"}
  ]
}
EOF

  # ========= 获取服务器 IP 和生成链接 =========
  SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ip.sb)
  VLESS_LINK="vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#KIM@vless-reality-vison"

  # ========= 输出 =========
  clear
  echo -e "${GREEN}==================================================${NC}"
  echo -e "${GREEN}        Xray VLESS + Reality 安装完成${NC}"
  echo -e "${GREEN}==================================================${NC}"
  echo ""
  echo -e "${YELLOW}服务器信息：${NC}"
  echo -e "  服务器IP : ${GREEN}${SERVER_IP}${NC}"
  echo -e "  端口     : ${GREEN}${XRAY_PORT}${NC}"
  echo -e "  UUID     : ${GREEN}${UUID}${NC}"
  echo -e "  Reality 公钥 : ${GREEN}${PUBLIC_KEY}${NC}"
  echo -e "  shortId  : ${GREEN}${SHORT_ID}${NC}"
  echo -e "  SNI      : ${GREEN}${SERVER_NAME}${NC}"
  echo -e "  flow     : ${GREEN}xtls-rprx-vision${NC}"
  echo ""
  echo -e "${BLUE}VLESS 链接：${NC}"
  echo "$VLESS_LINK"
  echo ""
  echo -e "${GREEN}==================================================${NC}"
  echo -e "${YELLOW}服务管理命令：${NC}"
  echo -e "  查看状态：systemctl status xray"
  echo -e "  查看日志：journalctl -u xray -n 50 -f"
  echo -e "  重启服务：systemctl restart xray"
  echo -e "${GREEN}==================================================${NC}"

  # ========= 保存配置 =========
  cat > ./xray_info.txt <<EOF
========== Xray VLESS Reality 配置信息 ==========
服务器IP: $SERVER_IP
端口: $XRAY_PORT
UUID: $UUID
Reality 公钥: $PUBLIC_KEY
shortId: $SHORT_ID
SNI: $SERVER_NAME
flow: xtls-rprx-vision

【节点链接】
$VLESS_LINK
=================================================
EOF

elif [ "$INSTALL_TYPE" -eq 2 ]; then
  # ========= 仅 VMess + WS + TLS 安装 =========
  
  # ========= 检查并释放 80 端口 =========
  echo -e "${GREEN}检查 80 端口是否被占用...${NC}"
  if lsof -i :80 > /dev/null 2>&1; then
    echo -e "${YELLOW}80 端口已被占用，尝试释放...${NC}"
    
    # 停止 nginx 服务（如果存在）
    if systemctl is-active --quiet nginx 2>/dev/null; then
      echo "停止 nginx 服务..."
      systemctl stop nginx
    fi
    
    # 停止 apache 服务（如果存在）
    if systemctl is-active --quiet apache2 2>/dev/null; then
      echo "停止 apache2 服务..."
      systemctl stop apache2
    fi

    # 强制释放 80 端口
    echo "强制释放 80 端口..."
    fuser -k 80/tcp 2>/dev/null || true
    sleep 2
  fi

  # ========= 安装 ACME.sh =========
  echo -e "${GREEN}安装 ACME.sh...${NC}"
  if [ ! -f ~/.acme.sh/acme.sh ]; then
    curl https://get.acme.sh | sh
  else
    echo "ACME.sh 已安装，跳过..."
  fi

  # ========= 使用 ZeroSSL =========
  echo -e "${GREEN}使用 ZeroSSL 作为证书提供商${NC}"
  ~/.acme.sh/acme.sh --set-default-ca --server zerossl

  # ========= 手动输入域名 =========
  echo -e "${GREEN}=======================${NC}"
  read -p "请输入在cloudflae解析好的域名: " DOMAIN
  if [ -z "$DOMAIN" ]; then
    echo -e "${RED}域名不能为空，请重新运行脚本并输入有效的域名。${NC}"
    exit 1
  fi

  # 注册邮箱
  EMAIL="admin@${DOMAIN}"
  echo -e "${GREEN}使用邮箱: $EMAIL 注册 ZeroSSL${NC}"
  ~/.acme.sh/acme.sh --register-account -m $EMAIL --server zerossl || true

  # ========= 申请证书 =========
  echo -e "${GREEN}申请证书: $DOMAIN${NC}"
  if ! ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone -k ec-256 --force --insecure; then
    echo -e "${RED}证书申请失败！${NC}"
    echo -e "${YELLOW}请检查：${NC}"
    echo "1. 域名 DNS 解析是否正确"
    echo "2. 端口 80 是否可用"
    echo "3. 是否超过速率限制"
    exit 1
  fi

  # ========= 安装证书 =========
  CERT_DIR="/kimssl"
  if [ ! -d "$CERT_DIR" ]; then
    echo "目录 $CERT_DIR 不存在，正在创建..."
    mkdir -p $CERT_DIR
  fi

  echo "安装证书到 $CERT_DIR/，用域名命名..."
  ~/.acme.sh/acme.sh --install-cert -d $DOMAIN --ecc \
    --key-file $CERT_DIR/${DOMAIN}.key \
    --fullchain-file $CERT_DIR/${DOMAIN}.crt

  chmod 644 $CERT_DIR/${DOMAIN}.crt $CERT_DIR/${DOMAIN}.key

  # ========= 生成 UUID 和 WebSocket Path =========
  UUID=$(cat /proc/sys/kernel/random/uuid)
  WS_PATH=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)

  # ========= 手动输入端口 =========
  echo -e "${GREEN}=======================${NC}"
  read -p "请输入要使用的端口 (默认: 8443): " XRAY_PORT
  if [ -z "$XRAY_PORT" ]; then
    XRAY_PORT=8443
    echo -e "${GREEN}使用默认端口: $XRAY_PORT${NC}"
  else
    echo -e "${GREEN}使用端口: $XRAY_PORT${NC}"
  fi

  # ========= 生成 Xray 配置（VMess） =========
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"},
      {"type": "field", "domain": ["geosite:apple", "geosite:microsoft"], "outboundTag": "direct"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
      {"type": "field", "ip": ["geoip:cn"], "outboundTag": "block"},
      {"type": "field", "port": "443", "network": "udp", "outboundTag": "block"},
      {"type": "field", "network": "udp,tcp", "outboundTag": "direct"}
    ]
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [{"id": "${UUID}", "alterId": 0}]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "certificates": [
            {
              "certificateFile": "${CERT_DIR}/${DOMAIN}.crt",
              "keyFile": "${CERT_DIR}/${DOMAIN}.key"
            }
          ]
        },
        "wsSettings": {
          "path": "/${WS_PATH}",
          "headers": {"Host": "${DOMAIN}"}
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF

  # ========= 生成 VMESS 链接 =========
  SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 https://ip.sb || curl -s --max-time 5 http://ifconfig.me)
  
  base64_encode() {
    if [[ "$(uname)" == "Darwin" ]]; then
      echo -n "$1" | base64
    else
      echo -n "$1" | base64 -w 0
    fi
  }

  FIXED_DOMAIN="www.visa.com.sg"
  VMESS_JSON="{\"v\":\"2\",\"ps\":\"vmess+ws+tls\",\"add\":\"${FIXED_DOMAIN}\",\"port\":\"${XRAY_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/${WS_PATH}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"fp\":\"chrome\"}"
  VMESS_LINK="vmess://$(base64_encode "$VMESS_JSON")"

  # ========= 重新启动之前停止的 nginx =========
  echo "检查并恢复 nginx 服务..."

  # 重新启动 nginx（如果之前是停止的）
  if systemctl list-unit-files | grep -q nginx; then
    if ! systemctl is-active --quiet nginx; then
      echo "重新启动 nginx..."
      systemctl start nginx
      if systemctl is-active --quiet nginx; then
        echo -e "${GREEN}nginx 已成功重启${NC}"
      else
        echo -e "${YELLOW}nginx 启动失败，请手动检查${NC}"
      fi
    else
      echo "nginx 已在运行，无需操作"
    fi
  fi

  # ========= 输出 =========
  clear
  echo -e "${GREEN}==================================================${NC}"
  echo -e "${GREEN}        Xray VMess + WebSocket + TLS 安装完成${NC}"
  echo -e "${GREEN}==================================================${NC}"
  echo ""
  echo -e "${YELLOW}服务器信息：${NC}"
  echo -e "  证书域名 : ${GREEN}${DOMAIN}${NC}"
  echo -e "  服务器IP : ${GREEN}${SERVER_IP}${NC}"
  echo -e "  端口     : ${GREEN}${XRAY_PORT}${NC}"
  echo -e "  UUID     : ${GREEN}${UUID}${NC}"
  echo -e "  WebSocket Path : ${GREEN}/${WS_PATH}${NC}"
  echo -e "  证书文件 : ${GREEN}${CERT_DIR}/${DOMAIN}.crt${NC}"
  echo -e "  密钥文件 : ${GREEN}${CERT_DIR}/${DOMAIN}.key${NC}"
  echo -e "  TLS指纹  : ${GREEN}chrome${NC}"
  echo ""
  echo -e "${BLUE}VMESS 链接：${NC}"
  echo "$VMESS_LINK"
  echo ""
  echo -e "${GREEN}==================================================${NC}"
  echo -e "${YELLOW}服务管理命令：${NC}"
  echo -e "  查看状态：systemctl status xray"
  echo -e "  查看日志：journalctl -u xray -n 50 -f"
  echo -e "  重启服务：systemctl restart xray"
  echo -e "${GREEN}==================================================${NC}"

  # ========= 保存配置 =========
  cat > ./xray_info.txt <<EOF
========== Xray VMess 配置信息 ==========
证书域名: $DOMAIN
服务器IP: $SERVER_IP
端口: $XRAY_PORT
UUID: $UUID
WebSocket Path: /$WS_PATH
证书文件: $CERT_DIR/${DOMAIN}.crt
密钥文件: $CERT_DIR/${DOMAIN}.key
TLS指纹: chrome

【节点链接】
$VMESS_LINK
=========================================
EOF

else
  # ========= 两种节点共存安装 =========
  
  # ========= 第一部分：VLESS + Reality 配置 =========
  echo -e "${GREEN}========== 配置 VLESS + Reality ==========${NC}"
  
  # ========= 端口设置 =========
  read -p "请输入 VLESS Reality 端口（默认 443）: " REALITY_PORT
  if [ -z "$REALITY_PORT" ]; then
    REALITY_PORT=443
  fi

  # ========= Reality 域名设置 =========
  read -p "请输入 Reality 伪装域名（默认 www.icloud.com）: " REALITY_DOMAIN
  if [ -z "$REALITY_DOMAIN" ]; then
    DEST_DOMAIN="www.icloud.com"
    SERVER_NAME="www.icloud.com"
  else
    DEST_DOMAIN="$REALITY_DOMAIN"
    SERVER_NAME="$REALITY_DOMAIN"
  fi

  # ========= 生成 UUID 和 Reality 密钥 =========
  UUID1=$(xray uuid)
  
  KEYS=$(xray x25519)
  PRIVATE_KEY=$(echo "$KEYS" | grep '^PrivateKey:' | cut -d':' -f2 | tr -d ' ')
  PUBLIC_KEY=$(echo "$KEYS" | grep '^Password:' | cut -d':' -f2 | tr -d ' ')

  SHORT_ID_LEN_BYTES=$((RANDOM % 6 + 3))
  SHORT_ID=$(openssl rand -hex "$SHORT_ID_LEN_BYTES")
  SHORT_IDS_JSON="[\"\", \"$SHORT_ID\"]"

  # ========= 第二部分：VMess + WS + TLS 配置 =========
  echo -e "${GREEN}========== 配置 VMess + WS + TLS ==========${NC}"
  
  # ========= 检查并释放 80 端口 =========
  echo -e "${GREEN}检查 80 端口是否被占用...${NC}"
  if lsof -i :80 > /dev/null 2>&1; then
    echo -e "${YELLOW}80 端口已被占用，尝试释放...${NC}"
    
    # 停止 nginx 服务（如果存在）
    if systemctl is-active --quiet nginx 2>/dev/null; then
      echo "停止 nginx 服务..."
      systemctl stop nginx
    fi
    
    # 停止 apache 服务（如果存在）
    if systemctl is-active --quiet apache2 2>/dev/null; then
      echo "停止 apache2 服务..."
      systemctl stop apache2
    fi

    # 强制释放 80 端口
    echo "强制释放 80 端口..."
    fuser -k 80/tcp 2>/dev/null || true
    sleep 2
  fi

  # ========= 安装 ACME.sh =========
  echo -e "${GREEN}安装 ACME.sh...${NC}"
  if [ ! -f ~/.acme.sh/acme.sh ]; then
    curl https://get.acme.sh | sh
  fi

  # ========= 使用 ZeroSSL =========
  echo -e "${GREEN}使用 ZeroSSL 作为证书提供商${NC}"
  ~/.acme.sh/acme.sh --set-default-ca --server zerossl

  # ========= 手动输入域名 =========
  echo -e "${GREEN}=======================${NC}"
  read -p "请输入要申请证书的域名: " DOMAIN
  if [ -z "$DOMAIN" ]; then
    echo -e "${RED}域名不能为空，请重新运行脚本并输入有效的域名。${NC}"
    exit 1
  fi

  # 注册邮箱
  EMAIL="admin@${DOMAIN}"
  echo -e "${GREEN}使用邮箱: $EMAIL 注册 ZeroSSL${NC}"
  ~/.acme.sh/acme.sh --register-account -m $EMAIL --server zerossl || true

  # ========= 申请证书 =========
  echo -e "${GREEN}申请证书: $DOMAIN${NC}"
  if ! ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone -k ec-256 --force --insecure; then
    echo -e "${RED}证书申请失败！${NC}"
    exit 1
  fi

  # ========= 安装证书 =========
  CERT_DIR="/kimssl"
  if [ ! -d "$CERT_DIR" ]; then
    mkdir -p $CERT_DIR
  fi

  echo "安装证书到 $CERT_DIR/..."
  ~/.acme.sh/acme.sh --install-cert -d $DOMAIN --ecc \
    --key-file $CERT_DIR/${DOMAIN}.key \
    --fullchain-file $CERT_DIR/${DOMAIN}.crt

  chmod 644 $CERT_DIR/${DOMAIN}.crt $CERT_DIR/${DOMAIN}.key

  # ========= 生成第二个 UUID 和 WebSocket Path =========
  UUID2=$(cat /proc/sys/kernel/random/uuid)
  WS_PATH=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 12)

  # ========= 手动输入 VMess 端口 =========
  echo -e "${GREEN}=======================${NC}"
  read -p "请输入 VMess + WS + TLS 使用的端口 (默认: 8443): " VMESS_PORT
  if [ -z "$VMESS_PORT" ]; then
    VMESS_PORT=8443
  fi

  # ========= 生成共存 Xray 配置 =========
  cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "dns": {"servers": ["8.8.8.8", "1.1.1.1"]},
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"},
      {"type": "field", "domain": ["geosite:apple", "geosite:microsoft"], "outboundTag": "direct"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
      {"type": "field", "ip": ["geoip:cn"], "outboundTag": "block"},
      {"type": "field", "network": "udp,tcp", "outboundTag": "direct"}
    ]
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $REALITY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID1", "flow": "xtls-rprx-vision"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST_DOMAIN:443",
          "xver": 0,
          "serverNames": ["$SERVER_NAME"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": $SHORT_IDS_JSON
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    },
    {
      "listen": "0.0.0.0",
      "port": ${VMESS_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [{"id": "${UUID2}", "alterId": 0}]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${DOMAIN}",
          "certificates": [
            {
              "certificateFile": "${CERT_DIR}/${DOMAIN}.crt",
              "keyFile": "${CERT_DIR}/${DOMAIN}.key"
            }
          ]
        },
        "wsSettings": {
          "path": "/${WS_PATH}",
          "headers": {"Host": "${DOMAIN}"}
        }
      },
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}, "tag": "direct"},
   {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF

  # ========= 获取服务器 IP =========
  SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ip.sb || curl -s http://ifconfig.me)

  # ========= 生成两个链接 =========
  # VLESS 链接
  VLESS_LINK="vless://${UUID1}@${SERVER_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#KIM@vless-reality"

  # VMESS 链接
  base64_encode() {
    if [[ "$(uname)" == "Darwin" ]]; then
      echo -n "$1" | base64
    else
      echo -n "$1" | base64 -w 0
    fi
  }

  FIXED_DOMAIN="www.visa.com.sg"
  VMESS_JSON="{\"v\":\"2\",\"ps\":\"vmess+ws+tls\",\"add\":\"${FIXED_DOMAIN}\",\"port\":\"${VMESS_PORT}\",\"id\":\"${UUID2}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/${WS_PATH}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"fp\":\"chrome\"}"
  VMESS_LINK="vmess://$(base64_encode "$VMESS_JSON")"

  # ========= 重新启动之前停止的 nginx =========
  echo "检查并恢复 nginx 服务..."

  if systemctl list-unit-files | grep -q nginx; then
    if ! systemctl is-active --quiet nginx; then
      echo "重新启动 nginx..."
      systemctl start nginx
      if systemctl is-active --quiet nginx; then
        echo -e "${GREEN}nginx 已成功重启${NC}"
      else
        echo -e "${YELLOW}nginx 启动失败，请手动检查${NC}"
      fi
    else
      echo "nginx 已在运行，无需操作"
    fi
  fi

  # ========= 输出 =========
  clear
  echo -e "${GREEN}==================================================${NC}"
  echo -e "${GREEN}        Xray 双节点共存安装完成${NC}"
  echo -e "${GREEN}==================================================${NC}"
  echo ""
  echo -e "${YELLOW}服务器信息：${NC}"
  echo -e "  服务器IP : ${GREEN}${SERVER_IP}${NC}"
  echo ""
  echo -e "${BLUE}【VLESS + Reality 节点】${NC}"
  echo -e "  端口     : ${GREEN}${REALITY_PORT}${NC}"
  echo -e "  UUID     : ${GREEN}${UUID1}${NC}"
  echo -e "  Reality 公钥 : ${GREEN}${PUBLIC_KEY}${NC}"
  echo -e "  shortId  : ${GREEN}${SHORT_ID}${NC}"
  echo -e "  SNI      : ${GREEN}${SERVER_NAME}${NC}"
  echo -e "  flow     : ${GREEN}xtls-rprx-vision${NC}"
  echo ""
  echo -e "${BLUE}链接：${NC}"
  echo "$VLESS_LINK"
  echo ""
  echo -e "${BLUE}【VMess + WS + TLS 节点】${NC}"
  echo -e "  证书域名 : ${GREEN}${DOMAIN}${NC}"
  echo -e "  端口     : ${GREEN}${VMESS_PORT}${NC}"
  echo -e "  UUID     : ${GREEN}${UUID2}${NC}"
  echo -e "  WebSocket Path : ${GREEN}/${WS_PATH}${NC}"
  echo -e "  证书文件 : ${GREEN}${CERT_DIR}/${DOMAIN}.crt${NC}"
  echo -e "  密钥文件 : ${GREEN}${CERT_DIR}/${DOMAIN}.key${NC}"
  echo -e "  TLS指纹  : ${GREEN}chrome${NC}"
  echo ""
  echo -e "${BLUE}链接：${NC}"
  echo "$VMESS_LINK"
  echo ""
  echo -e "${GREEN}==================================================${NC}"
  echo -e "${YELLOW}服务管理命令：${NC}"
  echo -e "  查看状态：systemctl status xray"
  echo -e "  查看日志：journalctl -u xray -n 50 -f"
  echo -e "  重启服务：systemctl restart xray"
  echo -e "${GREEN}==================================================${NC}"

  # ========= 保存配置 =========
  cat > ./xray_info.txt <<EOF
========== Xray 双节点共存配置信息 ==========
服务器IP: $SERVER_IP

【VLESS + Reality】
端口: $REALITY_PORT
UUID: $UUID1
Reality 公钥: $PUBLIC_KEY
shortId: $SHORT_ID
SNI: $SERVER_NAME
flow: xtls-rprx-vision

链接:
$VLESS_LINK

【VMess + WS + TLS】
证书域名: $DOMAIN
端口: $VMESS_PORT
UUID: $UUID2
WebSocket Path: /$WS_PATH
证书文件: $CERT_DIR/${DOMAIN}.crt
密钥文件: $CERT_DIR/${DOMAIN}.key
TLS指纹: chrome

链接:
$VMESS_LINK
===============================================
EOF

fi

# ========= 启动 Xray 服务 =========
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

sleep 3
if systemctl is-active --quiet xray; then
  echo -e "${GREEN}Xray 服务运行正常！${NC}"
else
  echo -e "${RED}❌ Xray 启动失败，请检查日志：journalctl -u xray -n 50${NC}"
  exit 1
fi

echo -e "${GREEN}配置信息已保存到 ./xray_info.txt${NC}"
