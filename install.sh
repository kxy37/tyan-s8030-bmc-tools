#!/bin/sh
# tyan-s8030-bmc-tools 安装脚本
#
# 用法：
#   sudo ./install.sh                      # 只装风扇曲线（组件 1）
#   sudo ./install.sh --with-thresholds    # 同时装 BMC 阈值修正（组件 2，可选）
#   sudo ./install.sh --enable             # 装完立即启动
#   sudo ./install.sh --with-thresholds --enable
#
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WITH_THRESHOLDS=0
ENABLE=0

for arg in "$@"; do
    case "$arg" in
        --with-thresholds) WITH_THRESHOLDS=1 ;;
        --enable)          ENABLE=1 ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) printf '未知参数: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

fail() { printf 'install: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 环境检查
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || fail "需要 root 权限（sudo ./install.sh）"
[ "$(uname -s)" = Linux ] || fail "仅支持 Linux"
command -v systemctl >/dev/null 2>&1 || fail "需要 systemd"
command -v python3    >/dev/null 2>&1 || fail "需要 python3"
command -v ipmitool   >/dev/null 2>&1 || fail "需要 ipmitool（apt install ipmitool / dnf install ipmitool）"
[ -e /dev/ipmi0 ] || fail "/dev/ipmi0 不存在，请先加载 ipmi 驱动：
    sudo modprobe ipmi_si ipmi_devintf
    echo -e 'ipmi_si\\nipmi_devintf' | sudo tee /etc/modules-load.d/ipmi.conf"

python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' \
    || fail "需要 Python 3.7 或更高版本"

# ---------------------------------------------------------------------------
# 组件 1：风扇温度曲线
# ---------------------------------------------------------------------------
echo "==> [1/2] 安装风扇温度曲线 (fanctl)"
install -o root -g root -m 0755 "$HERE/fanctl.py"      /usr/local/sbin/fanctl.py
install -o root -g root -m 0644 "$HERE/fanctl.service" /etc/systemd/system/fanctl.service

if [ ! -e /etc/fanctl.conf ]; then
    install -o root -g root -m 0644 "$HERE/fanctl.conf.example" /etc/fanctl.conf
    echo "    已放置默认配置 /etc/fanctl.conf"
else
    echo "    已存在 /etc/fanctl.conf，保持不动"
fi

python3 -m py_compile /usr/local/sbin/fanctl.py && echo "    Python 语法 OK"

# ---------------------------------------------------------------------------
# 组件 2（可选）：BMC 传感器阈值修正
# ---------------------------------------------------------------------------
if [ "$WITH_THRESHOLDS" -eq 1 ]; then
    TDIR="$HERE/optional/bmc-thresholds"
    [ -d "$TDIR" ] || fail "找不到 $TDIR"

    echo
    echo "==> [2/2] 安装 BMC 阈值修正 (bmc-thresholds)"
    install -o root -g root -m 0755 "$TDIR/bmc-thresholds.sh"      /usr/local/sbin/bmc-thresholds.sh
    install -o root -g root -m 0644 "$TDIR/bmc-thresholds.service" /etc/systemd/system/bmc-thresholds.service
    install -o root -g root -m 0644 "$TDIR/bmc-thresholds.timer"   /etc/systemd/system/bmc-thresholds.timer

    if [ ! -e /etc/bmc-thresholds.conf ]; then
        install -o root -g root -m 0644 "$TDIR/bmc-thresholds.conf.example" /etc/bmc-thresholds.conf
        echo "    已放置默认配置 /etc/bmc-thresholds.conf"
    else
        echo "    已存在 /etc/bmc-thresholds.conf，保持不动"
    fi

    bash -n /usr/local/sbin/bmc-thresholds.sh && echo "    脚本语法 OK"
    echo "    ⚠️  该组件会修改 BMC 传感器告警阈值 —— 先看清楚 /etc/bmc-thresholds.conf 里的注释再启用"
else
    echo
    echo "==> [2/2] 跳过可选组件 BMC 阈值修正"
    echo "    需要的话执行:  sudo ./install.sh --with-thresholds"
fi

# ---------------------------------------------------------------------------
systemctl daemon-reload
echo
echo "==> 显示当前生效配置"
/usr/local/sbin/fanctl.py --show-config | sed 's/^/    /'

echo
echo "==> 安装完成。建议先手动验证（不要直接启用）："
echo "    sudo /usr/local/sbin/fanctl.py --dry-run --once    # 演练，绝不下发"
echo "    sudo /usr/local/sbin/fanctl.py --once              # 真下发一次"
echo "    sudo ipmitool sdr type Fan | grep CPU_FAN          # 看转速是否变化"

if [ "$ENABLE" -eq 1 ]; then
    echo
    echo "==> 启用并启动服务"
    systemctl enable --now fanctl.service
    [ "$WITH_THRESHOLDS" -eq 1 ] && systemctl enable --now bmc-thresholds.timer
    sleep 3
    echo "    fanctl.service       = $(systemctl is-active fanctl.service)"
    [ "$WITH_THRESHOLDS" -eq 1 ] && echo "    bmc-thresholds.timer = $(systemctl is-active bmc-thresholds.timer)"
    echo
    systemctl --no-pager --full status fanctl.service | head -12
else
    echo
    echo "==> 服务尚未启用。确认无误后执行："
    echo "    sudo systemctl enable --now fanctl.service"
    [ "$WITH_THRESHOLDS" -eq 1 ] && echo "    sudo systemctl enable --now bmc-thresholds.timer"
fi
