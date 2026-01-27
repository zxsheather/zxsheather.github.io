# Pintos 内核启动（十二）：线程系统初始化

## 概述

本文档详细解析 Pintos 内核的线程系统初始化过程，包括 `thread_init()` 和 `thread_start()` 两个关键函数。线程是操作系统调度的基本单位，线程系统的正确初始化是内核正常运行的基础。

Pintos 的线程系统具有以下特点：
1. **每个线程占用一个页**：线程结构体位于页底部，栈从页顶向下增长
2. **简单的调度器**：默认使用轮转调度（Round-Robin）
3. **主线程转换**：将当前执行流转换为正式的线程

## 原始代码

### thread.c 中的 thread_init() 函数

```c
/** Initializes the threading system by transforming the code
   that's currently running into a thread.  This can't work in
   general and it is possible in this case only because loader.S
   was careful to put the bottom of the stack at a page boundary.

   Also initializes the run queue and the tid lock.

   After calling this function, be sure to initialize the page
   allocator before trying to create any threads with
   thread_create().

   It is not safe to call thread_current() until this function
   finishes. */
void
thread_init (void) 
{
  ASSERT (intr_get_level () == INTR_OFF);

  lock_init (&tid_lock);
  list_init (&ready_list);
  list_init (&all_list);

  /* Set up a thread structure for the running thread. */
  initial_thread = running_thread ();
  init_thread (initial_thread, "main", PRI_DEFAULT);
  initial_thread->status = THREAD_RUNNING;
  initial_thread->tid = allocate_tid ();
}
```

### thread.c 中的 thread_start() 函数

```c
/** Starts preemptive thread scheduling by enabling interrupts.
   Also creates the idle thread. */
void
thread_start (void) 
{
  /* Create the idle thread. */
  struct semaphore idle_started;
  sema_init (&idle_started, 0);
  thread_create ("idle", PRI_MIN, idle, &idle_started);

  /* Start preemptive thread scheduling. */
  intr_enable ();

  /* Wait for the idle thread to initialize idle_thread. */
  sema_down (&idle_started);
}
```

### thread.h 中的 struct thread 定义

```c
struct thread
  {
    /* Owned by thread.c. */
    tid_t tid;                          /* Thread identifier. */
    enum thread_status status;          /* Thread state. */
    char name[16];                      /* Name (for debugging purposes). */
    uint8_t *stack;                     /* Saved stack pointer. */
    int priority;                       /* Priority. */
    struct list_elem allelem;           /* List element for all threads list. */

    /* Shared between thread.c and synch.c. */
    struct list_elem elem;              /* List element. */

#ifdef USERPROG
    /* Owned by userprog/process.c. */
    uint32_t *pagedir;                  /* Page directory. */
#endif

    /* Owned by thread.c. */
    unsigned magic;                     /* Detects stack overflow. */
  };
```

## 前置知识

### 1. 线程内存布局

Pintos 中每个线程占用一个完整的 4KB 页：

```
        4 kB +---------------------------------+
             |          kernel stack           |
             |                |                |
             |                |                |
             |                V                |
             |         grows downward          |
             |                                 |
             |                                 |
             |                                 |
             |                                 |
             |                                 |
             |                                 |
             |                                 |
             |                                 |
             +---------------------------------+
             |              magic              |
             |                :                |
             |                :                |
             |               name              |
             |              status             |
        0 kB +---------------------------------+
```

这种设计的优点：
1. **快速定位线程结构**：将栈指针向下取整到页边界即可找到线程结构
2. **栈溢出检测**：通过检查 magic 成员是否被覆写
3. **简化内存管理**：分配/释放线程只需操作一个页

### 2. 线程状态

```c
enum thread_status
  {
    THREAD_RUNNING,     /* Running thread. */
    THREAD_READY,       /* Not running but ready to run. */
    THREAD_BLOCKED,     /* Waiting for an event to trigger. */
    THREAD_DYING        /* About to be destroyed. */
  };
```

状态转换图：

```
                          创建
                           │
                           ↓
                    ┌─────────────┐
                    │  BLOCKED    │◄──────────────┐
                    └─────────────┘               │
                           │                      │
                           │ unblock              │ block (等待事件)
                           ↓                      │
    ┌─────────────┐  调度  ┌─────────────┐       │
    │  RUNNING    │◄──────│   READY     │       │
    └─────────────┘       └─────────────┘       │
           │                     ↑               │
           │                     │               │
           │     yield/抢占      │               │
           └─────────────────────┘               │
           │                                     │
           │ exit                                │
           ↓                                     │
    ┌─────────────┐                              │
    │   DYING     │                              │
    └─────────────┘                              │
```

