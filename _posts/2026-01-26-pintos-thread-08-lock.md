---
layout: post
title: "Pintos 线程系统详解（八）：锁"
date: 2026-01-26
categories: [技术, Pintos]
tags: [OS, Pintos, 同步, 锁, 互斥]
description: "详细解析 Pintos 中锁（Lock）的实现，理解互斥机制。"
mermaid: true
---

## 概述

本文档详细解析 Pintos 中**锁（Lock）**的实现。锁是最常用的同步原语，用于实现**互斥**（Mutual Exclusion），确保同一时刻只有一个线程能访问共享资源。

在 Pintos 中，锁是基于**信号量**实现的。

---

## 原始代码

### synch.h 中的定义

```c
/** Lock. */
struct lock 
  {
    struct thread *holder;      /**< Thread holding lock (for debugging). */
    struct semaphore semaphore; /**< Binary semaphore controlling access. */
  };

void lock_init (struct lock *);
void lock_acquire (struct lock *);
bool lock_try_acquire (struct lock *);
void lock_release (struct lock *);
bool lock_held_by_current_thread (const struct lock *);
```

### synch.c 中的实现

```c
/** Initializes LOCK.  A lock can be held by at most a single
   thread at any given time.  Our locks are not "recursive", that
   is, it is an error for the thread currently holding a lock to
   try to acquire that lock.

   A lock is a specialization of a semaphore with an initial
   value of 1.  The difference between a lock and such a
   semaphore is twofold.  First, a semaphore can have a value
   greater than 1, but a lock can only be owned by a single
   thread at a time.  Second, a semaphore does not have an owner,
   meaning that one thread can "down" the semaphore and then
   another one "up" it, but with a lock the same thread must both
   acquire and release it.  When these restrictions prove
   onerous, it's a good sign that a semaphore should be used,
   instead of a lock. */
void
lock_init (struct lock *lock)
{
  ASSERT (lock != NULL);

  lock->holder = NULL;
  sema_init (&lock->semaphore, 1);
}

/** Acquires LOCK, sleeping until it becomes available if
   necessary.  The lock must not already be held by the current
   thread.

   This function may sleep, so it must not be called within an
   interrupt handler.  This function may be called with
   interrupts disabled, but interrupts will be turned back on if
   we need to sleep. */
void
lock_acquire (struct lock *lock)
{
  ASSERT (lock != NULL);
  ASSERT (!intr_context ());
  ASSERT (!lock_held_by_current_thread (lock));

  sema_down (&lock->semaphore);
  lock->holder = thread_current ();
}

/** Tries to acquires LOCK and returns true if successful or false
   on failure.  The lock must not already be held by the current
   thread.

   This function will not sleep, so it may be called within an
   interrupt handler. */
bool
lock_try_acquire (struct lock *lock)
{
  bool success;

  ASSERT (lock != NULL);
  ASSERT (!lock_held_by_current_thread (lock));

  success = sema_try_down (&lock->semaphore);
  if (success)
    lock->holder = thread_current ();
  return success;
}

/** Releases LOCK, which must be owned by the current thread.

   An interrupt handler cannot acquire a lock, so it does not
   make sense to try to release a lock within an interrupt
   handler. */
void
lock_release (struct lock *lock) 
{
  ASSERT (lock != NULL);
  ASSERT (lock_held_by_current_thread (lock));

  lock->holder = NULL;
  sema_up (&lock->semaphore);
}

/** Returns true if the current thread holds LOCK, false
   otherwise.  (Note that testing whether some other thread holds
   a lock would be racy.) */
bool
lock_held_by_current_thread (const struct lock *lock) 
{
  ASSERT (lock != NULL);

  return lock->holder == thread_current ();
}
```

---

## 前置知识

### 1. 锁 vs 信号量

