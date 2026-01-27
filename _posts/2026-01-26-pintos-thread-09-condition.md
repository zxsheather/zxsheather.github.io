---
layout: post
title: "Pintos 线程系统详解（九）：条件变量"
date: 2026-01-26
categories: [技术, Pintos]
tags: [OS, Pintos, 同步, 条件变量]
description: "详细解析 Pintos 中条件变量（Condition Variable）的实现，理解高级同步机制。"
mermaid: true
---

## 概述

本文档详细解析 Pintos 中**条件变量（Condition Variable）**的实现。条件变量允许线程等待特定条件成立，是实现复杂同步场景的重要工具。

条件变量必须与锁配合使用，用于：
- 等待某个条件变为真
- 通知条件已改变

---

## 原始代码

### synch.h 中的定义

```c
/** Condition variable. */
struct condition 
  {
    struct list waiters;        /**< List of waiting threads. */
  };

void cond_init (struct condition *);
void cond_wait (struct condition *, struct lock *);
void cond_signal (struct condition *, struct lock *);
void cond_broadcast (struct condition *, struct lock *);
```

### synch.c 中的实现

```c
/** One semaphore in a list. */
struct semaphore_elem 
  {
    struct list_elem elem;              /**< List element. */
    struct semaphore semaphore;         /**< This semaphore. */
  };

/** Initializes condition variable COND.  A condition variable
   allows one piece of code to signal a condition and cooperating
   code to receive the signal and act upon it. */
void
cond_init (struct condition *cond)
{
  ASSERT (cond != NULL);

  list_init (&cond->waiters);
}

/** Atomically releases LOCK and waits for COND to be signaled by
   some other piece of code.  After COND is signaled, LOCK is
   reacquired before returning.  LOCK must be held before calling
   this function.

   The monitor implemented by this function is "Mesa" style, not
   "Hoare" style, that is, sending and receiving a signal are not
   an atomic operation.  Thus, typically the caller must recheck
   the condition after the wait completes and, if necessary, wait
   again.

   A given condition variable is associated with only a single
   lock, but one lock may be associated with any number of
   condition variables.  That is, there is a one-to-many mapping
   from locks to condition variables.

   This function may sleep, so it must not be called within an
   interrupt handler.  This function may be called with
   interrupts disabled, but interrupts will be turned back on if
   we need to sleep. */
void
cond_wait (struct condition *cond, struct lock *lock) 
{
  struct semaphore_elem waiter;

  ASSERT (cond != NULL);
  ASSERT (lock != NULL);
  ASSERT (!intr_context ());
  ASSERT (lock_held_by_current_thread (lock));
  
  sema_init (&waiter.semaphore, 0);
  list_push_back (&cond->waiters, &waiter.elem);
  lock_release (lock);
  sema_down (&waiter.semaphore);
  lock_acquire (lock);
}

/** If any threads are waiting on COND (protected by LOCK), then
   this function signals one of them to wake up from its wait.
   LOCK must be held before calling this function.

   An interrupt handler cannot acquire a lock, so it does not
   make sense to try to signal a condition variable within an
   interrupt handler. */
void
cond_signal (struct condition *cond, struct lock *lock UNUSED) 
{
  ASSERT (cond != NULL);
  ASSERT (lock != NULL);
  ASSERT (!intr_context ());
  ASSERT (lock_held_by_current_thread (lock));

  if (!list_empty (&cond->waiters)) 
    sema_up (&list_entry (list_pop_front (&cond->waiters),
                          struct semaphore_elem, elem)->semaphore);
}

/** Wakes up all threads, if any, waiting on COND (protected by
   LOCK).  LOCK must be held before calling this function.

   An interrupt handler cannot acquire a lock, so it does not
   make sense to try to signal a condition variable within an
   interrupt handler. */
void
cond_broadcast (struct condition *cond, struct lock *lock) 
{
  ASSERT (cond != NULL);
  ASSERT (lock != NULL);

  while (!list_empty (&cond->waiters))
    cond_signal (cond, lock);
}
```

---

## 前置知识

### 1. 为什么需要条件变量？

考虑一个生产者-消费者场景：

