#!/bin/bash

# --- 配置 ---
REPO_URL="https://github.com/PatrickBlanq/sing-box-web"
INSTALL_DIR="/opt/sing-box-web"
SING_BOX_BIN="/usr/local/bin/sing-box"
SERVICE_NAME="sing-box-web"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${GREEN}=== 开始部署 Sing-box Web 控制面板 ===${NC}"

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
if [ -d "$INSTALL_DIR" ]; then
    echo "目录已存在，正在更新..."
    cd "$INSTALL_DIR"
    git pull
else
    git clone "$REPO_URL.git" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi

# 3. 安装 Python 依赖
echo -e "${YELLOW}[3/5] 安装 Python 依赖...${NC}"
# 检查是否需要虚拟环境 (推荐，但为了兼容你的 service 文件，这里先直接装到系统)
# 如果你的 service 文件里写的是 /usr/bin/python3 app.py，那么依赖必须装在全局
pip3 install -r requirements.txt

# 4. 下载 Sing-box 核心
echo -e "${YELLOW}[4/5] 安装 Sing-box 核心...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64)  CORE_ARCH="amd64" ;;
    aarch64) CORE_ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

# 获取官方最新版本
CORE_TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
CORE_VERSION=${CORE_TAG#v}
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${CORE_TAG}/sing-box-${CORE_VERSION}-linux-${CORE_ARCH}.tar.gz"

echo "正在下载 Sing-box ${CORE_TAG}..."
curl -L -o sing-box.tar.gz "$DOWNLOAD_URL"

if [ $? -ne 0 ]; then
    echo -e "${RED}Sing-box 核心下载失败！${NC}"
    exit 1
fi

tar -xzf sing-box.tar.gz
# 移动核心到 /usr/local/bin (你的 service 文件里需要确保路径一致)
# 这里假设你的 app.py 会调用全局的 sing-box 命令，或者你在 service 里不用它
# 但通常最好把它放在 PATH 里
mv sing-box-*/sing-box "$SING_BOX_BIN"
chmod +x "$SING_BOX_BIN"
rm -rf sing-box.tar.gz sing-box-*

echo "Sing-box 核心已安装到: $SING_BOX_BIN"

# 5. 配置 Systemd 服务
echo -e "${YELLOW}[5/5] 配置系统服务...${NC}"

# 复制你的 service 文件到系统目录
cp "$INSTALL_DIR/sing-box-web.service" /etc/systemd/system/$SERVICE_NAME.service

# 重新加载并启动
systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl restart $SERVICE_NAME

# 检查状态
if systemctl is-active --quiet $SERVICE_NAME; then
    echo -e "${GREEN}部署成功！${NC}"
    echo -e "Web 面板已启动。"
    echo -e "服务状态: systemctl status $SERVICE_NAME"
    # 获取本机 IP (简单的获取方式)
    IP=$(curl -s ifconfig.me)
    echo -e "访问地址: http://$IP:5000 (假设端口是 5000)"
else
    echo -e "${RED}服务启动失败，请检查日志:${NC}"
    journalctl -u $SERVICE_NAME -n 20 --no-pager
fi