| 特性 | 锁（Lock） | 信号量（Semaphore） |
|------|-----------|---------------------|
| 值的范围 | 0 或 1 | 任意非负整数 |
| 所有者 | 有（holder） | 无 |
| 释放约束 | 只有持有者可释放 | 任何线程可 up |
| 递归支持 | Pintos 不支持 | 不适用 |
| 主要用途 | 互斥 | 资源计数、同步 |

### 2. 互斥的概念

**临界区（Critical Section）**：访问共享资源的代码段。

**互斥**：确保同一时刻只有一个线程在临界区内。

```c
// 没有互斥 - 危险！
shared_counter++;  // 多线程同时执行会出错

// 有互斥 - 安全
lock_acquire (&counter_lock);
shared_counter++;  // 只有一个线程能执行
lock_release (&counter_lock);
```

### 3. 为什么锁需要所有者？

1. **调试**：可以知道谁持有锁
2. **安全**：防止非持有者释放锁
3. **防止递归**：检测同一线程重复获取锁

---

## struct lock 详解

```c
struct lock 
  {
    struct thread *holder;      /**< Thread holding lock. */
    struct semaphore semaphore; /**< Binary semaphore controlling access. */
  };
```

**holder**：当前持有锁的线程
- NULL 表示锁未被持有
- 非 NULL 表示被某线程持有

**semaphore**：底层的二进制信号量
- 初始值为 1
- 用于实现互斥

**内存布局**：

```
struct lock
┌─────────────────────────────────┐
│   holder (4 bytes)              │  指向持有者线程
├─────────────────────────────────┤
│   semaphore.value (4 bytes)     │  0 或 1
├─────────────────────────────────┤
│   semaphore.waiters (list)      │  等待队列
└─────────────────────────────────┘
```

---

## lock_init() 详解

```c
void
lock_init (struct lock *lock)
{
  ASSERT (lock != NULL);

  lock->holder = NULL;
  sema_init (&lock->semaphore, 1);
}
```

初始化锁：
1. holder 设为 NULL（无持有者）
2. 信号量初始化为 1（锁可用）

---

## lock_acquire() 详解

```c
void
lock_acquire (struct lock *lock)
{
  ASSERT (lock != NULL);
  ASSERT (!intr_context ());              // 不能在中断中获取
  ASSERT (!lock_held_by_current_thread (lock));  // 不能重复获取

  sema_down (&lock->semaphore);           // 获取信号量
  lock->holder = thread_current ();       // 设置持有者
}
```

### 执行流程

```
线程 A 调用 lock_acquire(&lock)
         │
         ▼
    检查断言
         │
         ▼
    sema_down(&lock->semaphore)
         │
         ├─── semaphore.value > 0 ───► value--，立即返回
         │
         └─── semaphore.value == 0 ───► 阻塞等待
                      │
                      ▼
              (等待锁被释放)
                      │
                      ▼
              (被唤醒，value--)
         │
         ◄────────────┘
         │
         ▼
    lock->holder = thread_current()
         │
         ▼
      返回（已获取锁）
```

### 为什么不能重复获取？

```c
ASSERT (!lock_held_by_current_thread (lock));
```

Pintos 的锁是**非递归**的。如果允许重复获取：

```c
void func_a (void) {
  lock_acquire (&lock);
  func_b ();            // 调用 func_b
  lock_release (&lock);
}

void func_b (void) {
  lock_acquire (&lock);  // 死锁！已经持有但 value=0
  // ...
  lock_release (&lock);
}
```

要解决这个问题需要**递归锁**，但 Pintos 不支持。

---

## lock_try_acquire() 详解

```c
bool
lock_try_acquire (struct lock *lock)
{
  bool success;

  ASSERT (lock != NULL);
  ASSERT (!lock_held_by_current_thread (lock));

  success = sema_try_down (&lock->semaphore);
  if (success)
    lock->holder = thread_current ();
  return success;
}
```

