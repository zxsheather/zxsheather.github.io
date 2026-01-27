# Pintos 内核启动（十五）：启动完成与任务执行

## 概述

本文档是 Pintos 内核启动系列的最后一篇，详细解析内核启动完成后的任务执行过程。在完成所有初始化工作后，内核需要：

1. 打印启动完成信息
2. 解析并执行命令行指定的操作
3. 正确关闭或重启系统

这一阶段标志着 Pintos 从**初始化状态**过渡到**正常运行状态**。

## 原始代码

### pintos_init() 的最后部分

```c
printf ("Boot complete.\n");

if (*argv != NULL) {
  /* Run actions specified on kernel command line. */
  run_actions (argv);
} else {
  // TODO: no command line passed to kernel. Run interactively 
}

/* Finish up. */
shutdown ();
thread_exit ();
```

### run_actions() 函数

```c
/** Executes all of the actions specified in ARGV[]
   up to the null pointer sentinel. */
static void
run_actions (char **argv) 
{
  /* An action. */
  struct action 
    {
      char *name;                       /* Action name. */
      int argc;                         /* # of args, including action name. */
      void (*function) (char **argv);   /* Function to execute action. */
    };

  /* Table of supported actions. */
  static const struct action actions[] = 
    {
      {"run", 2, run_task},
#ifdef FILESYS
      {"ls", 1, fsutil_ls},
      {"cat", 2, fsutil_cat},
      {"rm", 2, fsutil_rm},
      {"extract", 1, fsutil_extract},
      {"append", 2, fsutil_append},
#endif
      {NULL, 0, NULL},
    };

  while (*argv != NULL)
    {
      const struct action *a;
      int i;

      /* Find action name. */
      for (a = actions; ; a++)
        if (a->name == NULL)
          PANIC ("unknown action `%s' (use -h for help)", *argv);
        else if (!strcmp (*argv, a->name))
          break;

      /* Check for required arguments. */
      for (i = 1; i < a->argc; i++)
        if (argv[i] == NULL)
          PANIC ("action `%s' requires %d argument(s)", *argv, a->argc - 1);

      /* Invoke action and advance. */
      a->function (argv);
      argv += a->argc;
    }
}
```

### run_task() 函数

```c
/** Runs the task specified in ARGV[1]. */
static void
run_task (char **argv)
{
  const char *task = argv[1];
  
  printf ("Executing '%s':\n", task);
#ifdef USERPROG
  process_wait (process_execute (task));
#else
  run_test (task);
#endif
  printf ("Execution of '%s' complete.\n", task);
}
```

## 启动完成标志

### "Boot complete." 的意义

当内核打印 "Boot complete." 时，表示以下所有初始化已完成：

```
┌─────────────────────────────────────────────────────────────┐
│                      启动完成检查清单                         │
├─────────────────────────────────────────────────────────────┤
│ ✓ BSS 段已清零                                               │
│ ✓ 命令行已解析                                               │
│ ✓ 线程系统已初始化                                           │
│ ✓ 控制台已初始化                                             │
│ ✓ 内存系统已初始化（palloc + malloc）                        │
│ ✓ 永久页表已建立                                             │
│ ✓ 中断系统已初始化                                           │
│ ✓ 设备已初始化（定时器、键盘、串口）                          │
│ ✓ 抢占式调度已启动                                           │
│ ✓ 定时器已校准                                               │
│ ✓ 文件系统已初始化（如果启用）                               │
└─────────────────────────────────────────────────────────────┘
```

### 启动输出示例

```
Pintos booting with 4,096 kB RAM...
383 pages available in kernel pool.
383 pages available in user pool.
Calibrating timer...  1,234,567 loops/s.
Boot complete.
```

## 命令行动作系统

### 动作表结构

```c
struct action 
{
  char *name;                       /* 动作名称 */
  int argc;                         /* 参数数量（包括动作名） */
  void (*function) (char **argv);   /* 执行函数 */
};

