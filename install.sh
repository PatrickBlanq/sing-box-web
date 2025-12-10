#!/bin/bash

# 配置部分
REPO="your-username/sing-box-web" # 你的 GitHub 仓库
BINARY_NAME="sing-box-web"
INSTALL_DIR="/usr/local/bin"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}=== 开始安装 Sing-box Web ===${NC}"

# 1. 检测架构
ARCH=$(uname -m)
case $ARCH in
    x86_64)
        DOWNLOAD_ARCH="linux-amd64"
        ;;
    aarch64)
        DOWNLOAD_ARCH="linux-arm64"
        ;;
    *)
        echo -e "${RED}不支持的架构: $ARCH${NC}"
        exit 1
        ;;
esac

# 2. 获取最新版本 (通过 GitHub API)
LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$LATEST_TAG" ]; then
    echo -e "${RED}获取最新版本失败，请检查网络${NC}"
    exit 1
fi

echo -e "发现最新版本: ${GREEN}$LATEST_TAG${NC}"

# 3. 下载文件
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/${BINARY_NAME}-${DOWNLOAD_ARCH}"
echo "正在下载: $DOWNLOAD_URL"

curl -L -o "$INSTALL_DIR/$BINARY_NAME" "$DOWNLOAD_URL"

if [ $? -ne 0 ]; then
    echo -e "${RED}下载失败${NC}"
    exit 1
fi

chmod +x "$INSTALL_DIR/$BINARY_NAME"

# 4. 配置 Systemd (开机自启)
# 假设你的程序运行需要 config.json，这里可以顺便生成一个默认配置
cat > /etc/systemd/system/$BINARY_NAME.service <<EOF
[Unit]
Description=Sing-box Web UI
After=network.target

[Service]
Type=simple
User=root
ExecStart=$INSTALL_DIR/$BINARY_NAME
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $BINARY_NAME
systemctl restart $BINARY_NAME

echo -e "${GREEN}安装完成！${NC}"
echo -e "服务已启动，请访问 http://IP:端口"
