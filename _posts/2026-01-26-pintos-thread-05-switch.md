---
layout: post
title: "Pintos 线程系统详解（五）：上下文切换"
date: 2026-01-26
categories: [技术, Pintos]
tags: [OS, Pintos, 线程, 汇编, 上下文切换]
description: "详细解析 Pintos 中 switch.S 的汇编代码，理解线程上下文切换的底层实现。"
mermaid: true
---

## 概述

本文档详细解析 Pintos 中线程上下文切换的核心实现——`switch.S`。上下文切换是操作系统最底层的机制之一，它允许 CPU 从一个线程切换到另一个线程，保存和恢复执行状态。

---

## 原始代码

### switch.S

```plaintext
#include "threads/switch.h"

#### struct thread *switch_threads (struct thread *cur, struct thread *next);
####
#### Switches from CUR, which must be the running thread, to NEXT,
#### which must also be running switch_threads(), returning CUR in
#### NEXT's context.
####
#### This function works by assuming that the thread we're switching
#### into is also running switch_threads().  Thus, all it has to do is
#### preserve a few registers on the stack, then switch stacks and
#### restore the registers.  As part of switching stacks we record the
#### current stack pointer in CUR's thread structure.

.globl switch_threads
.func switch_threads
switch_threads:
	# Save caller's register state.
	#
	# Note that the SVR4 ABI allows us to destroy %eax, %ecx, %edx,
	# but requires us to preserve %ebx, %ebp, %esi, %edi.  See
	# [SysV-ABI-386] pages 3-11 and 3-12 for details.
	#
	# This stack frame must match the one set up by thread_create()
	# in size.
	pushl %ebx
	pushl %ebp
	pushl %esi
	pushl %edi

	# Get offsetof (struct thread, stack).
.globl thread_stack_ofs
	mov thread_stack_ofs, %edx

	# Save current stack pointer to old thread's stack, if any.
	movl SWITCH_CUR(%esp), %eax
	movl %esp, (%eax,%edx,1)

	# Restore stack pointer from new thread's stack.
	movl SWITCH_NEXT(%esp), %ecx
	movl (%ecx,%edx,1), %esp

	# Restore caller's register state.
	popl %edi
	popl %esi
	popl %ebp
	popl %ebx
        ret
.endfunc

.globl switch_entry
.func switch_entry
switch_entry:
	# Discard switch_threads() arguments.
	addl $8, %esp

	# Call thread_schedule_tail(prev).
	pushl %eax
.globl thread_schedule_tail
	call thread_schedule_tail
	addl $4, %esp

	# Start thread proper.
	ret
.endfunc
```

### switch.h

```c
#ifndef THREADS_SWITCH_H
#define THREADS_SWITCH_H

#ifndef __ASSEMBLER__
/** switch_thread()'s stack frame. */
struct switch_threads_frame 
  {
    uint32_t edi;               /**<  0: Saved %edi. */
    uint32_t esi;               /**<  4: Saved %esi. */
    uint32_t ebp;               /**<  8: Saved %ebp. */
    uint32_t ebx;               /**< 12: Saved %ebx. */
    void (*eip) (void);         /**< 16: Return address. */
    struct thread *cur;         /**< 20: switch_threads()'s CUR argument. */
    struct thread *next;        /**< 24: switch_threads()'s NEXT argument. */
  };

/** Stack frame for switch_entry(). */
struct switch_entry_frame
  {
    void (*eip) (void);
  };

/** Switches from CUR, which must be the running thread, to NEXT,
   which must also be running switch_threads(), returning CUR in
   NEXT's context. */
struct thread *switch_threads (struct thread *cur, struct thread *next);

void switch_entry (void);
#endif

/** Offsets used by switch.S. */
#define SWITCH_CUR      20
#define SWITCH_NEXT     24

#endif /**< threads/switch.h */
```

---

## 前置知识

### 1. 什么是上下文（Context）？

线程的上下文是线程执行状态的完整描述，包括：
- **寄存器**：EAX, EBX, ECX, EDX, ESI, EDI, EBP, ESP, EIP
- **栈**：栈上的所有数据
- **其他**：标志寄存器等

切换线程就是切换这些状态。

### 2. x86 寄存器

```
通用寄存器:
┌────────────────────────────────────────────────────────┐
│  EAX  │ 累加器，函数返回值                             │
│  EBX  │ 基址寄存器，callee-saved                       │
│  ECX  │ 计数器，caller-saved                           │
│  EDX  │ 数据寄存器，caller-saved                       │
│  ESI  │ 源索引，callee-saved                           │
│  EDI  │ 目的索引，callee-saved                         │
│  EBP  │ 栈帧基址指针，callee-saved                     │
│  ESP  │ 栈指针                                         │
│  EIP  │ 指令指针（程序计数器）                         │
└────────────────────────────────────────────────────────┘
```

