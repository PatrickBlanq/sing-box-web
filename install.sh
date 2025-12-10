#!/bin/bash

# --- 配置 ---
# 默认使用官方，如果连接失败自动切换镜像
GITHUB_URL="https://github.com"
REPO_PATH="PatrickBlanq/sing-box-web"
INSTALL_DIR="/opt/sing-box-web"
SING_BOX_BIN="/usr/local/bin/sing-box"
SERVICE_NAME="sing-box-web"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}=== 开始部署 Sing-box Web 控制面板 ===${NC}"

# --- 0. 网络检查与加速 ---
check_github() {
    echo -e "${YELLOW}正在测试 GitHub 连接...${NC}"
    if curl -s --head --request GET --connect-timeout 5 https://github.com > /dev/null; then
        echo -e "${GREEN}GitHub 连接正常${NC}"
    else
        echo -e "${RED}GitHub 连接超时，自动切换加速镜像...${NC}"
        GITHUB_URL="https://mirror.ghproxy.com/https://github.com"
        echo -e "已切换源: $GITHUB_URL"
    fi
}
check_github

# 1. 检查并安装基础依赖
echo -e "${YELLOW}[1/5] 检查系统依赖...${NC}"
if [ -f /etc/debian_version ]; then
    apt-get update
    apt-get install -y git python3 python3-pip curl tar
elif [ -f /etc/redhat-release ]; then
    yum install -y git python3 python3-pip curl tar
fi

# 2. 部署项目代码
echo -e "${YELLOW}[2/5] 拉取项目代码...${NC}"
CLONE_URL="$GITHUB_URL/$REPO_PATH.git"

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "目录已存在，正在更新..."
    cd "$INSTALL_DIR"
    git pull
else
    rm -rf "$INSTALL_DIR"
    echo "正在克隆: $CLONE_URL"
    git clone "$CLONE_URL" "$INSTALL_DIR"
    
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}克隆失败！请检查网络。${NC}"
        exit 1
    fi
    cd "$INSTALL_DIR"
fi

# 3. 安装 Python 依赖 (修改了这里：找不到文件就自动装 Flask)
echo -e "${YELLOW}[3/5] 安装 Python 依赖...${NC}"
if [ -f "requirements.txt" ]; then
    pip3 install -r requirements.txt
else
    echo -e "${YELLOW}提示: 未找到 requirements.txt，正在安装默认依赖 (Flask requests)...${NC}"
    pip3 install Flask requests psutil
fi

# 4. 下载 Sing-box 核心
echo -e "${YELLOW}[4/5] 安装 Sing-box 核心...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64)  CORE_ARCH="amd64" ;;
    aarch64) CORE_ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

# 获取版本号 (增加容错)
CORE_TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$CORE_TAG" ]; then
    echo -e "${RED}API 获取版本失败，使用默认版本 v1.8.0${NC}"
    CORE_TAG="v1.8.0"
fi

CORE_VERSION=${CORE_TAG#v}
DOWNLOAD_URL="$GITHUB_URL/SagerNet/sing-box/releases/download/${CORE_TAG}/sing-box-${CORE_VERSION}-linux-${CORE_ARCH}.tar.gz"

echo "正在下载 Sing-box ${CORE_TAG}..."
curl -L -o sing-box.tar.gz "$DOWNLOAD_URL"

# 检查文件大小
FILE_SIZE=$(stat -c%s "sing-box.tar.gz" 2>/dev/null || echo 0)
if [ "$FILE_SIZE" -lt 1000 ]; then
    echo -e "${RED}核心下载失败！${NC}"
    rm -f sing-box.tar.gz
    exit 1
fi

tar -xzf sing-box.tar.gz
mv sing-box-*/sing-box "$SING_BOX_BIN"
chmod +x "$SING_BOX_BIN"
rm -rf sing-box.tar.gz sing-box-*

# 5. 配置 Systemd 服务
echo -e "${YELLOW}[5/5] 配置系统服务...${NC}"
# 确保 service 文件存在
if [ ! -f "$INSTALL_DIR/sing-box/sing-box-web.service" ]; then
    echo -e "${RED}错误：仓库中缺少 sing-box-web.service 文件！${NC}"
    exit 1
fi

cp "$INSTALL_DIR/sing-box-web.service" /etc/systemd/system/$SERVICE_NAME.service
systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl restart $SERVICE_NAME

if systemctl is-active --quiet $SERVICE_NAME; then
    echo -e "${GREEN}部署成功！${NC}"
    IP=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')
    echo -e "访问地址: http://$IP:5000"
else
    echo -e "${RED}服务启动失败，最后几行日志:${NC}"
    journalctl -u $SERVICE_NAME -n 10 --no-pager
fi