### 3. 线程优先级

```c
#define PRI_MIN 0       /* Lowest priority. */
#define PRI_DEFAULT 31  /* Default priority. */
#define PRI_MAX 63      /* Highest priority. */
```

- 优先级范围：0-63（64 个级别）
- 数值越大优先级越高
- 默认优先级为 31

### 4. 关键数据结构

```c
/* 就绪队列：等待运行的线程 */
static struct list ready_list;

/* 所有线程列表 */
static struct list all_list;

/* 空闲线程 */
static struct thread *idle_thread;

/* 主线程（运行 init.c:main() 的线程）*/
static struct thread *initial_thread;

/* TID 分配锁 */
static struct lock tid_lock;
```

## 逐行代码解析

### thread_init() 函数解析

#### 第1行：检查中断状态

```c
ASSERT (intr_get_level () == INTR_OFF);
```

**详细解析**：

1. **为什么需要关中断**？
   - 初始化过程中修改共享数据结构
   - 需要防止中断处理程序访问未初始化的数据
   - 确保初始化的原子性

2. **此时中断为什么是关闭的**？
   - 从系统启动开始中断就是关闭的
   - `intr_enable()` 在 `thread_start()` 中才会被调用

#### 第2-4行：初始化全局数据结构

```c
lock_init (&tid_lock);
list_init (&ready_list);
list_init (&all_list);
```

**详细解析**：

1. **tid_lock 初始化**：
   - 用于保护线程 ID 的分配
   - 确保每个线程获得唯一的 TID

2. **ready_list 初始化**：
   - 就绪队列，存放等待运行的线程
   - 使用双向链表实现

3. **all_list 初始化**：
   - 所有线程的列表
   - 用于调试和遍历所有线程

**链表初始状态**：

```
ready_list (空)
┌──────────┐
│   head   │◄──┐
├──────────┤   │
│   tail   │───┘
└──────────┘

all_list (空)
┌──────────┐
│   head   │◄──┐
├──────────┤   │
│   tail   │───┘
└──────────┘
```

#### 第5行：获取当前线程结构体

```c
initial_thread = running_thread ();
```

**详细解析**：

`running_thread()` 函数的实现：

```c
struct thread *
running_thread (void) 
{
  uint32_t *esp;

  /* Copy the CPU's stack pointer into `esp', and then round that
     down to the start of a page.  Because `struct thread' is
     always at the beginning of a page and the stack pointer is
     somewhere in the middle, this locates the current thread. */
  asm ("mov %%esp, %0" : "=g" (esp));
  return pg_round_down (esp);
}
```

**工作原理**：

```
当前内存布局：

                                ESP 在这里 ↓
┌───────────────────────────────────────────┐ 页顶 (页基址 + 4KB)
│                栈内容                      │
│            (函数调用等)                    │
├───────────────────────────────────────────┤ ESP 指向的位置
│                                           │
│             未使用的栈空间                 │
│                                           │
├───────────────────────────────────────────┤
│                                           │
│          struct thread (未初始化)         │
│                                           │
└───────────────────────────────────────────┘ 页底 (页基址)

pg_round_down(ESP) = 页底地址 = struct thread 地址
```

**为什么这能工作**？

- `loader.S` 精心设置了初始栈位置，使其底部对齐到页边界
- 初始栈在内核 BSS 段的末尾
- 这个页在 `thread_init` 之前就已经被当作"主线程"的页使用

#### 第6行：初始化线程结构体

```c
init_thread (initial_thread, "main", PRI_DEFAULT);
```

**详细解析**：

`init_thread()` 函数的实现：

```c
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

**逐步解析**：

1. **memset 清零**：将整个结构体清零
2. **status = THREAD_BLOCKED**：初始状态为阻塞（稍后会改为 RUNNING）
3. **strlcpy name**：复制线程名称（最多 15 字符 + '\0'）
4. **stack = t + PGSIZE**：栈指针初始化到页顶
5. **priority**：设置优先级
6. **magic = THREAD_MAGIC**：设置魔数（用于检测栈溢出）
7. **加入 all_list**：将线程添加到所有线程列表

**初始化后的布局**：

```
4 KB  ┌───────────────────────────────┐ t->stack 指向这里
      │                               │
      │        (栈空间)               │
      │                               │
      ├───────────────────────────────┤
      │   magic = 0xcd6abf4b          │ 栈溢出检测
      ├───────────────────────────────┤
      │   priority = 31               │
      ├───────────────────────────────┤
      │   stack (指向页顶)            │
      ├───────────────────────────────┤
      │   name = "main\0..."          │
      ├───────────────────────────────┤
      │   status = THREAD_BLOCKED     │
      ├───────────────────────────────┤
      │   tid = 0 (未分配)            │
