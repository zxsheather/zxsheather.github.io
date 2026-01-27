---
layout: post
title: "Pintos Loader.S 详解（九）：read_sector 函数"
date: 2026-01-21
categories: [技术, Pintos]
tags: [OS, Pintos, 汇编, 引导加载程序]
description: "Pintos 引导加载程序中 read_sector 函数的实现，使用 BIOS 扩展读取功能从磁盘读取扇区。"
---

## 概述

`read_sector` 函数是引导加载程序的核心功能之一，负责从磁盘读取一个扇区（512 字节）到内存。它使用 BIOS 的扩展读取功能（Extended Read），支持 LBA 寻址，可以访问大于 8GB 的硬盘。

---

## 原始代码

```
#### Sector read subroutine.  Takes a drive number in DL (0x80 = hard
#### disk 0, 0x81 = hard disk 1, ...) and a sector number in EBX, and
#### reads the specified sector into memory at ES:0000.  Returns with
#### carry set on error, clear otherwise.  Preserves all
#### general-purpose registers.

read_sector:
	pusha
	sub %ax, %ax
	push %ax			# LBA sector number [48:63]
	push %ax			# LBA sector number [32:47]
	push %ebx			# LBA sector number [0:31]
	push %es			# Buffer segment
	push %ax			# Buffer offset (always 0)
	push $1				# Number of sectors to read
	push $16			# Packet size
	mov $0x42, %ah			# Extended read
	mov %sp, %si			# DS:SI -> packet
	int $0x13			# Error code in CF
	popa				# Pop 16 bytes, preserve flags
popa_ret:
	popa
	ret				# Error code still in CF
```

---

## 前置知识

### 磁盘寻址方式

历史上有两种主要的磁盘寻址方式：

#### CHS（Cylinder-Head-Sector）寻址

```
      柱面 (Cylinder)
         │
    ┌────┼────┐
    │ ┌──┼──┐ │     磁头 (Head)
    │ │  │  │ │     ↓
    │ │  │  │ │   ┌───┐
    │ │  ●──┼─┼───│ H0│  扇区 (Sector)
    │ │  │  │ │   ├───┤
    │ │  │  │ │   │ H1│
    │ └──┼──┘ │   └───┘
    └────┼────┘
```

- **柱面**：同一半径的所有磁道
- **磁头**：选择哪个盘面
- **扇区**：磁道上的具体位置

**CHS 的限制：**
- 柱面: 10 位 (0-1023)
- 磁头: 8 位 (0-255)
- 扇区: 6 位 (1-63)
- 最大: 1024 × 256 × 63 × 512 = **8.4 GB**

#### LBA（Logical Block Addressing）寻址

```
扇区 0    扇区 1    扇区 2    ...    扇区 N
┌────────┬────────┬────────┬─────┬────────┐
│   0    │   1    │   2    │ ... │   N    │
└────────┴────────┴────────┴─────┴────────┘
```

- 扇区从 0 开始连续编号
- 简单直观
- 48 位 LBA 支持 **128 PB**

### BIOS INT 13h 扩展

为了支持 LBA 和大硬盘，BIOS 提供了扩展磁盘服务：

| AH 值 | 功能 |
|-------|------|
| 0x41 | 检查扩展是否支持 |
| 0x42 | **扩展读取**（我们使用这个）|
| 0x43 | 扩展写入 |
| 0x44 | 验证扇区 |
| 0x48 | 获取驱动器参数 |

### DAP（Disk Address Packet）

扩展读取使用一个叫 DAP 的数据结构来指定参数：

```
偏移  大小  内容
────────────────────────────
0     1    数据包大小（16 或 24）
1     1    保留（必须为 0）
2     2    要读取的扇区数
4     2    缓冲区偏移
6     2    缓冲区段
8     8    起始 LBA 扇区号（64 位）
```

---

## 逐行详解

### 第 1 行：保存寄存器

```
read_sector:
	pusha
```

保存所有通用寄存器。函数承诺不修改调用者的寄存器。

---

### 第 2-8 行：在栈上构建 DAP

```
	sub %ax, %ax
	push %ax			# LBA sector number [48:63]
	push %ax			# LBA sector number [32:47]
	push %ebx			# LBA sector number [0:31]
	push %es			# Buffer segment
	push %ax			# Buffer offset (always 0)
	push $1				# Number of sectors to read
	push $16			# Packet size
```

这段代码在栈上构建 DAP 结构。由于栈是向下增长的，我们按**逆序**压入字段。

**逐条分析：**

1. **`sub %ax, %ax`**：AX = 0，用于后续的零值

2. **`push %ax`** (两次)：
   - 压入 LBA 的高 32 位（位 32-63）
   - 这里总是 0，因为我们不访问超大硬盘