### 3. 调用约定（Calling Convention）

**SVR4 ABI (System V Application Binary Interface)**：

| 寄存器 | 保存责任 | 说明 |
|--------|----------|------|
| EAX, ECX, EDX | Caller-saved | 调用者保存，被调用者可随意使用 |
| EBX, EBP, ESI, EDI | Callee-saved | 被调用者保存，必须保持不变 |

**函数调用过程**：

```
调用前:
1. 参数从右向左压栈
2. call 指令压入返回地址
3. 跳转到函数

调用中:
4. 被调用函数保存 callee-saved 寄存器
5. 执行函数体
6. 恢复 callee-saved 寄存器

返回:
7. ret 指令弹出返回地址并跳转
8. 调用者清理参数
```

### 4. 栈帧布局

```
高地址
┌─────────────────────┐
│     参数 2 (next)   │  ESP+24 (调用后)
├─────────────────────┤
│     参数 1 (cur)    │  ESP+20 (调用后)
├─────────────────────┤
│     返回地址        │  ESP+16 (call 指令压入)
├─────────────────────┤
│     保存的 EBX      │  ESP+12 (push 指令)
├─────────────────────┤
│     保存的 EBP      │  ESP+8
├─────────────────────┤
│     保存的 ESI      │  ESP+4
├─────────────────────┤
│     保存的 EDI      │  ESP+0  ← 当前 ESP
└─────────────────────┘
低地址
```

---

## switch_threads() 逐行详解

### 函数签名

```c
struct thread *switch_threads (struct thread *cur, struct thread *next);
```

- **参数**：cur（当前线程），next（下一线程）
- **返回值**：切换前的线程（即 cur），但返回给 next 线程

### 保存 callee-saved 寄存器

```plaintext
switch_threads:
	pushl %ebx
	pushl %ebp
	pushl %esi
	pushl %edi
```

这四条指令保存必须保留的寄存器到栈上：

```
执行前:                          执行后:
┌─────────────────┐              ┌─────────────────┐
│      next       │              │      next       │
├─────────────────┤              ├─────────────────┤
│      cur        │              │      cur        │
├─────────────────┤              ├─────────────────┤
│   返回地址      │ ← ESP        │   返回地址      │
└─────────────────┘              ├─────────────────┤
                                 │      ebx        │
                                 ├─────────────────┤
                                 │      ebp        │
                                 ├─────────────────┤
                                 │      esi        │
                                 ├─────────────────┤
                                 │      edi        │ ← ESP
                                 └─────────────────┘
```

### 获取 stack 字段偏移量

```plaintext
.globl thread_stack_ofs
	mov thread_stack_ofs, %edx
```

`thread_stack_ofs` 是在 thread.c 中定义的：

```c
uint32_t thread_stack_ofs = offsetof (struct thread, stack);
```

这告诉汇编代码 `stack` 字段在 `struct thread` 中的偏移量。

### 保存当前栈指针

```plaintext
	movl SWITCH_CUR(%esp), %eax    # eax = cur
	movl %esp, (%eax,%edx,1)       # cur->stack = esp
```

**步骤分解**：

1. `SWITCH_CUR(%esp)` = `20(%esp)` = cur 参数的地址
2. `movl SWITCH_CUR(%esp), %eax` 将 cur 指针加载到 EAX
3. `(%eax,%edx,1)` = `eax + edx*1` = `cur + stack_offset` = `&(cur->stack)`
4. `movl %esp, (%eax,%edx,1)` 将当前 ESP 保存到 `cur->stack`

**结果**：cur 线程的栈指针被保存。

### 恢复新线程的栈指针

```plaintext
	movl SWITCH_NEXT(%esp), %ecx   # ecx = next
	movl (%ecx,%edx,1), %esp       # esp = next->stack
```

**步骤分解**：

1. `SWITCH_NEXT(%esp)` = `24(%esp)` = next 参数的地址
2. `movl SWITCH_NEXT(%esp), %ecx` 将 next 指针加载到 ECX
3. `(%ecx,%edx,1)` = `&(next->stack)`
4. `movl (%ecx,%edx,1), %esp` 从 `next->stack` 恢复 ESP

**关键点**：执行完这条指令后，我们已经切换到了新线程的栈！

### 恢复新线程的寄存器