0 KB  └───────────────────────────────┘ initial_thread 指向这里
```

#### 第7-8行：设置运行状态和分配 TID

```c
initial_thread->status = THREAD_RUNNING;
initial_thread->tid = allocate_tid ();
```

**详细解析**：

1. **状态改为 RUNNING**：
   - 主线程当前正在运行
   - 覆盖 init_thread 设置的 BLOCKED 状态

2. **分配 TID**：
   - `allocate_tid()` 返回下一个可用的线程 ID
   - 主线程的 TID 为 1

**allocate_tid() 实现**：

```c
static tid_t
allocate_tid (void) 
{
  static tid_t next_tid = 1;
  tid_t tid;

  lock_acquire (&tid_lock);
  tid = next_tid++;
  lock_release (&tid_lock);

  return tid;
}
```

**注意**：虽然此时还没有其他线程，但使用锁是好习惯，确保代码的正确性。

### thread_start() 函数解析

#### 第1-3行：创建空闲线程同步信号量

```c
struct semaphore idle_started;
sema_init (&idle_started, 0);
thread_create ("idle", PRI_MIN, idle, &idle_started);
```

**详细解析**：

1. **信号量目的**：
   - 等待空闲线程完成初始化
   - 确保 `idle_thread` 变量被正确设置

2. **thread_create 参数**：
   - `"idle"`：线程名称
   - `PRI_MIN`：最低优先级（0）
   - `idle`：线程函数
   - `&idle_started`：传递给 idle 函数的参数

**为什么需要空闲线程**？

- 当没有其他线程就绪时，CPU 需要运行某些东西
- 空闲线程执行 `hlt` 指令，使 CPU 进入低功耗状态
- 这比忙等待更节能

#### 第4行：启用中断

```c
intr_enable ();
```

**详细解析**：

- 从这一刻起，定时器中断开始触发
- 抢占式调度正式开始
- 空闲线程可能在这之后被调度运行

#### 第5行：等待空闲线程初始化

```c
sema_down (&idle_started);
```

**详细解析**：

这里可能发生以下情况：

**场景1：空闲线程先运行**
```
主线程                     空闲线程
   │                          │
   │ create idle              │
   │────────────────────────→│
   │                          │
   │ enable interrupts        │
   │                          │
   │                    ┌─────┤ 被调度
   │                    │     │
   │                    │  idle_thread = self
   │                    │     │
   │                    │  sema_up()
   │◄───────────────────┘     │
   │                          │
   │ sema_down() (直接成功)   │
   │                          │
```

**场景2：主线程继续运行**
```
主线程                     空闲线程
   │                          │
   │ create idle              │
   │                          │ (在 ready_list 中)
   │ enable interrupts        │
   │                          │
   │ sema_down()              │
   │     (阻塞，信号量=0)     │
   │                    ┌─────┤ 被调度
   │                    │     │
   │                    │  idle_thread = self
   │                    │     │
   │                    │  sema_up()
   │◄───────────────────┘     │
   │ (唤醒)                   │
   │                          │
```

### idle() 函数解析

```c
static void
idle (void *idle_started_ UNUSED) 
{
  struct semaphore *idle_started = idle_started_;
  idle_thread = thread_current ();
  sema_up (idle_started);

  for (;;) 
    {
      /* Let someone else run. */
      intr_disable ();
      thread_block ();

      /* Re-enable interrupts and wait for the next one.
         The `sti' instruction disables interrupts until the
         completion of the next instruction, so these two
         instructions are executed atomically.  This atomicity is
         important; otherwise, an interrupt could be handled
         between re-enabling interrupts and waiting for the next
         one to occur, wasting as much as one clock tick worth of
         time. */
      asm volatile ("sti; hlt" : : : "memory");
    }
}
```

**详细解析**：

1. **设置 idle_thread**：
   - 保存自己的线程指针到全局变量
   - 供调度器在就绪队列为空时使用

2. **通知主线程**：
   - `sema_up()` 释放信号量
   - 允许主线程继续执行

3. **无限循环**：
   ```c
   for (;;) {
     intr_disable ();   // 关中断
     thread_block ();   // 阻塞自己，调度其他线程
     
     // 被唤醒后执行
     asm volatile ("sti; hlt" : : : "memory");
   }
   ```

4. **sti; hlt 原子性**：
   - `sti`：开中断
   - `hlt`：停止 CPU 直到下一个中断
   - x86 保证 `sti` 后的第一条指令不会被中断
   - 这确保了 `hlt` 能够被执行

**为什么需要这种原子性**？

```
如果不是原子的：

