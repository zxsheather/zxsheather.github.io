# Pintos 内核启动（十一）：永久页表建立

## 概述

本文档详细解析 Pintos 内核的 `paging_init()` 函数，该函数负责建立永久的页表结构，替换 `start.S` 中创建的临时页表。这是内核初始化过程中至关重要的一步，它建立了内核运行所需的完整地址映射。

在 `start.S` 中，我们创建了一个简单的临时页表，只映射了前 64MB 的物理内存。现在，`paging_init()` 将创建一个完整的页表，映射所有检测到的物理内存，并正确设置页面保护属性。

## 原始代码

### init.c 中的 paging_init() 函数

```c
/** Populates the base page directory and page table with the
   kernel virtual mapping, and then sets up the CPU to use the
   new page directory.  Points init_page_dir to the page
   directory it creates. */
static void
paging_init (void)
{
  uint32_t *pd, *pt;
  size_t page;
  extern char _start, _end_kernel_text;

  pd = init_page_dir = palloc_get_page (PAL_ASSERT | PAL_ZERO);
  pt = NULL;
  for (page = 0; page < init_ram_pages; page++)
    {
      uintptr_t paddr = page * PGSIZE;
      char *vaddr = ptov (paddr);
      size_t pde_idx = pd_no (vaddr);
      size_t pte_idx = pt_no (vaddr);
      bool in_kernel_text = &_start <= vaddr && vaddr < &_end_kernel_text;

      if (pd[pde_idx] == 0)
        {
          pt = palloc_get_page (PAL_ASSERT | PAL_ZERO);
          pd[pde_idx] = pde_create (pt);
        }

      pt[pte_idx] = pte_create_kernel (vaddr, !in_kernel_text);
    }

  /* Store the physical address of the page directory into CR3
     aka PDBR (page directory base register).  This activates our
     new page tables immediately.  See [IA32-v2a] "MOV--Move
     to/from Control Registers" and [IA32-v3a] 3.7.5 "Base Address
     of the Page Directory". */
  asm volatile ("movl %0, %%cr3" : : "r" (vtop (init_page_dir)));
}
```

### pte.h 中的辅助函数和宏

```c
/** Virtual addresses are structured as follows:

    31                  22 21                  12 11                   0
   +----------------------+----------------------+----------------------+
   | Page Directory Index |   Page Table Index   |    Page Offset       |
   +----------------------+----------------------+----------------------+
*/

/** Page table index (bits 12:21). */
#define PTSHIFT PGBITS                     /* First page table bit. */
#define PTBITS  10                         /* Number of page table bits. */

/** Page directory index (bits 22:31). */
#define PDSHIFT (PTSHIFT + PTBITS)         /* First page directory bit. */
#define PDBITS  10                         /* Number of page dir bits. */

/** Obtains page table index from a virtual address. */
static inline unsigned pt_no (const void *va) {
  return ((uintptr_t) va & PTMASK) >> PTSHIFT;
}

/** Obtains page directory index from a virtual address. */
static inline uintptr_t pd_no (const void *va) {
  return (uintptr_t) va >> PDSHIFT;
}

/** Page entry flags. */
#define PTE_P 0x1               /* 1=present, 0=not present. */
#define PTE_W 0x2               /* 1=read/write, 0=read-only. */
#define PTE_U 0x4               /* 1=user/kernel, 0=kernel only. */

/** Returns a PDE that points to page table PT. */
static inline uint32_t pde_create (uint32_t *pt) {
  ASSERT (pg_ofs (pt) == 0);
  return vtop (pt) | PTE_U | PTE_P | PTE_W;
}

/** Returns a PTE that points to PAGE.
   The PTE's page is readable.
   If WRITABLE is true then it will be writable as well.
   The page will be usable only by ring 0 code (the kernel). */
static inline uint32_t pte_create_kernel (void *page, bool writable) {
  ASSERT (pg_ofs (page) == 0);
  return vtop (page) | PTE_P | (writable ? PTE_W : 0);
}
```

