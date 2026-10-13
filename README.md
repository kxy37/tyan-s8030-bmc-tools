# tyan-s8030-bmc-tools

针对 **TYAN S8030 系列主板**（AMI MegaRAC BMC）两个"原厂毛病"的小工具集。

| 组件 | 解决的问题 | 是否必需 |
|---|---|---|
| **`fanctl`** | CPU 风扇被钉死在固定转速，不随温度变化 → **让 CPU 风扇按温度自动调速** | 核心 |
| **`bmc-thresholds`** | 主板进风温度传感器阈值过低，装了显卡后**蜂鸣器长鸣 + 故障灯误报** → 修正阈值并保持 | **可选** |

两者都跑在**操作系统侧**，通过主机带内 IPMI（`/dev/ipmi0`）与 BMC 通信，
**不刷固件、不改 BMC、不写寄存器**。停止服务即恢复原状。

- 纯 Shell / Python，除 `ipmitool` 外**零依赖**
- 不需要 lm-sensors / storcli / smartctl
- 所有参数（风扇通道、传感器编号、曲线、阈值）都在配置文件里

---

## 一、先看你的板子是不是这样

```bash
# 1) CPU 风扇是不是恒定转速？
sudo ipmitool sdr type Fan | grep CPU_FAN
#    隔一会儿再看一次：如果温度变了转速完全不变 → 就是"固定转速"病

# 2) 有没有蜂鸣器/故障灯误报？（看 BMC 事件日志）
sudo ipmitool sel elist | grep -i "Upper Critical"
#    如果反复出现 MB_Air_Inlet ... Reading 50 > Threshold 50
#    → 就是阈值过低引起的误报
```

---

## 二、组件 1：`fanctl` —— CPU 风扇温度曲线

### 原理

TYAN S8030 的 BMC **不做温度调速**，CPU 风扇出厂固定 30% 占空比（约 3450 RPM），
无论 CPU 多热都不动。这块板保留了厂商的 **OEM IPMI 命令**，可以直接设置
某个风扇通道的占空比：

```bash
ipmitool raw 0x2e 0x44 0xfd 0x19 0x00 <风扇通道号> 0x01 <占空比 0x00~0x64>
#                                         ↑ 0x00 = CPU_FAN      ↑ 0x00~0x64 (0~100%)
```

`fanctl` 就是：**定时读 CPU 温度 → 按曲线算目标占空比 → 用上面这条命令下发**。

> 📖 **依据**：主板手册 [p72 Hardware Health Configuration](docs/README.md) 说明了这个风扇策略 ——
> 只有 `Fan Speed Control`（[Manual] / [Full Speed]）和 `PWM Minimal Duty Cycle` 两个选项，
> **没有温度曲线这种东西**。所以"按温度调速"只能在主机侧自己实现。
> （顺带：手册 p72 还写明，装了 GeForce/Quadro 显卡时应把 `Fan Speed Control` 改成 `[Full Speed]`。）

### 实测效果（S8030GM2NE + EPYC 7K62）

| CPU 温度 | 占空比 | CPU 风扇转速 |
|---|---|---|
| 45°C（空载） | 30% | 3450 ~ 3588 RPM |
| 56°C | 42% | 4278 RPM |
| 61°C | 49% | 4692 RPM |
| 63°C | 52% | 4830 RPM |
| — | 100% | 7314 RPM |

### 配置

`/etc/fanctl.conf`（可选，不创建就用内置默认值），完整注释见 `fanctl.conf.example`：

```ini
fan_idx     = 0x00      # CPU 风扇通道号
temp_sensor = 0x01      # 温度传感器编号（S8030: 0x01 = CPU_Tctl_Value）
curve       = 45:30, 55:40, 65:55, 75:78, 85:100
min_duty    = 30        # 建议 = 出厂占空比，保证不会比原厂更热
```

```bash
sudo fanctl.py --show-config     # 确认解析正确
sudo systemctl restart fanctl    # 生效
```

**调曲线**：想更安静 → 各点温度整体调高 5~10°C；想更凉快 → 各点占空比整体调高 10~20%。

---

## 三、组件 2（可选）：`bmc-thresholds` —— 修正进风阈值误报

### 问题现象

装了 GeForce / Quadro 显卡后，**蜂鸣器长鸣、主板亮红灯**，BMC 事件日志里反复出现：

```
Memory ... / Temperature MB_Air_Inlet | Upper Critical going high | Reading 50 > Threshold 50
```

### 原因

`MB_Air_Inlet` 是主板上的**进风区温度**传感器，出厂设定**标称 32°C、上限只有 50°C**。

