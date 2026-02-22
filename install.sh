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

# ========= 安装必需的软件包 =========
echo -e "${GREEN}安装必需的软件包...${NC}"
apt update
apt install -y curl socat lsof unzip

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

# ========= 使用 ZeroSSL（避免 Let's Encrypt 速率限制） =========
echo -e "${GREEN}使用 ZeroSSL 作为证书提供商${NC}"
~/.acme.sh/acme.sh --set-default-ca --server zerossl

# ========= 手动输入域名 =========
echo -e "${GREEN}=======================${NC}"
read -p "请输入要申请证书的域名: " DOMAIN
if [ -z "$DOMAIN" ]; then
  echo -e "${RED}域名不能为空，请重新运行脚本并输入有效的域名。${NC}"
  exit 1
fi

# 注册邮箱（使用域名作为默认邮箱）
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

# ========= 安装证书到指定路径（用域名命名） =========
# 创建证书目录
CERT_DIR="/kimssl"
if [ ! -d "$CERT_DIR" ]; then
  echo "目录 $CERT_DIR 不存在，正在创建..."
  mkdir -p $CERT_DIR
fi

# 将证书文件安装到指定路径，用域名命名
echo "安装证书到 $CERT_DIR/，用域名命名..."
~/.acme.sh/acme.sh --install-cert -d $DOMAIN --ecc \
  --key-file $CERT_DIR/${DOMAIN}.key \
  --fullchain-file $CERT_DIR/${DOMAIN}.crt

# 设置证书和私钥文件的权限
echo "设置证书和私钥文件的权限..."
chmod 644 $CERT_DIR/${DOMAIN}.crt $CERT_DIR/${DOMAIN}.key

# ========= 安装 Xray =========
echo -e "${GREEN}安装 Xray...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 检查 Xray 是否成功安装
if ! command -v xray &> /dev/null; then
  echo -e "${RED}Xray 安装失败，请手动检查错误日志。${NC}"
  exit 1
fi
echo -e "${GREEN}Xray 安装成功！${NC}"

# ========= VMess UUID 和 WebSocket Path 设置 =========
UUID=$(cat /proc/sys/kernel/random/uuid)
# 生成随机 WebSocket Path（使用12位随机字符串）
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

# ========= Xray 配置文件生成（使用域名命名的证书） =========
echo -e "${GREEN}生成 Xray 配置文件...${NC}"
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "alterId": 0
          }
        ]
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
          "headers": {
            "Host": "${DOMAIN}"
          }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

# 检查配置文件语法
echo "检查 Xray 配置文件..."
xray -test -config /usr/local/etc/xray/config.json

# ========= 启动 Xray 服务 =========
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 等待服务启动
sleep 3

# 检查服务状态
if systemctl is-active --quiet xray; then
  echo -e "${GREEN}Xray 服务启动成功！${NC}"
else
  echo -e "${RED}Xray 服务启动失败，请检查日志：journalctl -u xray -n 50${NC}"
  exit 1
fi

# ========= 获取服务器 IP =========
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 https://ip.sb || curl -s --max-time 5 http://ifconfig.me)

# ========= Base64 编码函数 =========
base64_encode() {
  if [[ "$(uname)" == "Darwin" ]]; then
    echo -n "$1" | base64
  else
    echo -n "$1" | base64 -w 0
  fi
}

# ========= 生成 VMESS 链接） =========
echo -e "${GREEN}生成 VMESS 链接...${NC}"


FIXED_DOMAIN="www.visa.com.sg"  # 在这里设置你的固定域名
VMESS_JSON_IP="{\"v\":\"2\",\"ps\":\"vmess+ws+tls\",\"add\":\"${FIXED_DOMAIN}\",\"port\":\"${XRAY_PORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${DOMAIN}\",\"path\":\"/${WS_PATH}\",\"tls\":\"tls\",\"sni\":\"${DOMAIN}\",\"fp\":\"chrome\"}"
VMESS_LINK_IP="vmess://$(base64_encode "$VMESS_JSON_IP")"

# ========= 输出信息 =========
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
echo "建议使用cdn"
echo "$VMESS_LINK_IP"
echo ""
echo -e "${GREEN}==================================================${NC}"
echo -e "${YELLOW}服务管理命令：${NC}"
echo -e "  查看状态：systemctl status xray"
echo -e "  查看日志：journalctl -u xray -n 50 -f"
echo -e "  重启服务：systemctl restart xray"
echo -e "${GREEN}==================================================${NC}"

# ========= 保存配置到文件 =========
cat > ./xray_info.txt <<EOF
========== Xray 配置信息 ==========
证书域名: $DOMAIN
服务器IP: $SERVER_IP
端口: $XRAY_PORT
UUID: $UUID
WebSocket Path: /$WS_PATH
证书文件: $CERT_DIR/${DOMAIN}.crt
密钥文件: $CERT_DIR/${DOMAIN}.key
TLS指纹: chrome

【节点链接】
$VMESS_LINK_IP
===================================
EOF

echo -e "${GREEN}配置信息已保存到 ./xray_info.txt${NC}"