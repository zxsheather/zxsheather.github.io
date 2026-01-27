---
layout: post
title: "Pintos 线程系统详解（三）：线程创建"
date: 2026-01-26
categories: [技术, Pintos]
tags: [OS, Pintos, 线程, 内存管理]
description: "详细解析 Pintos 中 thread_create() 函数的实现，理解线程如何被创建和初始化。"
mermaid: true
---

## 概述

本文档详细解析 Pintos 中线程创建的过程。`thread_create()` 是创建新线程的核心函数，它负责：
1. 分配内存（一个 4KB 页）
2. 初始化线程结构体
3. 设置初始栈帧
4. 将线程加入就绪队列

理解这个函数是理解线程如何开始执行的关键。

---

## 原始代码

### thread_create() 函数

```c
/** Creates a new kernel thread named NAME with the given initial
   PRIORITY, which executes FUNCTION passing AUX as the argument,
   and adds it to the ready queue.  Returns the thread identifier
   for the new thread, or TID_ERROR if creation fails.

   If thread_start() has been called, then the new thread may be
   scheduled before thread_create() returns.  It could even exit
   before thread_create() returns.  Contrariwise, the original
   thread may run for any amount of time before the new thread is
   scheduled.  Use a semaphore or some other form of
   synchronization if you need to ensure ordering.

   The code provided sets the new thread's `priority' member to
   PRIORITY, but no actual priority scheduling is implemented.
   Priority scheduling is the goal of Problem 1-3. */
tid_t
thread_create (const char *name, int priority,
               thread_func *function, void *aux) 
{
  struct thread *t;
  struct kernel_thread_frame *kf;
  struct switch_entry_frame *ef;
  struct switch_threads_frame *sf;
  tid_t tid;

  ASSERT (function != NULL);

  /* Allocate thread. */
  t = palloc_get_page (PAL_ZERO);
  if (t == NULL)
    return TID_ERROR;

  /* Initialize thread. */
  init_thread (t, name, priority);
  tid = t->tid = allocate_tid ();

  /* Stack frame for kernel_thread(). */
  kf = alloc_frame (t, sizeof *kf);
  kf->eip = NULL;
  kf->function = function;
  kf->aux = aux;

  /* Stack frame for switch_entry(). */
  ef = alloc_frame (t, sizeof *ef);
  ef->eip = (void (*) (void)) kernel_thread;

  /* Stack frame for switch_threads(). */
  sf = alloc_frame (t, sizeof *sf);
  sf->eip = switch_entry;
  sf->ebp = 0;

  /* Add to run queue. */
  thread_unblock (t);

  return tid;
}
```

### init_thread() 函数

```c
/** Does basic initialization of T as a blocked thread named NAME. */
static void
init_thread (struct thread *t, const char *name, int priority)
{
  enum intr_level old_level;

  ASSERT (t != NULL);
  ASSERT (PRI_MIN <= priority && priority <= PRI_MAX);
  ASSERT (name != NULL);

  memset (t, 0, sizeof *t);
  t->status = THREAD_BLOCKED;
  strlcpy (t->name, name, sizeof t->name);
  t->stack = (uint8_t *) t + PGSIZE;
  t->priority = priority;
  t->magic = THREAD_MAGIC;

  old_level = intr_disable ();
  list_push_back (&all_list, &t->allelem);
  intr_set_level (old_level);
}
```

### alloc_frame() 函数

```c
/** Allocates a SIZE-byte frame at the top of thread T's stack and
   returns a pointer to the frame's base. */
static void *
alloc_frame (struct thread *t, size_t size) 
{
  /* Stack data is always allocated in word-size units. */
  ASSERT (is_thread (t));
  ASSERT (size % sizeof (uint32_t) == 0);

  t->stack -= size;
  return t->stack;
}
```

### kernel_thread() 函数

```c
/** Function used as the basis for a kernel thread. */
static void
kernel_thread (thread_func *function, void *aux) 
{
  ASSERT (function != NULL);

  intr_enable ();       /**< The scheduler runs with interrupts off. */
  function (aux);       /**< Execute the thread function. */
  thread_exit ();       /**< If function() returns, kill the thread. */
}
```

---

## 前置知识

### 1. 函数调用约定

在 x86 32 位系统中，函数调用遵循以下约定（cdecl）：

```
调用前:
┌──────────────────┐
│     参数 n       │  高地址
│     ...          │
│     参数 2       │
│     参数 1       │
│   返回地址       │  ← call 指令自动压入
└──────────────────┘  ← ESP（调用后）

