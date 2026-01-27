---
layout: post
title: "Pintos 线程系统详解（七）：信号量"
date: 2026-01-26
categories: [技术, Pintos]
tags: [OS, Pintos, 同步, 信号量]
description: "详细解析 Pintos 中信号量（Semaphore）的实现，理解这一基础同步原语。"
mermaid: true
---

## 概述

本文档详细解析 Pintos 中**信号量（Semaphore）**的实现。信号量是最基础的同步原语之一，可以用来实现：
- 互斥（Mutual Exclusion）
- 资源计数
- 线程间同步

Pintos 中的锁和条件变量都是基于信号量实现的。

---

## 原始代码

### synch.h 中的定义

```c
/** A counting semaphore. */
struct semaphore 
  {
    unsigned value;             /**< Current value. */
    struct list waiters;        /**< List of waiting threads. */
  };

void sema_init (struct semaphore *, unsigned value);
void sema_down (struct semaphore *);
bool sema_try_down (struct semaphore *);
void sema_up (struct semaphore *);
```

### synch.c 中的实现

```c
/** Initializes semaphore SEMA to VALUE.  A semaphore is a
   nonnegative integer along with two atomic operators for
   manipulating it:

   - down or "P": wait for the value to become positive, then
     decrement it.

   - up or "V": increment the value (and wake up one waiting
     thread, if any). */
void
sema_init (struct semaphore *sema, unsigned value) 
{
  ASSERT (sema != NULL);

  sema->value = value;
  list_init (&sema->waiters);
}

/** Down or "P" operation on a semaphore.  Waits for SEMA's value
   to become positive and then atomically decrements it.

   This function may sleep, so it must not be called within an
   interrupt handler.  This function may be called with
   interrupts disabled, but if it sleeps then the next scheduled
   thread will probably turn interrupts back on. */
void
sema_down (struct semaphore *sema) 
{
  enum intr_level old_level;

  ASSERT (sema != NULL);
  ASSERT (!intr_context ());

  old_level = intr_disable ();
  while (sema->value == 0) 
    {
      list_push_back (&sema->waiters, &thread_current ()->elem);
      thread_block ();
    }
  sema->value--;
  intr_set_level (old_level);
}

/** Down or "P" operation on a semaphore, but only if the
   semaphore is not already 0.  Returns true if the semaphore is
   decremented, false otherwise.

   This function may be called from an interrupt handler. */
bool
sema_try_down (struct semaphore *sema) 
{
  enum intr_level old_level;
  bool success;

  ASSERT (sema != NULL);

  old_level = intr_disable ();
  if (sema->value > 0) 
    {
      sema->value--;
      success = true; 
    }
  else
    success = false;
  intr_set_level (old_level);

  return success;
}

/** Up or "V" operation on a semaphore.  Increments SEMA's value
   and wakes up one thread of those waiting for SEMA, if any.

   This function may be called from an interrupt handler. */
void
sema_up (struct semaphore *sema) 
{
  enum intr_level old_level;

  ASSERT (sema != NULL);

  old_level = intr_disable ();
  if (!list_empty (&sema->waiters)) 
    thread_unblock (list_entry (list_pop_front (&sema->waiters),
                                struct thread, elem));
  sema->value++;
  intr_set_level (old_level);
}
```

---

## 前置知识

### 1. 信号量的概念

**信号量**是 Dijkstra 在 1965 年提出的同步原语，由两部分组成：
- 一个**整数值**
- 两个**原子操作**：P（等待/down）和 V（信号/up）

**P 操作**（荷兰语 Proberen，尝试）：
```
while (value == 0) wait;
value--;
```

**V 操作**（荷兰语 Verhogen，增加）：
```
value++;
if (有线程在等待) 唤醒一个;
```

### 2. 信号量的用途

**二进制信号量（Binary Semaphore）**：value 只为 0 或 1
- 用于互斥（类似锁）

**计数信号量（Counting Semaphore）**：value 可以是任意非负整数
- 用于资源计数（如限制并发数）
- 用于生产者-消费者问题

### 3. 为什么叫"信号量"？

可以把它想象成停车场的空位数：
- 初始值 = 总停车位数
- 进入（P）：如果有空位，占用一个；否则等待
- 离开（V）：释放一个空位，可能让等待的车进入

---

## struct semaphore 详解

```c
struct semaphore 
  {
    unsigned value;             /**< Current value. */
    struct list waiters;        /**< List of waiting threads. */
  };
```

**value**：当前值
- 表示可用资源数
- value > 0：有可用资源
- value == 0：无可用资源，需要等待

**waiters**：等待线程队列
- 当 value == 0 时，等待的线程在此队列中
- FIFO 顺序（先等待的先被唤醒）

**内存布局**：

```
struct semaphore
┌─────────────────────────┐
│   value (4 bytes)       │
├─────────────────────────┤
│   waiters.head.prev     │
│   waiters.head.next     │
│   waiters.tail.prev     │
│   waiters.tail.next     │
└─────────────────────────┘
```

