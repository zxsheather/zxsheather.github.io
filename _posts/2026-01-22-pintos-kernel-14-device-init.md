# Pintos 内核启动（十四）：设备初始化

## 概述

本文档详细解析 Pintos 内核的设备初始化过程。在中断系统初始化完成后，内核需要初始化各种硬件设备，使它们能够正常工作。Pintos 涉及的主要设备包括：

1. **定时器（Timer）**：提供时间基准和周期性中断
2. **键盘（Keyboard）**：处理用户输入
3. **串口（Serial Port）**：用于调试输出和通信
4. **控制台（Console）**：管理屏幕输出

这些设备的初始化顺序是精心设计的，确保系统能够正确响应硬件事件。

## 初始化顺序

```c
/* pintos_init() 中的设备初始化顺序 */

/* Initialize interrupt handlers. */
intr_init ();        // 中断系统
timer_init ();       // 定时器
kbd_init ();         // 键盘
input_init ();       // 输入缓冲区

/* Start thread scheduler and enable interrupts. */
thread_start ();     // 启动调度（开中断）
serial_init_queue ();// 串口队列模式
timer_calibrate ();  // 定时器校准
```

**初始化时序图**：

```
时间轴 ────────────────────────────────────────────────────→

中断关闭                           │  中断开启
─────────────────────────────────│───────────────────────────
                                  │
intr_init()                       │
    │                             │
    ├─→ pic_init()               │
    │                             │
    └─→ 加载 IDT                  │
                                  │
timer_init()                      │
    │                             │
    └─→ 配置 PIT                  │
        注册定时器中断            │
                                  │
kbd_init()                        │
    │                             │
    └─→ 注册键盘中断              │
                                  │
input_init()                      │
    │                             │
    └─→ 初始化输入队列            │
                                  │
                              thread_start()
                                  │
                                  ├─→ 创建空闲线程
                                  │
                                  └─→ intr_enable()
                                        │
                                        ↓ 中断开始被处理
                                        
                              serial_init_queue()
                                  │
                                  └─→ 启用串口中断
                                  
                              timer_calibrate()
                                  │
                                  └─→ 测量 CPU 速度
```

## 定时器初始化

### 原始代码

```c
/* timer.c */

/** Number of timer ticks since OS booted. */
static int64_t ticks;

/** Sets up the timer to interrupt TIMER_FREQ times per second,
   and registers the corresponding interrupt. */
void
timer_init (void) 
{
  pit_configure_channel (0, 2, TIMER_FREQ);
  intr_register_ext (0x20, timer_interrupt, "8254 Timer");
}

/* pit.c */

/** 8254 registers. */
#define PIT_PORT_CONTROL          0x43
#define PIT_PORT_COUNTER(CHANNEL) (0x40 + (CHANNEL))

/** PIT cycles per second. */
#define PIT_HZ 1193180

void
pit_configure_channel (int channel, int mode, int frequency)
{
  uint16_t count;
  enum intr_level old_level;

  ASSERT (channel == 0 || channel == 2);
  ASSERT (mode == 2 || mode == 3);

  /* Convert FREQUENCY to a PIT counter value. */
  if (frequency < 19)
    count = 0;
  else if (frequency > PIT_HZ)
    count = 2;
  else
    count = (PIT_HZ + frequency / 2) / frequency;

  /* Configure the PIT. */
  old_level = intr_disable ();
  outb (PIT_PORT_CONTROL, ((channel << 6) | 0x30 | (mode << 1)));
  outb (PIT_PORT_COUNTER (channel), count);
  outb (PIT_PORT_COUNTER (channel), count >> 8);
  intr_set_level (old_level);
}
```

### 8254 PIT 硬件架构

```
                    ┌───────────────────────────────────────┐
                    │           8254 PIT                    │
                    │                                       │
  时钟输入 ─────────┼─→ CLK (1.193180 MHz)                  │
  (1.193180 MHz)    │                                       │
                    │ ┌─────────────┐ ┌─────────────┐       │
                    │ │  Channel 0  │ │  Channel 1  │       │
                    │ │             │ │             │       │
                    │ │ 计数器      │ │ 计数器      │       │
                    │ │             │ │   (DRAM)    │       │
                    │ │ OUT0 ───────┼─┼─────────────┼─→ IRQ0 (定时器中断)
                    │ └─────────────┘ └─────────────┘       │
                    │                                       │
                    │ ┌─────────────┐                       │
                    │ │  Channel 2  │                       │
                    │ │             │                       │
                    │ │ 计数器      │                       │
                    │ │             │                       │
                    │ │ OUT2 ───────┼───────────────────→ Speaker
                    │ └─────────────┘                       │
                    │                                       │
端口 0x40-0x43 ────┼─→ 控制/数据                           │
                    └───────────────────────────────────────┘
```