函数开头:
push %ebp          ; 保存旧 ebp
mov %esp, %ebp     ; 建立栈帧
```

### 2. 栈帧结构

每个函数调用都会建立一个栈帧：

```
高地址
┌──────────────────┐
│   参数 n         │
│   ...            │
│   参数 1         │
├──────────────────┤
│   返回地址       │  ← call 指令压入
├──────────────────┤
│   旧 EBP         │  ← 当前 EBP 指向这里
├──────────────────┤
│   局部变量 1     │
│   ...            │
│   局部变量 n     │  ← ESP
└──────────────────┘
低地址
```

### 3. 栈帧类型定义

```c
/* switch.h */

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

/* thread.c */

/** Stack frame for kernel_thread(). */
struct kernel_thread_frame 
  {
    void *eip;                  /**< Return address. */
    thread_func *function;      /**< Function to call. */
    void *aux;                  /**< Auxiliary data for function. */
  };
```

---

## 逐步详解

### 第一步：参数检查和内存分配

```c
tid_t
thread_create (const char *name, int priority,
               thread_func *function, void *aux) 
{
  struct thread *t;
  struct kernel_thread_frame *kf;
  struct switch_entry_frame *ef;
  struct switch_threads_frame *sf;
  tid_t tid;

  ASSERT (function != NULL);  // function 不能为 NULL

  /* Allocate thread. */
  t = palloc_get_page (PAL_ZERO);  // 分配一个全零的页
  if (t == NULL)
    return TID_ERROR;  // 内存不足
```

**palloc_get_page(PAL_ZERO)**：
- 分配一个 4KB 页
- PAL_ZERO 标志表示将页内容清零
- 返回页的起始地址（页对齐）

**内存布局（刚分配完）**：

```
        4096 ┌─────────────────────┐
             │                     │
             │    全是 0           │
             │                     │
             │                     │
             │                     │
             │                     │
             │                     │
             │                     │
           0 └─────────────────────┘ ← t 指向这里
```

### 第二步：初始化线程结构

```c
  /* Initialize thread. */
  init_thread (t, name, priority);
  tid = t->tid = allocate_tid ();
```

**init_thread() 详解**：

```c
static void
init_thread (struct thread *t, const char *name, int priority)
{
  ASSERT (t != NULL);
  ASSERT (PRI_MIN <= priority && priority <= PRI_MAX);
  ASSERT (name != NULL);

  memset (t, 0, sizeof *t);           // 清零（虽然 PAL_ZERO 已经做了）
  t->status = THREAD_BLOCKED;          // 初始状态为阻塞
  strlcpy (t->name, name, sizeof t->name);  // 复制名称（最多 15 字符）
  t->stack = (uint8_t *) t + PGSIZE;   // 栈指针指向页顶
  t->priority = priority;              // 设置优先级
  t->magic = THREAD_MAGIC;             // 设置魔数

  // 加入 all_list
  old_level = intr_disable ();
  list_push_back (&all_list, &t->allelem);
  intr_set_level (old_level);
}
```

**内存布局（init_thread 后）**：

```
        4096 ┌─────────────────────┐ ← t->stack 初始值
             │                     │
             │    (栈空间)         │
             │                     │
             │                     │
             ├─────────────────────┤
             │      magic          │
             │      priority       │
             │      stack (指针)   │
             │      name[16]       │
             │      status         │
             │      tid            │
           0 └─────────────────────┘ ← t
```

### 第三步：设置栈帧

这是最关键的部分！我们需要设置三层栈帧：

```c
  /* Stack frame for kernel_thread(). */
  kf = alloc_frame (t, sizeof *kf);
  kf->eip = NULL;
  kf->function = function;
  kf->aux = aux;

  /* Stack frame for switch_entry(). */
  ef = alloc_frame (t, sizeof *ef);
  ef->eip = (void (*) (void)) kernel_thread;

  /* Stack frame for switch_threads(). */
  sf = alloc_frame (t, sizeof *sf);
  sf->eip = switch_entry;
  sf->ebp = 0;
```

**alloc_frame() 的工作**：

```c
static void *
alloc_frame (struct thread *t, size_t size) 
{
  t->stack -= size;   // 栈向下增长
  return t->stack;    // 返回新的栈顶
}
```

让我们一步步看栈的变化：

**初始状态**：

```
        4096 ┌─────────────────────┐ ← t->stack
             │                     │
             │                     │
             │                     │
```

**设置 kernel_thread_frame 后**：

```c
kf = alloc_frame (t, sizeof *kf);  // 12 字节
kf->eip = NULL;
kf->function = function;
kf->aux = aux;
```

```
        4096 ┌─────────────────────┐
             │       aux           │  4 字节
             │     function        │  4 字节
             │     eip (NULL)      │  4 字节
        4084 ├─────────────────────┤ ← t->stack, kf
             │                     │
```

**设置 switch_entry_frame 后**：

```c
ef = alloc_frame (t, sizeof *ef);  // 4 字节
ef->eip = (void (*) (void)) kernel_thread;
```

```
        4096 ┌─────────────────────┐
             │       aux           │
             │     function        │
             │     eip (NULL)      │  ← kf
        4084 ├─────────────────────┤
             │ eip (kernel_thread) │  ← ef
        4080 ├─────────────────────┤ ← t->stack
             │                     │
```

**设置 switch_threads_frame 后**：

```c
sf = alloc_frame (t, sizeof *sf);  // 28 字节
sf->eip = switch_entry;
sf->ebp = 0;
// edi, esi, ebx 保持为 0（PAL_ZERO）
```

```
        4096 ┌─────────────────────┐
             │       aux           │
             │     function        │
             │     eip (NULL)      │  ← kf
        4084 ├─────────────────────┤
             │ eip (kernel_thread) │  ← ef
        4080 ├─────────────────────┤
             │    next (未设置)    │  28: 参数
             │    cur (未设置)     │  24: 参数
             │  eip (switch_entry) │  20: 返回地址
             │    ebx (0)          │  16:
             │    ebp (0)          │  12:
             │    esi (0)          │   8:
             │    edi (0)          │   4:
        4052 ├─────────────────────┤ ← t->stack, sf
             │                     │
```

### 第四步：加入就绪队列

```c
  /* Add to run queue. */
  thread_unblock (t);

  return tid;
}
```

`thread_unblock(t)` 将线程从 BLOCKED 变为 READY，加入 ready_list。

---

## 完整栈帧布局

```
高地址
4096    ┌───────────────────────────────────────────┐
        │               aux                         │ ┐
        │             function                      │ │ kernel_thread_frame
        │           eip (NULL)                      │ ┘ (12 bytes)
        ├───────────────────────────────────────────┤
        │         eip (kernel_thread)               │   switch_entry_frame
        ├───────────────────────────────────────────┤   (4 bytes)
        │    next  (未初始化，由 schedule 设置)     │ ┐
        │    cur   (未初始化，由 schedule 设置)     │ │
        │    eip   (switch_entry)                   │ │ switch_threads_frame
        │    ebx   (0)                              │ │ (28 bytes)
        │    ebp   (0)                              │ │
        │    esi   (0)                              │ │
        │    edi   (0)                              │ ┘
        ├───────────────────────────────────────────┤ ← t->stack
        │                                           │
        │         (栈增长空间 - 未使用)             │
        │    kernel_thread() 执行时使用此空间      │
        │                                           │
        ├───────────────────────────────────────────┤
        │              magic                        │
        │            (其他字段)                     │
        │           struct thread                   │