## 前置知识

### 1. x86 两级页表结构

x86 保护模式使用**两级页表**进行地址转换：

```
32位虚拟地址
┌──────────────┬──────────────┬──────────────┐
│  PD Index    │  PT Index    │   Offset     │
│  (10 bits)   │  (10 bits)   │  (12 bits)   │
└──────┬───────┴──────┬───────┴──────┬───────┘
       │              │              │
       │   ┌──────────┘              │
       │   │                         │
       ↓   │                         ↓
   ┌───────┴──────┐             ┌─────────┐
   │ Page Dir     │   ┌─────→ │ Physical│
   │ (1024项)     │   │        │  Page   │
   │ ┌─────────┐  │   │        │ (4KB)   │
CR3→│ PDE 0   │  │   │        └────┬────┘
   │ ├─────────┤  │   │             │
   │ │  ...    │  │   │             │
   │ ├─────────┤  │   │             ↓
   │ │PDE[idx] │──┼───┤        ┌─────────┐
   │ ├─────────┤  │   │        │ 物理地址 │
   │ │  ...    │  │   │        └─────────┘
   │ └─────────┘  │   │
   └──────────────┘   │
                      │
   ┌──────────────┐   │
   │ Page Table   │◄──┘
   │ (1024项)     │
   │ ┌─────────┐  │
   │ │ PTE 0   │  │
   │ ├─────────┤  │
   │ │  ...    │  │
   │ ├─────────┤  │
   │ │PTE[idx] │──────────────────→ 物理页帧
   │ ├─────────┤  │
   │ │  ...    │  │
   │ └─────────┘  │
   └──────────────┘
```

### 2. 页目录项（PDE）格式

```
31                                 12 11  9 8 7 6 5 4 3 2 1 0
+------------------------------------+-----+-+-+-+-+-+-+-+-+-+
|    Page Table Physical Address     | AVL |G|S|0|A|D|W|U|R|P|
+------------------------------------+-----+-+-+-+-+-+-+-+-+-+
                                           | | | | | | | | |
                                           | | | | | | | | +-- Present
                                           | | | | | | | +---- Read/Write
                                           | | | | | | +------ User/Supervisor
                                           | | | | | +-------- Write-Through
                                           | | | | +---------- Cache Disable
                                           | | | +------------ Accessed
                                           | | +-------------- (reserved)
                                           | +---------------- Page Size (0=4KB)
                                           +------------------ Global
```

### 3. 页表项（PTE）格式

```
31                                 12 11  9 8 7 6 5 4 3 2 1 0
+------------------------------------+-----+-+-+-+-+-+-+-+-+-+
|      Physical Page Address         | AVL |G|0|D|A|C|W|U|R|P|
+------------------------------------+-----+-+-+-+-+-+-+-+-+-+
                                           | | | | | | | | |
                                           | | | | | | | | +-- Present
                                           | | | | | | | +---- Read/Write
                                           | | | | | | +------ User/Supervisor
                                           | | | | | +-------- Write-Through
                                           | | | | +---------- Cache Disable
                                           | | | +------------ Accessed
                                           | | +-------------- Dirty
                                           | +---------------- (reserved)
                                           +------------------ Global
```

### 4. 临时页表 vs 永久页表

| 特性 | 临时页表 (start.S) | 永久页表 (paging_init) |
|------|-------------------|----------------------|
| 创建时机 | 进入保护模式前 | 内存系统初始化后 |
| 覆盖范围 | 固定 64MB | 所有检测到的物理内存 |
| 位置 | BSS 段静态分配 | 动态从内存池分配 |
| 代码保护 | 无 | 内核代码段只读 |
| 用途 | 启动过渡 | 长期运行 |

### 5. 链接器符号