static const struct action actions[] = 
{
  {"run", 2, run_task},     /* 运行测试或程序 */
#ifdef FILESYS
  {"ls", 1, fsutil_ls},     /* 列出文件 */
  {"cat", 2, fsutil_cat},   /* 显示文件内容 */
  {"rm", 2, fsutil_rm},     /* 删除文件 */
  {"extract", 1, fsutil_extract},  /* 解压 tar */
  {"append", 2, fsutil_append},    /* 追加到 tar */
#endif
  {NULL, 0, NULL},          /* 哨兵 */
};
```

### 动作执行流程

```
run_actions(argv)
    │
    │  argv = ["run", "alarm-multiple", NULL]
    │
    ↓
┌─────────────────────────────────────────────────────────────┐
│ while (*argv != NULL)                                       │
│     │                                                       │
│     ├─→ 查找动作名                                          │
│     │   for (a = actions; ...; a++)                        │
│     │       if (!strcmp(*argv, a->name)) break;            │
│     │                                                       │
│     │   找到: a = {"run", 2, run_task}                     │
│     │                                                       │
│     ├─→ 检查参数数量                                        │
│     │   argc = 2, 需要 1 个额外参数                         │
│     │   argv[1] = "alarm-multiple" ✓                       │
│     │                                                       │
│     ├─→ 执行动作                                            │
│     │   a->function(argv)                                   │
│     │   → run_task(["run", "alarm-multiple"])              │
│     │                                                       │
│     └─→ 前进指针                                            │
│         argv += 2                                           │
│         → argv = [NULL]                                     │
│                                                             │
│ 循环结束，*argv == NULL                                     │
└─────────────────────────────────────────────────────────────┘
```

### 命令行示例

**运行测试**：
```bash
pintos -- run alarm-multiple
```
解析后的 argv：
```
["run", "alarm-multiple", NULL]
```

**运行用户程序**：
```bash
pintos -- run 'echo hello world'
```
解析后的 argv：
```
["run", "echo hello world", NULL]
```

**多个动作**：
```bash
pintos -- ls cat README run test
```
解析后的 argv：
```
["ls", "cat", "README", "run", "test", NULL]
```

执行顺序：
1. `ls`（无参数）
2. `cat README`
3. `run test`

## 测试运行（非用户程序模式）

### run_test() 函数

当 `USERPROG` 未定义时，`run_task` 调用 `run_test()`：

```c
/* tests/threads/tests.c */

static const struct test tests[] = 
{
  {"alarm-single", test_alarm_single},
  {"alarm-multiple", test_alarm_multiple},
  {"alarm-simultaneous", test_alarm_simultaneous},
  {"alarm-priority", test_alarm_priority},
  {"alarm-zero", test_alarm_zero},
  {"alarm-negative", test_alarm_negative},
  {"priority-change", test_priority_change},
  /* ... 更多测试 ... */
  {NULL, NULL},
};

void
run_test (const char *name) 
{
  const struct test *t;

  for (t = tests; t->name != NULL; t++)
    if (!strcmp (name, t->name))
      {
        t->function ();
        return;
      }
  PANIC ("no test named \"%s\"", name);
}
```

### 测试执行流程

```
run_task(["run", "alarm-multiple"])
    │
    ↓
run_test("alarm-multiple")
    │
    ├─→ 在测试表中查找
    │
    ├─→ 找到 test_alarm_multiple
    │
    └─→ 调用 test_alarm_multiple()
            │
            ├─→ 创建多个测试线程
            │
            ├─→ 每个线程调用 timer_sleep()
            │
            ├─→ 等待所有线程完成
            │
            └─→ 检查结果
```

## 用户程序执行（USERPROG 模式）

### process_execute() 流程

```c
/* userprog/process.c */

tid_t
process_execute (const char *file_name) 
{
  char *fn_copy;
  tid_t tid;

  /* Make a copy of FILE_NAME. */
  fn_copy = palloc_get_page (0);
  if (fn_copy == NULL)
    return TID_ERROR;
  strlcpy (fn_copy, file_name, PGSIZE);

  /* Create a new thread to execute FILE_NAME. */
  tid = thread_create (file_name, PRI_DEFAULT, start_process, fn_copy);
  if (tid == TID_ERROR)
    palloc_free_page (fn_copy); 
  return tid;
}
```

### 用户程序加载和执行

```
process_execute("echo hello world")
    │
    ├─→ 复制文件名到新页
    │
    ├─→ thread_create("echo", PRI_DEFAULT, start_process, fn_copy)
    │       │
    │       └─→ 创建新线程，入口为 start_process
    │
    └─→ 返回线程 ID

