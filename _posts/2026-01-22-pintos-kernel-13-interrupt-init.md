# Pintos 内核启动（十三）：中断系统初始化

## 概述

本文档详细解析 Pintos 内核的中断系统初始化过程 `intr_init()`。中断是操作系统响应外部事件和处理异常的核心机制。正确初始化中断系统是操作系统能够响应硬件事件（如定时器、键盘）和处理软件异常（如除零错误、缺页）的前提。

Pintos 的中断系统涉及以下关键组件：
1. **IDT（Interrupt Descriptor Table）**：中断描述符表，存储中断处理程序的入口
2. **PIC（Programmable Interrupt Controller）**：可编程中断控制器，管理硬件中断
3. **中断处理函数**：实际处理中断的 C 代码

## 原始代码

### interrupt.c 中的 intr_init() 函数

```c
/** Initializes the interrupt system. */
void
intr_init (void)
{
  uint64_t idtr_operand;
  int i;

  /* Initialize interrupt controller. */
  pic_init ();

  /* Initialize IDT. */
  for (i = 0; i < INTR_CNT; i++)
    idt[i] = make_intr_gate (intr_stubs[i], 0);

  /* Load IDT register.
     See [IA32-v2a] "LIDT" and [IA32-v3a] 5.10 "Interrupt
     Descriptor Table (IDT)". */
  idtr_operand = make_idtr_operand (sizeof idt - 1, idt);
  asm volatile ("lidt %0" : : "m" (idtr_operand));

  /* Initialize intr_names. */
  for (i = 0; i < INTR_CNT; i++)
    intr_names[i] = "unknown";
  intr_names[0] = "#DE Divide Error";
  intr_names[1] = "#DB Debug Exception";
  intr_names[2] = "NMI Interrupt";
  intr_names[3] = "#BP Breakpoint Exception";
  intr_names[4] = "#OF Overflow Exception";
  intr_names[5] = "#BR BOUND Range Exceeded Exception";
  intr_names[6] = "#UD Invalid Opcode Exception";
  intr_names[7] = "#NM Device Not Available Exception";
  intr_names[8] = "#DF Double Fault Exception";
  intr_names[9] = "Coprocessor Segment Overrun";
  intr_names[10] = "#TS Invalid TSS Exception";
  intr_names[11] = "#NP Segment Not Present";
  intr_names[12] = "#SS Stack Fault Exception";
  intr_names[13] = "#GP General Protection Exception";
  intr_names[14] = "#PF Page-Fault Exception";
  intr_names[16] = "#MF x87 FPU Floating-Point Error";
  intr_names[17] = "#AC Alignment Check Exception";
  intr_names[18] = "#MC Machine-Check Exception";
  intr_names[19] = "#XF SIMD Floating-Point Exception";
}
```

### pic_init() 函数

```c
/** Initializes the PICs.  Refer to [8259A] for details.

   By default, interrupts 0...15 delivered by the PICs will go to
   interrupt vectors 0...15.  Those vectors are also used for CPU
   traps and exceptions, so we reprogram the PICs so that
   interrupts 0...15 are delivered to interrupt vectors 32...47
   (0x20...0x2f) instead. */
static void
pic_init (void)
{
  /* Mask all interrupts on both PICs. */
  outb (PIC0_DATA, 0xff);
  outb (PIC1_DATA, 0xff);

  /* Initialize master. */
  outb (PIC0_CTRL, 0x11); /* ICW1: single mode, edge triggered, expect ICW4. */
  outb (PIC0_DATA, 0x20); /* ICW2: line IR0...7 -> irq 0x20...0x27. */
  outb (PIC0_DATA, 0x04); /* ICW3: slave PIC on line IR2. */
  outb (PIC0_DATA, 0x01); /* ICW4: 8086 mode, normal EOI, non-buffered. */

  /* Initialize slave. */
  outb (PIC1_CTRL, 0x11); /* ICW1: single mode, edge triggered, expect ICW4. */
  outb (PIC1_DATA, 0x28); /* ICW2: line IR0...7 -> irq 0x28...0x2f. */
  outb (PIC1_DATA, 0x02); /* ICW3: slave ID is 2. */
  outb (PIC1_DATA, 0x01); /* ICW4: 8086 mode, normal EOI, non-buffered. */

  /* Unmask all interrupts. */
  outb (PIC0_DATA, 0x00);
  outb (PIC1_DATA, 0x00);
}
```

