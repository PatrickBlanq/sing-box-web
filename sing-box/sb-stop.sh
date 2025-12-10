#!/usr/bin/env bash
set -euo pipefail

SERVICE="${SERVICE:-sing-box}"
STATE="/run/sb-guard.state"

# 先停 sing-box，避免默认路由仍指向 TUN
systemctl stop "$SERVICE" 2>/dev/null || true

# 读取 start 时记录的 IFACE/LAN_CIDR
IFACE=""
LAN_CIDR=""
if [[ -f "$STATE" ]]; then
  # shellcheck disable=SC1090
  . "$STATE"
  IFACE="${IFACE_NAME:-$IFACE}"
  LAN_CIDR="${LAN_CIDR:-$LAN_CIDR}"
fi
# 回退自动探测
[[ -z "${IFACE}" ]] && IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {print $5; exit}')"
[[ -z "${LAN_CIDR:-}" ]] && LAN_CIDR="$(ip -4 route show dev "$IFACE" | awk '/proto kernel/ {print $1; exit}')"
[[ -z "${LAN_CIDR:-}" ]] && LAN_CIDR="192.168.50.0/24"

# 删除我们添加的 iptables 规则（精确匹配带 -s）
if [[ -n "${IFACE:-}" ]]; then
  for PROTO in udp tcp; do
    while iptables -t nat -C PREROUTING -i "$IFACE" -s "$LAN_CIDR" -p "$PROTO" --dport 53 -j REDIRECT --to-ports 53 2>/dev/null; do
      iptables -t nat -D PREROUTING -i "$IFACE" -s "$LAN_CIDR" -p "$PROTO" --dport 53 -j REDIRECT --to-ports 53 || true
    done
  done
  while iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -o "$IFACE" -j MASQUERADE || true
  done
  while iptables -C INPUT -i "$IFACE" -p udp --dport 53 -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -i "$IFACE" -p udp --dport 53 -j ACCEPT || true
  done
  while iptables -C INPUT -i "$IFACE" -p tcp --dport 53 -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -i "$IFACE" -p tcp --dport 53 -j ACCEPT || true
  done
fi

# 恢复 sysctl（按记录值）
if [[ -f "$STATE" ]]; then
  # shellcheck disable=SC1090
  . "$STATE"
  sysctl -w net.ipv4.ip_forward="${IP_FORWARD:-0}" >/dev/null || true
  sysctl -w net.ipv4.conf.all.route_localnet="${ROUTE_LOCALNET_ALL:-0}" >/dev/null || true
  if [[ -n "${IFACE:-}" ]] && [[ -d "/proc/sys/net/ipv4/conf/${IFACE}" ]]; then
    sysctl -w net.ipv4.conf.${IFACE}.route_localnet="${ROUTE_LOCALNET_IFACE:-0}" >/dev/null || true
  fi
fi

# 恢复 resolv.conf
if [[ -f /etc/resolv.conf.sb.bak ]]; then
  mv -f /etc/resolv.conf.sb.bak /etc/resolv.conf || true
else
  echo "nameserver 192.168.50.1" > /etc/resolv.conf || true
fi

# 恢复 systemd-resolved（如之前是激活）
if [[ -f "$STATE" ]]; then
  # shellcheck disable=SC1090
  . "$STATE"
  [[ "${RESOLVED_ACTIVE:-0}" = "1" ]] && systemctl enable --now systemd-resolved 2>/dev/null || true
fi

command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save || true
rm -f "$STATE"
echo "sb-stop: done."