新线程执行:
start_process(fn_copy)
    │
    ├─→ 解析命令行（"echo hello world"）
    │
    ├─→ 加载可执行文件 "echo"
    │   │
    │   ├─→ 打开文件
    │   ├─→ 验证 ELF 头
    │   ├─→ 加载程序段到内存
    │   └─→ 设置入口点
    │
    ├─→ 设置用户栈
    │   │
    │   ├─→ 压入参数字符串
    │   ├─→ 压入参数指针数组
    │   └─→ 压入 argc 和 argv
    │
    └─→ 跳转到用户空间执行
        │
        └─→ intr_exit() 返回到用户程序入口
```

### process_wait() 等待子进程

```c
int
process_wait (tid_t child_tid) 
{
  /* 等待子进程退出 */
  /* 返回子进程的退出状态 */
}
```

**主线程执行流**：

```
run_task()
    │
    ├─→ process_execute("echo hello world")
    │       │
    │       └─→ 返回子进程 tid
    │
    └─→ process_wait(tid)
            │
            ├─→ 阻塞等待子进程退出
            │
            └─→ 子进程退出后，返回退出状态
```

## 系统关闭

### shutdown() 函数

```c
/* devices/shutdown.c */

static enum shutdown_type how = SHUTDOWN_NONE;

void
shutdown (void)
{
  switch (how)
    {
    case SHUTDOWN_POWER_OFF:
      shutdown_power_off ();
      break;
      
    case SHUTDOWN_REBOOT:
      shutdown_reboot ();
      break;
      
    default:
      /* 默认不关机，只是退出 */
      break;
    }
}

void
shutdown_configure (enum shutdown_type new_how)
{
  how = new_how;
}
```

### 关机方式

**关机（Power Off）**：
```c
void
shutdown_power_off (void) 
{
  printf ("Powering off...\n");
  
  /* ACPI 关机 */
  outw (0xB004, 0x2000);  /* Bochs/QEMU */
  outw (0x604, 0x2000);   /* QEMU 新版本 */
  
  /* 如果上面不工作，尝试 APM */
  outb (0x8900, 'S');
  outb (0x8900, 'h');
  outb (0x8900, 'u');
  outb (0x8900, 't');
  outb (0x8900, 'd');
  outb (0x8900, 'o');
  outb (0x8900, 'w');
  outb (0x8900, 'n');
  
  /* 如果还不工作，死循环 */
  for (;;);
}
```

**重启（Reboot）**：
```c
void
shutdown_reboot (void)
{
  printf ("Rebooting...\n");
  
  /* 通过 8042 键盘控制器重启 */
  outb (0x64, 0xFE);
  
  /* 如果不工作，三重错误重启 */
  for (;;);
}
```

### 命令行关机选项

```bash
# 执行完任务后关机
pintos -q -- run alarm-multiple

# 执行完任务后重启
pintos -r -- run alarm-multiple
```

对应的命令行解析：

```c
else if (!strcmp (name, "-q"))
  shutdown_configure (SHUTDOWN_POWER_OFF);
else if (!strcmp (name, "-r"))
  shutdown_configure (SHUTDOWN_REBOOT);
```

## 主线程退出

### thread_exit() 分析

```c
void
thread_exit (void) 
{
  ASSERT (!intr_context ());

#ifdef USERPROG
  process_exit ();
#endif

  /* Remove thread from all threads list, set our status to dying,
     and schedule another process.  That process will destroy us
     when it calls thread_schedule_tail(). */
  intr_disable ();
  list_remove (&thread_current()->allelem);
  thread_current ()->status = THREAD_DYING;
  schedule ();
  NOT_REACHED ();
}
```

**退出流程**：

```
thread_exit()
    │
    ├─→ 关中断
    │
    ├─→ 从 all_list 移除当前线程
    │
    ├─→ 设置状态为 THREAD_DYING
    │
    └─→ schedule()
            │
            └─→ 切换到其他线程
                │
                └─→ 其他线程的 thread_schedule_tail()
                        │
                        └─→ 释放 DYING 线程的内存页
                        
