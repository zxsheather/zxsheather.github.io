---
layout: post
title: "Pintos Loader.S 详解（四）：加载内核"
date: 2026-01-21
categories: [技术, Pintos]
tags: [OS, Pintos, 汇编, 引导加载程序]
description: "Pintos 引导加载程序找到内核分区后，将内核从磁盘读取到内存中。"
---

## 概述

找到 Pintos 内核分区后，这部分代码负责将内核从磁盘读取到内存中。这是引导加载程序最重要的工作之一。

---

## 原始代码

```
#### We found a kernel.  The kernel's drive is in DL.  The partition
#### table entry for the kernel's partition is at ES:SI.  Our job now
#### is to read the kernel from disk and jump to its start address.

load_kernel:
	call puts
	.string "\rLoading"

	# Figure out number of sectors to read.  A Pintos kernel is
	# just an ELF format object, which doesn't have an
	# easy-to-read field to identify its own size (see [ELF1]).
	# But we limit Pintos kernels to 512 kB for other reasons, so
	# it's easy enough to just read the entire contents of the
	# partition or 512 kB from disk, whichever is smaller.
	mov %es:12(%si), %ecx		# EBP = number of sectors
	cmp $1024, %ecx			# Cap size at 512 kB
	jbe 1f
	mov $1024, %cx
1:

	mov %es:8(%si), %ebx		# EBX = first sector
	mov $0x2000, %ax		# Start load address: 0x20000

next_sector:
	# Read one sector into memory.
	mov %ax, %es			# ES:0000 -> load address
	call read_sector
	jc read_failed

	# Print '.' as progress indicator once every 16 sectors == 8 kB.
	test $15, %bl
	jnz 1f
	call puts
	.string "."
1:

	# Advance memory pointer and disk sector.
	add $0x20, %ax
	inc %bx
	loop next_sector

	call puts
	.string "\r"
```

---

## 前置知识

### 什么是 ELF 格式？

ELF（Executable and Linkable Format）是 Linux/Unix 系统上最常用的可执行文件格式。Pintos 内核就是一个 ELF 文件。

**ELF 文件的基本结构：**

```
┌─────────────────────────┐
│      ELF 头部           │ ← 包含入口地址、程序头表位置等
├─────────────────────────┤
│     程序头表            │ ← 描述各段如何加载到内存
├─────────────────────────┤
│                         │
│     代码段 (.text)      │ ← 可执行指令
│                         │
├─────────────────────────┤
│                         │
│     数据段 (.data)      │ ← 初始化的全局变量
│                         │
├─────────────────────────┤
│     其他段...           │
└─────────────────────────┘
```

### 为什么限制内核大小为 512KB？

1. **实模式内存限制**：在实模式下，只能访问 1MB 内存
2. **加载地址**：内核加载到 0x20000（128KB），到 640KB（0xA0000）有约 512KB 空间
3. **简化代码**：限制大小可以避免复杂的内存管理

### 内存布局

```
地址              内容
───────────────────────────────────
0x00000          中断向量表、BIOS 数据
...
0x07C00          Loader 代码
0x07E00          Loader 结束
...
0x20000  ←────── 内核加载起始地址
...
0xA0000  ←────── 内核加载结束地址（最大）
...
0xA0000-0xFFFFF  显存和 BIOS ROM
```

---

## 逐行详解

### 阶段 1：打印加载信息

```
load_kernel:
	call puts
	.string "\rLoading"
```

打印 "Loading"，告诉用户内核正在加载。

`\r`（回车符）将光标移动到行首，覆盖之前的 "Pintos hdaX" 输出。

---

### 阶段 2：计算要读取的扇区数

```
	mov %es:12(%si), %ecx		# ECX = number of sectors
	cmp $1024, %ecx			# Cap size at 512 kB
	jbe 1f
	mov $1024, %cx
1:
```

**逐行解释：**

