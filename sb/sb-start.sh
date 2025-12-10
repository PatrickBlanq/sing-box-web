#!/usr/bin/env bash
set -euo pipefail

# 可用环境变量覆盖：
#   IFACE=eth0       # 出网口（默认自动探测）
#   SERVICE=sing-box # sing-box 的 systemd 服务名
#   CFG=/opt/sing-box-web/sing-box/sing-box_config.json  # 配置路径（仅用于提示）

SERVICE="${SERVICE:-sing-box}"
CFG="${CFG:-/root/arm/sing-box_config.json}"
STATE="/run/sb-guard.state"

# 自动探测出网口
IFACE="${IFACE:-$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {print $5; exit}')}"
if [[ -z "${IFACE}" ]]; then
  echo "ERROR: cannot detect uplink iface, set IFACE=eth0" >&2
  exit 1
fi

# 自动探测 LAN 网段（192.168.50.0/24 这种），失败则回退
LAN_CIDR="$(ip -4 route show dev "$IFACE" | awk '/proto kernel/ {print $1; exit}')"
[[ -z "${LAN_CIDR}" ]] && LAN_CIDR="192.168.50.0/24"

echo "sb-start: IFACE=${IFACE}, LAN_CIDR=${LAN_CIDR}"

# 记录当前状态用于恢复
mkdir -p "$(dirname "$STATE")"; : > "$STATE"
echo "IFACE_NAME=${IFACE}" >>"$STATE"
echo "LAN_CIDR=${LAN_CIDR}" >>"$STATE"
echo "IP_FORWARD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" >>"$STATE"
echo "ROUTE_LOCALNET_ALL=$(cat /proc/sys/net/ipv4/conf/all/route_localnet 2>/dev/null || echo 0)" >>"$STATE"
echo "ROUTE_LOCALNET_IFACE=$(cat /proc/sys/net/ipv4/conf/${IFACE}/route_localnet 2>/dev/null || echo 0)" >>"$STATE"
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  echo "RESOLVED_ACTIVE=1" >>"$STATE"
else
  echo "RESOLVED_ACTIVE=0" >>"$STATE"
fi
[[ -f /etc/resolv.conf.sb.bak ]] || cp -f /etc/resolv.conf /etc/resolv.conf.sb.bak 2>/dev/null || true

# 关闭 systemd-resolved（避免占 53/改 resolv.conf）
systemctl disable --now systemd-resolved 2>/dev/null || true
# 本机 DNS 指向 sing-box 的 dns-in
echo "nameserver 127.0.0.1" > /etc/resolv.conf

# sysctl：启转发 + 允许 REDIRECT 到 127.0.0.1
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
sysctl -w net.ipv4.conf.${IFACE}.route_localnet=1 >/dev/null

# NAT：同口转发需要 MASQUERADE
iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE

# 放行本机 53
iptables -C INPUT -i "$IFACE" -p udp --dport 53 -j ACCEPT 2>/dev/null || \
iptables -I INPUT -i "$IFACE" -p udp --dport 53 -j ACCEPT
iptables -C INPUT -i "$IFACE" -p tcp --dport 53 -j ACCEPT 2>/dev/null || \
iptables -I INPUT -i "$IFACE" -p tcp --dport 53 -j ACCEPT

# 仅对 LAN 段的 DNS 重定向到本机 53
iptables -t nat -C PREROUTING -i "$IFACE" -s "$LAN_CIDR" -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || \
iptables -t nat -A PREROUTING -i "$IFACE" -s "$LAN_CIDR" -p udp --dport 53 -j REDIRECT --to-ports 53
iptables -t nat -C PREROUTING -i "$IFACE" -s "$LAN_CIDR" -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || \
iptables -t nat -A PREROUTING -i "$IFACE" -s "$LAN_CIDR" -p tcp --dport 53 -j REDIRECT --to-ports 53

# 持久化（如有）
command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || true

# 启动 sing-box
echo "sb-start: restarting ${SERVICE} ..."
systemctl restart "$SERVICE"
systemctl --no-pager --full status "$SERVICE" | sed -n '1,20p'
echo "sb-start: done. (建议在上级 DHCP 把 DNS/Option6 设置为本机 IP，全网生效)"