链接器脚本（linker script）定义了一些特殊符号：
- `_start`：内核代码段起始地址
- `_end_kernel_text`：内核代码段结束地址

这些符号用于区分代码段和数据段，以便正确设置页面保护。

## 逐行代码解析

### 第1-3行：变量声明和外部符号

```c
uint32_t *pd, *pt;
size_t page;
extern char _start, _end_kernel_text;
```

**详细解析**：

1. **pd（Page Directory）**：
   - 类型：`uint32_t *`（指向32位整数的指针）
   - 用途：指向页目录
   - 页目录包含 1024 个 PDE（页目录项）

2. **pt（Page Table）**：
   - 类型：`uint32_t *`
   - 用途：指向当前正在填充的页表
   - 每个页表包含 1024 个 PTE（页表项）

3. **page**：
   - 循环变量，遍历所有物理页

4. **外部符号**：
   - `_start`：内核代码起始位置
   - `_end_kernel_text`：内核代码结束位置
   - 这些符号由链接器自动生成

### 第4行：分配页目录

```c
pd = init_page_dir = palloc_get_page (PAL_ASSERT | PAL_ZERO);
```

**详细解析**：

1. **palloc_get_page 调用**：
   - `PAL_ASSERT`：分配失败时触发 PANIC
   - `PAL_ZERO`：将页清零（所有 PDE 初始化为 0，即"不存在"）

2. **双重赋值**：
   - `pd`：局部变量，方便后续访问
   - `init_page_dir`：全局变量，供其他模块使用

3. **为什么需要清零**？
   - PDE 值为 0 表示页表项"不存在"
   - CPU 访问不存在的页会触发 Page Fault
   - 确保未映射的地址不会被意外访问

**页目录初始状态**：

```
页目录 (4KB)
┌───────────────┐ pd[0]
│      0        │ (不存在)
├───────────────┤ pd[1]
│      0        │ (不存在)
├───────────────┤
│     ...       │
├───────────────┤ pd[1023]
│      0        │ (不存在)
└───────────────┘
```

### 第5行：初始化页表指针

```c
pt = NULL;
```

**详细解析**：

- 初始化为 NULL，表示还没有分配任何页表
- 后续循环中会按需分配页表

### 第6-7行：遍历所有物理页

```c
for (page = 0; page < init_ram_pages; page++)
{
  uintptr_t paddr = page * PGSIZE;
```

**详细解析**：

1. **循环范围**：
   - 从物理页 0 开始
   - 到 `init_ram_pages - 1` 结束
   - 覆盖所有检测到的物理内存

2. **物理地址计算**：
   - `paddr = page * 4096`
   - 每次循环处理一个 4KB 物理页

**示例**：假设有 4MB 物理内存（1024 页）
- page = 0: paddr = 0x00000000
- page = 1: paddr = 0x00001000
- page = 255: paddr = 0x000FF000
- page = 256: paddr = 0x00100000 (1MB)
- ...

### 第8行：计算虚拟地址

```c
char *vaddr = ptov (paddr);
```

**详细解析**：

- `ptov(paddr) = paddr + PHYS_BASE = paddr + 0xC0000000`
- 建立物理地址到虚拟地址的映射

**映射示例**：

| 物理地址 | 虚拟地址 |
|---------|---------|
| 0x00000000 | 0xC0000000 |
| 0x00001000 | 0xC0001000 |
| 0x00100000 | 0xC0100000 |
| 0x003FF000 | 0xC03FF000 |

### 第9-10行：提取页表索引

```c
size_t pde_idx = pd_no (vaddr);
size_t pte_idx = pt_no (vaddr);
```

**详细解析**：

1. **pd_no (vaddr)**：
   - 提取虚拟地址的高 10 位（bits 22-31）
   - 范围：0 - 1023
   - 用于索引页目录

2. **pt_no (vaddr)**：
   - 提取虚拟地址的中间 10 位（bits 12-21）
   - 范围：0 - 1023
   - 用于索引页表