---

## sema_init() 详解

```c
void
sema_init (struct semaphore *sema, unsigned value) 
{
  ASSERT (sema != NULL);

  sema->value = value;
  list_init (&sema->waiters);
}
```

初始化信号量：
1. 设置初始值
2. 初始化等待队列（空链表）

**使用示例**：

```c
struct semaphore sema;
sema_init (&sema, 1);  // 二进制信号量，用于互斥
sema_init (&sema, 5);  // 计数信号量，最多 5 个并发
sema_init (&sema, 0);  // 用于同步，初始无资源
```

---

## sema_down() 详解

这是**等待**操作（P 操作）：

```c
void
sema_down (struct semaphore *sema) 
{
  enum intr_level old_level;

  ASSERT (sema != NULL);
  ASSERT (!intr_context ());  // 不能在中断处理中调用

  old_level = intr_disable ();
  while (sema->value == 0)    // 循环等待
    {
      list_push_back (&sema->waiters, &thread_current ()->elem);
      thread_block ();        // 阻塞自己
    }
  sema->value--;              // 获取资源
  intr_set_level (old_level);
}
```

### 执行流程

```
线程调用 sema_down(&sema)
         │
         ▼
    禁用中断
         │
         ▼
    value == 0?  ─────► 是 ─────► 加入 waiters
         │                           │
         │ 否                        │
         │                           ▼
         │                      thread_block()
         │                           │
         │                           │ (被其他线程唤醒)
         │                           │
         │ ◄─────────────────────────┘
         │
         ▼
    value-- (获取资源)
         │
         ▼
    恢复中断
         │
         ▼
      返回
```

### 为什么用 while 而不是 if？

考虑多个线程等待的情况：

```
sema.value = 0
waiters: [A] → [B] → [C]

Thread D 调用 sema_up():
    1. 唤醒 A
    2. value++ (value = 1)

但如果在 A 被调度前，D 又调用了 sema_down():
    value-- (value = 0)

A 被调度后:
    如果用 if：直接执行 value--，但 value 已经是 0！
    如果用 while：重新检查，发现 value == 0，继续等待
```

---

## sema_try_down() 详解

这是**非阻塞**版本的 down 操作：

```c
bool
sema_try_down (struct semaphore *sema) 
{
  enum intr_level old_level;
  bool success;

  ASSERT (sema != NULL);

  old_level = intr_disable ();
  if (sema->value > 0) 
    {
      sema->value--;
      success = true; 
    }
  else
    success = false;
  intr_set_level (old_level);

  return success;
}
```

**特点**：
- 不会阻塞
- 成功返回 true，失败返回 false
- 可以在中断处理程序中调用

**使用场景**：
- 轮询资源是否可用
- 不希望阻塞的情况

```c
if (sema_try_down (&resource_sema)) {
  // 获得资源，使用它
  use_resource ();
  sema_up (&resource_sema);
} else {
  // 资源不可用，做其他事
  do_something_else ();
}
```

---

## sema_up() 详解

这是**信号**操作（V 操作）：

```c
void
sema_up (struct semaphore *sema) 
{
  enum intr_level old_level;

  ASSERT (sema != NULL);

  old_level = intr_disable ();
  if (!list_empty (&sema->waiters)) 
    thread_unblock (list_entry (list_pop_front (&sema->waiters),
                                struct thread, elem));
  sema->value++;
  intr_set_level (old_level);
}
```

### 执行流程

```
线程调用 sema_up(&sema)
         │
         ▼
    禁用中断
         │
         ▼
    waiters 空?  ────► 否 ────► 取出队首线程
         │                        │
         │ 是                     │
         │                        ▼
         │                   thread_unblock()
         │                        │
         │ ◄──────────────────────┘
         │
         ▼
      value++
         │
         ▼
    恢复中断
         │
         ▼
      返回
```

### 先唤醒还是先递增？

当前实现：先唤醒，后递增。

这没有本质区别，因为：
1. 整个操作在中断禁用下是原子的
2. 被唤醒的线程不会立即运行（只是变为 READY）

---

## 信号量的使用模式

### 1. 互斥锁（Mutex）

```c
struct semaphore mutex;
sema_init (&mutex, 1);  // 初始值为 1

// 临界区
sema_down (&mutex);
// ... 访问共享资源 ...
sema_up (&mutex);
```

### 2. 资源计数

```c
#define MAX_CONNECTIONS 10
struct semaphore conn_sema;
sema_init (&conn_sema, MAX_CONNECTIONS);

void handle_connection (void) {
  sema_down (&conn_sema);  // 获取连接槽
  // ... 处理连接 ...
  sema_up (&conn_sema);    // 释放连接槽
}
```

### 3. 线程同步