## 前置知识

### 1. x86 中断分类

x86 系统中的中断分为三类：

```
中断类型
│
├─→ 异常（Exceptions）: CPU 内部产生
│   │
│   ├─→ 故障（Faults）: 可恢复，返回到引起故障的指令
│   │   例：#PF Page Fault, #GP General Protection
│   │
│   ├─→ 陷阱（Traps）: 可恢复，返回到下一条指令
│   │   例：#BP Breakpoint, #OF Overflow
│   │
│   └─→ 终止（Aborts）: 不可恢复
│       例：#DF Double Fault, #MC Machine Check
│
├─→ 软件中断（Software Interrupts）: INT 指令产生
│   例：INT 0x80 (系统调用)
│
└─→ 硬件中断（Hardware Interrupts）: 外部设备产生
    │
    ├─→ 可屏蔽中断（Maskable）: 通过 PIC 传递
    │   例：定时器、键盘、硬盘
    │
    └─→ 不可屏蔽中断（NMI）: 直接到达 CPU
        例：内存校验错误
```

### 2. 中断向量表

x86 支持 256 个中断向量（0-255）：

| 向量范围 | 类型 | 说明 |
|---------|------|------|
| 0-19 | CPU 异常 | 由 Intel 定义 |
| 20-31 | 保留 | Intel 保留 |
| 32-47 | 硬件中断 | 重映射后的 IRQ 0-15 |
| 48-255 | 可用 | 软件中断、系统调用等 |

### 3. 8259A PIC 架构

PC 使用两片级联的 8259A PIC：

```
                           ┌─────────────────┐
                           │      CPU        │
                           │                 │
                           │   INTR ◄────────┼──────┐
                           └─────────────────┘      │
                                                    │
┌──────────────────────┐                    ┌──────┴──────────────┐
│     外部设备          │                    │    Master PIC       │
│                      │                    │    (8259A #0)       │
│  IRQ0: 定时器 ───────┼────────────────────┼→ IR0               │
│  IRQ1: 键盘 ─────────┼────────────────────┼→ IR1               │
│  IRQ2: 级联 ─────────┼────────────────────┼→ IR2 ◄─────────────┼──┐
│  IRQ3: COM2 ─────────┼────────────────────┼→ IR3               │  │
│  IRQ4: COM1 ─────────┼────────────────────┼→ IR4               │  │
│  IRQ5: LPT2 ─────────┼────────────────────┼→ IR5               │  │
│  IRQ6: 软盘 ─────────┼────────────────────┼→ IR6               │  │
│  IRQ7: LPT1 ─────────┼────────────────────┼→ IR7               │  │
│                      │                    └────────────────────┘  │
│                      │                                            │
│                      │                    ┌────────────────────┐  │
│                      │                    │    Slave PIC        │  │
│                      │                    │    (8259A #1)       │  │
│  IRQ8: RTC ──────────┼────────────────────┼→ IR0               │  │
│  IRQ9: ACPI ─────────┼────────────────────┼→ IR1               │  │
│  IRQ10: 可用 ────────┼────────────────────┼→ IR2               │  │
│  IRQ11: 可用 ────────┼────────────────────┼→ IR3               │  │
│  IRQ12: PS/2鼠标 ────┼────────────────────┼→ IR4               │  │
│  IRQ13: FPU ─────────┼────────────────────┼→ IR5               │  │
│  IRQ14: IDE Primary ─┼────────────────────┼→ IR6               │  │
│  IRQ15: IDE Secondary┼────────────────────┼→ IR7               │  │
│                      │                    │         INT ────────┼──┘
└──────────────────────┘                    └────────────────────┘
```

### 4. IDT 描述符格式

每个 IDT 条目（门描述符）是 8 字节：