1. **`mov %es:12(%si), %ecx`**：
   - 从分区表项偏移 12 处读取 4 字节（扇区数）
   - 存入 ECX 寄存器
   
   回顾分区表项结构：
   ```
   偏移 0:  启动标志
   偏移 4:  分区类型
   偏移 8:  起始 LBA（4 字节）
   偏移 12: 扇区总数（4 字节）← 我们读取这里
   ```

2. **`cmp $1024, %ecx`**：
   - 比较 ECX 和 1024
   - 1024 扇区 × 512 字节/扇区 = 512KB

3. **`jbe 1f`**：
   - `jbe` = Jump if Below or Equal（无符号小于等于则跳转）
   - `1f` = 向前（forward）找标签 `1:`
   - 如果扇区数 ≤ 1024，跳过下一条指令

4. **`mov $1024, %cx`**：
   - 如果扇区数 > 1024，将其限制为 1024
   - 注意这里只修改 CX（16 位），高 16 位被清零，但没关系因为 1024 足够用 16 位表示

**为什么要限制大小？**

- 保护内存：防止覆盖 640KB 以上的系统区域
- 简化循环：`loop` 指令使用 CX，16 位足够

---

### 阶段 3：获取起始扇区号

```
	mov %es:8(%si), %ebx		# EBX = first sector
	mov $0x2000, %ax		# Start load address: 0x20000
```

1. **`mov %es:8(%si), %ebx`**：
   - 从分区表项偏移 8 处读取起始 LBA
   - 这是内核在磁盘上的第一个扇区

2. **`mov $0x2000, %ax`**：
   - 设置加载地址的段部分
   - 段地址 0x2000 × 16 = 线性地址 0x20000

---

### 阶段 4：读取扇区循环

```
next_sector:
	# Read one sector into memory.
	mov %ax, %es			# ES:0000 -> load address
	call read_sector
	jc read_failed
```

**循环开始：**

1. **`mov %ax, %es`**：设置 ES 段寄存器为当前加载地址
2. **`call read_sector`**：读取一个扇区到 ES:0000
   - DL = 硬盘号（在整个过程中保持不变）
   - EBX = 扇区号
   - ES:0 = 目标内存地址
3. **`jc read_failed`**：如果读取失败（CF=1），跳转到错误处理

---

### 阶段 5：显示进度

```
	# Print '.' as progress indicator once every 16 sectors == 8 kB.
	test $15, %bl
	jnz 1f
	call puts
	.string "."
1:
```

**每 16 个扇区打印一个点。**

1. **`test $15, %bl`**：
   - 测试 BL 的低 4 位是否为 0
   - `test` 指令执行 AND 运算，只设置标志位，不保存结果
   - 15 = 0b1111 = 0xF

2. **`jnz 1f`**：
   - `jnz` = Jump if Not Zero（如果结果不为零则跳转）
   - 如果 BL & 0xF ≠ 0，跳过打印

**为什么是 16 扇区？**

- 16 扇区 × 512 字节 = 8KB
- 512KB 内核 / 8KB = 64 个点
- 这样可以显示合理的进度，不会太快也不会太慢

**`test` 指令详解：**

| BL 值 | BL & 15 | 结果 |
|-------|---------|------|
| 0 | 0 & 15 = 0 | 打印 |
| 1 | 1 & 15 = 1 | 不打印 |
| 15 | 15 & 15 = 15 | 不打印 |
| 16 | 16 & 15 = 0 | 打印 |
| 32 | 32 & 15 = 0 | 打印 |

---

### 阶段 6：前进到下一个扇区

```
	# Advance memory pointer and disk sector.
	add $0x20, %ax
	inc %bx
	loop next_sector
```

1. **`add $0x20, %ax`**：
   - 内存地址增加 0x20 个段单位
   - 0x20 × 16 = 512 字节 = 1 个扇区

2. **`inc %bx`**：
   - 扇区号加 1

3. **`loop next_sector`**：
   - CX 减 1
   - 如果 CX ≠ 0，跳转到 `next_sector` 继续循环
   - 如果 CX = 0，循环结束

**`loop` 指令的等效代码：**

```
loop next_sector
# 等价于：
dec %cx
jnz next_sector
```

---

### 阶段 7：完成加载

