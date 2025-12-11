#!/bin/bash

# --- 配置 (必须与 install.sh 一致) ---
INSTALL_DIR="/opt/sing-box-web"
SERVICE_NAME="sing-box-web"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${YELLOW}=== 正在卸载 Sing-box Web 面板 ===${NC}"

# 1. 停止并禁用服务
echo "正在停止服务..."
if [ -x "$INSTALL_DIR/sb.stop.sh" ]; then
    bash "$INSTALL_DIR/sb.stop.sh"
else
    echo "$INSTALL_DIR/sb.stop.sh 目录不存在 。"
fi
if systemctl is-active --quiet $SERVICE_NAME; then
    systemctl stop $SERVICE_NAME
    echo "服务已停止。"
fi

if systemctl is-enabled --quiet $SERVICE_NAME; then
    systemctl disable $SERVICE_NAME
    echo "服务已禁用。"
fi

# 2. 删除 Service 文件
echo "删除系统服务文件..."
rm -f /etc/systemd/system/$SERVICE_NAME.service
systemctl daemon-reload

# 3. 杀掉残留进程 (保险起见)
# 有时候 python 进程可能还在跑
pkill -f "sb-web.py"
pkill -f "sing-box run"

# 4. 删除安装目录
echo "删除程序文件..."
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}已删除目录: $INSTALL_DIR${NC}"
else
    echo "目录不存在，跳过。"
fi

# 5. 删除软连接 (如果安装脚本创建过)
if [ -L "/usr/local/bin/sing-box" ]; then
    # 只有当它是指向我们安装目录的软连接时才删，防止误删用户自己装的
    LINK_TARGET=$(readlink -f /usr/local/bin/sing-box)
    if [[ "$LINK_TARGET" == *"$INSTALL_DIR"* ]]; then
        rm -f /usr/local/bin/sing-box
        echo "已删除 sing-box 软连接。"
    fi
fi

# 6. 清理 Python 依赖? (可选，通常不建议)
# 一般不建议自动卸载 pip 包，因为可能被其他程序共用。
# 如果非要删：pip3 uninstall -y Flask requests psutil PyYAML
#  bash <(curl -Ls https://raw.githubusercontent.com/PatrickBlanq/sing-box-web/main/install.sh)

#  bash <(curl -Ls https://raw.githubusercontent.com/PatrickBlanq/sing-box-web/main/uninstall.sh)


echo -e "${GREEN}=== 卸载完成！ ===${NC}"
echo "Sing-box Web 已从系统中彻底移除。"
