# Pintos 内核启动（十）：内存系统初始化

## 概述

本文档详细解析 Pintos 内核的内存系统初始化过程，包括页分配器 `palloc_init()` 和动态内存分配器 `malloc_init()` 的初始化。内存系统是操作系统最核心的子系统之一，它为内核和用户程序提供内存分配服务。

Pintos 的内存管理采用**两级分配**策略：
1. **页分配器（Page Allocator）**：以页（4KB）为单位分配物理内存
2. **块分配器（Block Allocator）**：在页的基础上，提供任意大小的内存分配

## 原始代码

### palloc.c 中的 palloc_init() 函数

```c
/* Pool allocator data structure. */
struct pool
  {
    struct lock lock;           /* Mutual exclusion. */
    struct bitmap *used_map;    /* Bitmap of free pages. */
    uint8_t *base;              /* Base of pool. */
  };

/* Two pools: one for kernel data, one for user pages. */
static struct pool kernel_pool, user_pool;

/* Initializes the page allocator.  At most USER_PAGE_LIMIT
   pages are put into the user pool. */
void
palloc_init (size_t user_page_limit)
{
  /* Free memory starts at 1 MB and runs to the end of RAM. */
  uint8_t *free_start = ptov (1024 * 1024);
  uint8_t *free_end = ptov (init_ram_pages * PGSIZE);
  size_t free_pages = (free_end - free_start) / PGSIZE;
  size_t user_pages = free_pages / 2;
  size_t kernel_pages;
  if (user_pages > user_page_limit)
    user_pages = user_page_limit;
  kernel_pages = free_pages - user_pages;

  /* Give half of memory to kernel, half to user. */
  init_pool (&kernel_pool, free_start, kernel_pages, "kernel pool");
  init_pool (&user_pool, free_start + kernel_pages * PGSIZE,
             user_pages, "user pool");
}

/* Initializes pool P as starting at START and ending at END,
   naming it NAME for debugging purposes. */
static void
init_pool (struct pool *p, void *base, size_t page_cnt, const char *name) 
{
  /* We'll put the pool's used_map at its base.
     Calculate the space needed for the bitmap
     and subtract it from the pool's size. */
  size_t bm_pages = DIV_ROUND_UP (bitmap_buf_size (page_cnt), PGSIZE);
  if (bm_pages > page_cnt)
    PANIC ("Not enough memory in %s for bitmap.", name);
  page_cnt -= bm_pages;

  printf ("%zu pages available in %s.\n", page_cnt, name);

  /* Initialize the pool. */
  lock_init (&p->lock);
  p->used_map = bitmap_create_in_buf (page_cnt, base, bm_pages * PGSIZE);
  p->base = base + bm_pages * PGSIZE;
}
```

### malloc.c 中的 malloc_init() 函数

```c
/* Descriptor. */
struct desc
  {
    size_t block_size;          /* Size of each element in bytes. */
    size_t blocks_per_arena;    /* Number of blocks in an arena. */
    struct list free_list;      /* List of free blocks. */
    struct lock lock;           /* Lock. */
  };

/* Arena. */
struct arena 
  {
    unsigned magic;             /* Always set to ARENA_MAGIC. */
    struct desc *desc;          /* Owning descriptor, null for big block. */
    size_t free_cnt;            /* Free blocks; pages in big block. */
  };

/* Our set of descriptors. */
static struct desc descs[10];   /* Descriptors. */
static size_t desc_cnt;         /* Number of descriptors. */

/* Initializes the malloc() descriptors. */
void
malloc_init (void) 
{
  size_t block_size;

  for (block_size = 16; block_size < PGSIZE / 2; block_size *= 2)
    {
      struct desc *d = &descs[desc_cnt++];
      ASSERT (desc_cnt <= sizeof descs / sizeof *descs);
      d->block_size = block_size;
      d->blocks_per_arena = (PGSIZE - sizeof (struct arena)) / block_size;
      list_init (&d->free_list);
      lock_init (&d->lock);
    }
}
```

## 前置知识

### 1. 内存布局回顾

在 Pintos 启动时，内存布局如下：