### PIT 配置详解

**pit_configure_channel() 参数计算**：

```c
/* TIMER_FREQ = 100 Hz (每秒 100 次中断) */
/* PIT_HZ = 1193180 Hz */

count = PIT_HZ / TIMER_FREQ
      = 1193180 / 100
      = 11932 (约)

/* 实际频率 = 1193180 / 11932 ≈ 100.007 Hz */
```

**控制字格式**（端口 0x43）：

```
位 7-6: 通道选择 (00=Ch0, 01=Ch1, 10=Ch2)
位 5-4: 访问模式 (11=先低后高)
位 3-1: 工作模式 (010=Mode 2, 011=Mode 3)
位 0:   BCD/二进制 (0=二进制)

对于 Channel 0, Mode 2:
(0 << 6) | 0x30 | (2 << 1) = 0x34
```

**Mode 2（速率发生器）工作原理**：

```
计数值 = 11932

时间轴 ─────────────────────────────────────────────→
         │←────── 11932 个时钟周期 ──────→│
         │                                │
OUT ─────┘                               ┌┘
         ↑                               ↑
      计数开始                        计数到0
      (输出变高)                      (脉冲，输出变低，然后立即变高)
                                      同时重新加载计数值
```

### timer_init() 流程

```
timer_init()
    │
    ├─→ pit_configure_channel(0, 2, TIMER_FREQ)
    │   │
    │   ├─→ 计算 count = 11932
    │   │
    │   ├─→ 关中断（防止配置过程中产生中断）
    │   │
    │   ├─→ outb(0x43, 0x34)  // 控制字
    │   │
    │   ├─→ outb(0x40, 11932 & 0xFF)  // 计数值低字节
    │   │
    │   ├─→ outb(0x40, 11932 >> 8)    // 计数值高字节
    │   │
    │   └─→ 恢复中断状态
    │
    └─→ intr_register_ext(0x20, timer_interrupt, "8254 Timer")
        │
        └─→ 注册中断处理程序
            向量号 = 0x20 (IRQ0)
            处理函数 = timer_interrupt
```

### 定时器中断处理

```c
/** Timer interrupt handler. */
static void
timer_interrupt (struct intr_frame *args UNUSED)
{
  ticks++;
  thread_tick ();
}
```

**每次定时器中断执行的操作**：

1. **增加 ticks**：全局计时器，记录系统运行的时钟周期数
2. **thread_tick()**：
   - 更新线程统计信息
   - 检查时间片是否用完
   - 如果用完，设置 `yield_on_return`

```c
void
thread_tick (void) 
{
  struct thread *t = thread_current ();

  /* Update statistics. */
  if (t == idle_thread)
    idle_ticks++;
  else if (t->pagedir != NULL)
    user_ticks++;
  else
    kernel_ticks++;

  /* Enforce preemption. */
  if (++thread_ticks >= TIME_SLICE)
    intr_yield_on_return ();
}
```

### 定时器校准

```c
void
timer_calibrate (void) 
{
  unsigned high_bit, test_bit;

  ASSERT (intr_get_level () == INTR_ON);
  printf ("Calibrating timer...  ");

  /* Approximate loops_per_tick as the largest power-of-two
     still less than one timer tick. */
  loops_per_tick = 1u << 10;
  while (!too_many_loops (loops_per_tick << 1)) 
    {
      loops_per_tick <<= 1;
      ASSERT (loops_per_tick != 0);
    }

  /* Refine the next 8 bits of loops_per_tick. */
  high_bit = loops_per_tick;
  for (test_bit = high_bit >> 1; test_bit != high_bit >> 10; test_bit >>= 1)
    if (!too_many_loops (high_bit | test_bit))
      loops_per_tick |= test_bit;

  printf ("%'"PRIu64" loops/s.\n", (uint64_t) loops_per_tick * TIMER_FREQ);
}
```

**校准目的**：

- 测量 CPU 在一个时钟周期内能执行多少次空循环
- 用于实现 `timer_mdelay()` 等忙等待函数
- 在不同速度的 CPU 上提供一致的延迟

**校准算法**：

```
1. 初始值 = 1024 (2^10)

2. 二分查找最大值：
   while (loops_per_tick * 2 < 一个 tick 的循环数)
       loops_per_tick *= 2
   
   结果：找到最大的 2 的幂次

3. 精细调整（8位精度）：
   逐位测试，得到更精确的值

示例输出：
Calibrating timer...  1,234,567 loops/s.
```

