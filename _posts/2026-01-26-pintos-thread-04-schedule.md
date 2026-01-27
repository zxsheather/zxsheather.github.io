---
layout: post
title: "Pintos 线程系统详解（四）：线程调度"
date: 2026-01-26
categories: [技术, Pintos]
tags: [OS, Pintos, 线程, 调度]
description: "详细解析 Pintos 中的线程调度机制，包括 schedule() 函数和调度算法。"
mermaid: true
---

## 概述

本文档详细解析 Pintos 中的线程调度机制。调度器（scheduler）是操作系统的核心组件，负责决定哪个线程获得 CPU 时间。Pintos 默认使用**轮转调度（Round-Robin）**算法。

---

## 原始代码

### schedule() 函数

```c
/** Schedules a new process.  At entry, interrupts must be off and
   the running process's state must have been changed from
   running to some other state.  This function finds another
   thread to run and switches to it.

   It's not safe to call printf() until thread_schedule_tail()
   has completed. */
static void
schedule (void) 
{
  struct thread *cur = running_thread ();
  struct thread *next = next_thread_to_run ();
  struct thread *prev = NULL;

  ASSERT (intr_get_level () == INTR_OFF);
  ASSERT (cur->status != THREAD_RUNNING);
  ASSERT (is_thread (next));

  if (cur != next)
    prev = switch_threads (cur, next);
  thread_schedule_tail (prev);
}
```

### next_thread_to_run() 函数

```c
/** Chooses and returns the next thread to be scheduled.  Should
   return a thread from the run queue, unless the run queue is
   empty.  (If the running thread can continue running, then it
   will be in the run queue.)  If the run queue is empty, return
   idle_thread. */
static struct thread *
next_thread_to_run (void) 
{
  if (list_empty (&ready_list))
    return idle_thread;
  else
    return list_entry (list_pop_front (&ready_list), struct thread, elem);
}
```

### thread_schedule_tail() 函数

```c
/** Completes a thread switch by activating the new thread's page
   tables, and, if the previous thread is dying, destroying it.

   At this function's invocation, we just switched from thread
   PREV, the new thread is already running, and interrupts are
   still disabled.  This function is normally invoked by
   thread_schedule() as its final action before returning, but
   the first time a thread is scheduled it is called by
   switch_entry() (see switch.S).

   It's not safe to call printf() until the thread switch is
   complete.  In practice that means that printf()s should be
   added at the end of the function.

   After this function and its caller returns, the thread switch
   is complete. */
void
thread_schedule_tail (struct thread *prev)
{
  struct thread *cur = running_thread ();
  
  ASSERT (intr_get_level () == INTR_OFF);

  /* Mark us as running. */
  cur->status = THREAD_RUNNING;

  /* Start new time slice. */
  thread_ticks = 0;

#ifdef USERPROG
  /* Activate the new address space. */
  process_activate ();
#endif

  /* If the thread we switched from is dying, destroy its struct
     thread.  This must happen late so that thread_exit() doesn't
     pull out the rug under itself.  (We don't free
     initial_thread because its memory was not obtained via
     palloc().) */
  if (prev != NULL && prev->status == THREAD_DYING && prev != initial_thread) 
    {
      ASSERT (prev != cur);
      palloc_free_page (prev);
    }
}
```

### thread_yield() 函数

```c
/** Yields the CPU.  The current thread is not put to sleep and
   may be scheduled again immediately at the scheduler's whim. */
void
thread_yield (void) 
{
  struct thread *cur = thread_current ();
  enum intr_level old_level;
  
  ASSERT (!intr_context ());

  old_level = intr_disable ();
  if (cur != idle_thread) 
    list_push_back (&ready_list, &cur->elem);
  cur->status = THREAD_READY;
  schedule ();
  intr_set_level (old_level);
}
```

### thread_tick() 函数

```c
/** Called by the timer interrupt handler at each timer tick.
   Thus, this function runs in an external interrupt context. */
void
thread_tick (void) 
{
  struct thread *t = thread_current ();

  /* Update statistics. */
  if (t == idle_thread)
    idle_ticks++;
#ifdef USERPROG
  else if (t->pagedir != NULL)
    user_ticks++;
#endif
  else
    kernel_ticks++;

  /* Enforce preemption. */
  if (++thread_ticks >= TIME_SLICE)
    intr_yield_on_return ();
}
```

---

## 前置知识