0       └───────────────────────────────────────────┘ ← t
低地址
```

---

## 新线程如何开始执行？

这是理解线程系统的关键！让我们跟踪新线程第一次被调度的过程：

### 1. 调度器选中新线程

```c
static void
schedule (void) 
{
  struct thread *cur = running_thread ();
  struct thread *next = next_thread_to_run ();  // 选中新线程
  
  if (cur != next)
    prev = switch_threads (cur, next);  // 切换到新线程
  thread_schedule_tail (prev);
}
```

### 2. switch_threads() 切换

```plaintext
switch_threads:
    # 保存旧线程的寄存器
    pushl %ebx
    pushl %ebp
    pushl %esi
    pushl %edi

    # 保存旧线程的栈指针
    mov thread_stack_ofs, %edx
    movl SWITCH_CUR(%esp), %eax
    movl %esp, (%eax,%edx,1)      # cur->stack = esp

    # 恢复新线程的栈指针
    movl SWITCH_NEXT(%esp), %ecx
    movl (%ecx,%edx,1), %esp      # esp = next->stack

    # 恢复新线程的寄存器（对于新线程，是 0）
    popl %edi
    popl %esi
    popl %ebp
    popl %ebx
    ret  # 返回到 sf->eip，即 switch_entry
```

### 3. switch_entry() 执行

```plaintext
switch_entry:
    # 丢弃 switch_threads() 的参数
    addl $8, %esp

    # 调用 thread_schedule_tail(prev)
    pushl %eax
    call thread_schedule_tail
    addl $4, %esp

    # ret 将返回到 ef->eip，即 kernel_thread
    ret
```

### 4. kernel_thread() 执行

```c
static void
kernel_thread (thread_func *function, void *aux) 
{
  ASSERT (function != NULL);

  intr_enable ();       // 开启中断
  function (aux);       // 执行用户指定的函数！
  thread_exit ();       // 函数返回后退出线程
}
```

### 执行流程图

```
schedule()
    │
    ▼
switch_threads(cur, next)
    │
    │  保存 cur 的寄存器和栈指针
    │  恢复 next 的栈指针
    │  恢复 next 的寄存器 (全是 0)
    │
    ▼  ret (从 next 的栈弹出返回地址)