```
物理地址                   内容
┌─────────────────────┐
│  0x00000 - 0x003FF  │   实模式中断向量表
├─────────────────────┤
│  0x00400 - 0x004FF  │   BIOS 数据区
├─────────────────────┤
│  0x07C00 - 0x07DFF  │   引导扇区（loader）
├─────────────────────┤
│  0x20000 - 0x????? │   内核代码和数据
├─────────────────────┤
│  0xA0000 - 0xBFFFF  │   VGA 显存
├─────────────────────┤
│  0xC0000 - 0xFFFFF  │   BIOS ROM
├─────────────────────┤
│  0x100000 (1 MB)    │   可用内存开始
│         ...         │   空闲内存
│  init_ram_pages*4KB │   内存结束
└─────────────────────┘
```

### 2. 虚拟地址与物理地址转换

Pintos 使用简单的地址映射：
- **物理地址 → 虚拟地址**：`ptov(phys) = phys + PHYS_BASE`
- **虚拟地址 → 物理地址**：`vtop(virt) = virt - PHYS_BASE`

其中 `PHYS_BASE = 0xC0000000`（3GB）。

### 3. 位图（Bitmap）

位图是一种高效的数据结构，用于追踪资源的使用状态：
- 每个比特代表一个页的状态（0=空闲，1=已使用）
- 空间效率高：管理 N 页只需要 N/8 字节
- 操作效率：O(1) 的单页操作，O(N) 的连续页搜索

### 4. Slab 分配器思想

`malloc` 实现采用了类似 Slab 分配器的思想：
- **Arena**：一个页大小的内存块
- **Block**：Arena 中固定大小的分配单元
- **Descriptor**：管理某种大小块的描述符

## 逐行代码解析

### palloc_init() 函数解析

#### 第1-2行：计算可用内存范围

```c
uint8_t *free_start = ptov (1024 * 1024);
uint8_t *free_end = ptov (init_ram_pages * PGSIZE);
```

**详细解析**：

1. **free_start 的计算**：
   - `1024 * 1024 = 0x100000` 是物理地址 1MB
   - `ptov(0x100000)` 转换为虚拟地址 `0xC0100000`
   - 为什么从 1MB 开始？因为低 1MB 包含：
     - 实模式中断向量表和 BIOS 数据区
     - 引导代码
     - 内核代码（加载到 0x20000）
     - VGA 显存（0xA0000-0xBFFFF）
     - BIOS ROM（0xC0000-0xFFFFF）

2. **free_end 的计算**：
   - `init_ram_pages` 是在 `start.S` 中通过 BIOS 调用检测到的内存页数
   - `init_ram_pages * PGSIZE` 是物理内存的总大小（字节）
   - `ptov()` 将其转换为对应的虚拟地址

#### 第3-7行：计算内核和用户页数

```c
size_t free_pages = (free_end - free_start) / PGSIZE;
size_t user_pages = free_pages / 2;
size_t kernel_pages;
if (user_pages > user_page_limit)
  user_pages = user_page_limit;
kernel_pages = free_pages - user_pages;
```

**详细解析**：

1. **free_pages**：总的可用页数 = (内存结束 - 1MB) / 页大小

2. **内存分配策略**：
   - 默认将可用内存平分给内核和用户
   - `user_page_limit` 参数可以限制用户池的最大大小
   - 内核池获得剩余的所有页

3. **为什么需要 user_page_limit**？
   - 在测试环境中，可能需要限制用户内存来测试内存不足的情况
   - 默认值来自命令行参数 `--ul=`

**数值示例**：
假设物理内存为 4MB（`init_ram_pages = 1024`）：
- `free_pages = (4MB - 1MB) / 4KB = 768` 页
- `user_pages = 768 / 2 = 384` 页
- `kernel_pages = 768 - 384 = 384` 页

#### 第8-10行：初始化内存池

```c
init_pool (&kernel_pool, free_start, kernel_pages, "kernel pool");
init_pool (&user_pool, free_start + kernel_pages * PGSIZE,
           user_pages, "user pool");
```

**详细解析**：

内存池的布局：

```
虚拟地址
┌─────────────────────────────┐ 0xC0100000 (1MB 物理地址)
│                             │
│       内核池（kernel_pool） │
│                             │
├─────────────────────────────┤ 0xC0100000 + kernel_pages * 4KB
│                             │
│       用户池（user_pool）   │
│                             │
└─────────────────────────────┘ 内存结束
```