NOT_REACHED()  // 永远不会执行到这里
```

### 为什么主线程要 thread_exit()？

1. **资源回收**：释放主线程占用的内存
2. **调度器运行**：让空闲线程或其他线程接管 CPU
3. **正确终止**：避免执行未定义的代码

## 完整启动到关机流程

```
┌─────────────────────────────────────────────────────────────────┐
│                        Pintos 生命周期                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 电源开启                                                     │
│     │                                                           │
│     ↓                                                           │
│  2. BIOS 执行                                                    │
│     │                                                           │
│     ↓                                                           │
│  3. Loader 加载内核                                              │
│     │                                                           │
│     ↓                                                           │
│  4. start.S 执行                                                 │
│     │                                                           │
│     ├─→ 实模式初始化                                            │
│     ├─→ 进入保护模式                                            │
│     └─→ 跳转到 pintos_init                                      │
│                                                                 │
│  5. pintos_init() 执行                                          │
│     │                                                           │
│     ├─→ 初始化各子系统                                          │
│     │   ├─→ BSS 清零                                            │
│     │   ├─→ 命令行解析                                          │
│     │   ├─→ 线程系统                                            │
│     │   ├─→ 内存系统                                            │
│     │   ├─→ 中断系统                                            │
│     │   └─→ 设备初始化                                          │
│     │                                                           │
│     ├─→ "Boot complete."                                        │
│     │                                                           │
│     ├─→ run_actions()                                           │
│     │   │                                                       │
│     │   └─→ 执行命令行指定的任务                                │
│     │       │                                                   │
│     │       ├─→ run (测试或用户程序)                           │
│     │       ├─→ ls, cat, rm (文件操作)                         │
│     │       └─→ ...                                             │
│     │                                                           │
│     ├─→ shutdown()                                              │
│     │   │                                                       │
│     │   ├─→ -q: 关机                                            │
│     │   └─→ -r: 重启                                            │
│     │                                                           │
│     └─→ thread_exit()                                           │
│                                                                 │
│  6. 空闲线程运行                                                 │
│     │                                                           │
│     └─→ hlt 等待中断（直到关机/重启）                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## 调试支持

### 帮助信息

```c
static void
usage (void)
{
  printf ("\nCommand line syntax: [OPTION...] [ACTION...]\n"
          "Options must precede actions.\n"
          "Actions are executed in the order specified.\n"
          "\nAvailable actions:\n"
#ifdef USERPROG
          "  run 'PROG [ARG...]' Run PROG and wait for it to complete.\n"
#else
          "  run TEST           Run TEST.\n"
#endif
#ifdef FILESYS
          "  ls                 List files in the root directory.\n"
          "  cat FILE           Print FILE to the console.\n"
          "  rm FILE            Delete FILE.\n"
          /* ... */
#endif
          "\nOptions:\n"
          "  -h                 Print this help message and power off.\n"
          "  -q                 Power off VM after actions or on panic.\n"
          /* ... */
          );
  shutdown_power_off ();
}
```

**使用 -h 查看帮助**：
```bash
pintos -- -h
```

### 调试输出

**Boot 过程的关键输出**：

```
Pintos booting with 4,096 kB RAM...       ← 内存检测
383 pages available in kernel pool.       ← 页分配器
383 pages available in user pool.
Calibrating timer...  1,234,567 loops/s.  ← 定时器校准
Boot complete.                            ← 启动完成
Executing 'alarm-multiple':               ← 开始执行任务
(alarm-multiple) ...                      ← 任务输出
Execution of 'alarm-multiple' complete.   ← 任务完成
Powering off...                           ← 关机
```

## 统计信息打印

### print_stats() 函数