3. **`push %ebx`**：
   - EBX 包含要读取的扇区号（LBA 位 0-31）
   - 注意这是 32 位压栈

4. **`push %es`**：
   - 缓冲区的段地址
   - 调用者已经设置好了

5. **`push %ax`**：
   - 缓冲区偏移 = 0
   - 总是从段的开始读取

6. **`push $1`**：
   - 读取 1 个扇区

7. **`push $16`**：
   - DAP 大小 = 16 字节

**栈上的 DAP 结构：**

```
      高地址
   ┌─────────────┐
   │   pusha 的  │
   │   寄存器    │
   ├─────────────┤
   │  LBA[48:63] │ = 0
   ├─────────────┤
   │  LBA[32:47] │ = 0
   ├─────────────┤
   │  LBA[0:31]  │ = EBX (扇区号)
   ├─────────────┤
   │   段地址    │ = ES
   ├─────────────┤
   │   偏移      │ = 0
   ├─────────────┤
   │   扇区数    │ = 1
   ├─────────────┤
   │   大小      │ = 16      ← SP 指向这里
   └─────────────┘
      低地址
```

---

### 第 9-11 行：调用 BIOS 扩展读取

```
	mov $0x42, %ah			# Extended read
	mov %sp, %si			# DS:SI -> packet
	int $0x13			# Error code in CF
```

**`mov $0x42, %ah`**：
- 选择扩展读取功能

**`mov %sp, %si`**：
- 让 SI 指向栈顶（DAP 的开始）
- BIOS 通过 DS:SI 访问 DAP
- 由于 DS = 0，DS:SI = 0:SP = 栈上的 DAP

**`int $0x13`**：
- 调用 BIOS 磁盘服务
- 参数：
  - AH = 0x42（扩展读取）
  - DL = 驱动器号（调用者设置）
  - DS:SI = DAP 地址

**返回值：**
- CF = 0：成功
- CF = 1：失败，AH = 错误码

---

### 第 12 行：清理 DAP

```
	popa				# Pop 16 bytes, preserve flags
```

**这是一个巧妙的技巧！**

`popa` 正常用于恢复寄存器，但这里用它来弹出 16 字节的 DAP：
- DAP 大小 = 16 字节
- `popa` 弹出 16 字节
- 正好清理了 DAP

**关键：`popa` 不影响标志寄存器**，所以 CF（进位标志）保持 BIOS 设置的值。

**寄存器会变吗？**

会！`popa` 把 DAP 的数据当作寄存器值弹出。但没关系，因为：
1. 下一条 `popa` 会恢复正确的寄存器值
2. 这只是一个清理技巧

---

### 第 13-14 行：恢复寄存器并返回

```
popa_ret:
	popa
	ret				# Error code still in CF
```

**`popa`**：
- 恢复最初 `pusha` 保存的寄存器

**`ret`**：
- 返回调用者
- CF 仍然包含 BIOS 的返回状态

**`popa_ret` 标签**：
- 这个标签被 `putc` 函数共享使用（见前一节）

---

## 内存和栈的变化

### 调用前

```
参数:
- DL = 0x80 (硬盘 0)
- EBX = 100 (扇区号)
- ES = 0x2000 (目标段)

栈:
   [返回地址]  ← SP
```

### 执行后

```
结果:
- ES:0000 (即 0x20000) 包含扇区 100 的内容
- CF = 0 (成功) 或 1 (失败)
- 所有寄存器恢复原值
```

---

## DAP 字段详解

| 字段 | 大小 | Pintos 中的值 | 说明 |
|------|------|--------------|------|
| 大小 | 1 字节 | 16 | DAP 结构大小 |
| 保留 | 1 字节 | 0 | 必须为 0（和大小字段一起压入）|
| 扇区数 | 2 字节 | 1 | 只读 1 个扇区 |
| 偏移 | 2 字节 | 0 | 缓冲区偏移 |
| 段 | 2 字节 | ES | 缓冲区段 |
| LBA | 8 字节 | EBX | 扇区号（只用低 32 位）|

### 为什么 LBA 是 64 位？

虽然 Pintos 只用 32 位（最大 2TB），但 BIOS 接口是 64 位的，所以高 32 位用 0 填充。

---

## 错误处理

### 常见错误码（AH 中返回）

| 错误码 | 含义 |
|--------|------|
| 0x00 | 成功 |
| 0x01 | 无效命令 |
| 0x02 | 地址标记未找到 |
| 0x04 | 扇区未找到 |
| 0x05 | 重置失败 |
| 0x07 | 驱动器参数活动失败 |
| 0x09 | DMA 越界 |
| 0x0A | 坏扇区标志 |
| 0x10 | ECC 数据错误 |
| 0x20 | 控制器失败 |
| 0x40 | 寻道失败 |
| 0x80 | 超时 |
| 0xAA | 驱动器未就绪 |
| 0xBB | 未定义错误 |

