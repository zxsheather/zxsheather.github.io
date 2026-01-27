---
layout: post
title: "Pintos 线程系统详解（六）：阻塞与唤醒"
date: 2026-01-26
categories: [技术, Pintos]
tags: [OS, Pintos, 线程, 同步]
description: "详细解析 Pintos 中线程的阻塞与唤醒机制，包括 thread_block() 和 thread_unblock() 函数。"
mermaid: true
---

## 概述

本文档详细解析 Pintos 中线程的阻塞与唤醒机制。当线程需要等待某个事件时，它会阻塞自己；当事件发生时，另一个线程会唤醒它。这是实现同步原语的基础。

---

## 原始代码

### thread_block() 函数

```c
/** Puts the current thread to sleep.  It will not be scheduled
   again until awoken by thread_unblock().

   This function must be called with interrupts turned off.  It
   is usually a better idea to use one of the synchronization
   primitives in synch.h. */
void
thread_block (void) 
{
  ASSERT (!intr_context ());
  ASSERT (intr_get_level () == INTR_OFF);

  thread_current ()->status = THREAD_BLOCKED;
  schedule ();
}
```

### thread_unblock() 函数

```c
/** Transitions a blocked thread T to the ready-to-run state.
   This is an error if T is not blocked.  (Use thread_yield() to
   make the running thread ready.)

   This function does not preempt the running thread.  This can
   be important: if the caller had disabled interrupts itself,
   it may expect that it can atomically unblock a thread and
   update other data. */
void
thread_unblock (struct thread *t) 
{
  enum intr_level old_level;

  ASSERT (is_thread (t));

  old_level = intr_disable ();
  ASSERT (t->status == THREAD_BLOCKED);
  list_push_back (&ready_list, &t->elem);
  t->status = THREAD_READY;
  intr_set_level (old_level);
}
```

---

## 前置知识

### 1. 为什么需要阻塞？

线程有时需要等待某些条件才能继续：
- 等待 I/O 完成
- 等待其他线程释放资源
- 等待定时器到期
- 等待用户输入

如果不阻塞，就需要"忙等待"（busy waiting），浪费 CPU 资源。

### 2. 阻塞 vs 忙等待

```
忙等待（Busy Waiting）:
while (!condition) {
  // 空循环，浪费 CPU
}

阻塞等待（Blocking Wait）:
while (!condition) {
  将自己加入等待队列;
  thread_block ();  // 不占用 CPU
}
```

### 3. 阻塞的语义

当线程阻塞时：
1. 它不再被调度运行
2. CPU 可以运行其他线程
3. 直到被显式唤醒才能再次运行

---

## thread_block() 详解

### 函数签名和断言

```c
void
thread_block (void) 
{
  ASSERT (!intr_context ());           // 不能在中断处理中调用
  ASSERT (intr_get_level () == INTR_OFF);  // 中断必须已禁用
```

### 为什么不能在中断上下文中阻塞？

中断处理程序必须快速完成：
1. 中断处理不应该被调度
2. 阻塞会导致中断无法完成
3. 可能导致系统死锁

### 为什么中断必须已禁用？

调用者需要在阻塞前完成原子操作：

```c
// 典型使用模式
old_level = intr_disable ();  // 禁用中断
while (!condition) {
  list_push_back (&wait_list, &cur->elem);  // 原子操作 1
  thread_block ();                           // 原子操作 2
}
intr_set_level (old_level);
```

如果 `thread_block()` 自己禁用中断，就无法保证"检查条件"和"阻塞"是原子的。

### 设置状态并调度

```c
  thread_current ()->status = THREAD_BLOCKED;
  schedule ();
}
```

关键点：
1. 先设置状态为 BLOCKED
2. 然后调度其他线程运行
3. **不**将自己加入任何队列（调用者的责任）

### 为什么 thread_block() 不把线程加入等待队列？

因为不同的等待有不同的队列：
- 信号量有自己的 waiters 队列
- 条件变量有自己的 waiters 队列
- 其他等待可能有其他队列

所以调用者负责把线程加入适当的队列。

---

## thread_unblock() 详解

### 函数签名和断言

```c
void
thread_unblock (struct thread *t) 
{
  enum intr_level old_level;

  ASSERT (is_thread (t));  // 必须是有效线程
```

