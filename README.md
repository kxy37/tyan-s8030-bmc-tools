# tyan-s8030-bmc-tools

针对 **TYAN S8030 系列主板**（AMI MegaRAC BMC）两个原厂毛病的修复工具。

| 组件 | 解决什么 | 必需 |
|---|---|---|
| **`fanctl`** | CPU 风扇被固定在固定占空比、不随温度变化 → **改成按温度自动调速** | 是 |
| **`bmc-thresholds`** | 进风温度阈值过低 → 装显卡后**蜂鸣器长鸣、故障灯误报** → 修正并持久保持 | 否（可选） |

**先看清三个限制：**

1. **`fanctl` 只能控 CPU 风扇。** 厂商命令在 S8030GM2NE 上实测**只暴露 `0x00` 一个通道**
   （`0x01-0x0f` 全部无效），不是"没配置对"，是这台机器就这一个通道可用。
2. **3-pin 风扇无法软件调速**（没有 PWM 输入脚）。见 [§5.2](#52-3-pin-风扇调速无效)。
3. **`bmc-thresholds` 是降低一颗传感器的告警灵敏度**，不解决散热本身。
   它解决的是"误报"，不是"过热"。

三个共同点：只走主机带内 IPMI（`/dev/ipmi0`）；不刷固件、不装内核模块、不直接访问
BMC 寄存器；全部参数在配置文件里，除 `ipmitool` 外零依赖。

---

## 一、先判断你的板子有没有这两个毛病

```bash
# 1) CPU 风扇是不是恒定转速？
sudo ipmitool sdr type Fan | grep CPU_FAN      # 隔几分钟再看一次
#    温度变了转速完全不变 → 命中"固定转速"病 → 用 fanctl

# 2) 有没有反复的进风温度告警？
sudo ipmitool sel elist | grep -i "Upper Critical"
#    反复出现 MB_Air_Inlet ... Reading 50 > Threshold 50 → 用 bmc-thresholds
```

---

## 二、`fanctl` —— CPU 风扇温度曲线

### 原理

这块板的 BMC 不做温度调速，CPU 风扇出厂固定 30% 占空比（约 3450 RPM）。
但主板保留了厂商的 OEM IPMI 命令，可以直接设置某个风扇通道的占空比：

```bash
ipmitool raw 0x2e 0x44 0xfd 0x19 0x00 <风扇通道号> 0x01 <占空比 0x00~0x64>
#                                         ↑ 0x00 = CPU_FAN   ↑ 0x00~0x64 (0~100%)
```

`fanctl` 就是：**定时读 CPU 温度 → 按曲线算占空比 → 用上面这条命令下发**。

> 📖 主板手册 [p72 Hardware Health Configuration](docs/README.md) 印证了这一点：风扇策略只有
> `Fan Speed Control`（[Manual] / [Full Speed]）和 `PWM Minimal Duty Cycle` 两个选项，
> **没有温度曲线**。所以"按温度调速"只能在主机侧实现。
> （同页还写明：装了 GeForce/Quadro 显卡时应把 `Fan Speed Control` 改成 `[Full Speed]`。）

### 实测效果（S8030GM2NE + EPYC 7K62）

| CPU 温度 | 占空比 | CPU 风扇转速 |
|---|---|---|
| ≤45°C（空载） | 30% | 3450–3588 RPM |
| 56°C | 42% | 4278 RPM |
| 61°C | 49% | 4692 RPM |
| 63°C | 52% | 4830 RPM |
| —（手动拉满测试） | 100% | 7314 RPM |

> 占空比 → 转速基本线性，可用来自估其它取值。

### 配置

`/etc/fanctl.conf`（可选，不存在则用内置默认值），完整注释见 `fanctl.conf.example`：

```ini
fan_idx     = 0x00      # CPU 风扇通道号
temp_sensor = 0x01      # 温度传感器编号（S8030: 0x01 = CPU_Tctl_Value）
curve       = 45:30, 55:40, 65:55, 75:78, 85:100
min_duty    = 30        # 默认 = 出厂占空比，保证不会比原厂更热
```

```bash
sudo fanctl.py --show-config     # 确认解析正确
sudo systemctl restart fanctl    # 生效
```

**调曲线**：想更安静 → 各点温度整体调高 5–10°C；想更凉快 → 各点占空比整体调高 10–20%。

---

## 三、`bmc-thresholds`（可选）—— 修正进风阈值误报

### 现象

装了 GeForce / Quadro 显卡后蜂鸣器长鸣、主板亮红灯，BMC 事件日志里反复出现：

```
Temperature MB_Air_Inlet | Upper Critical going high | Reading 50 > Threshold 50
```

### 原因

`MB_Air_Inlet` 是主板上的进风区温度传感器，出厂**标称 32°C、上限只有 50°C**。

> 📖 手册 [p141–144 Appendix II](docs/README.md) 给出了它的定义和板图位置 ——
> "Temperature of the M/B Air Inlet Area"，位于主板下边缘、**紧贴 SYS_FAN2/FAN3 插座旁**。

装上显卡后，显卡散热鳍片的尾气**正好吹在这颗传感器上**，于是它测到的其实是显卡尾气温度。

**为什么敢调高**：实测这颗读数（45–50°C）比"出风"传感器（43–47°C）还高 ——
物理上倒挂（空气穿过机箱只会被加热，进风本该是最冷的一点），说明它已经不在测进风了。
同时其余四道防线全部保持原值不动：CPU 95°C、内存区 85°C、供电 MOSFET 110°C、出风 70°C。

### 为什么需要"服务 + 定时器"而不是一条命令

**这块 BMC 在完全断电（拔电源线）后，会把可设阈值恢复成出厂值。**
单独执行一次 `ipmitool sensor thresh ...` 会在下次断电后失效。

所以用 `bmc-thresholds.timer`：**开机 30 秒后**及**每 10 分钟**检查一次，
读实际生效值，与目标不符才写回（幂等，不会反复刷写）。

> 这个坑是实测踩出来的：手动改成 75°C 后拔了一次电源，阈值悄悄回到 50°C，蜂鸣器又响了。

### 配置

`/etc/bmc-thresholds.conf`，每行一条，可写多行：

```
<传感器名> <传感器编号(16进制)> <目标上限°C>

MB_Air_Inlet 0x32 75
```

```bash
sudo bmc-thresholds.sh                              # 立即应用/检查一次
sudo systemctl enable --now bmc-thresholds.timer
```

### ⚠️ 读取阈值的陷阱

**`ipmitool sdr get <名>` 显示的是 SDR 记录里的出厂规格值，永远不变** ——
即使你已经改成功，它照样显示 50。判断是否生效要用下面三种之一：

```bash
sudo ipmitool raw 0x04 0x27 0x32
#   输出如 10 00 00 00 00 4b 00
#   字节序 = [读数, LNC, LCR, LNR, UNC, UCR, UNR]，第 6 字节 0x4b = 75 ← 实际生效值

sudo ipmitool sensor get MB_Air_Inlet | grep -i "Upper critical"   # 75.000 ✓
sudo ipmitool sensor | grep MB_Air_Inlet                            # 表格形式 ✓
```

---

## 四、安装

```bash
sudo ./install.sh --with-thresholds --enable   # 两个组件都装并启用
sudo ./install.sh --enable                     # 只装 fanctl
sudo ./install.sh --with-thresholds            # 先装不启用（推荐）
```

自检项：root、Linux、systemd、python3(≥3.7)、ipmitool、`/dev/ipmi0`。

> `/dev/ipmi0` 不存在时：
> ```bash
> sudo modprobe ipmi_si ipmi_devintf
> echo -e "ipmi_si\nipmi_devintf" | sudo tee /etc/modules-load.d/ipmi.conf
> ```

### 推荐：先验证再启用

```bash
sudo /usr/local/sbin/fanctl.py --show-config      # 只看配置，不动作
sudo /usr/local/sbin/fanctl.py --dry-run --once   # 演练，不下发
sudo /usr/local/sbin/fanctl.py --once             # 真下发一次
sudo ipmitool sdr type Fan | grep CPU_FAN         # 转速变了吗？
```

转速变了 → 启用：

```bash
sudo systemctl enable --now fanctl.service
sudo systemctl enable --now bmc-thresholds.timer   # 装了就启用
sudo journalctl -u fanctl -f
```

转速没变 → 见下节。

---

## 五、排错

### 5.1 转速不跟着变

先用原始命令把 CPU 风扇拉满，判断是"命令无效"还是"风扇不支持"：

```bash
sudo ipmitool raw 0x2e 0x44 0xfd 0x19 0x00 0x00 0x01 0x64   # 通道 0x00 拉 100%
sudo ipmitool sdr type Fan | grep CPU_FAN
```

| 结果 | 判断 | 下一步 |
|---|---|---|
| 转速上去 | 命令有效 | 检查配置里 `fan_idx` / `temp_sensor` 是否配对 |
| 转速没变 | 命令无效**或**风扇是 3-pin | 先看 [§5.2](#52-3-pin-风扇调速无效) |
| 返回 `0xc1 Invalid command` | 命令在你的板子上不支持 | 见 [§5.3](#53-命令返回-0xc1) |

### 5.2 3-pin 风扇调速无效

**这是"没反应"最常见的原因。**

3-pin 风扇只有 **12V / GND / 测速** 三根线，**没有 PWM 输入脚**，拿到的是恒定 12V，
所以无论占空比写多少转速都不变。**只能换 4-pin PWM 风扇**
（或改用支持电压调速的硬件，服务器主板通常不支持）。

判断方法：看风扇插头是 3 根还是 4 根线；或软件对比：

```bash
sudo ipmitool raw 0x2e 0x44 0xfd 0x19 0x00 0x00 0x01 0x1e   # 30%
sleep 6; sudo ipmitool sdr type Fan | grep CPU_FAN
sudo ipmitool raw 0x2e 0x44 0xfd 0x19 0x00 0x00 0x01 0x64   # 100%
sleep 6; sudo ipmitool sdr type Fan | grep CPU_FAN
```

两次转速相同 → 该风扇不受 PWM 控制。

> **实测情况（S8030GM2NE）**：CPU 风扇是 4-pin，可以调速；
> 机箱风扇是 3-pin，不可调速，且本来就在固定满速运行。

### 5.3 命令返回 `0xc1`

`0x2e 0x44` 是 **TYAN 专用**命令，别的厂商用别的 netfn：

| 厂商 | OEM netfn | 备注 |
|---|---|---|
| TYAN | `0x2e` | 本项目适用 |
| Supermicro | `0x30` | 命令形如 `raw 0x30 0x70 0x66 0x01 0x00 0x<占空比>`（据社区工具实现，未在超微机器上验证）|

### 5.4 想控其它风扇（注意：很可能做不到）

厂商命令在 S8030GM2NE 上只暴露了 `0x00`（CPU_FAN）。其它通道即使去写，
风扇转速也不会变 —— **这是预期行为，不是配置错误**。

想碰运气可以扫一遍（不同型号的通道号确实可能不同：社区在 **S8030GM4NE-2T** 上
报告过 `0x00=cpu, 0x02=机箱, 0x03=硬盘, 0x04=PCIE`）：

```bash
for idx in 0x00 0x01 0x02 0x03 0x04 0x05; do
  echo "--- idx=$idx 拉满 ---"
  sudo ipmitool raw 0x2e 0x44 0xfd 0x19 0x00 $idx 0x01 0x64
  sleep 5
  sudo ipmitool sdr type Fan | grep -E "CPU_FAN|SYS_FAN_[1-4] "
done
```

扫不出来又想控多个风扇 → 见 [`docs/alternatives.md`](docs/alternatives.md)。

### 5.5 温度读不到

```bash
sudo ipmitool sdr elist | grep -iE "cpu|temp"   # 找 CPU 传感器及其编号
sudo ipmitool raw 0x04 0x2d 0x01                # 返回 4 个字节，第 1 个 = 温度(16进制)
```

第 2 个字节的 **bit5 置位**表示"读数不可用"（`fanctl` 会识别并切保底转速）。

### 5.6 蜂鸣器还是响

```bash
sudo ipmitool raw 0x04 0x27 0x32        # 第 6 字节应为 4b (=75)
systemctl status bmc-thresholds.timer   # 定时器在跑吗
sudo ipmitool sel elist | grep -i "Upper Critical" | tail -5   # 到底哪颗在触发
```

如果阈值已是 75 但还在响，说明触发的是**另一颗**传感器，看最后一行确认名字和编号，
再按同样格式加进 `/etc/bmc-thresholds.conf`。

---

## 六、安全设计

| 机制 | 说明 |
|---|---|
| `min_duty` 下限 | 默认 = 出厂占空比 30%，**任何时候都不会比原厂更热** |
| `max_step` / `deadband` | 每周期最多变 15%；小于 2% 不动作，避免抖动 |
| `failsafe_duty` 保底 | 读不到温度或异常 → 切 60%，**绝不把"读不到"当"很凉"** |
| SIGTERM + `ExecStopPost` | 停止服务时主动恢复保底转速，systemd 再兜一次 |
| `Restart=always` | 进程崩溃自动拉起 |
| 阈值脚本幂等 | 只在值不符时写，不会反复刷 BMC |
| 阈值定时器 | 断电复位后自动补回 |

**完全撤销**：`sudo ./uninstall.sh --with-thresholds`
（会先把 CPU 风扇放到 60%，再删文件；阈值需手动改回，或断电重启让 BMC 自恢复出厂值）

---

## 七、出处与致谢

**风扇曲线用的 OEM 命令不是本项目发现的**：

- **原始发现**：Chiphell 用户 wangmice
  《[今天无意中发现泰安S8030通过ipmi控制风扇速度的命令](https://www.chiphell.com/thread-2604921-1-1.html)》
- **参考实现**：[BiteMeIfYouCan/TYANS8030FAN](https://github.com/BiteMeIfYouCan/TYANS8030FAN)（Python，多分区曲线）、
  [sonmihpc/AutoFan](https://github.com/sonmihpc/AutoFan)（Go，GPU 温度驱动）
- **其它方案对比（含 p2afan）**：见 [`docs/alternatives.md`](docs/alternatives.md)
- **官方手册**：收录在 [`docs/`](docs/README.md)，含页码导航

本项目为独立实现，未复制上述项目的代码。

---

## 八、常见问题

**Q：会不会把风扇/主板搞坏？**
不会。只下发占空比、只改传感器告警阈值，用的是主板厂商自己实现的 OEM 接口
（注意：`0x2e 0x44` 是**厂商私有命令，不是标准 IPMI 命令**，换厂商就失效）。
不刷固件、不装内核模块、不直接访问 BMC 寄存器。停止服务即恢复原状。

**Q：为什么只控 CPU 风扇，不控机箱风扇？**
两个独立的原因，都要满足才能控：
1. **厂商命令只暴露了 CPU_FAN 一个通道**（本板实测 `0x01-0x0f` 全部无效）——
   这一条与风扇类型无关，就算机箱风扇换成 4-pin 也还是控不了；
2. 机箱风扇通常是 3-pin，本来就不受 PWM 控制。
要控多个风扇请参考 [`docs/alternatives.md`](docs/alternatives.md)。

**Q：超微 / 其它厂商的主板能用吗？**
`fanctl` 不行（netfn 不同，见 §5.3）。`bmc-thresholds` 的原理可照搬，但各家 BMC
的断电复位行为不同，需要自行验证，改配置文件里的传感器名和编号即可。

**Q：内存不识别、某个通道缺失之类的问题能顺便解决吗？**
不能。那是硬件故障（例如 CPU 插座弯针），本项目只处理 BMC 的两个软件层毛病。

---

## 九、许可

MIT，见 `LICENSE`。