### init_pool() 函数解析

#### 第1-4行：计算位图所需空间

```c
size_t bm_pages = DIV_ROUND_UP (bitmap_buf_size (page_cnt), PGSIZE);
if (bm_pages > page_cnt)
  PANIC ("Not enough memory in %s for bitmap.", name);
page_cnt -= bm_pages;
```

**详细解析**：

1. **位图大小计算**：
   - `bitmap_buf_size(page_cnt)` 返回管理 `page_cnt` 页需要的位图字节数
   - 公式：`ceiling(page_cnt / 8)` 字节
   - `DIV_ROUND_UP` 将字节数向上取整到页

2. **空间检查**：
   - 如果位图本身需要的页数超过了总页数，说明内存太小
   - 这是一个致命错误，触发内核 PANIC

3. **调整可用页数**：
   - 位图占用的页不能再用于分配
   - 实际可用页数 = 原始页数 - 位图页数

**数值示例**：
假设 `page_cnt = 384`：
- 位图需要 `384 / 8 = 48` 字节
- 向上取整到页：1 页
- 实际可用：`384 - 1 = 383` 页

#### 第5-9行：初始化池结构

```c
printf ("%zu pages available in %s.\n", page_cnt, name);

lock_init (&p->lock);
p->used_map = bitmap_create_in_buf (page_cnt, base, bm_pages * PGSIZE);
p->base = base + bm_pages * PGSIZE;
```

**详细解析**：

1. **打印信息**：启动时会看到类似输出：
   ```
   383 pages available in kernel pool.
   383 pages available in user pool.
   ```

2. **锁初始化**：
   - 每个池有独立的锁
   - 保证多线程访问时的互斥

3. **位图创建**：
   - `bitmap_create_in_buf` 在预分配的缓冲区中创建位图
   - 位图放在池的起始位置
   - 所有位初始化为 0（表示空闲）

4. **基址调整**：
   - `p->base` 是实际可分配内存的起始地址
   - 跳过位图占用的空间

**池结构布局**：

```
                    pool 结构
                 ┌─────────────┐
                 │    lock     │ 互斥锁
                 ├─────────────┤
                 │  used_map   │───┐ 指向位图
                 ├─────────────┤   │
                 │    base     │───┼──┐ 指向可分配内存
                 └─────────────┘   │  │
                                   │  │
池内存布局                          │  │
┌─────────────────────────────┐   │  │
│      位图区（bm_pages）      │◄──┘  │
│  [0|0|0|0|0|0|0|0|...]     │       │
├─────────────────────────────┤◄─────┘
│         第 0 页             │
├─────────────────────────────┤
│         第 1 页             │
├─────────────────────────────┤
│          ...                │
├─────────────────────────────┤
│      第 page_cnt-1 页       │
└─────────────────────────────┘
```

### malloc_init() 函数解析

#### 第1-2行：循环初始化描述符

```c
size_t block_size;

for (block_size = 16; block_size < PGSIZE / 2; block_size *= 2)
```

**详细解析**：

1. **块大小范围**：
   - 最小块：16 字节
   - 最大块：`PGSIZE / 2 = 2048` 字节（不含）
   - 实际大小：16, 32, 64, 128, 256, 512, 1024 字节

2. **为什么最小是 16 字节**？
   - `struct block` 至少需要存储一个 `list_elem`（8 字节）
   - 对齐要求和实用性考虑

3. **为什么最大是 2KB**？
   - Arena 头部占用空间
   - 需要保证至少能放 2 个块

#### 第3-9行：初始化每个描述符

```c
{
  struct desc *d = &descs[desc_cnt++];
  ASSERT (desc_cnt <= sizeof descs / sizeof *descs);
  d->block_size = block_size;
  d->blocks_per_arena = (PGSIZE - sizeof (struct arena)) / block_size;
  list_init (&d->free_list);
  lock_init (&d->lock);
}
```

**详细解析**：

1. **描述符数组**：
   - `descs[10]` 预分配 10 个描述符槽位
   - 实际使用 7 个（16 到 1024）

2. **每 Arena 块数计算**：
   - `PGSIZE = 4096` 字节
   - `sizeof(struct arena)` 约 12 字节
   - 公式：`(4096 - 12) / block_size`