**地址分解示例**：

```
虚拟地址 0xC0001000 (对应物理地址 0x00001000)

二进制: 1100 0000 0000 0000 0001 0000 0000 0000
        ├────────┬─┤├────────┬─┤├────────┬───┤
         PD Index    PT Index     Offset
           768          1           0

pde_idx = 768 (0x300)
pte_idx = 1
offset  = 0
```

### 第11行：判断是否为内核代码段

```c
bool in_kernel_text = &_start <= vaddr && vaddr < &_end_kernel_text;
```

**详细解析**：

1. **判断条件**：
   - 检查当前虚拟地址是否在内核代码段范围内
   - `_start`：内核代码起始
   - `_end_kernel_text`：内核代码结束

2. **为什么需要区分**？
   - 代码段应该是**只读**的（不应被修改）
   - 数据段需要是**可写**的
   - 这是基本的内存保护机制

**内核内存布局**：

```
┌─────────────────────┐ _start (约 0xC0020000)
│                     │
│    .text 段         │ ← 代码段（只读）
│    (内核代码)        │
│                     │
├─────────────────────┤ _end_kernel_text
│                     │
│    .rodata 段       │ ← 只读数据
│                     │
├─────────────────────┤
│                     │
│    .data 段         │ ← 已初始化数据（可写）
│                     │
├─────────────────────┤
│                     │
│    .bss 段          │ ← 未初始化数据（可写）
│                     │
└─────────────────────┘
```

### 第12-16行：按需分配页表

```c
if (pd[pde_idx] == 0)
{
  pt = palloc_get_page (PAL_ASSERT | PAL_ZERO);
  pd[pde_idx] = pde_create (pt);
}
```

**详细解析**：

1. **检查条件**：
   - `pd[pde_idx] == 0` 表示该页目录项尚未指向任何页表
   - 需要分配一个新的页表

2. **分配页表**：
   - `palloc_get_page(PAL_ASSERT | PAL_ZERO)`
   - 获取一个清零的页作为页表
   - 一个页表可以容纳 1024 个 PTE

3. **创建 PDE**：
   - `pde_create(pt)` 构造页目录项
   - 设置标志位：PTE_U | PTE_P | PTE_W

**pde_create 函数分析**：

```c
static inline uint32_t pde_create (uint32_t *pt) {
  ASSERT (pg_ofs (pt) == 0);        // 确保页表页对齐
  return vtop (pt) | PTE_U | PTE_P | PTE_W;
}
```

- `vtop(pt)`：将页表的虚拟地址转换为物理地址
- `PTE_P`：Present 位，表示页表存在
- `PTE_W`：Writable 位，允许写入
- `PTE_U`：User 位，允许用户态访问（这里设置是为了支持用户程序）

**PDE 格式**：

```
31                                    12 11        0
+---------------------------------------+----------+
|     Page Table Physical Address       |   Flags  |
+---------------------------------------+----------+
                                        PTE_U = 0x4
                                        PTE_W = 0x2
                                        PTE_P = 0x1
                                        
结果: PDE = (pt 物理地址) | 0x7
```

### 第17行：创建页表项

```c
pt[pte_idx] = pte_create_kernel (vaddr, !in_kernel_text);
```

**详细解析**：

1. **pte_create_kernel 调用**：
   - 第一个参数：虚拟地址（用于计算物理页地址）
   - 第二个参数：是否可写
     - `!in_kernel_text`：如果在代码段内，不可写
     - 代码段：writable = false
     - 数据段：writable = true

**pte_create_kernel 函数分析**：

```c
static inline uint32_t pte_create_kernel (void *page, bool writable) {
  ASSERT (pg_ofs (page) == 0);      // 确保地址页对齐
  return vtop (page) | PTE_P | (writable ? PTE_W : 0);
}
```