## 键盘初始化

### 原始代码

```c
/* kbd.c */

/** Keyboard data register port. */
#define DATA_REG 0x60

static intr_handler_func keyboard_interrupt;

/** Initializes the keyboard. */
void
kbd_init (void) 
{
  intr_register_ext (0x21, keyboard_interrupt, "8042 Keyboard");
}
```

### 8042 键盘控制器

```
┌─────────────────────────────────────────────────────────────┐
│                     8042 键盘控制器                          │
│                                                             │
│  ┌─────────────┐                      ┌─────────────────┐  │
│  │   输入缓冲   │ ◄── 端口 0x60 写 ◄── │  CPU 命令       │  │
│  └─────────────┘                      └─────────────────┘  │
│          │                                                  │
│          ↓                                                  │
│  ┌─────────────┐                                           │
│  │   控制器     │                                           │
│  └─────────────┘                                           │
│          │                                                  │
│          ↓                                                  │
│  ┌─────────────┐                      ┌─────────────────┐  │
│  │   输出缓冲   │ ─→ 端口 0x60 读 ─→  │  CPU 接收数据   │  │
│  └─────────────┘                      └─────────────────┘  │
│          │                                                  │
│          ↓                                                  │
│      IRQ1 (向量 0x21)                                       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
            ↑
            │ PS/2 协议
            ↓
      ┌─────────────┐
      │   键盘      │
      └─────────────┘
```

### 键盘中断处理

```c
static void
keyboard_interrupt (struct intr_frame *args UNUSED) 
{
  /* Must read scancode to clear interrupt. */
  uint8_t scancode = inb (DATA_REG);
  
  /* 处理扫描码 */
  if (scancode & 0x80) {
    /* 按键释放 */
    scancode &= ~0x80;
    handle_key_release (scancode);
  } else {
    /* 按键按下 */
    handle_key_press (scancode);
  }
}
```

**扫描码到字符的转换**：

```
扫描码 → 查表 → ASCII 字符

示例：
扫描码 0x1E = 'A' (无 Shift)
扫描码 0x1E + Shift = 'A' (有 Shift)
扫描码 0x9E = 'A' 释放 (0x1E | 0x80)
```

### 输入缓冲区

```c
/* input.c */

/** Stores a character in the input buffer. */
void
input_putc (uint8_t key)
{
  ASSERT (intr_get_level () == INTR_OFF);
  if (!intq_full (&buffer))
    intq_putc (&buffer, key);
}

/** Retrieves a character from the input buffer. */
uint8_t
input_getc (void) 
{
  enum intr_level old_level;
  uint8_t key;

  old_level = intr_disable ();
  key = intq_getc (&buffer);
  intr_set_level (old_level);
  
  return key;
}
```

**缓冲区结构**：

```
              写入 (中断上下文)
                   │
                   ↓
         ┌─────────────────────────────┐
buffer:  │ a │ b │ c │   │   │   │   │ │
         └─────────────────────────────┘
           ↑                       ↑
          head                    tail
           │
           └── 读取 (进程上下文)
```

## 串口初始化

### 原始代码

```c
/* serial.c */

/** I/O port base address for the first serial port. */
#define IO_BASE 0x3f8

/** Transmission mode. */
static enum { UNINIT, POLL, QUEUE } mode;

/** Initializes the serial port device for polling mode. */
static void
init_poll (void) 
{
  ASSERT (mode == UNINIT);
  outb (IER_REG, 0);                    /* Turn off all interrupts. */
  outb (FCR_REG, 0);                    /* Disable FIFO. */
  set_serial (9600);                    /* 9.6 kbps, N-8-1. */
  outb (MCR_REG, MCR_OUT2);             /* Required to enable interrupts. */
  intq_init (&txq);
  mode = POLL;
} 

/** Initializes the serial port device for queued mode. */
void
serial_init_queue (void) 
{
  enum intr_level old_level;

  if (mode == UNINIT)
    init_poll ();
  ASSERT (mode == POLL);

  intr_register_ext (0x24, serial_interrupt, "16550A Serial");
  mode = QUEUE;
  old_level = intr_disable ();
  write_ier ();
  intr_set_level (old_level);
}
```

### 16550A UART 寄存器