3. **各描述符配置**：

| desc_cnt | block_size | blocks_per_arena |
|----------|------------|------------------|
| 0 | 16 | 255 |
| 1 | 32 | 127 |
| 2 | 64 | 63 |
| 3 | 128 | 31 |
| 4 | 256 | 15 |
| 5 | 512 | 7 |
| 6 | 1024 | 3 |

4. **空闲链表**：
   - 每个描述符维护一个空闲块链表
   - 初始为空，按需分配 Arena

5. **锁**：
   - 每个描述符有独立的锁
   - 不同大小的分配可以并行进行

**描述符与 Arena 关系图**：

```
描述符数组 descs[]
┌─────────────┬─────────────┬─────────────┬─────────────┐
│  desc[0]    │  desc[1]    │  desc[2]    │    ...      │
│ size=16     │ size=32     │ size=64     │             │
│ blocks=255  │ blocks=127  │ blocks=63   │             │
│ free_list ──┼─→           │ free_list ──┼─→           │
└──────┼──────┴─────────────┴──────┼──────┴─────────────┘
       │                           │
       ↓                           ↓
   ┌───────┐                   ┌───────┐
   │Arena A│                   │Arena C│
   │header │                   │header │
   ├───────┤                   ├───────┤
   │block 0│                   │block 0│
   │block 1│                   │block 1│
   │  ...  │                   │  ...  │
   │blk 254│                   │blk 62 │
   └───────┘                   └───────┘
```

## 内存分配流程

### 页分配 palloc_get_multiple()

```c
void *
palloc_get_multiple (enum palloc_flags flags, size_t page_cnt)
{
  struct pool *pool = flags & PAL_USER ? &user_pool : &kernel_pool;
  void *pages;
  size_t page_idx;

  if (page_cnt == 0)
    return NULL;

  lock_acquire (&pool->lock);
  page_idx = bitmap_scan_and_flip (pool->used_map, 0, page_cnt, false);
  lock_release (&pool->lock);

  if (page_idx != BITMAP_ERROR)
    pages = pool->base + PGSIZE * page_idx;
  else
    pages = NULL;

  if (pages != NULL) 
    {
      if (flags & PAL_ZERO)
        memset (pages, 0, PGSIZE * page_cnt);
    }
  else 
    {
      if (flags & PAL_ASSERT)
        PANIC ("palloc_get: out of pages");
    }

  return pages;
}
```

**分配流程**：

```
palloc_get_multiple(PAL_USER | PAL_ZERO, 3)
              │
              ↓
    ┌─────────────────────┐
    │ 1. 选择内存池       │
    │    PAL_USER → user  │
    │    否则 → kernel    │
    └─────────┬───────────┘
              ↓
    ┌─────────────────────┐
    │ 2. 获取池锁         │
    └─────────┬───────────┘
              ↓
    ┌─────────────────────┐
    │ 3. 在位图中搜索     │
    │    连续3个空闲位    │
    │    并设置为已使用   │
    └─────────┬───────────┘
              ↓
    ┌─────────────────────┐
    │ 4. 释放池锁         │
    └─────────┬───────────┘
              ↓
    ┌─────────────────────┐
    │ 5. 计算页地址       │
    │ addr = base + idx*4K│
    └─────────┬───────────┘
              ↓
    ┌─────────────────────┐
    │ 6. PAL_ZERO?        │
    │    是 → memset(0)   │
    └─────────┬───────────┘
              ↓
         返回地址
```

### 块分配 malloc()

```c
void *malloc (size_t size)
```

**分配流程**：

```
malloc(100)
    │
    ↓
┌───────────────────────┐
│ 1. 查找合适的描述符   │
│    100 → desc[3]      │
│    (block_size=128)   │
└───────────┬───────────┘
            ↓
┌───────────────────────┐
│ 2. 获取描述符锁       │
└───────────┬───────────┘
            ↓
┌───────────────────────┐
│ 3. free_list 空?      │
│    是 → 分配新 Arena  │
│    否 → 跳到步骤 5    │
└───────────┬───────────┘
            ↓
┌───────────────────────┐
│ 4. 初始化 Arena       │
│    - 设置 magic       │
│    - 关联描述符       │
│    - 添加所有块到     │
│      free_list        │
└───────────┬───────────┘
            ↓
┌───────────────────────┐
│ 5. 从 free_list 取块  │
│    更新 arena.free_cnt│
└───────────┬───────────┘
            ↓
┌───────────────────────┐
│ 6. 释放描述符锁       │
└───────────┬───────────┘
            ↓
        返回块地址
```