```
	call puts
	.string "\r"
```

打印回车符，准备下一行输出。

---

## 内存变化示意图

**加载过程中内存的变化：**

```
初始状态：
                    0x20000  0x20200  0x20400  ...
                    ┌────────┬────────┬────────┬───
内存:               │  空    │  空    │  空    │
                    └────────┴────────┴────────┴───

读取扇区 0 后：
                    ┌────────┬────────┬────────┬───
内存:               │扇区 0  │  空    │  空    │
                    └────────┴────────┴────────┴───
                    ES=0x2000

读取扇区 1 后：
                    ┌────────┬────────┬────────┬───
内存:               │扇区 0  │扇区 1  │  空    │
                    └────────┴────────┴────────┴───
                             ES=0x2020

读取扇区 2 后：
                    ┌────────┬────────┬────────┬───
内存:               │扇区 0  │扇区 1  │扇区 2  │
                    └────────┴────────┴────────┴───
                                      ES=0x2040

... 继续直到读完所有扇区 ...
```

---

## 加载地址计算示例

假设内核占 100 个扇区（约 50KB）：

| 循环次数 | CX | EBX (扇区) | AX (段) | ES:0 (线性地址) |
|----------|-----|-----------|---------|----------------|
| 1 | 100 | N | 0x2000 | 0x20000 |
| 2 | 99 | N+1 | 0x2020 | 0x20200 |
| 3 | 98 | N+2 | 0x2040 | 0x20400 |
| ... | ... | ... | ... | ... |
| 100 | 1 | N+99 | 0x3260 | 0x32600 |
| 结束 | 0 | - | - | - |

其中 N 是分区的起始扇区号。

---

## 实际输出示例

```
Loading..............................................................
```

- "Loading" 后面跟着很多点
- 每个点代表 8KB 已加载
- 如果内核是 256KB，会有 32 个点

---

## 常见问题

### Q1: 如果分区比 512KB 小会怎样？

代码只读取分区实际包含的扇区数。假设分区只有 100 扇区（50KB），就只读取 100 扇区。

### Q2: 为什么段地址每次增加 0x20？

在实模式下：
- 物理地址 = 段地址 × 16 + 偏移
- 一个扇区 = 512 字节
- 段地址增加 0x20 意味着物理地址增加 0x20 × 16 = 512 字节

### Q3: 为什么使用 16 位的 BX 而不是 32 位的 EBX？

实际上代码用 `inc %bx` 只增加 BX 的低 16 位。对于小于 32MB 的分区（64K 扇区），这足够了。Pintos 的设计假设不会有这么大的分区。

### Q4: 读取失败的原因有哪些？

- 硬盘物理故障
- 扇区号超出范围
- BIOS 驱动问题
- 模拟器配置错误

### Q5: 为什么注释说 ECX = EBP？

这是代码中的一个**注释错误**。应该是 "ECX = number of sectors"，不是 EBP。代码本身是正确的。

---

## 性能考虑

### 每次只读一个扇区是否低效？

是的，但有几个原因：

1. **简单性**：代码更简单，更可靠
2. **512 字节限制**：引导扇区空间有限
3. **兼容性**：某些老 BIOS 每次只能读有限扇区

现代引导加载程序（如 GRUB）会使用更高效的多扇区读取。

### 加载时间估算

假设：
- 硬盘读取速度：50MB/s
- 内核大小：512KB

加载时间 ≈ 512KB / 50MB/s ≈ 10ms

实际上大部分时间花在 BIOS 中断调用的开销上，但对于启动过程来说仍然很快。

---

## 练习思考

1. 如果要支持大于 512KB 的内核，需要修改哪些地方？

2. 为什么进度显示选择每 16 扇区一个点，而不是每 8 扇区或每 32 扇区？

3. 如果内核恰好是 0 字节（空分区），这段代码会发生什么？

4. `loop` 指令只检查 CX（16 位），如果需要读取超过 65535 个扇区怎么办？

---

## 练习答案

<details>
<summary>点击查看答案 1</summary>
<div markdown="1">

**支持大于 512KB 的内核需要修改以下地方：**