```
63                48 47 46 45 44 43 40 39        32
+------------------+--+-----+--+------+------------+
|  Offset 31:16    |P |DPL |S | Type |  Reserved  |
+------------------+--+-----+--+------+------------+

31                16 15                           0
+------------------+-----------------------------+
| Segment Selector |       Offset 15:0           |
+------------------+-----------------------------+

各字段说明：
- Offset: 中断处理程序的地址（分成两部分）
- P: 存在位（1=有效）
- DPL: 描述符特权级（0-3）
- S: 系统段（必须为0）
- Type: 门类型（14=中断门，15=陷阱门）
- Segment Selector: 代码段选择子
```

### 5. 中断门 vs 陷阱门

| 特性 | 中断门（Interrupt Gate）| 陷阱门（Trap Gate）|
|------|------------------------|-------------------|
| Type | 14 (0xE) | 15 (0xF) |
| 进入时 | 自动关中断 (IF=0) | 保持中断状态 |
| 用途 | 硬件中断 | 软件中断、异常 |

### 6. 中断帧（Interrupt Frame）

中断发生时 CPU 自动压栈的内容：

```
高地址
┌───────────────────┐
│       SS          │  (特权级改变时)
├───────────────────┤
│       ESP         │  (特权级改变时)
├───────────────────┤
│      EFLAGS       │
├───────────────────┤
│       CS          │
├───────────────────┤
│       EIP         │
├───────────────────┤
│   Error Code      │  (某些异常)
├───────────────────┤
│   (软件压入的)     │
│   寄存器等        │
└───────────────────┘
低地址
```

## 逐行代码解析

### intr_init() 函数解析

#### 第1-2行：变量声明

```c
uint64_t idtr_operand;
int i;
```

**详细解析**：

1. **idtr_operand**：
   - 64 位值，存储 IDTR 寄存器的操作数
   - 格式：低 16 位是限制（limit），高 32 位是基址（base）

2. **i**：循环变量

#### 第3行：初始化 PIC

```c
pic_init ();
```

**详细解析**：

这是关键的一步，重新配置 8259A PIC。详见下面的 `pic_init()` 解析。

#### 第4-5行：初始化 IDT

```c
for (i = 0; i < INTR_CNT; i++)
  idt[i] = make_intr_gate (intr_stubs[i], 0);
```

**详细解析**：

1. **INTR_CNT = 256**：x86 支持的中断向量数

2. **intr_stubs[]**：
   - 中断存根函数数组
   - 在 `intr-stubs.S` 中定义
   - 每个存根函数负责保存上下文并调用统一的处理函数

3. **make_intr_gate()**：
   - 创建中断门描述符
   - DPL=0 表示只有内核可以触发

4. **初始状态**：
   - 所有中断都使用中断门（进入时关中断）
   - 所有中断都没有实际处理程序（后续注册）

**intr_stubs 示意**：

```assembly
# intr-stubs.S 中的代码结构（简化）
intr00_stub:
    push $0         # 假错误码
    push $0x00      # 向量号
    jmp intr_entry

intr01_stub:
    push $0         # 假错误码
    push $0x01      # 向量号
    jmp intr_entry
    
# ... 256 个存根函数 ...
```

#### 第6-8行：加载 IDT

```c
idtr_operand = make_idtr_operand (sizeof idt - 1, idt);
asm volatile ("lidt %0" : : "m" (idtr_operand));
```

**详细解析**：

1. **make_idtr_operand()**：

```c
static inline uint64_t
make_idtr_operand (uint16_t limit, void *base)
{
  return limit | ((uint64_t) (uint32_t) base << 16);
}
```

构造 IDTR 操作数格式：
```
63                             16 15              0
+--------------------------------+----------------+
|         Base Address           |     Limit      |
+--------------------------------+----------------+
```

2. **sizeof idt - 1**：
   - IDT 大小为 256 × 8 = 2048 字节
   - limit = 2048 - 1 = 2047

3. **LIDT 指令**：
   - 将 IDT 的位置和大小加载到 IDTR 寄存器
   - 之后 CPU 会使用这个 IDT 处理中断

**IDTR 寄存器结构**：

```
47                             16 15              0
+--------------------------------+----------------+
|         IDT Base Address       |   IDT Limit    |
+--------------------------------+----------------+
```

#### 第9-25行：初始化中断名称

```c
for (i = 0; i < INTR_CNT; i++)
  intr_names[i] = "unknown";
intr_names[0] = "#DE Divide Error";
intr_names[1] = "#DB Debug Exception";
// ... 更多中断名称 ...
```