## 内存释放流程

### 页释放 palloc_free_multiple()

```c
void
palloc_free_multiple (void *pages, size_t page_cnt) 
{
  struct pool *pool;
  size_t page_idx;

  ASSERT (pg_ofs (pages) == 0);
  if (pages == NULL || page_cnt == 0)
    return;

  if (page_from_pool (&kernel_pool, pages))
    pool = &kernel_pool;
  else if (page_from_pool (&user_pool, pages))
    pool = &user_pool;
  else
    NOT_REACHED ();

  page_idx = pg_no (pages) - pg_no (pool->base);

#ifndef NDEBUG
  memset (pages, 0xcc, PGSIZE * page_cnt);
#endif

  ASSERT (bitmap_all (pool->used_map, page_idx, page_cnt));
  bitmap_set_multiple (pool->used_map, page_idx, page_cnt, false);
}
```

**释放流程**：

1. **地址验证**：检查地址是否页对齐
2. **确定所属池**：判断页属于内核池还是用户池
3. **计算页索引**：`page_idx = 页号 - 池基址页号`
4. **调试填充**：非 Release 版本填充 `0xCC`（帮助检测 use-after-free）
5. **更新位图**：将对应位设置为 0（空闲）

### 块释放 free()

```c
void free (void *p)
```

**释放流程**：

1. 找到块所属的 Arena
2. 验证 Arena 魔数
3. 获取描述符锁
4. 将块加入空闲链表
5. 如果 Arena 完全空闲：
   - 从空闲链表移除所有块
   - 归还页给页分配器
6. 释放描述符锁

## 内存分配标志

```c
enum palloc_flags
  {
    PAL_ASSERT = 001,   /* 分配失败时 panic */
    PAL_ZERO = 002,     /* 将页清零 */
    PAL_USER = 004      /* 从用户池分配 */
  };
```

**使用示例**：

```c
/* 分配一个清零的内核页 */
void *kpage = palloc_get_page(PAL_ZERO);

/* 分配一个用户页，失败时 panic */
void *upage = palloc_get_page(PAL_USER | PAL_ASSERT);

/* 分配 4 个连续的内核页 */
void *pages = palloc_get_multiple(0, 4);
```

## Arena 内存布局

单个 Arena 的详细布局：

```
Arena (4096 字节 = 1 页)
┌─────────────────────────────────┐ offset 0
│          struct arena           │
│  ┌─────────────────────────┐   │
│  │ magic = 0x9a548eed      │   │ 4 bytes
│  ├─────────────────────────┤   │
│  │ desc (指向描述符)       │   │ 4 bytes
│  ├─────────────────────────┤   │
│  │ free_cnt                │   │ 4 bytes
│  └─────────────────────────┘   │
├─────────────────────────────────┤ offset ~12
│           Block 0               │
│  ┌─────────────────────────┐   │
│  │ free_elem (if free)     │   │
│  │ 或 用户数据 (if used)   │   │
│  └─────────────────────────┘   │
├─────────────────────────────────┤
│           Block 1               │
├─────────────────────────────────┤
│            ...                  │
├─────────────────────────────────┤
│    Block (blocks_per_arena-1)   │
└─────────────────────────────────┘ offset 4096
```

## 大块分配

对于超过 1KB 的分配请求：

```c
if (d == descs + desc_cnt) 
{
  /* SIZE is too big for any descriptor.
     Allocate enough pages to hold SIZE plus an arena. */
  size_t page_cnt = DIV_ROUND_UP (size + sizeof *a, PGSIZE);
  a = palloc_get_multiple (0, page_cnt);
  if (a == NULL)
    return NULL;

  /* Initialize the arena to indicate a big block of PAGE_CNT
     pages, and return it. */
  a->magic = ARENA_MAGIC;
  a->desc = NULL;          /* 标记为大块 */
  a->free_cnt = page_cnt;  /* 存储页数 */
  return a + 1;
}
```