```c
// 消费者 - 不好的实现（忙等待）
while (true) {
  lock_acquire (&buffer_lock);
  while (buffer_is_empty ()) {
    lock_release (&buffer_lock);
    thread_yield ();              // 忙等待！
    lock_acquire (&buffer_lock);
  }
  consume (buffer_get ());
  lock_release (&buffer_lock);
}
```

**问题**：即使缓冲区为空，消费者也在不断检查，浪费 CPU。

**条件变量的解决方案**：

```c
// 消费者 - 好的实现
while (true) {
  lock_acquire (&buffer_lock);
  while (buffer_is_empty ()) {
    cond_wait (&not_empty, &buffer_lock);  // 高效等待
  }
  consume (buffer_get ());
  lock_release (&buffer_lock);
}
```

### 2. Monitor（管程）概念

**Monitor** 是一种同步机制，包含：
- **锁**：保护共享数据
- **条件变量**：等待/通知机制
- **共享数据**

Pintos 的条件变量实现了 **Mesa 风格**的管程：
- signal 只是唤醒等待者，不会立即切换
- 等待者被唤醒后需要重新检查条件

### 3. Mesa vs Hoare 风格

| 特性 | Mesa 风格 | Hoare 风格 |
|------|-----------|------------|
| signal 后 | 继续执行 | 立即切换到等待者 |
| wait 后 | 需要重新检查条件 | 条件保证为真 |
| 实现复杂度 | 简单 | 复杂 |
| Pintos 使用 | ✓ | |

```c
// Mesa 风格必须用 while
while (!condition) {
  cond_wait (&cond, &lock);
}

// Hoare 风格可以用 if（但通常也用 while 更安全）
if (!condition) {
  cond_wait (&cond, &lock);
}
```

---

## struct condition 详解

```c
struct condition 
  {
    struct list waiters;        /**< List of waiting threads. */
  };
```

非常简单：只有一个等待者列表。

但等待者不是直接的线程，而是 `semaphore_elem`：

```c
struct semaphore_elem 
  {
    struct list_elem elem;              /**< List element. */
    struct semaphore semaphore;         /**< This semaphore. */
  };
```

**为什么用信号量而不是直接用线程？**

每个等待者都有自己的信号量，这样可以：
1. 精确唤醒特定等待者
2. 等待者可以自己的速度运行

---

## cond_init() 详解

```c
void
cond_init (struct condition *cond)
{
  ASSERT (cond != NULL);

  list_init (&cond->waiters);
}
```

初始化条件变量：只需初始化等待者列表。

---

## cond_wait() 详解

这是最复杂的函数：

```c
void
cond_wait (struct condition *cond, struct lock *lock) 
{
  struct semaphore_elem waiter;

  ASSERT (cond != NULL);
  ASSERT (lock != NULL);
  ASSERT (!intr_context ());
  ASSERT (lock_held_by_current_thread (lock));  // 必须持有锁
  
  sema_init (&waiter.semaphore, 0);             // 初始化信号量为 0
  list_push_back (&cond->waiters, &waiter.elem); // 加入等待队列
  lock_release (lock);                           // 释放锁
  sema_down (&waiter.semaphore);                // 等待（阻塞）
  lock_acquire (lock);                           // 被唤醒后重新获取锁
}
```

### 执行流程

```
线程 A 调用 cond_wait(&cond, &lock)
         │
         ▼
    检查断言（必须持有锁）
         │
         ▼
    创建 semaphore_elem waiter
    sema_init(&waiter.semaphore, 0)
         │
         ▼
    加入 cond->waiters 队列
         │
         ▼
    lock_release(lock)     ← 释放锁！
         │
         ▼
    sema_down(&waiter.semaphore)  ← 阻塞等待
         │
         │ (其他线程调用 cond_signal)
         │
         ▼
    lock_acquire(lock)     ← 重新获取锁
         │
         ▼
      返回
```

### 关键点

1. **必须持有锁**：在检查条件和等待之间需要原子性
2. **释放锁再等待**：否则其他线程无法修改条件
3. **被唤醒后重新获取锁**：保持调用前后锁的状态一致

### 为什么用局部变量 waiter？

`waiter` 在栈上分配，当函数返回时自动销毁。这是安全的，因为：
- `cond_wait` 返回时，`waiter` 已经被移出队列（由 `cond_signal` 的 `list_pop_front`）
- 函数返回前，不再需要 `waiter`