> 📖 **依据**：主板手册 [p141–144 Appendix II: Fan and Temp Sensors](docs/README.md) 给出了它的
> 定义和板图位置 —— "Temperature of the M/B Air Inlet Area"，位于主板下边缘、
> **紧贴 SYS_FAN2/FAN3 插座旁**。

装上显卡后，显卡散热鳍片的尾气**正好吹在这颗传感器上**，于是它测到的其实是
**显卡尾气温度**，很容易撞到 50°C 触发告警。

> **为什么可以放心调高**：实测这颗读数（45~50°C）比"出风"传感器（43~47°C）还高 ——
> 物理上倒挂（空气穿过机箱只会被加热，进风本该是最冷的一点），说明它已经不在测进风了。
> 同时其余所有温度传感器都有充裕余量，所以只调这一颗**不影响整机保护**：
> CPU（95）、内存区（85）、供电 MOSFET（110）、出风（70）四道独立防线全部不动。

### 为什么需要一个"服务 + 定时器"，而不是一条命令

**很多 BMC 在完全断电（拔电源线）后，会把可设阈值恢复成出厂默认值。**
单独执行 `ipmitool sensor thresh ...` 会在下次断电后失效。

所以这里用 `bmc-thresholds.timer`：**开机 30 秒后**以及**每 10 分钟**检查一次，
读当前实际生效值 → 与目标不符才写回（幂等，不会反复刷写）。

> 本项目的作者就是**真实踩过这个坑**：手动改好 75°C 之后拔了一次电源，
> 阈值悄悄回到 50°C，蜂鸣器又响了。所以才有了这个定时器。

### 配置

`/etc/bmc-thresholds.conf`，每行一条：

```
<传感器名> <传感器编号(16进制)> <目标上限°C>

MB_Air_Inlet 0x32 75
```

```bash
sudo bmc-thresholds.sh                       # 立即应用/检查一次
sudo systemctl enable --now bmc-thresholds.timer
```

### ⚠️ 读取阈值的陷阱

**`ipmitool sdr get <名>` 显示的是 SDR 记录里的出厂规格值，永远不变**，
不能用来判断你到底改成功没有（即使已生效，它照样显示 50）。

要看**实际生效值**，用这三种之一：

```bash
sudo ipmitool raw 0x04 0x27 0x32
#   输出如 10 00 00 00 00 4b 00
#   字节序 = [读数, LNC, LCR, LNR, UNC, UCR, UNR]
#   第 6 字节 0x4b = 75  ← 这才是实际生效值

sudo ipmitool sensor get MB_Air_Inlet | grep -i "Upper critical"   # 75.000 ✓
sudo ipmitool sensor | grep MB_Air_Inlet                            # 表格形式 ✓
```

---

## 四、安装

```bash
# 只装风扇曲线
sudo ./install.sh --enable

# 风扇曲线 + 阈值修正
sudo ./install.sh --with-thresholds --enable

# 先装不启用（推荐，先手工验证）
sudo ./install.sh --with-thresholds
```

脚本会自检：root、Linux、systemd、python3(≥3.7)、ipmitool、`/dev/ipmi0`。

> 若 `/dev/ipmi0` 不存在：
> ```bash
> sudo modprobe ipmi_si ipmi_devintf
> echo -e "ipmi_si\nipmi_devintf" | sudo tee /etc/modules-load.d/ipmi.conf
> ```

### 推荐流程：先验证再启用

**第一次务必先做安全演练**，确认命令在你的板子上真的有效：

```bash
sudo /usr/local/sbin/fanctl.py --show-config      # 只看配置
sudo /usr/local/sbin/fanctl.py --dry-run --once   # 演练，不下发
sudo /usr/local/sbin/fanctl.py --once             # 真下发一次
sudo ipmitool sdr type Fan | grep CPU_FAN         # 看转速有没有变
```

转速变了 → 启用服务；没变 → 见下面的排错。

```bash
sudo systemctl enable --now fanctl.service
sudo systemctl enable --now bmc-thresholds.timer   # 如果装了组件 2
sudo journalctl -u fanctl -f
```

---

## 五、排错

### 1. 转速不跟着变

先直接用命令把风扇拉满，确认命令本身有效：

```bash
sudo ipmitool raw 0x2e 0x44 0xfd 0x19 0x00 0x00 0x01 0x64
sudo ipmitool sdr type Fan | grep CPU_FAN
```

**（a）转速上去了** → 命令有效，检查 `fan_idx` / `temp_sensor` 是否配对。

**（b）转速没变 → 先看风扇是不是 3-pin。**