**大块布局**：

```
┌─────────────────────────────────┐
│          struct arena           │  第 0 页
│  ┌─────────────────────────┐   │
│  │ magic = 0x9a548eed      │   │
│  │ desc = NULL (大块标记)   │   │
│  │ free_cnt = 页数         │   │
│  └─────────────────────────┘   │
├─────────────────────────────────┤
│                                 │
│         用户数据区              │
│       (page_cnt * 4KB          │
│        - sizeof arena)         │
│                                 │
└─────────────────────────────────┘
```

## 调试支持

### Use-After-Free 检测

```c
#ifndef NDEBUG
  /* Clear the block to help detect use-after-free bugs. */
  memset (b, 0xcc, d->block_size);
#endif
```

- 释放的内存填充 `0xCC`
- 如果程序访问已释放的内存，会读到 `0xCCCCCCCC`
- 这个值作为指针是无效的，容易暴露 bug

### Arena 完整性检查

```c
/* Check that the arena is valid. */
ASSERT (a != NULL);
ASSERT (a->magic == ARENA_MAGIC);
```

- 魔数 `0x9a548eed` 检测内存损坏
- 如果 Arena 头部被覆写，魔数会变化

## 常见问题解答

### Q1: 为什么需要两个内存池？

**A**: 分离内核和用户内存有多个好处：
1. **安全性**：用户程序无法直接访问内核内存
2. **资源控制**：可以限制用户程序的内存使用
3. **简化回收**：进程退出时只需回收用户池中的页

### Q2: 为什么 malloc 使用 2 的幂次块大小？

**A**: 
1. **对齐友好**：2 的幂次自然满足各种对齐要求
2. **减少碎片**：标准化的块大小减少外部碎片
3. **快速匹配**：可以用位操作快速找到合适的描述符
4. **内部碎片可控**：最多浪费 50%

### Q3: 如何处理内存碎片？

**A**: Pintos 的设计减少了碎片：
1. **页分配器**：只有外部碎片（无法找到连续空闲页）
2. **块分配器**：
   - 内部碎片：请求 20 字节分配 32 字节
   - 外部碎片：通过 Arena 归还机制缓解

### Q4: palloc_init 为什么从 1MB 开始？

**A**: 低 1MB 内存布局复杂：
- 0-1KB：实模式中断向量表
- 1KB-640KB：常规内存（但已被内核占用）
- 640KB-1MB：VGA 和 BIOS ROM

从 1MB 开始可以获得干净的连续内存。

## 练习题

### 练习1：分析内存效率

假设系统有 8MB 物理内存，计算：
1. 内核池和用户池各有多少可用页？
2. 内核池位图占用多少空间？

**提示**：
- 可用内存 = 8MB - 1MB = 7MB
- 总页数 = 7MB / 4KB = 1792 页

### 练习2：理解 malloc 选择

对于以下分配请求，malloc 会使用哪个描述符？
1. `malloc(1)`
2. `malloc(17)`
3. `malloc(1000)`
4. `malloc(2000)`
5. `malloc(5000)`

### 练习3：实现内存统计

在 `palloc.c` 中添加函数，返回当前可用的空闲页数：

```c
size_t palloc_free_pages(enum palloc_flags flags);
```

### 练习4：分析并发安全

分析以下场景是否线程安全：
1. 线程 A 调用 `malloc(32)`，线程 B 调用 `malloc(64)`
2. 线程 A 调用 `malloc(32)`，线程 B 调用 `malloc(32)`
3. 线程 A 调用 `palloc_get_page(PAL_USER)`，线程 B 调用 `palloc_get_page(0)`

## 下一篇预告

在下一篇文档中，我们将详细解析 `paging_init()` 函数，了解 Pintos 如何建立永久的页表结构，替换 `start.S` 中创建的临时页表。

## 参考资料

1. [Intel 64 and IA-32 Architectures Software Developer's Manual](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)
2. [Pintos Documentation - Memory Allocation](https://web.stanford.edu/class/cs140/projects/pintos/pintos_6.html)
3. [The Slab Allocator: An Object-Caching Kernel Memory Allocator](https://www.usenix.org/legacy/publications/library/proceedings/bos94/full_papers/bonwick.a)