- `vtop(page)`：将虚拟地址转换为物理地址
- `PTE_P`：Present 位
- 条件设置 `PTE_W`：根据 writable 参数决定

**注意**：没有设置 `PTE_U`，所以这些页只能在内核态（Ring 0）访问。

**PTE 格式示例**：

```
代码段页（只读）：
31                           12 11        0
+------------------------------+----------+
|    Physical Page Address     | 00000001 |
+------------------------------+----------+
                                 PTE_P = 1
                                 PTE_W = 0 (只读)
                                 PTE_U = 0 (仅内核)

数据段页（可写）：
31                           12 11        0
+------------------------------+----------+
|    Physical Page Address     | 00000011 |
+------------------------------+----------+
                                 PTE_P = 1
                                 PTE_W = 1 (可写)
                                 PTE_U = 0 (仅内核)
```

### 第18-22行：激活新页表

```c
/* Store the physical address of the page directory into CR3
   aka PDBR (page directory base register).  This activates our
   new page tables immediately.  See [IA32-v2a] "MOV--Move
   to/from Control Registers" and [IA32-v3a] 3.7.5 "Base Address
   of the Page Directory". */
asm volatile ("movl %0, %%cr3" : : "r" (vtop (init_page_dir)));
```

**详细解析**：

1. **内联汇编语法**：
   - `asm volatile`：告诉编译器这是汇编代码，不要优化
   - `"movl %0, %%cr3"`：将操作数 0 移动到 CR3 寄存器
   - `: :`：无输出操作数
   - `"r" (vtop (init_page_dir))`：输入操作数，使用任意通用寄存器

2. **CR3 寄存器**：
   - 也称为 PDBR（Page Directory Base Register）
   - 存储页目录的**物理地址**
   - 修改 CR3 会导致 TLB（Translation Lookaside Buffer）刷新

3. **地址转换**：
   - `init_page_dir` 是虚拟地址
   - `vtop()` 将其转换为物理地址
   - CPU 需要物理地址来定位页目录

**为什么使用 volatile**？

- 防止编译器优化掉这条指令
- 确保页表切换立即发生
- 这是一个有副作用的操作（改变内存映射）

**页表切换图示**：

```
                        切换前 (临时页表)
                    ┌─────────────────────┐
                    │  旧页目录 (BSS)      │
           CR3 ─────→  位于 init.c        │
                    └─────────────────────┘

                        ↓ movl %0, %%cr3 ↓

                        切换后 (永久页表)
                    ┌─────────────────────┐
                    │  新页目录 (动态分配) │
           CR3 ─────→  位于内核池         │
                    └─────────────────────┘
```

## 完整地址转换示例

假设访问虚拟地址 `0xC0123456`：

**步骤1：分解虚拟地址**

```
0xC0123456 = 1100 0000 0001 0010 0011 0100 0101 0110

PD Index  = 1100 0000 01 = 769 (0x301)
PT Index  = 00 0010 0011 = 35 (0x23)
Offset    = 0100 0101 0110 = 0x456
```

**步骤2：查找页目录**

```
PDE = pd[769]
    = 页表的物理地址 | PTE_U | PTE_P | PTE_W
```

**步骤3：查找页表**

```
pt = PDE & 0xFFFFF000  (提取页表物理地址)
PTE = pt[35]
    = 物理页的地址 | PTE_P | (PTE_W)
```

**步骤4：计算物理地址**

```
物理页帧 = PTE & 0xFFFFF000
物理地址 = 物理页帧 + 0x456
         = 0x00123000 + 0x456
         = 0x00123456
```

**完整转换图**：