```c
/* 在关机前打印各种统计信息 */
void
print_stats (void)
{
  timer_print_stats ();    /* 定时器统计 */
  thread_print_stats ();   /* 线程统计 */
  kbd_print_stats ();      /* 键盘统计 */
  console_print_stats ();  /* 控制台统计 */
}
```

**输出示例**：

```
Timer: 1234567 ticks
Thread: 1000 idle ticks, 234567 kernel ticks, 0 user ticks
Keyboard: 0 keys pressed
Console: 5678 characters output
```

## 常见问题解答

### Q1: 如果不传任何动作会怎样？

**A**: 
```c
if (*argv != NULL) {
  run_actions (argv);
} else {
  // TODO: no command line passed to kernel. Run interactively 
}
```
当前实现中，如果没有动作，内核会直接调用 `shutdown()` 和 `thread_exit()`，相当于什么都不做就关机。

### Q2: run_actions 可以执行多个动作吗？

**A**: 是的，动作按顺序执行：
```bash
pintos -- ls cat README run test
```
会依次执行：`ls` → `cat README` → `run test`

### Q3: 为什么 thread_exit() 后还有 NOT_REACHED()？

**A**: 
- `thread_exit()` 调用 `schedule()` 后永不返回
- `NOT_REACHED()` 是断言，如果执行到说明有 bug
- 它会触发 PANIC，帮助调试

### Q4: 关机失败会怎样？

**A**: 
- `shutdown_power_off()` 尝试多种关机方法
- 如果都失败，进入无限循环
- 在真实硬件上可能需要手动关电源
- 在模拟器中通常不会失败

## 练习题

### 练习1：添加新动作

添加一个 "hello" 动作，打印 "Hello, Pintos!"：

```c
static void
say_hello (char **argv UNUSED)
{
  printf ("Hello, Pintos!\n");
}
```

需要修改哪些代码？

### 练习2：交互模式

实现简单的交互模式，当没有命令行参数时：
1. 打印提示符
2. 从键盘读取命令
3. 执行命令
4. 重复

**提示**：使用 `input_getc()` 读取键盘输入。

### 练习3：启动时间测量

在 `pintos_init()` 中添加代码，测量并打印从启动到 "Boot complete." 的时间。

**提示**：使用 `timer_ticks()` 和 `TIMER_FREQ`。

### 练习4：分析启动瓶颈

修改内核，打印每个初始化阶段花费的时间：
```
BSS init: 1 ticks
Thread init: 5 ticks
Memory init: 10 ticks
...
Total boot time: 100 ticks
```

## 系列总结

恭喜你完成了 Pintos 内核启动系列的所有文档！让我们回顾一下整个启动流程：

### 启动阶段概览

| 文档 | 阶段 | 主要内容 |
|------|------|---------|
| 00 | 概述 | 系列介绍和整体架构 |
| 01-06 | start.S | 汇编启动代码 |
| 07-09 | pintos_init | C 初始化入口 |
| 10-11 | 内存 | 页分配器和页表 |
| 12 | 线程 | 线程系统初始化 |
| 13 | 中断 | 中断系统初始化 |
| 14 | 设备 | 硬件设备初始化 |
| 15 | 完成 | 任务执行和关机 |

### 关键概念

1. **实模式到保护模式**：x86 启动的根本转换
2. **页表和虚拟内存**：内存管理的基础
3. **线程和调度**：并发执行的基础
4. **中断处理**：响应硬件事件
5. **设备驱动**：与硬件交互

### 后续学习建议

1. **Project 1 (Threads)**：深入理解线程调度
2. **Project 2 (User Programs)**：理解用户/内核分离
3. **Project 3 (Virtual Memory)**：实现完整的虚拟内存
4. **Project 4 (File Systems)**：实现持久化存储

## 参考资料

1. [Pintos Documentation](https://web.stanford.edu/class/cs140/projects/pintos/pintos.html)
2. [Intel 64 and IA-32 Architectures Software Developer's Manual](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)
3. [OSDev Wiki](https://wiki.osdev.org/)
4. [xv6: A Simple, Unix-like Teaching Operating System](https://pdos.csail.mit.edu/6.828/2020/xv6.html)