### 禁用中断并检查状态

```c
  old_level = intr_disable ();
  ASSERT (t->status == THREAD_BLOCKED);  // 必须是阻塞状态
```

### 加入就绪队列

```c
  list_push_back (&ready_list, &t->elem);
  t->status = THREAD_READY;
```

关键点：
1. 将线程加入 ready_list
2. 修改状态为 READY
3. **不**立即调度（不会抢占当前线程）

### 恢复中断

```c
  intr_set_level (old_level);
}
```

### 为什么不立即调度？

为了给调用者更多控制：
1. 调用者可能还需要做其他操作
2. 调用者可能不希望被抢占
3. 保持原子性

如果需要立即调度，调用者可以调用 `thread_yield()`。

---

## 使用模式

### 等待事件的模式

```c
void
wait_for_something (void)
{
  enum intr_level old_level = intr_disable ();
  
  while (!something_happened) {
    // 1. 把自己加入等待队列
    list_push_back (&wait_queue, &thread_current ()->elem);
    // 2. 阻塞
    thread_block ();
    // 3. 被唤醒后，重新检查条件
  }
  
  intr_set_level (old_level);
}
```

### 通知事件的模式

```c
void
notify_something (void)
{
  enum intr_level old_level = intr_disable ();
  
  // 设置事件标志
  something_happened = true;
  
  // 唤醒等待的线程
  if (!list_empty (&wait_queue)) {
    struct thread *t = list_entry (list_pop_front (&wait_queue),
                                    struct thread, elem);
    thread_unblock (t);
  }
  
  intr_set_level (old_level);
}
```

### 为什么用 while 而不是 if？

可能存在**虚假唤醒**（spurious wakeup）：
1. 多个线程等待同一事件
2. 只有一个能获得资源
3. 其他线程需要继续等待

```c
// 错误的用法
if (!condition) {
  thread_block ();
}
// 唤醒后直接执行，但条件可能仍不满足！

// 正确的用法
while (!condition) {
  thread_block ();
}
// 唤醒后重新检查条件
```

---

## 阻塞唤醒流程图

### 单个线程等待

```
Thread A (等待者)                    Thread B (通知者)
     │                                    │
     │ intr_disable()                     │
     │     │                              │
     │     ▼                              │
     │ while (!event) {                   │
     │     │                              │
     │     ├─► 加入 wait_queue            │
     │     │                              │
     │     ├─► thread_block()             │
     │     │        │                     │
     │     │        ├─► status = BLOCKED  │
     │     │        │                     │
     │     │        ├─► schedule()        │
     │     │        │                     │
     │              ═══════════════════════════  ← A 被换出
     │                                    │
     │                               一些处理...
     │                                    │
     │                               event = true
     │                                    │
     │                               从 wait_queue 取出 A
     │                                    │
     │                               thread_unblock(A)
     │                                    │    │
     │                                    │    ├─► 加入 ready_list
     │                                    │    │
     │                                    │    ├─► A.status = READY
     │                                    │
     │                               ... 继续运行 ...
     │                                    │
     │                               最终某时刻 schedule()
     │              ═══════════════════════════  ← A 被换回
     │     │        │                     │
     │     │◄───────┘                     │
     │     │                              │
     │     └─► 重新检查 while (!event)    │
     │                                    │
     │ event 为 true，退出循环            │
     │     │                              │
     │     ▼                              │
     │ intr_set_level()                   │
     ▼                                    │
   继续执行                               │
```

### 多个线程等待

```
wait_queue: [A] → [B] → [C]

Thread D 调用 notify():
    1. event = true
    2. 从队首取出 A
    3. thread_unblock(A)

wait_queue: [B] → [C]
ready_list: [...] → [A]

A 被调度后:
    - 检查条件，条件满足
    - 继续执行，不再加入 wait_queue

B 和 C 仍在 wait_queue 中等待
```

---

## 与 thread_yield() 的区别

| 特性 | thread_block() | thread_yield() |
|------|----------------|----------------|
| 目标状态 | BLOCKED | READY |
| 加入队列 | 无（调用者负责） | ready_list |
| 何时返回 | 被 unblock 后 | 被再次调度后 |
| 典型用途 | 等待事件 | 让出 CPU |
| 可能立即返回 | 否 | 是（如果无其他就绪线程）|