```c
struct semaphore sync_sema;
sema_init (&sync_sema, 0);  // 初始值为 0

// 线程 A（等待者）
void thread_a (void) {
  sema_down (&sync_sema);   // 等待线程 B 的信号
  printf ("B has finished!\n");
}

// 线程 B（通知者）
void thread_b (void) {
  do_something ();
  sema_up (&sync_sema);     // 通知线程 A
}
```

### 4. 生产者-消费者

```c
struct semaphore empty_slots;  // 空槽数
struct semaphore filled_slots; // 满槽数
struct semaphore mutex;        // 保护缓冲区

sema_init (&empty_slots, BUFFER_SIZE);
sema_init (&filled_slots, 0);
sema_init (&mutex, 1);

void producer (void) {
  while (true) {
    item = produce_item ();
    sema_down (&empty_slots);  // 等待空槽
    sema_down (&mutex);        // 获取互斥锁
    buffer_add (item);
    sema_up (&mutex);          // 释放互斥锁
    sema_up (&filled_slots);   // 增加满槽数
  }
}

void consumer (void) {
  while (true) {
    sema_down (&filled_slots); // 等待满槽
    sema_down (&mutex);        // 获取互斥锁
    item = buffer_remove ();
    sema_up (&mutex);          // 释放互斥锁
    sema_up (&empty_slots);    // 增加空槽数
    consume_item (item);
  }
}
```

---

## 信号量状态图

```
                    sema_init(3)
                         │
                         ▼
                   ┌───────────┐
                   │ value = 3 │
                   │ waiters=[]│
                   └───────────┘
                         │
        ┌────────────────┼────────────────┐
        │ sema_down      │ sema_down      │ sema_down
        ▼                ▼                ▼
   ┌───────────┐   ┌───────────┐   ┌───────────┐
   │ value = 2 │   │ value = 1 │   │ value = 0 │
   │ waiters=[]│   │ waiters=[]│   │ waiters=[]│
   └───────────┘   └───────────┘   └───────────┘
                                        │
                                        │ sema_down (Thread A)
                                        ▼
                                   ┌───────────┐
                                   │ value = 0 │
                                   │waiters=[A]│
                                   └───────────┘
                                        │
                                        │ sema_up
                                        ▼
                                   ┌───────────┐
                                   │ value = 1 │
                                   │ waiters=[]│  A 被唤醒
                                   └───────────┘
```

---

## sema_self_test() 自测试

```c
/** Self-test for semaphores that makes control "ping-pong"
   between a pair of threads. */
void
sema_self_test (void) 
{
  struct semaphore sema[2];
  int i;

  printf ("Testing semaphores...");
  sema_init (&sema[0], 0);
  sema_init (&sema[1], 0);
  thread_create ("sema-test", PRI_DEFAULT, sema_test_helper, &sema);
  for (i = 0; i < 10; i++) 
    {
      sema_up (&sema[0]);    // 通知 helper
      sema_down (&sema[1]);  // 等待 helper
    }
  printf ("done.\n");
}

static void
sema_test_helper (void *sema_) 
{
  struct semaphore *sema = sema_;
  int i;

  for (i = 0; i < 10; i++) 
    {
      sema_down (&sema[0]);  // 等待主线程
      sema_up (&sema[1]);    // 通知主线程
    }
}
```

这个测试展示了信号量用于线程同步的"乒乓"模式。

---

## 常见问题

### Q1: 为什么信号量不能有负值？

**答**：Pintos 使用 `unsigned` 存储 value，不能为负。概念上，负值表示等待的线程数，但 Pintos 用 waiters 队列的长度来表示。

### Q2: sema_down 和 sema_up 必须成对出现吗？

**答**：不一定。取决于用途：
- 用于互斥时，应该成对
- 用于同步时，可能由不同线程调用
- 用于资源计数时，取决于资源的生命周期

### Q3: 信号量可以在中断处理程序中使用吗？

**答**：
- `sema_up()`：可以
- `sema_try_down()`：可以
- `sema_down()`：**不可以**（会阻塞）

### Q4: 唤醒的线程会立即运行吗？

**答**：不会。`thread_unblock()` 只是把线程加入 ready_list。被唤醒的线程会在将来某时刻被调度运行。

### Q5: 为什么信号量的 value 使用 unsigned？

**答**：概念上信号量值不应该为负。使用 unsigned 可以在编译时捕获一些错误，并明确表示设计意图。

---

## 练习思考

1. **分析题**：如果把 sema_down 中的 while 改成 if，给出一个会出错的场景。

2. **设计题**：如何实现一个"公平"的信号量，保证等待最久的线程先被唤醒？

3. **编程题**：用信号量实现一个有界缓冲区（bounded buffer）。

4. **思考题**：信号量和条件变量的本质区别是什么？

5. **扩展题**：研究"信号量的优先级反转问题"，并思考如何解决。

---

## 下一步

理解了信号量后，下一篇文档将介绍**锁（Lock）**的实现，它是信号量的一个重要应用。