**特点**：
- 非阻塞
- 成功返回 true，失败返回 false
- 可以在中断处理程序中调用（但通常不建议）

**使用场景**：

```c
if (lock_try_acquire (&lock)) {
  // 获取成功，使用资源
  use_resource ();
  lock_release (&lock);
} else {
  // 获取失败，做其他事
  handle_contention ();
}
```

---

## lock_release() 详解

```c
void
lock_release (struct lock *lock) 
{
  ASSERT (lock != NULL);
  ASSERT (lock_held_by_current_thread (lock));  // 必须是持有者

  lock->holder = NULL;              // 清除持有者
  sema_up (&lock->semaphore);       // 释放信号量
}
```

### 执行流程

```
线程 A 调用 lock_release(&lock)
         │
         ▼
    检查是否是持有者
         │
         ▼
    lock->holder = NULL
         │
         ▼
    sema_up(&lock->semaphore)
         │
         ├─── 有等待者 ───► 唤醒一个等待线程
         │
         └─── 无等待者 ───► 仅 value++
         │
         ▼
      返回
```

### 为什么只有持有者可以释放？

```c
ASSERT (lock_held_by_current_thread (lock));
```

这确保了锁的**语义正确性**：
- 防止意外释放别人的锁
- 便于调试（快速发现错误）

---

## lock_held_by_current_thread() 详解

```c
bool
lock_held_by_current_thread (const struct lock *lock) 
{
  ASSERT (lock != NULL);

  return lock->holder == thread_current ();
}
```

检查当前线程是否持有锁。

**为什么只能检查当前线程？**

> "Note that testing whether some other thread holds a lock would be racy."

检查其他线程是否持有锁存在竞态条件：
- 你检查时，那个线程可能正在释放锁
- 检查结果可能立即过时

但检查当前线程是安全的：
- 如果我持有锁，只有我能释放它
- 如果我不持有锁，我不能改变这个状态（直到我获取它）

---

## 锁的状态图

```
                    lock_init()
                         │
                         ▼
              ┌─────────────────────┐
              │    holder = NULL    │
              │ semaphore.value = 1 │
              │    (锁可用)         │
              └─────────────────────┘
                         │
                         │ Thread A: lock_acquire
                         ▼
              ┌─────────────────────┐
              │    holder = A       │
              │ semaphore.value = 0 │
              │   (锁被 A 持有)     │
              └─────────────────────┘
                         │
          ┌──────────────┴──────────────┐
          │                             │
          │ Thread B: lock_acquire      │ Thread A: lock_release
          ▼                             ▼
┌─────────────────────┐      ┌─────────────────────┐
│    holder = A       │      │    holder = NULL    │
│ semaphore.value = 0 │      │ semaphore.value = 1 │
│  waiters = [B]      │      │    (锁可用)         │
│   (B 在等待)        │      └─────────────────────┘
└─────────────────────┘
          │
          │ Thread A: lock_release
          ▼
┌─────────────────────┐
│    holder = B       │  ← B 被唤醒并获取锁
│ semaphore.value = 0 │
│   (锁被 B 持有)     │
└─────────────────────┘
```

---

## 锁的使用模式

### 1. 保护共享数据

```c
struct shared_data {
  struct lock lock;
  int value;
  // ... 其他字段 ...
};

void init_shared_data (struct shared_data *data) {
  lock_init (&data->lock);
  data->value = 0;
}

void update_data (struct shared_data *data, int new_value) {
  lock_acquire (&data->lock);
  data->value = new_value;
  lock_release (&data->lock);
}

int read_data (struct shared_data *data) {
  int value;
  lock_acquire (&data->lock);
  value = data->value;
  lock_release (&data->lock);
  return value;
}
```

### 2. 原子操作

```c
void atomic_increment (int *counter, struct lock *lock) {
  lock_acquire (lock);
  (*counter)++;
  lock_release (lock);
}
```

### 3. 保护链表操作