**详细解析**：

这些名称用于调试，当发生意外中断时打印友好的信息。

**标准 CPU 异常列表**：

| 向量 | 助记符 | 名称 | 类型 | 错误码 |
|------|--------|------|------|--------|
| 0 | #DE | Divide Error | Fault | 无 |
| 1 | #DB | Debug | Fault/Trap | 无 |
| 2 | NMI | Non-Maskable Interrupt | Interrupt | 无 |
| 3 | #BP | Breakpoint | Trap | 无 |
| 4 | #OF | Overflow | Trap | 无 |
| 5 | #BR | BOUND Range Exceeded | Fault | 无 |
| 6 | #UD | Invalid Opcode | Fault | 无 |
| 7 | #NM | Device Not Available | Fault | 无 |
| 8 | #DF | Double Fault | Abort | 有(0) |
| 9 | - | Coprocessor Segment Overrun | Fault | 无 |
| 10 | #TS | Invalid TSS | Fault | 有 |
| 11 | #NP | Segment Not Present | Fault | 有 |
| 12 | #SS | Stack-Segment Fault | Fault | 有 |
| 13 | #GP | General Protection | Fault | 有 |
| 14 | #PF | Page Fault | Fault | 有 |
| 15 | - | Reserved | - | - |
| 16 | #MF | x87 FPU Error | Fault | 无 |
| 17 | #AC | Alignment Check | Fault | 有(0) |
| 18 | #MC | Machine Check | Abort | 无 |
| 19 | #XF | SIMD Floating-Point | Fault | 无 |

### pic_init() 函数解析

#### 第1-2行：屏蔽所有中断

```c
outb (PIC0_DATA, 0xff);
outb (PIC1_DATA, 0xff);
```

**详细解析**：

- 写入数据端口设置中断屏蔽寄存器（IMR）
- 0xFF = 11111111b = 屏蔽所有 8 个中断线
- 防止初始化过程中产生中断

#### 第3-6行：初始化主 PIC

```c
outb (PIC0_CTRL, 0x11); /* ICW1 */
outb (PIC0_DATA, 0x20); /* ICW2 */
outb (PIC0_DATA, 0x04); /* ICW3 */
outb (PIC0_DATA, 0x01); /* ICW4 */
```

**ICW（Initialization Command Words）详解**：

**ICW1 (0x11)**：
```
位 7-5: 未使用
位 4:   1 = ICW1 标识
位 3:   0 = 边沿触发
位 2:   0 = 8 字节中断向量间隔
位 1:   0 = 级联模式
位 0:   1 = 需要 ICW4
```

**ICW2 (0x20)**：
```
位 7-3: 向量基址的高 5 位 = 0x20 = 32
位 2-0: 由 PIC 填充
结果：IR0-7 映射到向量 0x20-0x27
```

**ICW3 (0x04)**：
```
位 2:   1 = IR2 连接从 PIC
其他位: 0
```

**ICW4 (0x01)**：
```
位 4:   0 = 非特殊全嵌套模式
位 3-2: 00 = 非缓冲模式
位 1:   0 = 正常 EOI
位 0:   1 = 8086 模式
```

#### 第7-10行：初始化从 PIC

```c
outb (PIC1_CTRL, 0x11); /* ICW1 */
outb (PIC1_DATA, 0x28); /* ICW2: 映射到 0x28-0x2f */
outb (PIC1_DATA, 0x02); /* ICW3: 从 ID = 2 */
outb (PIC1_DATA, 0x01); /* ICW4 */
```

**ICW3 (0x02) 对于从 PIC**：
```
位 2-0: 010 = 从 ID 为 2（连接到主 PIC 的 IR2）
```

#### 第11-12行：取消屏蔽所有中断

```c
outb (PIC0_DATA, 0x00);
outb (PIC1_DATA, 0x00);
```

**详细解析**：

- 0x00 = 00000000b = 允许所有中断
- 虽然 PIC 不再屏蔽中断，但 CPU 的 IF 标志仍为 0
- 中断要等到 `intr_enable()` 才会真正被处理

### make_gate() 函数解析