switch_entry  (sf->eip)
    │
    │  丢弃参数
    │  调用 thread_schedule_tail()
    │
    ▼  ret (从栈弹出返回地址)
kernel_thread  (ef->eip)
    │
    │  intr_enable()
    │  function(aux)   ← 执行用户函数！
    │
    ▼  thread_exit()
线程结束
```

---

## 为什么需要三层栈帧？

### switch_threads_frame

**作用**：模拟 switch_threads() 被调用后的状态

新线程第一次被调度时，需要假装它之前调用过 switch_threads()：
- 有保存的寄存器（初始化为 0）
- 有返回地址（指向 switch_entry）

### switch_entry_frame

**作用**：提供 switch_entry 的返回地址

switch_entry 需要一个返回地址（指向 kernel_thread）。

### kernel_thread_frame

**作用**：为 kernel_thread() 提供参数

kernel_thread() 需要知道要执行的函数和参数。

---

## thread_func 类型

```c
typedef void thread_func (void *aux);
```

线程函数的签名：
- 返回类型：void
- 参数：一个 void 指针

**使用示例**：

```c
void
my_thread_func (void *aux) 
{
  int *data = (int *) aux;
  printf ("Thread received: %d\n", *data);
}

// 创建线程
int value = 42;
thread_create ("my-thread", PRI_DEFAULT, my_thread_func, &value);
```

---

## 常见问题

### Q1: 为什么 kf->eip 设置为 NULL？

**答**：这是 kernel_thread() 的"返回地址"。正常情况下，kernel_thread() 不会 return（它调用 thread_exit()）。设置为 NULL 是一个安全措施：如果意外 return，访问 NULL 会导致明显的错误。

### Q2: 新线程的栈指针为什么指向 switch_threads_frame？

**答**：因为新线程第一次被调度时，会从 switch_threads() 的末尾继续执行。此时栈上需要有：
1. 保存的寄存器（供 popl 恢复）
2. 返回地址（供 ret 跳转）

### Q3: 为什么 sf->ebp 设置为 0？

**答**：ebp=0 表示栈帧链的终点。调试器在回溯调用栈时，遇到 ebp=0 就知道到顶了。

### Q4: thread_create() 返回后新线程就开始运行了吗？

**答**：不一定。thread_create() 只是将新线程加入 ready_list。新线程什么时候运行取决于调度器。可能：
1. 立即被调度（如果优先级更高）
2. 在下一个时间片
3. 当前线程主动 yield 后

### Q5: 如何向线程函数传递多个参数？

**答**：将多个参数打包成一个结构体：

```c
struct thread_args {
  int a;
  int b;
  char *str;
};

void my_func (void *aux) {
  struct thread_args *args = aux;
  // 使用 args->a, args->b, args->str
}

// 注意：args 必须在线程执行期间有效！
struct thread_args args = {1, 2, "hello"};
thread_create ("test", PRI_DEFAULT, my_func, &args);
```

### Q6: 线程函数 return 后会发生什么？

**答**：kernel_thread() 会调用 thread_exit()：

```c
static void
kernel_thread (thread_func *function, void *aux) 
{
  function (aux);       // 执行用户函数
  thread_exit ();       // 用户函数返回后，退出线程
}
```

所以线程函数可以安全地 return，不需要显式调用 thread_exit()。

---

## 调试技巧

### 打印新线程信息

```c
tid_t
thread_create (const char *name, int priority,
               thread_func *function, void *aux) 
{
  // ... 原有代码 ...
  
  printf ("Created thread '%s' (tid=%d, priority=%d)\n",
          name, tid, priority);
  printf ("  stack at %p, thread at %p\n", t->stack, t);
  
  thread_unblock (t);
  return tid;
}
```

### 使用 GDB 跟踪

```plaintext
# 在 thread_create 设置断点
b thread_create

# 运行后查看新线程的栈
print *t
print *kf
print *ef
print *sf

# 单步执行
n
```

---

## 练习思考

1. **计算题**：thread_create() 在栈上分配了多少字节？（kernel_thread_frame + switch_entry_frame + switch_threads_frame）

2. **分析题**：如果 palloc_get_page() 不使用 PAL_ZERO 标志，会有什么问题？

3. **设计题**：如果想让线程创建时就是 RUNNING 状态（立即执行），需要修改哪些代码？

4. **调试题**：如果新线程创建后立即崩溃，可能是什么原因？如何诊断？

5. **扩展题**：如何实现 `thread_create_suspended()`，创建一个不自动加入就绪队列的线程？

---

## 下一步

理解了线程创建后，下一篇文档将详细介绍**线程调度**，看看调度器是如何选择下一个运行的线程的。
