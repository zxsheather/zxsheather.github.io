---
layout: post
title: "Pintos Loader.S 详解（六）：错误处理"
date: 2026-01-21
categories: [技术, Pintos]
tags: [OS, Pintos, 汇编, 引导加载程序]
description: "Pintos 引导加载程序的错误处理机制，包括磁盘读取失败和找不到分区等情况。"
---

## 概述

在引导过程中，很多事情可能出错：硬盘读取失败、找不到分区、找不到内核等。这部分代码负责处理这些错误情况，向用户显示错误信息，并通知 BIOS 启动失败。

---

## 原始代码

```
read_failed:
start:
	# Disk sector read failed.
	call puts
1:	.string "\rBad read\r"

	# Notify BIOS that boot failed.  See [IntrList].
	int $0x18
```

以及前面的：

```
no_such_drive:
no_boot_partition:
	# Didn't find a Pintos kernel partition anywhere, give up.
	call puts
	.string "\rNot found\r"

	# Notify BIOS that boot failed.  See [IntrList].
	int $0x18
```

---

## 错误类型分析

### 错误 1：磁盘读取失败（Bad read）

**触发条件：**
- `read_sector` 函数返回时 CF（进位标志）为 1
- 可能的原因：
  - 物理硬盘故障
  - 坏扇区
  - BIOS 驱动问题
  - 扇区号超出范围

**发生位置：**
```
call read_sector
jc read_failed      # 如果 CF=1，跳转到错误处理
```

### 错误 2：找不到驱动器（No such drive）

**触发条件：**
- 尝试读取不存在的硬盘的 MBR
- `read_sector` 在读取扇区 0 时失败

**发生位置：**
```
read_mbr:
    ...
    call read_sector
    jc no_such_drive    # 硬盘不存在
```

### 错误 3：找不到启动分区（Not found）

**触发条件：**
- 扫描完所有硬盘和分区
- 没有找到类型为 0x20（Pintos）且可启动（0x80）的分区

**发生位置：**
```
next_drive:
    inc %dl
    jnc read_mbr        # 继续扫描下一个硬盘
                        # 如果溢出，跳到 no_boot_partition

no_such_drive:
no_boot_partition:
    # 打印 "Not found"
```

---

## 逐行详解

### 错误处理入口点

```
read_failed:
start:
```

这里有两个标签指向同一位置！

**`read_failed`**：磁盘读取失败时跳转到这里
**`start`**：用于存储跳转地址（在成功路径中被覆盖）

这是一个巧妙的代码复用：
- 失败时：执行错误处理代码
- 成功时：这块内存被跳转地址覆盖

---

### 打印错误信息

```
	call puts
1:	.string "\rBad read\r"
```

**分析：**

1. **`call puts`**：调用字符串打印函数
2. **`1:`**：局部标签（用于内部跳转，不影响其他代码）
3. **`.string "\rBad read\r"`**：
   - `\r`（回车符）将光标移动到行首
   - "Bad read" 是错误信息
   - 最后的 `\r` 确保光标在行首

**为什么用 `\r` 而不是 `\n`？**

回车符 `\r` 只移动光标到行首，不换行。这样可以：
- 覆盖之前的 "Loading..." 输出
- 不浪费屏幕空间
- 清晰显示错误发生

---

### 通知 BIOS 启动失败

```
	int $0x18
```

**INT 18h 是什么？**

这是 BIOS 的"启动失败"中断。当引导加载程序无法启动操作系统时，调用此中断。

**BIOS 可能的响应：**

| BIOS 行为 | 说明 |
|-----------|------|
| 尝试下一个启动设备 | 如果启动顺序中还有其他设备 |
| 显示错误信息 | "No bootable device found" |
| 进入 BIOS 设置 | 让用户选择其他启动方式 |
| 执行 ROM BASIC | 在很老的系统上 |
| 系统挂起 | 什么都不做 |

**历史背景：**