```
┌─────────────────────────────────────────────────────────────────┐
│                      16550A UART                                │
│                                                                 │
│  端口 0x3F8 (DLAB=0):                                           │
│    读: RBR (接收缓冲)     写: THR (发送保持)                    │
│                                                                 │
│  端口 0x3F9 (DLAB=0):                                           │
│    读/写: IER (中断使能)                                        │
│                                                                 │
│  端口 0x3F8 (DLAB=1):                                           │
│    读/写: DLL (除数锁存低字节)                                  │
│                                                                 │
│  端口 0x3F9 (DLAB=1):                                           │
│    读/写: DLM (除数锁存高字节)                                  │
│                                                                 │
│  端口 0x3FA:                                                    │
│    读: IIR (中断识别)     写: FCR (FIFO 控制)                   │
│                                                                 │
│  端口 0x3FB: LCR (线路控制)                                     │
│  端口 0x3FC: MCR (调制解调器控制)                               │
│  端口 0x3FD: LSR (线路状态) [只读]                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 串口配置

```c
static void
set_serial (int bps)
{
  int base_rate = 1843200 / 16;
  uint16_t divisor = base_rate / bps;

  ASSERT (googol >= 300 && bps <= 115200);

  /* Enable DLAB. */
  outb (LCR_REG, LCR_DLAB);

  /* Set data rate. */
  outb (LS_REG, divisor & 0xff);
  outb (MS_REG, divisor >> 8);

  /* Reset DLAB, set N-8-1. */
  outb (LCR_REG, LCR_N81);
}
```

**波特率计算**：

```
基准频率 = 1843200 Hz / 16 = 115200 Hz
除数 = 115200 / 目标波特率

9600 bps: 除数 = 115200 / 9600 = 12
```

### 串口模式

| 模式 | 描述 | 使用场景 |
|------|------|---------|
| UNINIT | 未初始化 | 系统启动初期 |
| POLL | 轮询模式 | 中断未启用时 |
| QUEUE | 队列模式 | 正常运行时 |

**轮询模式 vs 队列模式**：

```
轮询模式：
  serial_putc()
      │
      └─→ 循环等待 THR 空
          │
          └─→ 写入字符到 THR

队列模式：
  serial_putc()
      │
      └─→ 写入字符到发送队列
          │
          └─→ 启用发送中断
              │
              ↓ (中断触发时)
          serial_interrupt()
              │
              └─→ 从队列取字符写入 THR
```

## 控制台初始化

### 原始代码

```c
/* console.c */

static struct lock console_lock;

void
console_init (void) 
{
  lock_init (&console_lock);
}

void
console_print_stats (void) 
{
  printf ("Console: %lld characters output\n", write_cnt);
}
```

### 控制台输出路径

```
printf() / putchar()
        │
        ↓
    console_lock
        │
        ↓
   ┌────┴────┐
   │         │
   ↓         ↓
  VGA     Serial
(屏幕)    (串口)
```

**多设备输出**：

```c
/* console.c */
static void
putchar_unlocked (uint8_t c) 
{
  if (vga_write_to_screen)
    vga_putc (c);
  if (serial_write_to_serial)
    serial_putc (c);
  write_cnt++;
}
```

## VGA 初始化

### 原始代码

```c
/* vga.c */

/** VGA text screen support. */

/** Number of columns and rows on the text display. */
#define COL_CNT 80
#define ROW_CNT 25

/** Current cursor position. */
static size_t cx, cy;

void
vga_init (void)
{
  /* 通常不需要特别初始化 */
  /* BIOS 已经设置好文本模式 */
}
```

### VGA 文本模式

```
VGA 显存地址: 0xB8000

┌────────────────────────────────────────────────────────────┐
│                     屏幕 (80x25)                            │
│                                                            │
│  每个字符占 2 字节:                                         │
│  ┌─────────┬─────────┐                                     │
│  │ 字符    │ 属性    │                                     │
│  │ (ASCII) │ (颜色)  │                                     │
│  └─────────┴─────────┘                                     │
│                                                            │
│  属性字节:                                                  │
│  ┌───┬───┬───┬───┬───┬───┬───┬───┐                        │
│  │ 7 │ 6 │ 5 │ 4 │ 3 │ 2 │ 1 │ 0 │                        │
│  │ B │ R │ G │ B │ I │ R │ G │ B │                        │
│  │ ← 背景色  →│← 前景色    →│                              │
│  └───┴───┴───┴───┴───┴───┴───┴───┘                        │
│                                                            │
│  B=闪烁, I=高亮, R=红, G=绿, B=蓝                          │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

### VGA 输出函数