```c
static uint64_t
make_gate (void (*function) (void), int dpl, int type)
{
  uint32_t e0, e1;

  ASSERT (function != NULL);
  ASSERT (dpl >= 0 && dpl <= 3);
  ASSERT (type >= 0 && type <= 15);

  e0 = (((uint32_t) function & 0xffff)     /* Offset 15:0. */
        | (SEL_KCSEG << 16));              /* Target code segment. */

  e1 = (((uint32_t) function & 0xffff0000) /* Offset 31:16. */
        | (1 << 15)                        /* Present. */
        | ((uint32_t) dpl << 13)           /* Descriptor privilege level. */
        | (0 << 12)                        /* System. */
        | ((uint32_t) type << 8));         /* Gate type. */

  return e0 | ((uint64_t) e1 << 32);
}
```

**描述符构造图示**：

假设 `function = 0xC0012345`，`dpl = 0`，`type = 14`（中断门）：

```
e0 构造：
┌────────────────┬────────────────┐
│  SEL_KCSEG     │  Offset 15:0   │
│    (0x08)      │   (0x2345)     │
└────────────────┴────────────────┘
e0 = 0x00082345

e1 构造：
┌────────────────┬─┬──┬─┬────┬────┐
│ Offset 31:16   │P│DPL│S│Type│ 0  │
│   (0xC001)     │1│ 0 │0│ E  │    │
└────────────────┴─┴──┴─┴────┴────┘
e1 = 0xC0018E00

最终描述符：
63                                                 0
+--------------------------------------------------+
|  0xC0018E00            |  0x00082345             |
+--------------------------------------------------+
```

## 中断处理流程

### 完整的中断处理流程

```
1. 中断发生
   │
   ├─→ 硬件中断：设备 → PIC → CPU INTR
   │
   └─→ 异常/软中断：CPU 内部产生
   
2. CPU 响应
   │
   ├─→ 保存当前状态到栈
   │   - EFLAGS, CS, EIP
   │   - 错误码（如果有）
   │   - SS, ESP（特权级改变时）
   │
   └─→ 从 IDT 获取处理程序地址
       向量号 × 8 + IDT 基址

3. 跳转到中断存根
   │
   ├─→ intrNN_stub (intr-stubs.S)
   │   - 压入错误码（如果 CPU 没压入）
   │   - 压入向量号
   │   - 跳转到 intr_entry
   │
   └─→ intr_entry
       - 保存所有通用寄存器
       - 保存段寄存器
       - 设置内核数据段
       - 调用 intr_handler()

4. C 语言处理
   │
   └─→ intr_handler (struct intr_frame *frame)
       │
       ├─→ 外部中断？
       │   - 设置 in_external_intr = true
       │
       ├─→ 查找并调用注册的处理程序
       │   handler = intr_handlers[frame->vec_no]
       │
       └─→ 外部中断完成处理
           - 发送 EOI 到 PIC
           - 检查是否需要调度

5. 返回
   │
   └─→ intr_exit (intr-stubs.S)
       - 恢复段寄存器
       - 恢复通用寄存器
       - iret 指令返回
```

### intr_handler() 函数详解

```c
void
intr_handler (struct intr_frame *frame) 
{
  bool external;
  intr_handler_func *handler;

  /* External interrupts are special. */
  external = frame->vec_no >= 0x20 && frame->vec_no < 0x30;
  if (external) 
    {
      ASSERT (intr_get_level () == INTR_OFF);
      ASSERT (!intr_context ());

      in_external_intr = true;
      yield_on_return = false;
    }

  /* Invoke the interrupt's handler. */
  handler = intr_handlers[frame->vec_no];
  if (handler != NULL)
    handler (frame);
  else if (frame->vec_no == 0x27 || frame->vec_no == 0x2f)
    {
      /* Spurious interrupt, ignore it. */
    }
  else
    unexpected_interrupt (frame);

  /* Complete the processing of an external interrupt. */
  if (external) 
    {
      ASSERT (intr_get_level () == INTR_OFF);
      ASSERT (intr_context ());

      in_external_intr = false;
      pic_end_of_interrupt (frame->vec_no); 

      if (yield_on_return) 
        thread_yield (); 
    }
}
```

**关键点**：

1. **外部中断识别**：向量号 0x20-0x2F 是 PIC 重映射后的硬件中断