在早期 IBM PC 上，INT 18h 会尝试从 ROM 中启动 BASIC 解释器。现代 BIOS 通常显示错误或尝试其他启动设备。

---

### "Not found" 错误处理

```
no_such_drive:
no_boot_partition:
	call puts
	.string "\rNot found\r"
	int $0x18
```

两种不同的错误使用相同的处理代码：
- **no_such_drive**：硬盘不存在
- **no_boot_partition**：找不到 Pintos 分区

它们共享同一个错误信息 "Not found"，因为对用户来说结果是一样的：无法启动。

---

## 代码复用详解

### 为什么 `start` 和 `read_failed` 是同一位置？

这是为了节省空间。让我们详细分析：

**需要的空间：**
- 跳转地址存储：4 字节
- 错误处理代码：约 10+ 字节

**复用方案：**
```
                 成功路径                    失败路径
                    │                           │
                    ▼                           ▼
start/read_failed: ┌───┬───┬───┬───┐    ┌───────────────┐
                   │ 跳│ 转│ 地│ 址│    │call puts      │
                   └───┴───┴───┴───┘    │"Bad read"     │
                         │               └───────────────┘
                         ▼
                    ljmp *start
                    (使用这4字节跳转)
```

**成功时：**
1. `mov %dx, start` 覆盖 `call` 指令的前 2 字节
2. `movw $0x2000, start + 2` 覆盖接下来的 2 字节
3. `ljmp *start` 从这 4 字节读取跳转地址

**失败时：**
1. 直接执行 `call puts`
2. 打印错误信息
3. 调用 INT 18h

---

## 错误显示时序

```
正常启动:
Pintos hda1234
Loading....................
(跳转到内核，不再显示)

磁盘读取失败:
Pintos hda1
Loading.....
Bad read
(系统挂起或 BIOS 接管)

找不到分区:
Pintos hda1234 hdb1234
Not found
(系统挂起或 BIOS 接管)
```

---

## 进位标志（Carry Flag）详解

`read_sector` 使用进位标志 CF 报告错误：

```
read_sector:
    ...
    int $0x13           # BIOS 磁盘服务
    ...
    ret                 # CF 保持 BIOS 设置的值

# 调用方检查 CF：
call read_sector
jc error_handler        # Jump if Carry (CF=1)
```

**为什么用 CF 而不是返回值？**

1. **效率**：不需要额外的寄存器或内存
2. **BIOS 约定**：INT 13h 本身就用 CF 报告错误
3. **简单**：一条 `jc` 指令就能检查

**CF 的两种状态：**

| CF 值 | 含义 |
|-------|------|
| 0 | 操作成功 |
| 1 | 操作失败 |

---

## 调试技巧

### 如何诊断 "Bad read" 错误

1. **检查硬盘镜像**
   ```bash
   # 验证镜像文件完整性
   ls -l os.dsk
   xxd os.dsk | head
   ```

2. **检查 QEMU 参数**
   ```bash
   # 确保硬盘正确连接
   qemu-system-i386 -hda os.dsk ...
   ```

3. **查看 BIOS 错误码**
   - INT 13h 在 AH 中返回错误码
   - 常见错误码：
     - 0x01: 无效命令
     - 0x02: 地址标记未找到
     - 0x04: 扇区未找到
     - 0x10: CRC 错误
     - 0x20: 控制器故障

### 如何诊断 "Not found" 错误

1. **检查分区表**
   ```bash
   # 查看分区信息
   fdisk -l os.dsk
   ```

2. **验证分区类型**
   ```bash
   # 分区类型应该是 0x20
   xxd -s 446 -l 64 os.dsk
   ```

3. **检查启动标志**
   - 第一个字节应该是 0x80（可启动）

---

## 错误处理流程图