### 1. 调度的基本概念

**调度器的职责**：
- 决定哪个线程运行
- 决定运行多长时间
- 实现公平性或其他策略

**调度时机**：
- 线程主动让出 CPU（yield）
- 线程阻塞等待事件（block）
- 线程时间片耗尽（抢占）
- 线程退出（exit）

### 2. 轮转调度（Round-Robin）

最简单的调度算法：
1. 所有就绪线程排成队列
2. 每个线程运行固定时间（时间片）
3. 时间片耗尽后，排到队尾
4. 下一个线程继续运行

```
就绪队列: [A] → [B] → [C] → (尾部)

时间片 1: A 运行，队列变为 [B] → [C] → [A]
时间片 2: B 运行，队列变为 [C] → [A] → [B]
时间片 3: C 运行，队列变为 [A] → [B] → [C]
... 循环 ...
```

### 3. 时间片

```c
#define TIME_SLICE 4  // 4 个 tick
```

一个 tick 是定时器中断的周期，默认约 10ms。
所以一个时间片约 40ms。

---

## schedule() 函数详解

### 函数签名和断言

```c
static void
schedule (void) 
{
  struct thread *cur = running_thread ();
  struct thread *next = next_thread_to_run ();
  struct thread *prev = NULL;

  ASSERT (intr_get_level () == INTR_OFF);  // 中断必须禁用
  ASSERT (cur->status != THREAD_RUNNING);   // 当前线程状态已改变
  ASSERT (is_thread (next));                // next 是有效线程
```

**为什么中断必须禁用？**

调度涉及多个操作，必须原子执行：
- 修改 ready_list
- 修改线程状态
- 切换栈和寄存器

**为什么 cur->status != THREAD_RUNNING？**

调用 schedule() 前，当前线程应该已经：
- 变为 READY（如果是 yield）
- 变为 BLOCKED（如果是 block）
- 变为 DYING（如果是 exit）

### 选择下一个线程

```c
  struct thread *next = next_thread_to_run ();
```

```c
static struct thread *
next_thread_to_run (void) 
{
  if (list_empty (&ready_list))
    return idle_thread;         // 队列空，运行 idle
  else
    return list_entry (list_pop_front (&ready_list), struct thread, elem);
}
```

这就是轮转调度的核心：
- 从队首取出一个线程
- 如果队列空，返回 idle_thread

### 执行上下文切换

```c
  if (cur != next)
    prev = switch_threads (cur, next);
```

**如果 cur == next**：当前线程继续运行（例如只有一个线程时）。

**switch_threads()**：在 switch.S 中实现，后面详细讲解。

### 完成切换

```c
  thread_schedule_tail (prev);
}
```

切换完成后的收尾工作，包括：
- 标记新线程为 RUNNING
- 重置时间片计数
- 释放 DYING 线程的内存

---

## next_thread_to_run() 详解

```c
static struct thread *
next_thread_to_run (void) 
{
  if (list_empty (&ready_list))
    return idle_thread;
  else
    return list_entry (list_pop_front (&ready_list), struct thread, elem);
}
```

### list_pop_front() 的作用

从链表头部移除并返回元素：

```
调用前:
ready_list: [A] → [B] → [C]

调用后:
ready_list: [B] → [C]
返回值: 指向 A 的 elem 的指针
```

### list_entry() 宏

```c
#define list_entry(LIST_ELEM, STRUCT, MEMBER) \
        ((STRUCT *) ((uint8_t *) (LIST_ELEM) - offsetof (STRUCT, MEMBER)))
```

从 list_elem 指针获取包含它的结构体指针：

```c
// elem 是 struct thread 中的成员
struct thread *t = list_entry (e, struct thread, elem);
```

**工作原理**：

```
struct thread
┌───────────────────┐ 0
│ tid               │
│ status            │
│ name[16]          │
│ stack             │
│ priority          │
│ allelem           │
├───────────────────┤ 40  ← elem 的偏移量 (假设)
│ elem.prev         │
│ elem.next         │
├───────────────────┤
│ ...               │
└───────────────────┘

如果知道 elem 的地址是 X，
那么 struct thread 的地址是 X - 40
```

---

## thread_schedule_tail() 详解

### 标记运行状态

```c
void
thread_schedule_tail (struct thread *prev)
{
  struct thread *cur = running_thread ();
  
  ASSERT (intr_get_level () == INTR_OFF);

  /* Mark us as running. */
  cur->status = THREAD_RUNNING;

  /* Start new time slice. */
  thread_ticks = 0;
```