> ### ⚠️ 3-pin 风扇不受 PWM 控制（最常见的"没反应"原因）
>
> 3-pin 风扇只有 **12V / GND / 测速** 三根线，**没有 PWM 输入脚**，
> 拿到的是恒定 12V，所以无论占空比写多少，转速都不变。
> **这种风扇只能通过电压调速（主板通常不支持），或者换 4-pin PWM 风扇。**
>
> 判断方法：看风扇插头是 3 根还是 4 根线。或者软件验证：
> ```bash
> sudo ipmitool raw 0x2e 0x44 0xfd 0x19 0x00 0x00 0x01 0x1e   # 30%
> sleep 6; sudo ipmitool sdr type Fan | grep CPU_FAN
> sudo ipmitool raw 0x2e 0x44 0xfd 0x19 0x00 0x00 0x01 0x64   # 100%
> sleep 6; sudo ipmitool sdr type Fan | grep CPU_FAN
> ```
> 两次转速一样 → 这个风扇不受 PWM 控制。
>
> **注意**：本项目作者的机器上，**CPU 风扇是 4-pin（可调），而机箱风扇是 3-pin（不可调）**。
> 所以本工具只控 CPU 风扇；机箱风扇想调速必须先换 4-pin 风扇。

**（c）命令返回 `0xc1 Invalid command`**

`0x2e 0x44` 这条命令是 **TYAN 的**。别的厂商用别的 netfn：

| 厂商 | OEM netfn | 备注 |
|---|---|---|
| TYAN | `0x2e` | 本项目适用 |
| Supermicro | `0x30` | 命令形如 `raw 0x30 0x70 0x66 0x01 0x00 0x<占空比>` |

**（d）命令有效但通道号不对**

同一厂商不同型号的通道号也可能不同。以 S8030 为例，社区脚本在
**S8030-2T / GM4NE-2T** 上是 `0x00=cpu, 0x02=机箱, 0x03=硬盘, 0x04=PCIE`，
但在 **S8030GM2NE** 上实测**只有 `0x00`（CPU 风扇）有效**。

扫描方法：

```bash
for idx in 0x00 0x01 0x02 0x03 0x04 0x05; do
  echo "--- idx=$idx 拉满 ---"
  sudo ipmitool raw 0x2e 0x44 0xfd 0x19 0x00 $idx 0x01 0x64
  sleep 5
  sudo ipmitool sdr type Fan | grep -E "CPU_FAN|SYS_FAN_[1-4] "
done
```

### 2. 温度读不到

```bash
sudo ipmitool sdr elist | grep -iE "cpu|temp"   # 找 CPU 对应的传感器和编号
sudo ipmitool raw 0x04 0x2d 0x01                # 返回 4 字节，第 1 字节 = 温度(16进制)
```

返回的第 2 字节 **bit5 置位**表示"读数不可用"（`fanctl` 会识别并切保底转速）。

### 3. 蜂鸣器还是响

```bash
# 确认阈值真的生效了（别被 sdr get 骗了，见上文"读取阈值的陷阱"）
sudo ipmitool raw 0x04 0x27 0x32
# 第 6 字节应该是 4b (75)

# 确认定时器在跑
systemctl status bmc-thresholds.timer
sudo journalctl -u bmc-thresholds -n 20
```

如果阈值是 75 但还在响，说明触发的不是这颗传感器 —— 查 SEL 里最后一条 Critical：

```bash
sudo ipmitool sel elist | grep -i "Upper Critical" | tail -5
```

---

## 六、安全设计

| 机制 | 说明 |
|---|---|
| `min_duty` 下限 | 默认 = 出厂占空比（30%），**任何时候都不会比原厂更热** |
| `max_step` 限速 | 每周期最多变化 15%，避免转速突变 |
| `deadband` 死区 | 2%，防止在曲线拐点来回抖动 |
| `failsafe_duty` 保底 | 读不到温度 / 异常 → 切 60%，**绝不把"读不到"当作"很凉"处理** |
| SIGTERM 处理 | 被 `systemctl stop` 时主动恢复保底转速 |
| `ExecStopPost` | 即使程序没来得及处理信号，systemd 再兜一次 |
| `Restart=always` | 进程崩溃自动拉起 |
| 阈值脚本幂等 | 只在值不符时才写，不会反复刷 BMC |
| 阈值定时器 | 断电后自动补回被 BMC 复位的阈值 |

**完全撤销**：`sudo ./uninstall.sh --with-thresholds`（会先把风扇放回 60% 再删文件）

---

## 七、出处与致谢

**风扇曲线用到的 OEM 命令不是本项目发现的**，出处：