```c
struct list shared_list;
struct lock list_lock;

void add_to_list (struct list_elem *elem) {
  lock_acquire (&list_lock);
  list_push_back (&shared_list, elem);
  lock_release (&list_lock);
}

struct list_elem *remove_from_list (void) {
  struct list_elem *e = NULL;
  lock_acquire (&list_lock);
  if (!list_empty (&shared_list))
    e = list_pop_front (&shared_list);
  lock_release (&list_lock);
  return e;
}
```

---

## 锁与信号量的对比实现

### 用信号量实现互斥

```c
struct semaphore mutex;
sema_init (&mutex, 1);

// 临界区
sema_down (&mutex);
// ... 访问共享资源 ...
sema_up (&mutex);
```

### 用锁实现互斥

```c
struct lock lock;
lock_init (&lock);

// 临界区
lock_acquire (&lock);
// ... 访问共享资源 ...
lock_release (&lock);
```

**锁的优势**：
- 有所有者概念，更安全
- 可以检测错误使用（如非持有者释放）
- 语义更清晰

---

## 死锁

### 什么是死锁？

多个线程互相等待对方持有的锁，永远无法继续。

```c
// Thread A                    // Thread B
lock_acquire (&lock1);         lock_acquire (&lock2);
lock_acquire (&lock2);         lock_acquire (&lock1);  // 死锁！
// ...                         // ...
lock_release (&lock2);         lock_release (&lock1);
lock_release (&lock1);         lock_release (&lock2);
```

```
Thread A:                    Thread B:
持有 lock1                   持有 lock2
等待 lock2 ─────────────► 被 B 持有
                            等待 lock1 ─────────────► 被 A 持有
```

### 避免死锁的方法

1. **锁顺序**：总是按相同顺序获取锁
   ```c
   // 总是先获取 lock1，再获取 lock2
   lock_acquire (&lock1);
   lock_acquire (&lock2);
   ```

2. **尝试获取**：使用 try_acquire，失败时释放已持有的锁
   ```c
   while (true) {
     lock_acquire (&lock1);
     if (lock_try_acquire (&lock2))
       break;
     lock_release (&lock1);
     thread_yield ();
   }
   ```

3. **超时机制**：Pintos 不支持，但其他系统可能有

---

## 常见问题

### Q1: 为什么 lock_acquire 不能在中断中调用？

**答**：因为它可能阻塞。中断处理程序必须快速完成，不能等待锁。

### Q2: 持有锁的线程退出了会怎样？

**答**：锁不会自动释放，等待的线程会永远阻塞。这是一个**bug**，应该确保线程退出前释放所有锁。

### Q3: 为什么 Pintos 的锁不是递归的？

**答**：递归锁更复杂，需要：
- 记录递归深度
- 只有深度降为 0 时才真正释放

Pintos 为了简单选择不支持。如果需要递归，应该重构代码避免递归获取。

### Q4: lock_try_acquire 什么时候有用？

**答**：
- 当不能阻塞时（如中断处理）
- 当有替代方案时
- 实现超时机制时

### Q5: 为什么先清除 holder 再 sema_up？

```c
lock->holder = NULL;
sema_up (&lock->semaphore);
```

**答**：顺序其实不重要，因为整个过程受禁用中断保护。但先清除 holder 更符合逻辑："先放弃所有权，再唤醒等待者"。

---

## 练习思考

1. **分析题**：如果 lock_release 不检查是否是持有者就释放，会有什么问题？

2. **设计题**：如何实现一个递归锁（可重入锁）？

3. **调试题**：如何检测死锁？

4. **思考题**：为什么 lock_held_by_current_thread 只能检查当前线程？

5. **扩展题**：研究读写锁（rwlock）的概念，思考如何实现。

---

## 下一步

理解了锁后，下一篇文档将介绍**条件变量（Condition Variable）**的实现，它允许线程等待特定条件成立。
