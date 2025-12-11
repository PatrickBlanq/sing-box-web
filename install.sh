#!/bin/bash

# --- 配置 ---
GITHUB_URL="https://github.com"
REPO_PATH="PatrickBlanq/sing-box-web"
# 必须和 service 文件里的路径一致
INSTALL_DIR="/opt/sing-box-web"
SERVICE_NAME="sing-box-web"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}=== 开始部署 Sing-box Web (标准版) ===${NC}"

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
pip3 install Flask requests psutil PyYAML

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
mv sing-box-*/sing-box "$INSTALL_DIR/sing-box"
rm -rf sing-box.tar.gz sing-box-*

# 5. 权限修正
echo -e "${YELLOW}[5/6] 修正权限...${NC}"
chmod +x "$INSTALL_DIR/sing-box"
chmod +x "$INSTALL_DIR/sb-start.sh"
chmod +x "$INSTALL_DIR/sb-stop.sh"
chmod 666 "$INSTALL_DIR/sing-box.log"

# 6. 配置服务 (使用仓库自带的 service 文件)
echo -e "${YELLOW}[6/6] 注册系统服务...${NC}"

SERVICE_FILE="$INSTALL_DIR/sing-box-web.service" # 注意这里的文件名

if [ -f "$SERVICE_FILE" ]; then
    # 复制到系统目录
    cp "$SERVICE_FILE" /etc/systemd/system/$SERVICE_NAME.service
    echo "已安装服务文件: $SERVICE_NAME.service"
else
    echo -e "${RED}致命错误：未在仓库根目录找到 sing-box-web.service 文件！${NC}"
    echo "请检查仓库结构是否正确。"
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
    echo -e "${RED}启动失败，最后日志:${NC}"
    journalctl -u $SERVICE_NAME -n 10 --no-pager
fi