### 调用者如何检查错误

```
call read_sector
jc error_handler        # 如果 CF=1，跳转到错误处理
# 成功，继续...
```

---

## 为什么在栈上构建 DAP？

### 替代方案 1：静态分配

```
# 静态 DAP
.data
dap:
    .byte 16        # 大小
    .byte 0         # 保留
    .word 1         # 扇区数
    .word 0         # 偏移
    .word 0         # 段 (需要填充)
    .long 0         # LBA (需要填充)
    .long 0
```

**问题：**
- 浪费 16 字节宝贵的代码空间
- 需要额外代码填充可变字段

### 替代方案 2：代码中嵌入

```
mov $dap, %si
# ...填充 dap...
int $0x13
```

**问题：**
- 仍然浪费空间
- 代码更复杂

### Pintos 方案

在栈上动态构建 DAP：
- 不占用额外代码空间
- 参数（ES, EBX）已经在寄存器中
- 用 `popa` 清理，不需要手动调整 SP

---

## 两个 popa 的解释

```
read_sector:
    pusha                   # (1) 保存寄存器，16 字节
    ...
    push ...                # 构建 DAP，16 字节
    push ...
    int $0x13
    popa                    # (2) 弹出 DAP，16 字节
popa_ret:
    popa                    # (3) 恢复寄存器，16 字节
    ret
```

栈的变化：

```
调用后:
    [DAP 16字节]
    [寄存器 16字节]
    [返回地址]

第一个 popa 后:
    [寄存器 16字节]
    [返回地址]

第二个 popa 后:
    [返回地址]   ← 正确状态！
```

---

## 常见问题

### Q1: 为什么用扩展读取而不是传统 INT 13h？

传统 INT 13h（AH=02h）使用 CHS 寻址，限制 8.4GB。扩展读取支持 LBA，可以访问任意大小的硬盘。

### Q2: 如果 BIOS 不支持扩展读取怎么办？

非常老的 BIOS 可能不支持。但自从 1990 年代中期以来，几乎所有 BIOS 都支持。Pintos 假设支持。

### Q3: 为什么每次只读一个扇区？

- 简单
- 兼容性好
- 512 字节代码空间限制
- 对于 Pintos 来说足够快

### Q4: 能否读取多个连续扇区？

可以，只需修改 DAP 的扇区数字段。但需要：
- 确保缓冲区足够大
- 某些 BIOS 有单次传输限制

### Q5: popa 把 DAP 弹到寄存器里，不会出问题吗？

不会，因为紧接着的第二个 `popa` 会恢复正确的寄存器值。第一个 `popa` 只是一个清理 16 字节的技巧。

---

## 性能考虑

### 每扇区一次 BIOS 调用

```
读取 100 个扇区:
- Pintos: 100 次 INT 13h
- 优化版: 可能只需 1-2 次

每次 INT 13h 调用开销:
- 中断处理
- 模式切换（如果在保护模式）
- BIOS 初始化
```

对于引导加载程序，这种开销是可接受的。

### 传输速率

受限于：
1. 硬盘物理速度
2. BIOS 效率
3. PIO 模式（没有 DMA）

典型速率：几 MB/s（足够引导）

---

## 练习思考

1. 如果要读取 2 个扇区，需要修改哪里？缓冲区需要多大？

2. 为什么 `push $16` 后紧跟的字节被设为 0？（提示：DAP 结构）

3. 如果 EBX 超过 32 位能表示的范围（约 2TB），会发生什么？

4. 能否用 `add $16, %sp` 代替第一个 `popa` 来清理 DAP？有什么区别？

5. 为什么 `popa_ret` 标签被两个函数共享？

---

## 练习答案

<details>
<summary>点击查看答案 1</summary>
<div markdown="1">

**读取 2 个扇区的修改：**

```asm
read_two_sectors:
    pusha
    sub %ax, %ax
    push %ax            # LBA [48:63]
    push %ax            # LBA [32:47]
    push %ebx           # LBA [0:31]
    push %es            # 缓冲区段
    push %ax            # 缓冲区偏移 = 0
    push $2             # 扇区数 = 2 ← 修改这里
    push $16            # 包大小 = 16
    mov $0x42, %ah
    mov %sp, %si
    int $0x13
    popa
    popa
    ret
```

**缓冲区大小**：
- 2 个扇区 × 512 字节 = **1024 字节 = 1KB**
- ES:0x0000 到 ES:0x03FF

**注意**：
- 某些 BIOS 对单次传输有限制（通常 127 扇区）
- 缓冲区不能跨越 64KB 段边界

</div>
</details>

<details>
<summary>点击查看答案 2</summary>
<div markdown="1">

**DAP 结构的第二个字节必须为 0：**

