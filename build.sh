#!/bin/bash
# LockNotifyBG 一键构建脚本
# 用法: ./build.sh          # 编译
#       ./build.sh install  # 编译并安装到设备（需配置 THEOS_DEVICE_IP）

set -e

cd "$(dirname "$0")"

echo "==> 检查 Theos 环境"
if [ -z "$THEOS" ]; then
    if [ -d "$HOME/theos" ]; then
        export THEOS="$HOME/theos"
    else
        echo "错误: 未找到 Theos，请先设置 \$THEOS 环境变量"
        exit 1
    fi
fi
echo "THEOS = $THEOS"

echo "==> 清理旧构建"
make clean 2>/dev/null || true

echo "==> 编译 LockNotifyBG"
make package

echo "==> 构建完成，产物:"
ls -lh packages/*.deb 2>/dev/null || echo "未生成 deb，请检查上方报错"

if [ "$1" == "install" ]; then
    if [ -z "$THEOS_DEVICE_IP" ]; then
        echo "错误: 安装需设置 THEOS_DEVICE_IP，例如:"
        echo "  export THEOS_DEVICE_IP=192.168.1.100"
        echo "  export THEOS_DEVICE_PORT=22"
        exit 1
    fi
    echo "==> 安装到设备 $THEOS_DEVICE_IP"
    make install
    echo "==> 安装完成，SpringBoard 将自动重启"
fi