2. **伪中断（Spurious Interrupt）**：
   - IRQ7 (0x27) 和 IRQ15 (0x2f) 可能产生伪中断
   - 由于 PIC 的硬件特性导致
   - 应该忽略而不是报错

3. **EOI（End of Interrupt）**：
   - 必须发送 EOI 告知 PIC 中断处理完成
   - 否则 PIC 不会传递后续中断

4. **yield_on_return**：
   - 允许中断处理程序请求调度
   - 常用于定时器中断（时间片用完）

## 中断帧结构

### struct intr_frame 详解

```c
struct intr_frame
{
  /* 由 intr_entry 压入的寄存器 */
  uint32_t edi;               /* Saved EDI. */
  uint32_t esi;               /* Saved ESI. */
  uint32_t ebp;               /* Saved EBP. */
  uint32_t esp_dummy;         /* Not used (PUSHA 的 ESP). */
  uint32_t ebx;               /* Saved EBX. */
  uint32_t edx;               /* Saved EDX. */
  uint32_t ecx;               /* Saved ECX. */
  uint32_t eax;               /* Saved EAX. */
  uint16_t gs, :16;           /* Saved GS. */
  uint16_t fs, :16;           /* Saved FS. */
  uint16_t es, :16;           /* Saved ES. */
  uint16_t ds, :16;           /* Saved DS. */

  /* 由 intrNN_stub 压入 */
  uint32_t vec_no;            /* Interrupt vector number. */
  uint32_t error_code;        /* Error code. */
  void *frame_pointer;        /* Saved EBP (for backtrace). */

  /* 由 CPU 压入 */
  void (*eip) (void);         /* Next instruction. */
  uint16_t cs, :16;           /* Code segment. */
  uint32_t eflags;            /* CPU flags. */
  void *esp;                  /* Stack pointer. */
  uint16_t ss, :16;           /* Stack segment. */
};
```

**栈布局图**：

```
中断发生时的栈布局（从高地址到低地址）：

┌─────────────────────────────────┐ 高地址
│             SS                  │ ← (仅在特权级改变时)
├─────────────────────────────────┤
│             ESP                 │ ← (仅在特权级改变时)
├─────────────────────────────────┤
│           EFLAGS                │ ← CPU 压入
├─────────────────────────────────┤
│             CS                  │ ← CPU 压入
├─────────────────────────────────┤
│             EIP                 │ ← CPU 压入
├─────────────────────────────────┤
│         Error Code              │ ← CPU/存根 压入
├─────────────────────────────────┤
│        Frame Pointer            │ ← 存根 压入
├─────────────────────────────────┤
│          vec_no                 │ ← 存根 压入
├─────────────────────────────────┤
│           DS                    │ ← intr_entry 压入
├─────────────────────────────────┤
│           ES                    │
├─────────────────────────────────┤
│           FS                    │
├─────────────────────────────────┤
│           GS                    │
├─────────────────────────────────┤
│      EAX, ECX, EDX, EBX         │ ← PUSHA
│      ESP_dummy, EBP, ESI, EDI   │
└─────────────────────────────────┘ 低地址 (ESP 指向这里)
```

## 中断注册

### 注册外部中断

```c
void
intr_register_ext (uint8_t vec_no, intr_handler_func *handler,
                   const char *name) 
{
  ASSERT (vec_no >= 0x20 && vec_no <= 0x2f);
  register_handler (vec_no, 0, INTR_OFF, handler, name);
}
```

**使用示例**（定时器）：

```c
/* timer.c */
void
timer_init (void) 
{
  /* ... 配置 PIT ... */
  
  intr_register_ext (0x20, timer_interrupt, "8254 Timer");
}
```

### 注册内部中断

```c
void
intr_register_int (uint8_t vec_no, int dpl, enum intr_level level,
                   intr_handler_func *handler, const char *name)
{
  ASSERT (vec_no < 0x20 || vec_no > 0x2f);
  register_handler (vec_no, dpl, level, handler, name);
}
```

**使用示例**（缺页异常）：

```c
/* exception.c */
void
exception_init (void) 
{
  /* ... */
  
  intr_register_int (14, 0, INTR_OFF, page_fault, "#PF Page-Fault Exception");
}
```

### register_handler() 实现