---

## cond_signal() 详解

```c
void
cond_signal (struct condition *cond, struct lock *lock UNUSED) 
{
  ASSERT (cond != NULL);
  ASSERT (lock != NULL);
  ASSERT (!intr_context ());
  ASSERT (lock_held_by_current_thread (lock));  // 必须持有锁

  if (!list_empty (&cond->waiters)) 
    sema_up (&list_entry (list_pop_front (&cond->waiters),
                          struct semaphore_elem, elem)->semaphore);
}
```

### 执行流程

```
线程 B 调用 cond_signal(&cond, &lock)
         │
         ▼
    检查断言（必须持有锁）
         │
         ▼
    waiters 空?  ────► 是 ────► 什么都不做
         │
         │ 否
         │
         ▼
    取出队首的 semaphore_elem
         │
         ▼
    sema_up(&elem->semaphore)
         │
         ▼
      返回
```

### 关键点

1. **只唤醒一个**：使用 `list_pop_front`
2. **FIFO 顺序**：先等待的先被唤醒
3. **可能无人等待**：`waiters` 可能为空

---

## cond_broadcast() 详解

```c
void
cond_broadcast (struct condition *cond, struct lock *lock) 
{
  ASSERT (cond != NULL);
  ASSERT (lock != NULL);

  while (!list_empty (&cond->waiters))
    cond_signal (cond, lock);
}
```

唤醒所有等待者。简单地重复调用 `cond_signal`。

**使用场景**：
- 当条件改变可能影响多个等待者时
- 当不知道哪个等待者应该被唤醒时

---

## 条件变量的使用模式

### 1. 等待条件模式

```c
lock_acquire (&lock);
while (!condition) {           // 用 while，不用 if
  cond_wait (&cond, &lock);
}
// 条件现在为真
do_something ();
lock_release (&lock);
```

### 2. 通知模式

```c
lock_acquire (&lock);
change_condition ();           // 修改条件
cond_signal (&cond, &lock);    // 通知等待者
// 或 cond_broadcast (&cond, &lock);
lock_release (&lock);
```

### 3. 生产者-消费者完整示例

```c
struct buffer {
  struct lock lock;
  struct condition not_empty;
  struct condition not_full;
  int items[BUFFER_SIZE];
  int count;
  int in, out;
};

void
buffer_init (struct buffer *b)
{
  lock_init (&b->lock);
  cond_init (&b->not_empty);
  cond_init (&b->not_full);
  b->count = 0;
  b->in = b->out = 0;
}

void
producer (struct buffer *b, int item)
{
  lock_acquire (&b->lock);
  
  while (b->count == BUFFER_SIZE)
    cond_wait (&b->not_full, &b->lock);  // 等待有空位
  
  b->items[b->in] = item;
  b->in = (b->in + 1) % BUFFER_SIZE;
  b->count++;
  
  cond_signal (&b->not_empty, &b->lock);  // 通知有数据
  lock_release (&b->lock);
}

int
consumer (struct buffer *b)
{
  int item;
  lock_acquire (&b->lock);
  
  while (b->count == 0)
    cond_wait (&b->not_empty, &b->lock);  // 等待有数据
  
  item = b->items[b->out];
  b->out = (b->out + 1) % BUFFER_SIZE;
  b->count--;
  
  cond_signal (&b->not_full, &b->lock);   // 通知有空位
  lock_release (&b->lock);
  
  return item;
}
```

---

## cond_wait 的原子性

```c
void
cond_wait (struct condition *cond, struct lock *lock) 
{
  // ...
  list_push_back (&cond->waiters, &waiter.elem);
  lock_release (lock);            // ← 这两步必须原子
  sema_down (&waiter.semaphore);  // ← 否则可能丢失信号
  lock_acquire (lock);
}
```

**问题场景**（如果不是原子的）：

```
Thread A (等待者)              Thread B (通知者)
─────────────────────         ─────────────────────
lock_release(lock)
                              lock_acquire(lock)
                              change_condition()
                              cond_signal(...)  // 信号丢失！
                              lock_release(lock)
sema_down(...)  // 永远等待
```

**为什么 Pintos 的实现是安全的？**