1. **修改大小限制**：
   ```asm
   cmp $1024, %ecx      # 原来：512KB = 1024 扇区
   # 改为：
   cmp $2048, %ecx      # 1MB = 2048 扇区
   ```

2. **考虑内存布局问题**：
   - 0x20000 到 0xA0000（640KB 边界）只有约 512KB
   - 要加载更大的内核，需要：
     - 使用高端内存（需要 A20 门控）
     - 或切换到保护模式后再加载
     - 或分段加载（先加载一部分，跳转后再加载剩余）

3. **可能需要启用 A20 门**：
   ```asm
   # A20 门控代码（允许访问 1MB 以上内存）
   in $0x92, %al
   or $2, %al
   out %al, $0x92
   ```

4. **代码空间限制**：
   - 这些修改可能超出 512 字节限制
   - 可能需要两阶段引导

</div>
</details>

<details>
<summary>点击查看答案 2</summary>
<div markdown="1">

**选择每 16 扇区（8KB）一个点的原因：**

1. **视觉效果**：
   - 512KB 内核 ÷ 8KB = 64 个点
   - 64 个点在一行内显示效果好（80 列屏幕）
   - 不会太少（看不到进度）也不会太多（刷屏）

2. **如果每 8 扇区（4KB）一个点**：
   - 512KB ÷ 4KB = 128 个点
   - 超过一行，需要换行或滚屏
   - 视觉上太密集

3. **如果每 32 扇区（16KB）一个点**：
   - 512KB ÷ 16KB = 32 个点
   - 可能太稀疏，进度感不强
   - 但也是可行的选择

4. **代码简洁性**：
   - `test $15, %bl` 检查低 4 位是否为 0
   - 15 = 0xF = 0b1111
   - 恰好对应 16 的倍数
   - 非常简洁的位操作

</div>
</details>

<details>
<summary>点击查看答案 3</summary>
<div markdown="1">

**如果内核是 0 字节（ECX = 0），代码行为如下：**

1. **`loop` 指令的行为**：
   - `loop` 先将 CX 减 1
   - 如果 CX = 0，减 1 后变成 0xFFFF（下溢）
   - CX ≠ 0，所以会继续循环！

2. **结果**：
   - 会读取 65535 个扇区（约 32MB）
   - 这会覆盖大量内存
   - 可能读取超出磁盘的扇区，导致错误

3. **这是一个潜在的 bug**：
   - 应该在循环前检查 CX 是否为 0
   - 可以添加：
   ```asm
   test %cx, %cx
   jz load_done      # CX = 0，跳过循环
   ```

4. **实际情况**：
   - Pintos 的分区创建工具不会创建空分区
   - 所以这种情况在实践中不会发生
   - 但从代码健壮性角度，应该处理

</div>
</details>

<details>
<summary>点击查看答案 4</summary>
<div markdown="1">

**如果需要读取超过 65535 个扇区（约 32MB），需要修改循环逻辑：**

1. **问题分析**：
   - `loop` 指令只使用 CX（16 位）
   - 最多循环 65535 次
   - 65535 × 512B ≈ 32MB

2. **解决方案 1：使用 32 位计数器**
   ```asm
   next_sector:
       # ... 读取扇区 ...
       dec %ecx            # 32 位递减
       jnz next_sector     # 不用 loop，用 jnz
   ```

3. **解决方案 2：嵌套循环**
   ```asm
   # 假设 ECX 中有扇区总数
   mov %ecx, %edx      # 保存高 16 位
   shr $16, %edx
   outer_loop:
       mov $0xFFFF, %cx
   inner_loop:
       # ... 读取扇区 ...
       loop inner_loop
       dec %dx
       jnz outer_loop
   ```

4. **实际考虑**：
   - 在实模式下很难访问超过 1MB 内存
   - 需要切换到保护模式或使用 Unreal Mode
   - Pintos 限制内核为 512KB，不需要这个优化

</div>
</details>

---

## 下一部分

内核加载到内存后，下一步是跳转到内核入口点执行。请参阅下一篇文章。