```plaintext
	popl %edi
	popl %esi
	popl %ebp
	popl %ebx
    ret
```

从新线程的栈上恢复寄存器，然后 `ret` 返回到新线程的返回地址。

---

## 上下文切换图解

### 切换前后的栈状态

```
Thread A 的栈 (切换前正在运行)        Thread B 的栈 (之前被切换出)
┌─────────────────┐                  ┌─────────────────┐
│      next       │                  │      next       │
├─────────────────┤                  ├─────────────────┤
│      cur        │                  │      cur        │
├─────────────────┤                  ├─────────────────┤
│  返回到 schedule│                  │  返回到 schedule│
├─────────────────┤                  ├─────────────────┤
│      ebx        │                  │      ebx        │
├─────────────────┤                  ├─────────────────┤
│      ebp        │                  │      ebp        │
├─────────────────┤                  ├─────────────────┤
│      esi        │                  │      esi        │
├─────────────────┤                  ├─────────────────┤
│      edi        │ ← ESP(A)         │      edi        │ ← ESP(B)
└─────────────────┘                  └─────────────────┘
        │                                    │
        │                                    │
A->stack ───────┘                  B->stack ─┘


                    执行 switch_threads(A, B)


Thread A 的栈 (已保存状态)           Thread B 的栈 (正在恢复)
┌─────────────────┐                  ┌─────────────────┐
│      next       │                  │      next       │
├─────────────────┤                  ├─────────────────┤
│      cur        │                  │      cur        │
├─────────────────┤                  ├─────────────────┤
│  返回到 schedule│                  │  返回到 schedule│
├─────────────────┤                  ├─────────────────┤
│      ebx        │                  │      ebx        │
├─────────────────┤                  ├─────────────────┤
│      ebp        │                  │      ebp        │
├─────────────────┤                  ├─────────────────┤
│      esi        │                  │      esi        │
├─────────────────┤                  ├─────────────────┤
│      edi        │                  │      edi        │ ← ESP (已切换!)
└─────────────────┘                  └─────────────────┘
        │                            
A->stack ─┘ (已保存)                
```

### 切换的关键时刻

```
时间 ──────────────────────────────────────────────────────────────►

Thread A 执行                 Thread B 执行
     │                             │
     │ call switch_threads         │
     ▼                             │
  压入返回地址                     │
     │                             │
     ▼                             │
  pushl %ebx/ebp/esi/edi          │
     │                             │
     ▼                             │
  A->stack = esp                   │
     │                             │
     ▼                             │
  esp = B->stack                   │
     │                             │
  ═══════════════════════════════════  ← 栈切换点！
     │                             │
                                   ▼
                           popl %edi/esi/ebp/ebx
                                   │
                                   ▼
                                  ret
                                   │
                                   ▼
                           返回到 schedule()
```

---

## switch_entry() 详解

这是新线程第一次运行时的入口点：

```plaintext
.globl switch_entry
.func switch_entry
switch_entry:
	# Discard switch_threads() arguments.
	addl $8, %esp

	# Call thread_schedule_tail(prev).
	pushl %eax
.globl thread_schedule_tail
	call thread_schedule_tail
	addl $4, %esp

	# Start thread proper.
	ret
.endfunc
```

### 为什么需要 switch_entry？

新线程第一次被调度时：
1. 它从未调用过 `switch_threads()`
2. 但它的栈被设置成好像调用过一样
3. `switch_entry` 处理这种特殊情况

### 逐行解析

**丢弃参数**：

```plaintext
addl $8, %esp
```

栈上有两个假的参数（cur 和 next），需要丢弃。

**调用 thread_schedule_tail**：

```plaintext
pushl %eax                    # 压入参数 (prev = eax)
call thread_schedule_tail     # 调用收尾函数
addl $4, %esp                 # 清理参数
```

EAX 包含 prev（切换前的线程），是 switch_threads 的返回值。

**开始执行线程**：

```plaintext
ret
```

返回到栈上的下一个返回地址，即 `kernel_thread()`。

### 新线程的栈帧回顾

```
高地址
┌─────────────────────────────────────────────┐
│               aux                           │ ← kernel_thread_frame
│             function                        │
│           eip (NULL)                        │
├─────────────────────────────────────────────┤
│         eip (kernel_thread)                 │ ← switch_entry_frame
├─────────────────────────────────────────────┤
│    next  (未使用)                           │
│    cur   (未使用)                           │
│    eip   (switch_entry)                     │ ← switch_threads_frame
│    ebx   (0)                                │
│    ebp   (0)                                │
│    esi   (0)                                │
│    edi   (0)                                │ ← t->stack
└─────────────────────────────────────────────┘
低地址
```