**注意**：此时 `running_thread()` 返回的是新线程，因为栈已经切换了。

### 切换地址空间（用户程序）

```c
#ifdef USERPROG
  /* Activate the new address space. */
  process_activate ();
#endif
```

对于用户进程，需要切换页表。内核线程不需要。

### 销毁 DYING 线程

```c
  /* If the thread we switched from is dying, destroy its struct thread. */
  if (prev != NULL && prev->status == THREAD_DYING && prev != initial_thread) 
    {
      ASSERT (prev != cur);
      palloc_free_page (prev);
    }
}
```

**为什么由下一个线程来释放？**

因为 DYING 线程正在使用自己的栈，不能释放自己占用的内存。

**为什么不释放 initial_thread？**

initial_thread 的内存不是通过 palloc 分配的，而是由 loader.S 设置的。

---

## thread_yield() 详解

```c
void
thread_yield (void) 
{
  struct thread *cur = thread_current ();
  enum intr_level old_level;
  
  ASSERT (!intr_context ());  // 不能在中断处理中调用

  old_level = intr_disable ();  // 禁用中断
  
  if (cur != idle_thread) 
    list_push_back (&ready_list, &cur->elem);  // 加入队尾
  cur->status = THREAD_READY;
  schedule ();                  // 调度
  
  intr_set_level (old_level);   // 恢复中断（被调度回来后）
}
```

### 执行流程

```
Thread A 调用 thread_yield()
        │
        ▼
    禁用中断
        │
        ▼
    A 加入 ready_list 队尾
        │
        ▼
    A.status = READY
        │
        ▼
    schedule()
        │
        ├───────────────────────┐
        │                       │
        ▼                       │
    切换到 Thread B             │
                                │
    ... B 运行一段时间 ...       │
                                │
    某时刻 B yield 或 block      │
        │                       │
        ▼                       │
    切换回 Thread A ◄───────────┘
        │
        ▼
    恢复中断
        │
        ▼
    thread_yield() 返回
```

### 为什么 idle_thread 不加入 ready_list？

idle_thread 是特殊的：
- 当且仅当 ready_list 为空时才运行
- 永远不应该出现在 ready_list 中
- 由 `next_thread_to_run()` 在需要时返回

---

## 时间片和抢占

### thread_tick() - 定时器中断处理

```c
void
thread_tick (void) 
{
  struct thread *t = thread_current ();

  /* Update statistics. */
  if (t == idle_thread)
    idle_ticks++;
#ifdef USERPROG
  else if (t->pagedir != NULL)
    user_ticks++;
#endif
  else
    kernel_ticks++;

  /* Enforce preemption. */
  if (++thread_ticks >= TIME_SLICE)
    intr_yield_on_return ();
}
```

### 抢占机制

```c
#define TIME_SLICE 4  // 时间片 = 4 ticks

static unsigned thread_ticks;  // 当前线程已运行的 ticks
```

每次定时器中断（每 tick）：
1. `thread_ticks++`
2. 如果 `thread_ticks >= TIME_SLICE`，设置抢占标志

### intr_yield_on_return()

```c
void
intr_yield_on_return (void) 
{
  ASSERT (intr_context ());  // 必须在中断上下文中
  yield_on_return = true;
}
```

只是设置一个标志，不立即 yield。

### 中断返回时检查

在 `intr_handler()` 末尾：

```c
void
intr_handler (struct intr_frame *frame) 
{
  // ... 处理中断 ...

  if (external) 
    {
      // ...
      if (yield_on_return) 
        thread_yield ();  // 中断返回前 yield
    }
}
```

---

## 调度流程图

### 时间片耗尽的抢占流程

```
时间 ──────────────────────────────────────────────────────►

Thread A 运行
┌─────────────────────────────────────────────────────────┐
│ tick 1 │ tick 2 │ tick 3 │ tick 4 │                     │
│        │        │        │   ↓    │                     │
│        │        │        │ 时间片耗尽                   │
│        │        │        │ intr_yield_on_return()      │
│        │        │        │   ↓                          │
│        │        │        │ thread_yield()              │
│        │        │        │   ↓                          │
│        │        │        │ schedule()                  │
└────────┴────────┴────────┴───┬──────────────────────────┘
                               │
                               ▼ 切换
Thread B 运行
┌─────────────────────────────────────────────────────────┐
│ tick 1 │ tick 2 │ tick 3 │ tick 4 │                     │
│        │        │        │   ...  │                     │
```