- **原始发现**：Chiphell 论坛用户 wangmice
  《[今天无意中发现泰安S8030通过ipmi控制风扇速度的命令](https://www.chiphell.com/thread-2604921-1-1.html)》
- **参考实现**：
  - [BiteMeIfYouCan/TYANS8030FAN](https://github.com/BiteMeIfYouCan/TYANS8030FAN) —— Python，多分区曲线
  - [sonmihpc/AutoFan](https://github.com/sonmihpc/AutoFan) —— Go，GPU 温度驱动
- **寄存器级方案（本项目未采用）**：
  [larkinwc/p2afan](https://github.com/larkinwc/p2afan) —— 它**绕开厂商的 IPMI 命令**，
  从主机侧经 ASPEED 的 P2A 桥直接写 PWM 占空比寄存器。

  注意它的**执行方式和本项目是同一个层级**（都是写 ASPEED 的 PWM 占空比寄存器），
  区别只在于用什么途径去写。所以：

  | | 本项目（fanctl） | p2afan |
  |---|---|---|
  | 写入对象 | ASPEED PWM 占空比寄存器 | **同一个寄存器** |
  | 途径 | 厂商 IPMI 命令 `0x2e 0x44`（经 BMC 转发） | 主机侧 P2A 桥直接写 |
  | 能控几个通道 | **只有厂商命令暴露的那些**（S8030GM2NE 上实测只有 CPU_FAN） | **全部** PWM 通道 |
  | 依赖 | 需要厂商命令存在 | 不依赖厂商命令，但要 P2A 桥可用 |
  | 4-pin 风扇 | ✅ 可控 | ✅ 可控 |
  | **3-pin 风扇** | ❌ **控不了** | ❌ **同样控不了** |

  **所以：p2afan 的强项是"多通道"和"不依赖厂商命令"，不是"能控 3-pin 风扇"。**
  3-pin 风扇没有 PWM 输入脚是**硬件层面**的限制，换任何软件都绕不过 ——
  只能换 4-pin 风扇（或改用支持电压调速的硬件，但服务器主板通常不支持）。
  本站实测见上文「3-pin 风扇不受 PWM 控制」。

  **什么时候该用它**：你需要给**多个风扇各自一条曲线**（例如 2 张显卡 + 硬盘笼 +
  CPU 分别按不同温度调速），而厂商命令只暴露了一个通道 —— 这时 p2afan 是唯一选择。

本项目的实现是独立的，未复制上述项目的代码。

### 参考资料

仓库 [`docs/`](docs/) 里收录了 **TYAN/MiTAC 官方主板手册**
（`S8030_v2.0c_031326.pdf`，Rev 2.0c，156 页），并对本项目相关的页码做了导航，
方便你核对本文的技术判断：

| 页码 | 内容 | 用在哪 |
|---|---|---|
| p26 | LED Definitions | 排查主板红灯/橙灯 |
| p33–34 | Installing the Memory / **Memory Population Table** | 4 条内存的正确插法（C0/D0/G0/H0） |
| **p72** | Hardware Health Configuration | **`Fan Speed Control` / `PWM Minimal Duty Cycle`** —— 为什么 BMC 没有温度曲线 |
| **p141–144** | Appendix II: Fan and Temp Sensors | **`MB_Air_Inlet` 的定义与板图位置** —— 为什么它会被显卡尾气烤到 |

> 手册版权归 MiTAC Computing Technology Corporation 所有，此处收录仅为方便对照，
> 官方下载入口：<https://www.tyan.com/support/download-center>。若权利人要求会立即移除。

---

## 八、常见问题

**Q：会不会把风扇/主板搞坏？**
不会。只下发占空比、只改传感器告警阈值，都是主板厂商提供的标准接口。
不刷固件、不改寄存器。停止服务 + 卸载，BMC 就按自己的策略接管。

**Q：为什么不控制机箱风扇？**
因为大多数人的机箱风扇是 3-pin（不受 PWM 控制）。CPU 风扇通常是 4-pin，所以能控。
详见上文「3-pin 风扇不受 PWM 控制」。

**Q：超微 / 其它厂商的主板能用吗？**
风扇命令不行（netfn 不同）。阈值修正是因为各家 BMC 复位行为不同，需要自己验证，
但从原理上可以照搬（改配置文件里的传感器名和编号）。

**Q：内存不识别、D0 通道缺失之类的问题能顺便解决吗？**
不能，那是硬件故障（例如插座弯针），本项目只针对 BMC 的两个软件层毛病。

---

## 九、许可

MIT，见 `LICENSE`。
