#!/bin/bash

# --- 配置 ---
# 你的仓库 (用于下载 Web UI 文件)
WEB_REPO="PatrickBlanq/sing-box-web"
# 官方核心仓库
CORE_REPO="SagerNet/sing-box"

INSTALL_DIR="/opt/sing-box-web"
BIN_DIR="/usr/local/bin"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}=== 开始安装 Sing-box Web Panel ===${NC}"

# 1. 准备目录
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR" || exit

# 2. 下载 Web UI 文件 (直接克隆你的仓库，或者下载 zip)
# 方案 A: 如果你的仓库里就是最终的 html/js，直接 clone
echo "正在拉取 Web 面板文件..."
if [ -d ".git" ]; then
    git pull
else
    # 如果没有 git，可以用 curl 下载 zip 解压
    # curl -L -o web.zip "https://github.com/$WEB_REPO/archive/refs/heads/main.zip"
    # unzip web.zip && mv sing-box-web-main/* . && rm -rf sing-box-web-main web.zip
    
    # 既然是 Linux 环境，通常都有 git，直接 clone 最方便后续更新
    git clone "https://github.com/$WEB_REPO.git" .
fi

# 3. 下载 Sing-box 核心 (官方)
echo "正在获取 Sing-box 核心..."
ARCH=$(uname -m)
case $ARCH in
    x86_64)  CORE_ARCH="amd64" ;;
    aarch64) CORE_ARCH="arm64" ;;
    *) echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1 ;;
esac

# 获取官方最新版本号
CORE_TAG=$(curl -s "https://api.github.com/repos/$CORE_REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
# 构造下载链接 (官方文件名格式: sing-box-1.8.0-linux-amd64.tar.gz)
# 注意：tag 是 v1.8.0，但文件名里通常没有 v
CORE_VERSION=${CORE_TAG#v} 
CORE_URL="https://github.com/$CORE_REPO/releases/download/$CORE_TAG/sing-box-${CORE_VERSION}-linux-${CORE_ARCH}.tar.gz"

echo "下载核心: $CORE_URL"
curl -L -o sing-box.tar.gz "$CORE_URL"

# 解压并安装
tar -xzf sing-box.tar.gz
# 移动二进制文件
mv sing-box-*/sing-box "$BIN_DIR/sing-box"
chmod +x "$BIN_DIR/sing-box"
# 清理
rm -rf sing-box.tar.gz sing-box-*

# 4. 配置 Systemd
# 这里假设你的项目里有一个 config.json 模板
# 并且你要运行的是 sing-box run -c ...
# 或者你的 Web UI 是一个 Python/Node 服务？
# 下面以纯 sing-box 运行为例：

echo "配置服务..."
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
User=root
# 这里假设配置文件在安装目录下
ExecStart=$BIN_DIR/sing-box run -c $INSTALL_DIR/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box

echo -e "${GREEN}安装完成！${NC}"
echo -e "请修改配置文件: $INSTALL_DIR/config.json"
echo -e "然后启动服务: systemctl start sing-box"