### 主动 yield 的流程

```
Thread A                          Thread B
    │                                │
    │ thread_yield()                 │
    │     │                          │
    │     ├── 加入 ready_list        │
    │     │                          │
    │     ├── status = READY         │
    │     │                          │
    │     ├── schedule()             │
    │     │        │                 │
    │     │        ├── next = B      │
    │     │        │                 │
    │     │        ├── switch ───────┤
    │                                │
    │                                │ 开始运行
    │                                │
    │                                │ ... 一段时间后 ...
    │                                │
    │                                │ schedule() 切回 A
    │◄───────────────────────────────┤
    │     │                          │
    │     └── 恢复中断               │
    │                                │
    ▼                                │
  继续运行                           │
```

---

## 调度的原子性保证

### 为什么需要禁用中断？

调度涉及的操作必须不可分割：

```c
// 危险的非原子操作示例（如果不禁用中断）：
list_push_back (&ready_list, &cur->elem);  // 步骤 1
// 如果这里发生中断，调度器可能看到不一致的状态！
cur->status = THREAD_READY;                 // 步骤 2
schedule ();                                // 步骤 3
```

### 中断禁用的范围

```c
void
thread_yield (void) 
{
  old_level = intr_disable ();   // ← 禁用
  // ---------- 临界区 ----------
  if (cur != idle_thread) 
    list_push_back (&ready_list, &cur->elem);
  cur->status = THREAD_READY;
  schedule ();
  // ---------- 临界区 ----------
  intr_set_level (old_level);    // ← 恢复
}
```

---

## 调度器的数据结构

```c
/* 就绪队列 - FIFO */
static struct list ready_list;

/* 时间片计数 */
static unsigned thread_ticks;

/* 时间片长度 */
#define TIME_SLICE 4

/* 统计信息 */
static long long idle_ticks;
static long long kernel_ticks;
static long long user_ticks;
```

**ready_list 结构**：

```
ready_list (双向链表)
┌──────────────────────────────────────────────────────┐
│                                                        │
│  head ◄──► Thread A ◄──► Thread B ◄──► Thread C ◄──► tail
│            (elem)        (elem)        (elem)          │
└──────────────────────────────────────────────────────┘
```

---

## 常见问题

### Q1: 如果所有线程都阻塞了会怎样？

**答**：idle_thread 会运行。idle_thread 的工作是：
1. 阻塞自己
2. 执行 `hlt` 指令等待中断
3. 中断发生后唤醒，然后继续阻塞

```c
static void
idle (void *aux UNUSED) 
{
  for (;;) 
    {
      intr_disable ();
      thread_block ();
      asm volatile ("sti; hlt" : : : "memory");
    }
}
```

### Q2: schedule() 为什么是 static 函数？

**答**：schedule() 是内部函数，只应该被以下函数调用：
- `thread_yield()`
- `thread_block()`
- `thread_exit()`

不应该直接从外部调用，因为调用前需要设置正确的状态。

### Q3: 为什么 thread_schedule_tail() 是全局函数？

**答**：因为 switch_entry() 需要调用它。switch_entry() 在 switch.S 中定义，需要一个全局符号。

### Q4: 线程优先级在当前实现中有效吗？

**答**：没有。当前实现只是 FIFO，不考虑优先级。实现优先级调度是 Project 1 的任务。

### Q5: thread_ticks 在哪里重置？

**答**：在 `thread_schedule_tail()` 中：

```c
thread_ticks = 0;  // 新线程开始新的时间片
```

---

## 练习思考

1. **分析题**：如果把 `list_push_back` 改成 `list_push_front`，对调度有什么影响？

2. **设计题**：如何实现基于优先级的调度？需要修改哪些函数？

3. **计算题**：假设有 3 个线程，时间片为 4 ticks，tick 周期为 10ms，每个线程运行完一轮需要多少时间？

4. **调试题**：如何验证轮转调度正在工作？（提示：打印日志）

5. **扩展题**：如何实现可变时间片？（不同优先级不同时间片长度）

---

## 下一步

理解了调度机制后，下一篇文档将深入 **switch.S** 汇编代码，看看上下文切换是如何在底层实现的。