```
              ┌────────────────────────────┐
              │      开始引导过程          │
              └─────────────┬──────────────┘
                            │
              ┌─────────────▼──────────────┐
              │       读取 MBR             │
              └─────────────┬──────────────┘
                     │      │
               成功  │      │ 失败
                     │      └──────────────────┐
              ┌──────▼──────┐                  │
              │ 检查分区表  │                  │
              └──────┬──────┘                  │
                     │                         │
            ┌────────┴────────┐                │
            │找到Pintos分区？ │                │
            └────────┬────────┘                │
               │     │                         │
          是   │     │ 否                      │
               │     └─────────────┐           │
        ┌──────▼──────┐           │           │
        │  加载内核   │           │           │
        └──────┬──────┘           │           │
          │    │                  │           │
     成功 │    │ 失败             │           │
          │    │                  │           │
          │    └────────┐         │           │
          │             │         │           │
   ┌──────▼──────┐  ┌───▼─────────▼───────────▼───┐
   │ 跳转到内核  │  │        错误处理              │
   │  (成功!)   │  │  - 打印 "Bad read" 或        │
   └─────────────┘  │    "Not found"              │
                    │  - INT 18h                  │
                    │  - BIOS 接管                │
                    └─────────────────────────────┘
```

---

## 代码安全性分析

### 潜在风险

1. **INT 18h 可能返回**
   - 代码假设 INT 18h 不会返回
   - 如果返回，行为未定义

2. **代码复用的脆弱性**
   - `start` 标签的位置很关键
   - 如果代码结构改变，可能破坏复用

3. **没有无限循环保护**
   - 错误处理后，如果 BIOS 返回，代码可能继续执行
   - 可能执行到随机数据

### 改进建议（如果空间允许）

```
error_loop:
    call puts
    .string "\rError\r"
    cli                     # 禁用中断
    hlt                     # 停止 CPU
    jmp error_loop          # 以防万一
```

这样确保系统在错误后完全停止。

---

## 常见问题

### Q1: 为什么两种错误用同一个消息？

空间限制！每个字符串占用宝贵的字节。用户通常不需要区分具体是哪种 "未找到" 错误。

### Q2: INT 18h 之后会发生什么？

取决于 BIOS 设置：
- 可能尝试从 CD-ROM、USB 等启动
- 可能显示 "No bootable device"
- 可能进入 BIOS 设置界面

### Q3: 如果 INT 18h 返回会怎样？

代码没有处理 INT 18h 返回的情况。如果 BIOS 返回：
- 执行会继续到 `int $0x18` 之后的代码
- 可能是 `puts` 函数或其他代码
- 结果未定义，可能崩溃

**为什么不处理？**
- 大多数 BIOS 不会返回
- 没有合理的恢复操作
- 节省代码空间

### Q4: 能否显示更详细的错误信息？

可以，但会增加代码大小。例如：
```
# 更详细的版本（伪代码）
cmp $0x80, %ah      # 检查 BIOS 错误码
je timeout_error
cmp $0x20, %ah
je controller_error
...
```

这会占用太多空间，不适合 512 字节限制。

---

## 练习思考

1. 如果要区分 "Bad read" 和 "Not found" 显示不同颜色，需要如何修改代码？

2. 为什么 `int $0x18` 之后没有 `hlt` 指令？

3. 如果在模拟器（如 QEMU）中遇到 "Not found" 错误，应该如何排查？

4. 能否在不增加代码大小的情况下提供更多错误信息？（提示：考虑用不同数量的字符表示不同错误）

---

## 练习答案

<details>
<summary>点击查看答案 1</summary>
<div markdown="1">

**在 VGA 文本模式下显示不同颜色，需要使用 INT 10h 的扩展功能：**

```asm
read_failed:
    mov $0x04, %bl      # 红色前景
    call colored_puts
    .string "\rBad read\r"
    jmp error_done

no_boot_partition:
    mov $0x06, %bl      # 棕色/黄色前景
    call colored_puts
    .string "\rNot found\r"

error_done:
    int $0x18

colored_puts:
    # 类似 puts，但使用 BL 中的颜色
    # INT 10h, AH=0Eh 的 BL 参数指定颜色
    ...
```

