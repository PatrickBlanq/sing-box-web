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
        echo -e "${RED}GitHub 连接超时，尝试使用加速镜像...${NC}"
        # 这里使用莫比乌斯等常见镜像，或者你可以换成 fastgit 等
        # 注意：镜像站可能会变，最稳妥的是让用户自己配代理
        # 这里演示切换到一个常用的镜像前缀
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

# 构造带加速的 Clone 地址
# 注意：如果是镜像，地址格式通常是 镜像/https://github.com/用户/库
CLONE_URL="$GITHUB_URL/$REPO_PATH.git"

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "目录已存在，正在更新..."
    cd "$INSTALL_DIR"
    git pull
else
    # 彻底清理旧的失败残留
    rm -rf "$INSTALL_DIR"
    
    echo "正在克隆: $CLONE_URL"
    git clone "$CLONE_URL" "$INSTALL_DIR"
    
    # 关键：检查 Clone 是否成功
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}克隆失败！请检查网络或配置代理。${NC}"
        exit 1
    fi
    cd "$INSTALL_DIR"
fi

# 3. 安装 Python 依赖
echo -e "${YELLOW}[3/5] 安装 Python 依赖...${NC}"
if [ ! -f "requirements.txt" ]; then
    echo -e "${RED}错误：找不到 requirements.txt，代码拉取可能不完整。${NC}"
    exit 1
fi
pip3 install -r requirements.txt

# 4. 下载 Sing-box 核心
echo -e "${YELLOW}[4/5] 安装 Sing-box 核心...${NC}"
ARCH=$(uname -m)
case $ARCH in
    x86_64)  CORE_ARCH="amd64" ;;
    aarch64) CORE_ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

# 获取版本号 (这一步如果 API 被墙也会失败，需要容错)
# 如果 API 失败，我们可以回退到一个硬编码的默认版本，或者报错
CORE_TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$CORE_TAG" ]; then
    echo -e "${RED}无法获取最新版本号，将使用默认版本 v1.8.0${NC}"
    CORE_TAG="v1.8.0"
fi

CORE_VERSION=${CORE_TAG#v}
# 构造下载链接 (同样应用加速)
# 官方: https://github.com/...
# 镜像: https://mirror.ghproxy.com/https://github.com/...
DOWNLOAD_URL="$GITHUB_URL/SagerNet/sing-box/releases/download/${CORE_TAG}/sing-box-${CORE_VERSION}-linux-${CORE_ARCH}.tar.gz"

echo "正在下载 Sing-box ${CORE_TAG}..."
echo "Url: $DOWNLOAD_URL"

curl -L -o sing-box.tar.gz "$DOWNLOAD_URL"

# 检查文件大小，防止下载了 0KB 的空文件
FILE_SIZE=$(stat -c%s "sing-box.tar.gz" 2>/dev/null || echo 0)
if [ "$FILE_SIZE" -lt 1000 ]; then
    echo -e "${RED}下载失败或文件损坏！${NC}"
    rm -f sing-box.tar.gz
    exit 1
fi

tar -xzf sing-box.tar.gz
mv sing-box-*/sing-box "$SING_BOX_BIN"
chmod +x "$SING_BOX_BIN"
rm -rf sing-box.tar.gz sing-box-*

# 5. 配置 Systemd 服务
echo -e "${YELLOW}[5/5] 配置系统服务...${NC}"
cp "$INSTALL_DIR/sing-box-web.service" /etc/systemd/system/$SERVICE_NAME.service
systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl restart $SERVICE_NAME

if systemctl is-active --quiet $SERVICE_NAME; then
    echo -e "${GREEN}部署成功！${NC}"
    # 获取 IP
    IP=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')
    echo -e "访问地址: http://$IP:5000"
else
    echo -e "${RED}服务启动失败，日志:${NC}"
    journalctl -u $SERVICE_NAME -n 10 --no-pager
fi