```c
// thread_yield: "我不需要 CPU 了，让别人用"
void thread_yield (void) {
  cur->status = THREAD_READY;
  list_push_back (&ready_list, &cur->elem);
  schedule ();
}

// thread_block: "我在等某事，别调度我"
void thread_block (void) {
  cur->status = THREAD_BLOCKED;
  schedule ();
  // 不加入任何队列！
}
```

---

## 中断与阻塞的关系

### 为什么阻塞操作需要禁用中断？

考虑以下场景：

```c
// 线程 A
void wait_for_data (void) {
  if (data_ready == false) {           // 检查
    // *** 如果这里发生中断 ***
    // 中断处理程序设置 data_ready = true
    // 并试图唤醒等待者（但还没有等待者！）
    list_push_back (&wait_list, &cur->elem);
    thread_block ();                    // 永远不会被唤醒！
  }
}
```

禁用中断可以避免这种竞态条件：

```c
void wait_for_data (void) {
  old_level = intr_disable ();          // 禁用中断
  if (data_ready == false) {
    list_push_back (&wait_list, &cur->elem);
    thread_block ();
  }
  intr_set_level (old_level);
}
```

### 阻塞后中断会恢复吗？

是的！`schedule()` 切换到其他线程后，新线程会恢复中断：

```c
void thread_yield (void) {
  old_level = intr_disable ();
  // ...
  schedule ();
  intr_set_level (old_level);  // 新线程的代码会执行到这里
}
```

或者对于新线程：

```c
static void
kernel_thread (thread_func *function, void *aux) 
{
  intr_enable ();  // 新线程第一件事就是开启中断
  function (aux);
  thread_exit ();
}
```

---

## 常见问题

### Q1: 为什么 thread_block() 不自己禁用中断？

**答**：因为调用者通常需要在禁用中断的情况下做其他操作（如检查条件、加入等待队列），然后才阻塞。如果 thread_block() 自己禁用中断，就无法保证这些操作是原子的。

### Q2: 阻塞的线程存储在哪里？

**答**：由调用者决定。常见的有：
- 信号量的 waiters 队列
- 条件变量的 waiters 队列
- 定时器的睡眠队列
- 自定义的等待队列

### Q3: thread_unblock() 能唤醒 READY 状态的线程吗？

**答**：不能，会触发断言失败：

```c
ASSERT (t->status == THREAD_BLOCKED);
```

### Q4: 如果没有其他线程可运行，阻塞会怎样？

**答**：idle_thread 会运行。它执行 `hlt` 指令等待中断，然后再次阻塞自己。

### Q5: thread_unblock() 能在中断处理程序中调用吗？

**答**：可以。thread_unblock() 只是把线程加入 ready_list，不涉及调度。

---

## 调试技巧

### 打印阻塞/唤醒信息

```c
void
thread_block (void) 
{
  printf ("Thread '%s' blocking\n", thread_current ()->name);
  thread_current ()->status = THREAD_BLOCKED;
  schedule ();
  printf ("Thread '%s' resumed\n", thread_current ()->name);
}

void
thread_unblock (struct thread *t) 
{
  printf ("Unblocking thread '%s'\n", t->name);
  // ...
}
```

### 检查等待队列

```c
void
debug_print_waiters (struct list *waiters)
{
  struct list_elem *e;
  printf ("Waiters: ");
  for (e = list_begin (waiters); e != list_end (waiters);
       e = list_next (e))
    {
      struct thread *t = list_entry (e, struct thread, elem);
      printf ("%s ", t->name);
    }
  printf ("\n");
}
```

---

## 练习思考

1. **分析题**：如果 thread_block() 忘记设置 status = BLOCKED 会怎样？

2. **设计题**：如何实现一个带超时的等待？（提示：结合定时器）

3. **调试题**：如果一个线程永远阻塞，如何诊断问题？

4. **思考题**：为什么 thread_unblock() 使用 list_push_back 而不是 list_push_front？

5. **扩展题**：如何实现优先级继承（priority inheritance）来避免优先级反转？

---

## 下一步

理解了阻塞与唤醒机制后，下一篇文档将介绍**信号量**（Semaphore）的实现，它是最基本的同步原语。
