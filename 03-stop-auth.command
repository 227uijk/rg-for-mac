#!/bin/zsh
echo "清理可能残留的认证进程。下面如果出现 Password，是 Mac 本机密码。"
sudo pkill -9 minieap >/dev/null 2>&1 || true
sudo pkill -9 mentohust >/dev/null 2>&1 || true
pkill -9 Supplicant >/dev/null 2>&1 || true
echo "已清理 minieap / mentohust / Supplicant。"
read "dummy?按回车关闭窗口..."
