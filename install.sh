#!/bin/bash

# --- 配置 ---
GITHUB_URL="https://github.com"
REPO_PATH="PatrickBlanq/sing-box-web"
INSTALL_DIR="/opt/sing-box-web"
SERVICE_NAME="sing-box-web"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}=== 开始部署 Sing-box Web 控制面板 ===${NC}"

# 0. 网络检查
check_github() {
    if curl -s --head --request GET --connect-timeout 5 https://github.com > /dev/null; then
        echo -e "${GREEN}GitHub 连接正常${NC}"
    else
        echo -e "${RED}连接超时，切换加速源...${NC}"
        GITHUB_URL="https://mirror.ghproxy.com/https://github.com"
    fi
}
check_github

# 1. 基础环境
echo -e "${YELLOW}[1/6] 检查依赖...${NC}"
if [ -f /etc/debian_version ]; then
    apt-get update -y && apt-get install -y git python3 python3-pip curl tar
elif [ -f /etc/redhat-release ]; then
    yum install -y git python3 python3-pip curl tar
fi

# 2. 拉取代码
echo -e "${YELLOW}[2/6] 拉取项目...${NC}"
CLONE_URL="$GITHUB_URL/$REPO_PATH.git"
rm -rf "$INSTALL_DIR"
git clone "$CLONE_URL" "$INSTALL_DIR"
if [ ! -d "$INSTALL_DIR" ]; then echo -e "${RED}克隆失败${NC}"; exit 1; fi

# 3. Python 依赖
echo -e "${YELLOW}[3/6] 安装 Python 库...${NC}"
pip3 install Flask requests psutil

# 4. 下载核心
echo -e "${YELLOW}[4/6] 安装 Sing-box 核心...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64)  CORE_ARCH="amd64" ;;
    aarch64) CORE_ARCH="arm64" ;;
    *) echo -e "${RED}不支持架构: $ARCH${NC}"; exit 1 ;;
esac

CORE_TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
[ -z "$CORE_TAG" ] && CORE_TAG="v1.8.0"

CORE_VERSION=${CORE_TAG#v}
DOWNLOAD_URL="$GITHUB_URL/SagerNet/sing-box/releases/download/${CORE_TAG}/sing-box-${CORE_VERSION}-linux-${CORE_ARCH}.tar.gz"

echo "下载核心..."
curl -L -o sing-box.tar.gz "$DOWNLOAD_URL"

FILE_SIZE=$(stat -c%s "sing-box.tar.gz" 2>/dev/null || echo 0)
if [ "$FILE_SIZE" -lt 1000 ]; then echo -e "${RED}核心下载失败${NC}"; rm -f sing-box.tar.gz; exit 1; fi

tar -xzf sing-box.tar.gz
# 确保 sb 目录存在
mkdir -p "$INSTALL_DIR/sb"
# 移动核心到 sb 目录 (适配你的 Python 逻辑)
mv sing-box-*/sing-box "$INSTALL_DIR/sb/sing-box"
rm -rf sing-box.tar.gz sing-box-*

# 5. 权限修正
echo -e "${YELLOW}[5/6] 修正权限...${NC}"
chmod +x "$INSTALL_DIR/sb/sing-box"
chmod +x "$INSTALL_DIR/sb/sb-start.sh"
touch "$INSTALL_DIR/sb/sing-box.log"
chmod 666 "$INSTALL_DIR/sb/sing-box.log"

# 6. 配置服务
echo -e "${YELLOW}[6/6] 注册系统服务...${NC}"

# 直接使用仓库里的 service 文件
# 注意：你需要确保仓库里的 service 文件路径是对的 (/opt/sing-box-web/web/sb-web.py)
if [ -f "$INSTALL_DIR/web/sing-box-web.service" ]; then
    cp "$INSTALL_DIR/web/sing-box-web.service" /etc/systemd/system/$SERVICE_NAME.service
else
    echo -e "${RED}错误：未找到 web/sing-box-web.service 文件！${NC}"
    exit 1
fi

systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl restart $SERVICE_NAME

if systemctl is-active --quiet $SERVICE_NAME; then
    echo -e "${GREEN}部署成功！${NC}"
    IP=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')
    echo -e "访问: http://$IP:5000"
else
    echo -e "${RED}启动失败，请自行检查日志。${NC}"
fi
