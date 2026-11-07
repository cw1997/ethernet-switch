# DE2-115 双端口 MII 交换机

两路 100 Mbit/s 全双工交换端口，两路互相独立的串口 Console，以及一块由板载
拨码开关和 LED 构成的面板。

## 板上运行的内容

| 端口 | PHY | 速率 | 备注 |
|---|---|---|---|
| 0 | ENET0（88E1111） | 100 Mbit/s 全双工 | JP1 必须置于 MII |
| 1 | ENET1（88E1111） | 100 Mbit/s 全双工 | |

`CLOCK_50` 是唯一的 50 MHz 内核时钟。`KEY0` 释放同步后的复位；其余三个按键
未使用。50 MHz 下 100 Mbit/s 端口每个八位组需要 4 个内核时钟，这正是 MII MAC
所要求的偶数 `BYTE_PERIOD`。

## Console

两路完全独立的 Console，各自拥有 UART、行缓冲、解析器和响应时序器。任何一路
都不会拖住另一路：某个口没插线、收到乱码、或正在被插拔，都触碰不到另一路能看见
的任何状态。

| Console | 连接器 | 电平 | 引脚 |
|---|---|---|---|
| 0 | 板载 RS-232 | RS-232 | `UART_RXD`、`UART_TXD`、`UART_CTS`、`UART_RTS` |
| 1 | JP5 扩展排针 | 3.3 V TTL | `GPIO_RXD`、`GPIO_TXD`、`GPIO_CTS_N`、`GPIO_RTS_N` |

Console 1 需要外接 USB-串口模块，它不是第二个 RS-232 口。引脚对应：

| 信号 | FPGA 引脚 | 排针引脚 |
|---|---|---|
| `GPIO_RXD` | `PIN_AB22` | GPIO[0] |
| `GPIO_CTS_N` | `PIN_AC15` | GPIO[1] |
| `GPIO_TXD` | `PIN_AB21` | GPIO[2] |
| `GPIO_RTS_N` | `PIN_Y17` | GPIO[3] |

两路默认 115200 8N1、无流控；启用时 CTS/RTS 为低有效。`help` 列出命令集。
所有命令都是查询——Console 没有任何写入交换机配置的路径。

## 拨码开关

`SW[7:0]` 驱动机前面板，`SW[17:8]` 未使用。

| 位置 | 功能 |
|---|---|
| `SW[1:0]` | 洪泛策略：0 = 仅广播，1 = 未知单播也洪泛，2 = 未知组播也洪泛（3 被钳位为 2） |
| `SW[2]` | 源地址学习使能 |
| `SW[3]` | 配置覆盖。**该位为低时上面两位被忽略**，使用 elaboration 默认值，因此无论其它开关怎么拨，板上电后都处于已知状态 |
| `SW[4]` | 清空转发表（电平；panel 把上升沿变成单拍脉冲） |
| `SW[5]` | 灯测试：全部灯点亮（含每端口灯），用来区分坏灯与"本来就该灭"；无需链路和流量 |
| `SW[7:6]` | 保留 |

## LED

| LED | 含义 |
|---|---|
| `LEDG[0]` | 端口 0 链路 |
| `LEDG[1]` | 端口 1 链路 |
| `LEDG[2]` | 端口 0 活动（最后一个八位组之后保持约 100 ms） |
| `LEDG[3]` | 端口 1 活动 |
| `LEDG[4]` | 端口 0 全双工 |
| `LEDG[5]` | 端口 1 全双工 |
| `LEDG[6]` | 端口 0 PHY 管理故障 |
| `LEDG[7]` | 端口 1 PHY 管理故障 |
| `LEDG[8]` | 转发表已满 |
| `LEDR[1:0]` | 端口 0 速率：`[0]` = 100 Mbit/s，`[1]` = 1000 Mbit/s |
| `LEDR[3:2]` | 端口 1 速率，编码相同 |
| `LEDR[7:4]` | 转发表使用率条，每格四分之一 |
| `LEDR[8]` | 转发表非空 |
| `LEDR[9]` | 至少一个链路 up |
| `LEDR[10]` | 洪泛策略 bit 0（解码后的实际值，仅在覆盖位有效时点亮） |
| `LEDR[11]` | 学习使能（解码后的实际值） |
| `LEDR[12]` | 配置覆盖生效 |
| `LEDR[13]` | 本拍有清表请求 |
| `LEDR[14]` | 心跳，约 4 Hz |
| `LEDR[15]` | Console 0 收到非法输入（粘滞） |
| `LEDR[16]` | Console 1 收到非法输入（粘滞） |
| `LEDR[17]` | 任一接收错误计数器非零 |

灯的含义在 `rtl/panel/es_panel.sv` 中决定，不在这里。本文件只说明哪个引脚点亮
哪盏灯，因此某块板若把 LED 换了顺序，只改一行，行为不变。

## PHY 管理

两片 PHY 通过 MDIO 轮询（地址 16 和 17）。只有当 PHY 报告有效的 100 Mbit/s
全双工链路时，该端口才被管理性使能。管理失败会显示在该端口的故障灯上，并出现在
Console 的 `link` 和 `port <n>` 输出里，而不是悄悄关掉流量。

`ENET0_RESET_N`、`ENET1_RESET_N` 跟随同步后的复位；没有额外的最短复位脉宽或
晶振稳定延时，PHY 中断引脚未使用。

## 构建

```
build.bat
```

或在已把 Quartus 加入 `PATH` 的终端里：

```
quartus_sh --flow compile ethernet_switch
```

工程固定 `SYNTHESIS=1` 和 `SEARCH_PATH ../../../rtl`，RTL 直接从仓库编译，
不存在需要同步的源码副本。

## 验证

板级顶层属于每一道 RTL 门禁，因此不会悄悄腐烂：

```sh
bash wsl.sh "make lint"   # Verilator -Wall，五个顶层
bash wsl.sh "make rtl"    # Icarus elaboration，五个顶层
bash wsl.sh "make synth"  # yosys，五个顶层
```

没有 testbench 实例化本顶层（它只是一张引脚表）；它背后的逻辑分别由
`sw_panel_tb`（拨码解码与指示灯）、`sw_console_tb`（控制台）、`sw_mii_tb` 与
`tb_sw_switch_mii`（MAC 与整机）覆盖，等价的板级壳由 `make vivado` 覆盖。