**颜色代码（前景色）**：
- 0x00: 黑色
- 0x01: 蓝色
- 0x02: 绿色
- 0x04: 红色
- 0x07: 白色
- 0x0C: 亮红色
- 0x0E: 黄色

**挑战**：这需要额外的代码空间，可能超出 512 字节限制。

</div>
</details>

<details>
<summary>点击查看答案 2</summary>
<div markdown="1">

**`int $0x18` 之后没有 `hlt` 指令的原因：**

1. **假设 INT 18h 不返回**：
   - 大多数 BIOS 会接管系统
   - 尝试其他启动设备或显示错误
   - 不会返回到调用者

2. **节省代码空间**：
   - `hlt` 指令需要 1 字节
   - 如果真的需要无限循环，需要更多字节：
   ```asm
   hang:
       cli     # 1 字节
       hlt     # 1 字节
       jmp hang # 2 字节
   ```
   - 总共 4 字节

3. **即使返回也不危险**：
   - 如果 INT 18h 返回，执行会继续到下一条指令
   - 下一条可能是 `puts` 函数或其他代码
   - 最坏情况是执行一些无害的代码然后崩溃
   - 不会造成数据损坏

4. **实际风险**：
   - 现代 BIOS 几乎都会接管
   - 只有非常老的系统可能返回
   - 那种情况下，系统本来就无法正常工作

</div>
</details>

<details>
<summary>点击查看答案 3</summary>
<div markdown="1">

**在 QEMU 中排查 "Not found" 错误的步骤：**

1. **检查磁盘镜像是否正确创建**：
   ```bash
   ls -la *.dsk
   file pintos.dsk
   ```

2. **查看分区表**：
   ```bash
   fdisk -l pintos.dsk
   # 或
   parted pintos.dsk print
   ```

3. **验证分区类型**：
   ```bash
   # 查看 MBR 的分区表区域
   xxd -s 446 -l 64 pintos.dsk
   # 检查偏移 4（分区类型）是否为 0x20
   ```

4. **验证启动标志**：
   ```bash
   # 第一个字节应该是 0x80
   xxd -s 446 -l 1 pintos.dsk
   ```

5. **验证 MBR 签名**：
   ```bash
   xxd -s 510 -l 2 pintos.dsk
   # 应该显示 55 aa
   ```

6. **检查 QEMU 命令行**：
   ```bash
   # 确保正确指定硬盘
   qemu-system-i386 -hda pintos.dsk ...
   ```

7. **使用 QEMU 监视器调试**：
   ```
   (qemu) info block
   (qemu) x /16xb 0x7dbe
   ```

</div>
</details>

<details>
<summary>点击查看答案 4</summary>
<div markdown="1">

**不增加代码大小提供更多错误信息的方法：**

1. **使用不同数量的字符**：
   ```asm
   # 1 个 'E' = 读取错误
   read_failed:
       call putc
       mov $'E', %al
       jmp error_done

   # 2 个 'E' = 找不到分区
   no_boot_partition:
       mov $'E', %al
       call putc
       call putc

   error_done:
       int $0x18
   ```

2. **使用不同字符**：
   - 'R' = Read error
   - 'N' = Not found
   - 'D' = Drive error

3. **使用蜂鸣器**：
   ```asm
   # 不同次数的蜂鸣表示不同错误
   mov $0x0e07, %ax    # 蜂鸣字符
   int $0x10
   ```

4. **使用数字代码**：
   ```asm
   # 打印 "E1", "E2", "E3" 等
   call puts
   .string "E"
   mov $'1', %al       # 或 '2', '3'
   call putc
   ```

5. **利用现有输出**：
   - 观察打印了多少硬盘/分区名称
   - "hda1234 hdb" 意味着在 hdb 的第一个分区出错
   - 这已经提供了一定的错误定位信息

</div>
</details>

---

## 下一部分

接下来我们分析 `puts` 辅助函数——一个非常巧妙的字符串打印实现。请参阅下一篇文章。