**DAP 结构**：
```
偏移 0: 包大小 (16 或 24)
偏移 1: 保留 (必须为 0)
偏移 2: 扇区数
...
```

**代码分析**：
```asm
push $16            # 压入 16 位即时数
```

压入 16 位数到栈时：
- 低字节 = 16 = 0x10（包大小）
- 高字节 = 0（保留字段，正好为 0！）

**内存布局**：
```
栈顶 → [10] [00] [01] [00] ...
          │    │    └────┴ 扇区数 = 1
          │    └─ 保留 = 0 ✓
          └─ 包大小 = 16
```

这是一个巧妙的副作用，节省了一次 push 操作。

</div>
</details>

<details>
<summary>点击查看答案 3</summary>
<div markdown="1">

**如果需要访问超过 2TB 的扇区，当前代码会失败：**

1. **问题分析**：
   - EBX 是 32 位，最大值 2^32 - 1
   - 2^32 × 512 字节 = 2TB
   - DAP 的 LBA 字段是 64 位，支持更大

2. **代码限制**：
   ```asm
   push %ax      # LBA [48:63] = 0
   push %ax      # LBA [32:47] = 0
   push %ebx     # LBA [0:31] = 扇区号
   ```
   - 只使用了低 32 位
   - 高 32 位始终为 0

3. **解决方案**：
   ```asm
   # 使用 64 位 LBA
   push %ecx     # LBA 高 32 位
   push %ebx     # LBA 低 32 位
   # ECX:EBX 合起来是 64 位扇区号
   ```

4. **实际情况**：
   - Pintos 的磁盘远小于 2TB
   - 在引导阶段不需要 64 位 LBA
   - 简化代码是合理的

</div>
</details>

<details>
<summary>点击查看答案 4</summary>
<div markdown="1">

**`add $16, %sp` 与 `popa` 的区别：**

```asm
# 方案 A: 使用 popa
popa                # 1 字节

# 方案 B: 使用 add
add $16, %sp        # 4 字节 (83 C4 10 或 81 C4 10 00)
```

**比较**：

| 方面 | popa | add $16, %sp |
|------|------|-------------|
| 字节数 | 1 | 3-4 |
| 寄存器 | 修改所有通用寄存器 | 只修改 SP |
| 标志 | 不影响 | 不影响 |

**为什么 popa 更好**：
1. 节省 2-3 字节
2. 不影响标志寄存器（CF 保持不变）
3. 虽然修改了寄存器，但紧接着的第二个 popa 会恢复正确的值

</div>
</details>

<details>
<summary>点击查看答案 5</summary>
<div markdown="1">

**`popa_ret` 被 `putc` 和 `read_sector` 共享的原因：**

1. **两个函数都以相同方式结束**：
   ```asm
   # putc 和 read_sector 的结尾
   popa    # 恢复寄存器
   ret     # 返回
   ```

2. **节省代码空间**：
   - 共享 2 条指令
   - 节省 2-3 字节

3. **实现方式**：
   ```asm
   putc:
       pusha
       # ... 操作 ...
       jmp popa_ret    # 跳转到共享代码
       # 或者直接掉落到 popa_ret

   read_sector:
       pusha
       # ... 操作 ...
       popa            # 清理 DAP
   popa_ret:
       popa            # 恢复寄存器
       ret
   ```

4. **代码组织**：
   - `putc` 和 `read_sector` 物理上相邻
   - `putc` 的结尾自然掉落到 `popa_ret`
   - 巧妙的代码布局

</div>
</details>

---

## 代码复习

完整的 `read_sector` 函数，带详细注释：

```
# 读取一个磁盘扇区到内存
# 参数:
#   DL = 驱动器号 (0x80 = 第一个硬盘)
#   EBX = LBA 扇区号
#   ES:0 = 目标缓冲区
# 返回:
#   CF = 0 成功, CF = 1 失败
# 保留所有通用寄存器

read_sector:
    pusha                       # 保存所有寄存器

    # 在栈上构建 DAP (Disk Address Packet)
    sub %ax, %ax
    push %ax                    # LBA [48:63] = 0
    push %ax                    # LBA [32:47] = 0
    push %ebx                   # LBA [0:31] = 扇区号
    push %es                    # 缓冲区段
    push %ax                    # 缓冲区偏移 = 0
    push $1                     # 扇区数 = 1
    push $16                    # 包大小 = 16 字节

    mov $0x42, %ah              # 扩展读取
    mov %sp, %si                # DS:SI -> DAP
    int $0x13                   # 调用 BIOS

    popa                        # 弹出 DAP (16 字节)
                                # 注意: 不影响 CF

popa_ret:
    popa                        # 恢复寄存器
    ret                         # CF 包含结果
```

---

## 下一部分

最后，我们来看 loader.S 末尾的数据结构定义。请参阅下一篇文章。