### 新线程首次执行流程

```
switch_threads() 切换到新线程
        │
        ▼
    popl %edi, %esi, %ebp, %ebx (值都是 0)
        │
        ▼
    ret (返回到 switch_entry)
        │
        ▼
switch_entry:
        │
    addl $8, %esp (丢弃 cur, next)
        │
        ▼
    pushl %eax; call thread_schedule_tail
        │
        ▼
    ret (返回到 kernel_thread)
        │
        ▼
kernel_thread:
        │
    intr_enable ()
        │
    function (aux)  ← 执行用户指定的函数！
        │
    thread_exit ()
```

---

## 为什么这样设计？

### 1. 统一的切换模型

所有线程（无论是第一次运行还是恢复执行）都通过 `switch_threads()` 切换。这种统一性简化了代码。

### 2. 最小化保存的状态

只保存 callee-saved 寄存器（EBX, EBP, ESI, EDI）和栈指针。其他寄存器由调用约定保证。

### 3. 栈就是上下文

线程的执行状态主要保存在栈上。切换栈指针就是切换上下文。

---

## 关键数据结构

### thread_stack_ofs

```c
/* thread.c */
uint32_t thread_stack_ofs = offsetof (struct thread, stack);
```

这是 `stack` 字段在 `struct thread` 中的偏移量。汇编代码需要知道这个值来访问 `t->stack`。

### SWITCH_CUR 和 SWITCH_NEXT

```c
/* switch.h */
#define SWITCH_CUR      20
#define SWITCH_NEXT     24
```

这些是参数在栈上的偏移量（相对于执行完 4 个 push 后的 ESP）。

```
ESP+24: next
ESP+20: cur
ESP+16: 返回地址
ESP+12: ebx
ESP+8:  ebp
ESP+4:  esi
ESP+0:  edi  ← ESP
```

---

## 常见问题

### Q1: 为什么不保存所有寄存器？

**答**：根据调用约定，caller-saved 寄存器（EAX, ECX, EDX）由调用者保存。调用 `switch_threads()` 的函数会处理这些寄存器。

### Q2: EIP 在哪里保存？

**答**：`call` 指令自动将返回地址（下一条指令的 EIP）压入栈。`ret` 指令从栈弹出并跳转。

### Q3: 为什么切换栈就能切换上下文？

**答**：因为：
1. 寄存器状态保存在栈上
2. 返回地址在栈上
3. 局部变量在栈上

切换栈指针后，popl 和 ret 会自动恢复正确的状态。

### Q4: switch_threads 的返回值是什么？

**答**：返回切换前的线程（cur）。但这个返回值是给切换后的线程看的。

```c
prev = switch_threads (cur, next);
// 这行代码执行后，"当前线程"已经变成了 next
// prev 是 next 看到的"之前的线程"
```

### Q5: 新线程为什么需要特殊处理？

**答**：新线程从未调用过 `switch_threads()`，但我们把它的栈设置成好像调用过一样。`switch_entry` 处理这种"假装"的情况，确保新线程能正确启动。

---

## 调试技巧

### 在 GDB 中观察切换

```plaintext
# 在 switch_threads 设置断点
b switch_threads

# 显示寄存器
info registers

# 显示栈内容
x/10x $esp

# 单步执行
si

# 观察 ESP 的变化
p/x $esp
```

### 添加调试输出

由于 switch_threads 中不能调用 printf（栈正在切换），可以在其前后添加：

```c
static void
schedule (void) 
{
  printf ("Before switch: cur=%s, next=%s\n", 
          cur->name, next->name);
  
  if (cur != next)
    prev = switch_threads (cur, next);
  
  // 此时已经是新线程了
  printf ("After switch: now=%s, prev=%s\n",
          running_thread()->name, 
          prev ? prev->name : "NULL");
  
  thread_schedule_tail (prev);
}
```

---

## 练习思考

1. **分析题**：如果忘记 `pushl %ebx`，会发生什么？

2. **计算题**：switch_threads_frame 占用多少字节？验证 SWITCH_CUR 和 SWITCH_NEXT 的值是否正确。

3. **设计题**：如果要支持浮点运算，需要保存哪些额外的寄存器？

4. **调试题**：如何验证上下文切换正在正确工作？

5. **扩展题**：研究 Linux 的 context_switch 实现，与 Pintos 对比有什么不同？

---

## 下一步

理解了上下文切换后，下一篇文档将介绍**线程的阻塞与唤醒**机制（`thread_block()` 和 `thread_unblock()`）。
