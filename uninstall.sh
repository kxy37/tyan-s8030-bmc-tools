#!/bin/sh
# tyan-s8030-bmc-tools 卸载脚本
#
# 用法：
#   sudo ./uninstall.sh                      # 只卸风扇曲线
#   sudo ./uninstall.sh --with-thresholds    # 连 BMC 阈值修正一起卸
#
# 卸载前会先把风扇放回一个安全转速，不会把它留在曲线最后一次算出的低速值上。
set -eu

WITH_THRESHOLDS=0
for arg in "$@"; do
    case "$arg" in
        --with-thresholds) WITH_THRESHOLDS=1 ;;
        *) printf '未知参数: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

fail() { printf 'uninstall: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || fail "需要 root 权限（sudo ./uninstall.sh）"

# ---------------------------------------------------------------------------
echo "==> 停止并禁用服务"
systemctl disable --now fanctl.service 2>/dev/null || true

echo "==> 把 CPU 风扇放回一个安全转速（60%，通道 0x00）"
echo "    注意：不同主板通道号可能不同，请自行确认"
if command -v ipmitool >/dev/null 2>&1; then
    ipmitool raw 0x2e 0x44 0xfd 0x19 0x00 0x00 0x01 0x3c 2>/dev/null \
        && echo "    已下发 60%" \
        || echo "    下发失败（可忽略：BMC 会按自己的策略接管）"
fi

echo "==> 删除风扇曲线相关文件"
rm -f /etc/systemd/system/fanctl.service /usr/local/sbin/fanctl.py

if [ "$WITH_THRESHOLDS" -eq 1 ]; then
    echo
    echo "==> 卸载 BMC 阈值修正"
    systemctl disable --now bmc-thresholds.timer 2>/dev/null || true
    rm -f /etc/systemd/system/bmc-thresholds.service \
          /etc/systemd/system/bmc-thresholds.timer \
          /usr/local/sbin/bmc-thresholds.sh
    echo "    ⚠️  注意：BMC 里已修改的阈值**不会**自动还原。"
    echo "        如需还原，手工执行（以 TYAN S8030 的进风传感器为例）："
    echo "          sudo ipmitool sensor thresh MB_Air_Inlet ucr 50"
fi

systemctl daemon-reload

echo
echo "==> 卸载完成。配置文件已保留（方便以后重装）："
echo "      /etc/fanctl.conf"
[ "$WITH_THRESHOLDS" -eq 1 ] && echo "      /etc/bmc-thresholds.conf"
echo "    如需一起删除："
echo "      sudo rm -f /etc/fanctl.conf /etc/bmc-thresholds.conf /etc/systemd/system/fanctl.service"