```c
void
vga_putc (int c)
{
  /* 处理特殊字符 */
  if (c == '\n') {
    newline ();
  } else if (c == '\r') {
    cx = 0;
  } else if (c == '\t') {
    do {
      vga_putc (' ');
    } while (cx % 8 != 0);
  } else if (c == '\b') {
    if (cx > 0)
      cx--;
  } else {
    /* 普通字符 */
    write_char (c);
    if (++cx >= COL_CNT) {
      newline ();
    }
  }
  
  /* 更新硬件光标 */
  move_cursor ();
}
```

## 设备初始化时序

### 完整初始化流程

```
pintos_init()
    │
    ├─→ bss_init()          // BSS 清零
    │
    ├─→ read_command_line() // 读取命令行
    │
    ├─→ thread_init()       // 线程系统
    │
    ├─→ console_init()      // 控制台锁
    │       │
    │       └─→ 此时 printf 可用（轮询模式）
    │
    ├─→ palloc_init()       // 页分配器
    │
    ├─→ malloc_init()       // 块分配器
    │
    ├─→ paging_init()       // 永久页表
    │
    ├─→ intr_init()         // 中断系统
    │       │
    │       ├─→ pic_init()
    │       │
    │       └─→ 加载 IDT
    │
    ├─→ timer_init()        // 定时器
    │       │
    │       └─→ 注册 IRQ0 (0x20)
    │
    ├─→ kbd_init()          // 键盘
    │       │
    │       └─→ 注册 IRQ1 (0x21)
    │
    ├─→ input_init()        // 输入缓冲
    │
    ├─→ thread_start()      // 开始调度
    │       │
    │       ├─→ 创建空闲线程
    │       │
    │       └─→ intr_enable()  ← 中断开始被处理
    │
    ├─→ serial_init_queue() // 串口队列模式
    │       │
    │       └─→ 注册 IRQ4 (0x24)
    │
    └─→ timer_calibrate()   // 校准定时器
            │
            └─→ 测量 loops_per_tick
```

### 中断优先级

PIC 默认中断优先级（数字越小优先级越高）：

| IRQ | 向量 | 设备 | 优先级 |
|-----|------|------|--------|
| 0 | 0x20 | 定时器 | 1（最高） |
| 1 | 0x21 | 键盘 | 2 |
| 2 | 0x22 | 级联 | 3 |
| 3 | 0x23 | COM2 | 4 |
| 4 | 0x24 | COM1 | 5 |
| ... | ... | ... | ... |

## 常见问题解答

### Q1: 为什么定时器要在中断开启前初始化？

**A**: 
- 配置 PIT 需要写多个端口，必须是原子操作
- 关中断状态下配置可以防止配置过程中产生中断
- 注册中断处理程序不需要中断开启

### Q2: 为什么串口有两种模式？

**A**: 
- 轮询模式：系统启动早期，中断未初始化
- 队列模式：正常运行，不浪费 CPU 等待

### Q3: timer_calibrate 必须在中断开启后吗？

**A**: 
- 是的，需要定时器中断来测量时间
- 通过等待 ticks 变化来确定循环次数

### Q4: 键盘初始化为什么如此简单？

**A**: 
- 8042 控制器由 BIOS 初始化
- 只需要注册中断处理程序
- 键盘硬件已经准备好发送扫描码

## 练习题

### 练习1：修改定时器频率

将 TIMER_FREQ 从 100 Hz 改为 1000 Hz：
1. 需要修改哪些代码？
2. 这对系统有什么影响？

### 练习2：实现键盘 LED 控制

实现函数控制键盘 LED（Caps Lock, Num Lock, Scroll Lock）：

```c
void kbd_set_leds(bool caps, bool num, bool scroll);
```

**提示**：向 8042 发送命令 0xED。

### 练习3：串口接收

当前代码主要关注串口输出。添加串口输入支持：
1. 在串口中断中处理接收
2. 将接收到的字符放入输入缓冲区

### 练习4：计算实际定时器频率

给定 PIT_HZ = 1193180 和 TIMER_FREQ = 100：
1. 计算实际的中断频率
2. 计算一小时后的时间误差

## 下一篇预告

在下一篇文档中，我们将详细解析启动完成和任务执行过程，了解 Pintos 如何从初始化阶段过渡到正常运行，以及如何执行用户指定的命令。

## 参考资料

1. [Intel 8254 Programmable Interval Timer Datasheet](https://www.scs.stanford.edu/10wi-cs140/pintos/specs/8254.pdf)
2. [8042 PS/2 Controller](https://wiki.osdev.org/%228042%22_PS/2_Controller)
3. [16550 UART](https://wiki.osdev.org/Serial_Ports)
4. [VGA Hardware](https://wiki.osdev.org/VGA_Hardware)