时刻 T:   sti          (开中断)
时刻 T+1: [中断到来]   (处理中断，可能唤醒某个线程)
时刻 T+2: hlt          (进入睡眠，但应该运行被唤醒的线程！)

结果：浪费了处理器时间
```

### thread_create() 函数详解

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

**栈帧布局**：

新线程创建后，其栈的布局如下：

```
4 KB  ┌───────────────────────────────┐
      │                               │
      │        (未使用的栈空间)        │
      │                               │
      ├───────────────────────────────┤
      │   kernel_thread_frame         │
      │  ┌─────────────────────────┐  │
      │  │ eip = NULL (返回地址)   │  │
      │  │ function (线程函数)     │  │
      │  │ aux (辅助参数)          │  │
      │  └─────────────────────────┘  │
      ├───────────────────────────────┤
      │   switch_entry_frame          │
      │  ┌─────────────────────────┐  │
      │  │ eip = kernel_thread     │  │
      │  └─────────────────────────┘  │
      ├───────────────────────────────┤
      │   switch_threads_frame        │
      │  ┌─────────────────────────┐  │
      │  │ eip = switch_entry      │  │ ← t->stack
      │  │ ebp = 0                 │  │
      │  │ ebx, esi, edi = 0       │  │
      │  └─────────────────────────┘  │
      ├───────────────────────────────┤
      │   struct thread               │
      │   (tid, name, priority, ...)  │
0 KB  └───────────────────────────────┘
```

**首次调度时的执行流**：

```
1. switch_threads() 恢复 sf 中的寄存器
   └→ ret 执行，跳转到 switch_entry

2. switch_entry (in switch.S)
   └→ ret 执行，跳转到 kernel_thread

3. kernel_thread()
   intr_enable();        // 开中断
   function(aux);        // 执行用户提供的函数
   thread_exit();        // 线程结束
```

## 调度器核心函数

### schedule() 函数

```c
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

**调度流程**：

```
schedule()
    │
    ├─→ cur = 当前线程
    │
    ├─→ next = next_thread_to_run()
    │         │
    │         ├─→ ready_list 非空? 取出第一个线程
    │         │
    │         └─→ ready_list 为空? 返回 idle_thread
    │
    ├─→ cur == next? ─→ 是 ─→ 跳过切换
    │         │
    │         └─→ 否 ─→ switch_threads(cur, next)
    │                     │
    │                     └─→ 保存 cur 的寄存器
    │                         恢复 next 的寄存器
    │                         返回 prev (= cur)
    │
    └─→ thread_schedule_tail(prev)
              │
              ├─→ 标记新线程为 RUNNING
              │
              ├─→ 重置时间片计数器
              │
              └─→ 如果 prev 正在死亡，释放其内存
```

### switch_threads() 函数 (switch.S)

```assembly
.globl switch_threads
.func switch_threads
switch_threads:
    # Save caller's register state.
    pushl %ebx
    pushl %ebp
    pushl %esi
    pushl %edi

    # Get offsetof (struct thread, stack).
    mov thread_stack_ofs, %edx

    # Save current stack pointer to old thread's stack.
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
```

**线程切换图示**：

```
切换前：                                  切换后：

线程 A (cur)                             线程 B (next)
┌─────────────┐                          ┌─────────────┐
│   栈顶      │                          │   栈顶      │
│     │       │                          │     │       │
│     ↓       │                          │     ↓       │
│             │                          │             │
│ [保存的寄存器]│◄── A->stack            │ [保存的寄存器]│◄── B->stack
└─────────────┘                          └─────────────┘
      ↑                                        │
      │                                        │
    ESP                                      ESP
      
                    switch_threads()
            ──────────────────────────────→
            保存 A 的 ESP 到 A->stack
            从 B->stack 恢复 ESP
```

## 线程生命周期

### 完整生命周期示例