```c
static void
register_handler (uint8_t vec_no, int dpl, enum intr_level level,
                  intr_handler_func *handler, const char *name)
{
  ASSERT (intr_handlers[vec_no] == NULL);
  if (level == INTR_ON)
    idt[vec_no] = make_trap_gate (intr_stubs[vec_no], dpl);
  else
    idt[vec_no] = make_intr_gate (intr_stubs[vec_no], dpl);
  intr_handlers[vec_no] = handler;
  intr_names[vec_no] = name;
}
```

**关键选择**：

- `INTR_ON`：使用陷阱门（不自动关中断）→ 允许中断嵌套
- `INTR_OFF`：使用中断门（自动关中断）→ 禁止中断嵌套

## PIC EOI 处理

```c
static void
pic_end_of_interrupt (int irq) 
{
  ASSERT (irq >= 0x20 && irq < 0x30);

  /* Acknowledge master PIC. */
  outb (0x20, 0x20);

  /* Acknowledge slave PIC if this is a slave interrupt. */
  if (irq >= 0x28)
    outb (0xa0, 0x20);
}
```

**EOI 流程**：

```
IRQ 0-7 (主 PIC):
    │
    └─→ 向主 PIC 发送 EOI
        outb(0x20, 0x20)

IRQ 8-15 (从 PIC):
    │
    ├─→ 向主 PIC 发送 EOI
    │   outb(0x20, 0x20)
    │
    └─→ 向从 PIC 发送 EOI
        outb(0xa0, 0x20)
```

**为什么从 PIC 中断需要两个 EOI**？

因为从 PIC 是级联到主 PIC 的 IR2，所以：
1. 从 PIC 需要知道中断处理完成
2. 主 PIC 也需要知道（释放 IR2 线）

## 常见问题解答

### Q1: 为什么需要重映射 PIC？

**A**: 
- x86 架构规定向量 0-31 用于 CPU 异常
- 默认 PIC 将 IRQ 0-15 映射到向量 0-15
- 这与 CPU 异常冲突
- 重映射到 32-47 避免冲突

### Q2: 中断门和陷阱门的实际区别？

**A**: 
- 中断门：进入时自动 `CLI`（关中断）
- 陷阱门：保持中断状态不变
- 效果：中断门处理程序开始时中断是关闭的

### Q3: 为什么外部中断处理要关中断？

**A**: 
1. 防止中断嵌套导致栈溢出
2. 简化中断处理程序的编写
3. Pintos 的设计选择，不是必须的

### Q4: yield_on_return 有什么用？

**A**: 
- 允许中断处理程序请求线程切换
- 例如：定时器中断检测到时间片用完
- 在返回前（而不是中断处理中）切换，保证原子性

## 练习题

### 练习1：PIC 重映射验证

修改 `pic_init()`，将硬件中断映射到向量 64-79，需要修改哪些代码？

### 练习2：中断计数器

添加功能，统计每种中断发生的次数，并提供函数查询：

```c
unsigned int intr_get_count(uint8_t vec_no);
```

### 练习3：理解中断优先级

分析以下场景：
1. CPU 正在处理定时器中断（IRQ0，向量 0x20）
2. 此时键盘产生中断（IRQ1，向量 0x21）
3. 中断会被如何处理？

### 练习4：实现中断屏蔽

实现函数来单独屏蔽/解除屏蔽特定 IRQ：

```c
void irq_mask(int irq);
void irq_unmask(int irq);
```

**提示**：操作 PIC 的 IMR（中断屏蔽寄存器）。

## 下一篇预告

在下一篇文档中，我们将详细解析设备初始化过程，了解 Pintos 如何初始化定时器、键盘、串口等硬件设备。

## 参考资料

1. [Intel 64 and IA-32 Architectures Software Developer's Manual, Volume 3A](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html) - Chapter 6: Interrupt and Exception Handling
2. [8259A Programmable Interrupt Controller Datasheet](https://pdos.csail.mit.edu/6.828/2018/readings/hardware/8259A.pdf)
3. [OSDev Wiki - 8259 PIC](https://wiki.osdev.org/8259_PIC)
4. [OSDev Wiki - Interrupt Descriptor Table](https://wiki.osdev.org/Interrupt_Descriptor_Table)