```
虚拟地址: 0xC0123456
              │
              ↓
┌─────────────────────────────────────────────────────┐
│                                                     │
│    ┌──────────────┐                                │
│    │    CR3       │──────────┐                     │
│    └──────────────┘          │                     │
│                              ↓                     │
│    ┌─────────────────────────────────┐             │
│    │         Page Directory          │             │
│    │  ┌───────────────────────────┐  │             │
│    │  │ pd[0]                     │  │             │
│    │  │ ...                       │  │             │
│    │  │ pd[769] ─────────────────────────┐         │
│    │  │ ...                       │  │   │         │
│    │  │ pd[1023]                  │  │   │         │
│    │  └───────────────────────────┘  │   │         │
│    └─────────────────────────────────┘   │         │
│                                          ↓         │
│    ┌─────────────────────────────────────────┐     │
│    │            Page Table                   │     │
│    │  ┌───────────────────────────────────┐  │     │
│    │  │ pt[0]                             │  │     │
│    │  │ ...                               │  │     │
│    │  │ pt[35] = 0x00123003 ─────────────────────┐ │
│    │  │ ...                               │  │   │ │
│    │  │ pt[1023]                          │  │   │ │
│    │  └───────────────────────────────────┘  │   │ │
│    └─────────────────────────────────────────┘   │ │
│                                                  │ │
│    ┌─────────────────────────────────────────┐   │ │
│    │          Physical Page                  │◄──┘ │
│    │  ┌───────────────────────────────────┐  │     │
│    │  │ offset 0x000                      │  │     │
│    │  │ ...                               │  │     │
│    │  │ offset 0x456 ◄── 目标数据         │  │     │
│    │  │ ...                               │  │     │
│    │  │ offset 0xFFF                      │  │     │
│    │  └───────────────────────────────────┘  │     │
│    └─────────────────────────────────────────┘     │
│                                                     │
└─────────────────────────────────────────────────────┘
              │
              ↓
物理地址: 0x00123456
```

## 页表覆盖范围分析

### 内核地址空间布局

```
虚拟地址空间 (4GB)
┌───────────────────────────────────┐ 0xFFFFFFFF
│                                   │
│         内核空间 (1GB)            │
│                                   │
│  ┌───────────────────────────┐   │
│  │ 物理内存直接映射           │   │
│  │ 0xC0000000 → 物理 0x0     │   │
│  │ 0xC0001000 → 物理 0x1000  │   │
│  │      ...                   │   │
│  │ 0xC0000000+RAM → 物理 RAM │   │
│  └───────────────────────────┘   │
│                                   │
├───────────────────────────────────┤ 0xC0000000 (PHYS_BASE)
│                                   │
│                                   │
│         用户空间 (3GB)            │
│         (未映射)                  │
│                                   │
│                                   │
└───────────────────────────────────┘ 0x00000000
```

### 需要的页表数量

假设物理内存为 N MB：

- 每个页表覆盖：4MB（1024 × 4KB）
- 需要的页表数：⌈N MB / 4 MB⌉

**示例**：

| 物理内存 | 页目录索引范围 | 需要的页表数 |
|---------|--------------|-------------|
| 4 MB | 768 | 1 |
| 8 MB | 768-769 | 2 |
| 64 MB | 768-783 | 16 |
| 256 MB | 768-831 | 64 |

### 页表索引计算

对于内核映射（从 PHYS_BASE 开始）：

```
PHYS_BASE = 0xC0000000

PD Index = 0xC0000000 >> 22 = 768 (0x300)
```

所以内核映射从页目录的第 768 项开始。

## 与临时页表的对比

### 临时页表（start.S）

```assembly
# 临时页表：固定映射 64MB
.align PGSIZE
init_page_dir:
    .long 0x00000087    # PDE[0]: 映射 0-4MB
    .fill 767, 4, 0     # PDE[1-767]: 空
    .long 0x00000087    # PDE[768]: 映射 0-4MB 到 0xC0000000-0xC03FFFFF
    # ... 更多固定 PDE
```

### 永久页表（paging_init）

```c
// 动态映射所有检测到的内存
for (page = 0; page < init_ram_pages; page++) {
    // 按需分配页表
    // 正确设置代码段保护
}
```

