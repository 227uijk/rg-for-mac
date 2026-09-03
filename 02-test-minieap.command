#!/bin/zsh
set -u

LAB_DIR="${0:A:h}"
MINIEAP="$LAB_DIR/minieap"
LOG_DIR="$LAB_DIR/logs"
CAP_DIR="$LAB_DIR/captures"
IFACE="${1:-en6}"
USERNAME="${CAMPUS_USERNAME:-your_student_id}" # 换成你自己的校园网账号，或用环境变量 CAMPUS_USERNAME 传入
STAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_FILE="$LOG_DIR/minieap-$STAMP.log"
CAP_FILE="$CAP_DIR/minieap-$STAMP.pcap"

mkdir -p "$LOG_DIR" "$CAP_DIR"

if ! ifconfig "$IFACE" >/dev/null 2>&1; then
  IFACE="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
fi

if [ -z "${IFACE:-}" ]; then
  echo "找不到网卡。请插好网线后重新运行。"
  exit 1
fi

if [ ! -x "$MINIEAP" ]; then
  echo "找不到 MiniEAP: $MINIEAP"
  exit 1
fi

echo "=== MiniEAP 认证测试 ==="
echo "网卡: $IFACE"
echo "日志: $LOG_FILE"
echo "抓包: $CAP_FILE"
echo
echo "这一步用于生成失败样本，方便和官方锐捷成功包对比。"
echo "如果下面出现 Password，是 Mac 本机密码。校园网密码会单独提示，输入时不会显示。"
echo
read -s "CAMPUS_PASSWORD?请输入校园网密码: "
echo

sudo -v || exit 1
sudo pkill -9 minieap >/dev/null 2>&1 || true
sudo pkill -9 mentohust >/dev/null 2>&1 || true

sudo tcpdump -i "$IFACE" -s 0 -w "$CAP_FILE" 'ether proto 0x888e' &
TCPDUMP_PID=$!
sleep 2

{
  echo "time=$(date '+%F %T')"
  echo "iface=$IFACE"
  echo "cmd=$MINIEAP --if-impl libpcap --module rjv3 -u $USERNAME -p ****** -n $IFACE -a 1 -d 0 --heartbeat 30"
  echo
  sudo "$MINIEAP" --if-impl libpcap --module rjv3 \
    -u "$USERNAME" -p "$CAMPUS_PASSWORD" -n "$IFACE" \
    -a 1 -d 0 --heartbeat 30
  echo
  echo "exit_status=$?"
} 2>&1 | tee "$LOG_FILE"

sudo kill -INT "$TCPDUMP_PID" >/dev/null 2>&1 || true
wait "$TCPDUMP_PID" >/dev/null 2>&1 || true

echo
echo "MiniEAP 测试结束。"
echo "日志: $LOG_FILE"
echo "抓包: $CAP_FILE"
read "dummy?按回车关闭窗口..."
