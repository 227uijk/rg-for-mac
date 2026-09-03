#!/bin/zsh
set -u

LAB_DIR="${0:A:h}"
CAP_DIR="$LAB_DIR/captures"
RUIJIE_APP="/Applications/Ruijie Supplicant.app"
IFACE="${1:-en6}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
CAP_FILE="$CAP_DIR/official-ruijie-$STAMP.pcap"

mkdir -p "$CAP_DIR"

if ! ifconfig "$IFACE" >/dev/null 2>&1; then
  IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
fi

if [ -z "${IFACE:-}" ]; then
  echo "找不到网卡。请插好网线后重新运行。"
  exit 1
fi

echo "=== 官方锐捷认证抓包 ==="
echo "网卡: $IFACE"
echo "输出: $CAP_FILE"
echo
echo "操作："
echo "1. 如果锐捷已经在线，请先在锐捷里断开/退出。"
echo "2. 回到这个窗口按回车。"
echo "3. 脚本会开始抓 EAPOL 包并打开锐捷。"
echo "4. 让锐捷完成一次认证，等这个窗口自动结束。"
echo
read "dummy?准备好后按回车开始..."

sudo -v || exit 1

echo "开始抓包，时间 120 秒。下面如果出现 Password，是 Mac 本机密码。"
sudo tcpdump -i "$IFACE" -s 0 -w "$CAP_FILE" 'ether proto 0x888e' &
TCPDUMP_PID=$!

sleep 2
open "$RUIJIE_APP"

for i in $(seq 120 -1 1); do
  printf "\r剩余 %3d 秒，请让锐捷完成认证..." "$i"
  sleep 1
done
echo

sudo kill -INT "$TCPDUMP_PID" >/dev/null 2>&1 || true
wait "$TCPDUMP_PID" >/dev/null 2>&1 || true

echo "抓包完成: $CAP_FILE"
echo "保持这个文件，后面用来对齐 MiniEAP 参数。"
read "dummy?按回车关闭窗口..."