**主要区别**：

| 特性 | 临时页表 | 永久页表 |
|------|---------|---------|
| 大小 | 固定 64MB | 动态（检测到的内存） |
| 分配方式 | 静态（BSS） | 动态（palloc） |
| 代码保护 | 无 | 代码段只读 |
| 页表数量 | 固定 16 个 | 按需分配 |
| 恒等映射 | 有（方便切换） | 无（不再需要） |

## TLB 刷新

修改 CR3 会自动刷新整个 TLB：

```
写入 CR3 前:
┌─────────────────────────────────┐
│             TLB                 │
│  ┌─────────────────────────┐   │
│  │ VA 0xC0001000 → PA 0x1000│   │ 旧的缓存项
│  │ VA 0xC0002000 → PA 0x2000│   │
│  │ ...                      │   │
│  └─────────────────────────┘   │
└─────────────────────────────────┘

写入 CR3 后:
┌─────────────────────────────────┐
│             TLB                 │
│  ┌─────────────────────────┐   │
│  │         (空)             │   │ 所有条目被清除
│  └─────────────────────────┘   │
└─────────────────────────────────┘

后续访问会重新填充 TLB
```

## 常见问题解答

### Q1: 为什么页目录项设置了 PTE_U（用户位）？

**A**: 虽然内核映射只在内核态使用，但 PDE 的 PTE_U 位需要设置为 1，原因是：
1. 用户程序的页表也会使用同一个页目录
2. 如果 PDE 设置 PTE_U=0，即使 PTE 设置 PTE_U=1，用户程序也无法访问
3. 实际的访问控制由 PTE 的 PTE_U 位决定

### Q2: 为什么代码段设置为只读？

**A**: 
1. **安全性**：防止恶意或错误代码修改内核指令
2. **调试**：写入代码段会触发 Page Fault，便于发现 bug
3. **稳定性**：防止缓冲区溢出覆盖代码

### Q3: 切换页表时会不会导致问题？

**A**: 不会，因为：
1. 新旧页表对内核地址的映射完全相同
2. CPU 当前执行的代码在切换前后都能正确访问
3. 栈和数据也都被正确映射

### Q4: 如果物理内存很大，页表会占用多少内存？

**A**: 
- 页目录：1 页 = 4KB
- 每 4MB 物理内存需要 1 个页表 = 4KB
- 例如 256MB 内存：1 + 64 = 65 页 = 260KB

这是相当高效的：260KB 管理 256MB，开销约 0.1%

## 练习题

### 练习1：地址分解

给定虚拟地址 `0xC0BADCAFE`（假设有足够内存），计算：
1. 页目录索引（PD Index）
2. 页表索引（PT Index）
3. 页内偏移（Offset）
4. 对应的物理地址

### 练习2：页表数量估算

如果系统有 512MB 物理内存：
1. 需要多少个页表？
2. 页目录和所有页表共占用多少内存？

### 练习3：代码保护验证

修改 paging_init，使数据段也变为只读：
1. 预测会发生什么？
2. 如何安全地测试这个修改？

### 练习4：添加恒等映射

如果需要在永久页表中保留低地址的恒等映射（物理地址 = 虚拟地址），需要如何修改 paging_init？

**提示**：考虑需要额外映射哪些地址，以及何时可以安全移除这些映射。

## 下一篇预告

在下一篇文档中，我们将详细解析线程系统的初始化 `thread_init()`，了解 Pintos 如何设置主线程和调度器基础设施。

## 参考资料

1. [Intel 64 and IA-32 Architectures Software Developer's Manual, Volume 3A: System Programming Guide](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html) - Chapter 4: Paging
2. [Pintos Reference Guide - Virtual Memory](https://web.stanford.edu/class/cs140/projects/pintos/pintos_6.html)
3. [OSDev Wiki - Paging](https://wiki.osdev.org/Paging)