因为：
1. `lock_release` 前，A 已经在等待队列中
2. `sema_down` 会阻塞，即使 `sema_up` 还没调用
3. 如果 B 在 A 的 `lock_release` 和 `sema_down` 之间调用 `cond_signal`，A 的信号量会被 up，`sema_down` 会立即返回

---

## 条件变量状态图

```
                    cond_init()
                         │
                         ▼
                   ┌───────────┐
                   │ waiters=[]│
                   │   (空)    │
                   └───────────┘
                         │
                         │ Thread A: cond_wait
                         ▼
                   ┌───────────┐
                   │waiters=[A]│  A 的信号量值为 0
                   └───────────┘
                         │
          ┌──────────────┴──────────────┐
          │                             │
          │ Thread B: cond_wait         │ Thread C: cond_signal
          ▼                             ▼
   ┌───────────┐                 ┌───────────┐
   │waiters=   │                 │ waiters=[]│  A 被唤醒
   │  [A, B]   │                 └───────────┘
   └───────────┘
          │
          │ Thread C: cond_broadcast
          ▼
   ┌───────────┐
   │ waiters=[]│  A 和 B 都被唤醒
   └───────────┘
```

---

## 常见问题

### Q1: 为什么 cond_wait 必须用 while 循环？

**答**：因为 Mesa 风格的管程中，被唤醒的线程不保证条件仍然为真：

1. **虚假唤醒**：多个线程等待同一条件
2. **竞争**：从被唤醒到重新获取锁之间，条件可能又变了

```c
// 错误
if (!condition) {
  cond_wait (&cond, &lock);
}
// 可能条件仍然为假！

// 正确
while (!condition) {
  cond_wait (&cond, &lock);
}
// 条件保证为真
```

### Q2: signal 和 broadcast 有什么区别？

**答**：
- `signal`：唤醒一个等待者（效率高）
- `broadcast`：唤醒所有等待者（更安全）

使用 `broadcast` 的场景：
- 条件变化可能满足多个等待者
- 不同等待者等待不同条件
- 不确定哪个等待者应该被唤醒

### Q3: 为什么条件变量必须和锁一起使用？

**答**：为了保护条件检查的原子性：

```c
// 没有锁 - 危险！
if (!condition) {         // 检查条件
  // 这里条件可能改变！
  cond_wait (...);        // 等待
}

// 有锁 - 安全
lock_acquire (&lock);
while (!condition) {
  cond_wait (&cond, &lock);  // 原子地释放锁并等待
}
lock_release (&lock);
```

### Q4: cond_signal 在无人等待时调用会怎样？

**答**：什么都不会发生。信号会"丢失"。这与信号量不同（信号量会记住）。

### Q5: 为什么等待者队列存储 semaphore_elem 而不是直接存储线程？

**答**：每个等待者有自己的信号量，可以：
1. 精确地唤醒特定等待者
2. 避免虚假唤醒问题
3. 简化实现

---

## 调试技巧

### 打印等待队列

```c
void
debug_print_condition (struct condition *cond)
{
  struct list_elem *e;
  printf ("Condition waiters: ");
  for (e = list_begin (&cond->waiters); 
       e != list_end (&cond->waiters);
       e = list_next (e))
    {
      struct semaphore_elem *se = list_entry (e, struct semaphore_elem, elem);
      // 需要额外信息来识别等待者
      printf ("(sema) ");
    }
  printf ("\n");
}
```

### 检测死锁模式

```c
void
cond_wait (struct condition *cond, struct lock *lock) 
{
  printf ("Thread '%s' waiting on condition\n", thread_current ()->name);
  // ... 原有代码 ...
  printf ("Thread '%s' woke up from condition\n", thread_current ()->name);
  lock_acquire (lock);
}
```

---

## 练习思考

1. **分析题**：画出生产者-消费者示例中，一个生产者、两个消费者的执行序列。

2. **设计题**：如何实现一个带超时的 `cond_wait`？

3. **编程题**：使用条件变量实现一个读写锁（多个读者或一个写者）。

4. **思考题**：为什么 Pintos 选择 Mesa 风格而不是 Hoare 风格？

5. **扩展题**：研究 `pthread_cond_t` 的实现，与 Pintos 对比。

---

## 下一步

理解了条件变量后，下一篇文档将介绍**中断处理**与线程的关系，理解中断如何影响线程调度。