```
1. 创建阶段
   thread_create("worker", PRI_DEFAULT, worker_func, arg)
   │
   ├─→ 分配一页内存
   ├─→ 初始化 thread 结构体
   ├─→ 设置栈帧
   └─→ thread_unblock() → 加入 ready_list
       状态: BLOCKED → READY

2. 首次运行
   schedule() 选中新线程
   │
   ├─→ switch_threads() 切换栈
   ├─→ switch_entry → kernel_thread
   └─→ function(aux) 开始执行
       状态: READY → RUNNING

3. 正常运行
   │
   ├─→ 可能 yield → READY → RUNNING
   ├─→ 可能 block → BLOCKED → READY → RUNNING
   └─→ 继续执行

4. 退出阶段
   thread_exit()
   │
   ├─→ 从 all_list 移除
   ├─→ 状态设为 DYING
   └─→ schedule() → 永不返回
       
5. 清理阶段
   thread_schedule_tail() (由下一个线程执行)
   │
   └─→ palloc_free_page(prev) 释放内存
```

## 魔数与栈溢出检测

### THREAD_MAGIC 的作用

```c
#define THREAD_MAGIC 0xcd6abf4b
```

**检测机制**：

```c
static bool
is_thread (struct thread *t)
{
  return t != NULL && t->magic == THREAD_MAGIC;
}

struct thread *
thread_current (void) 
{
  struct thread *t = running_thread ();
  
  /* Make sure T is really a thread.
     If either of these assertions fire, then your thread may
     have overflowed its stack. */
  ASSERT (is_thread (t));
  ASSERT (t->status == THREAD_RUNNING);

  return t;
}
```

**栈溢出示意**：

```
正常情况：
┌───────────────────────────────┐ 4KB
│           栈使用区             │
│             ↓                 │
├───────────────────────────────┤
│           空闲区               │
├───────────────────────────────┤
│  magic = 0xcd6abf4b ✓         │
│  ... 其他成员 ...             │
└───────────────────────────────┘ 0

栈溢出后：
┌───────────────────────────────┐ 4KB
│           栈使用区             │
│             ↓                 │
│             ↓                 │
│             ↓                 │
├───────────────────────────────┤
│  magic = ???????? ✗ (被覆盖)   │
│  ... 被破坏的数据 ...          │
└───────────────────────────────┘ 0
```

## 常见问题解答

### Q1: 为什么主线程可以被"转换"而不是"创建"？

**A**: 
1. 系统启动时已经有代码在执行
2. 这个执行流需要被纳入线程管理
3. `loader.S` 确保了栈底对齐到页边界
4. 只需填充 thread 结构体即可

### Q2: 为什么空闲线程优先级最低？

**A**: 
1. 空闲线程只在没有其他工作时运行
2. 最低优先级确保它不会抢占任何实际工作
3. 它的唯一目的是节省电力和等待中断

### Q3: thread_create 中的多个栈帧有什么作用？

**A**: 模拟线程之前被调度过的状态：
1. `switch_threads_frame`：模拟 `switch_threads` 调用点
2. `switch_entry_frame`：模拟返回到 `kernel_thread` 的入口
3. `kernel_thread_frame`：提供实际线程函数的参数

### Q4: 为什么要等待空闲线程初始化？

**A**: 
1. 调度器需要 `idle_thread` 指针
2. 当 `ready_list` 为空时返回 `idle_thread`
3. 如果不等待，可能返回 NULL 导致崩溃

## 练习题

### 练习1：分析栈使用

给定以下递归函数，计算需要多少栈空间：

```c
int factorial(int n) {
    if (n <= 1) return 1;
    return n * factorial(n - 1);
}
```

假设每次函数调用使用 32 字节栈空间，Pintos 线程最多能计算多大的阶乘？

### 练习2：线程状态追踪

画出以下场景中两个线程的状态转换：
1. 主线程创建线程 A
2. 线程 A 运行并调用 `sema_down()` 阻塞
3. 主线程调用 `sema_up()` 唤醒线程 A
4. 线程 A 运行完毕退出

### 练习3：修改时间片

`TIME_SLICE` 定义为 4 个时钟周期。如果改为：
1. `TIME_SLICE = 1`：会有什么影响？
2. `TIME_SLICE = 100`：会有什么影响？

### 练习4：实现线程统计

添加一个函数 `thread_count()` 返回当前存活的线程数。

**提示**：使用 `all_list` 链表。

## 下一篇预告

在下一篇文档中，我们将详细解析中断系统的初始化 `intr_init()`，了解 Pintos 如何设置 IDT（中断描述符表）和处理各种中断。

## 参考资料

1. [Intel 64 and IA-32 Architectures Software Developer's Manual](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)
2. [Pintos Documentation - Threads](https://web.stanford.edu/class/cs140/projects/pintos/pintos_2.html)
3. [OSDev Wiki - Context Switching](https://wiki.osdev.org/Context_Switching)
