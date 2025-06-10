---
layout: page
title: Git底层原理详解
data: 2025-05-09
tags: [Git]
---
# 一. 前言
在一开始接触Git与Github时，我对Git的一些操作十分疑惑。作为一名学生，我常用的操作无非以下几种：
```bash
# 创建仓库
git init  
# 克隆仓库
git clone [repository url]
# 将修改内容保存到暂存区
git add [file path]
# 提交到本地仓库
git commit -m "commit message"
# 推送到远端仓库
git push [remote branch name] [local branch name] 
```
在创建仓库阶段，`git init`会创建一个`.git`文件夹。那我就很疑惑了，`.git`文件夹是用来干什么的？里面保存了些什么？这值得我们探究<br>
在提交修改阶段，新手的我只会照葫芦画瓢，用最简单的方法：
```bash
# 将所有修改内容写入暂存区
git add .
# 提交到本地仓库
git commit -m "commit message"
# 推送到远端仓库
git push origin main
```
It looks like magic! 在终端上打上几行，到Github上看,wow,真的把修改保存并推送上去了。🙌😭🙌 Amazing! <br>
对于一般人来讲，了解这些也许就够用。但我想，这对学计算机的人来说远远不够。毕竟，“计算机中没有魔法”。所以，就让我们详细探究一下`git`的底层原理，理解这个堪称伟大的版本控制系统。
# 二. 初探
让我们先来看看这个神秘的`.git`文件夹中保存着什么：
## 1. 准备
首先，我们先新建一个`git`仓库,并切换到该文件夹
~~~bash 
// Terminal 1
╭─ ~ ────────────────────────────────────────────────────────────── 10:37:50 ─╮
╰─❯ git init git-demo                                                        ─╯
已初始化空的 Git 仓库于 /Users/apple/git-demo/.git/

╭─ ~ ────────────────────────────────────────────────────────────── 17:02:24 ─╮
╰─❯ cd git-demo
~~~
此时里面并没有任何东西，除了一个隐藏文件夹`git`(对于Mac系统来说)。我们可以用`git status`命令来查看当前git文件夹的状态
~~~bash 
// Terminal 1
╭─ ~/git-demo main ──────────────────────────────────────────────── 17:03:46 ─╮
╰─❯ ls                                                                       ─╯

╭─ ~/git-demo main ──────────────────────────────────────────────── 17:05:01 ─╮
╰─❯ git status                                                               ─╯
位于分支 main

尚无提交

无文件要提交（创建/拷贝文件并使用 "git add" 建立跟踪）
~~~
现在我们开一个新的终端并切换到git-demo目录，通过`watch`和`tree`工具来查看`.git`文件夹下保存了哪些内容。<br>
我们需要安装`tree`和`watch`工具，`tree`用于用树状结构展现文件夹的内容，`watch`用于监视`git`内容的变化。
```bash
brew install tree
brew install watch
```
然后，运行
```bash
// Terminal 2
# 0.5秒刷新一次
watch -n .5 tree .git
```
会显示这样的界面
```bash
// Terminal 2
Every 0.5s: tree. git                                                                                                                   
.git
├── HEAD
├── config
├── description
├── hooks
│   ├── applypatch-msg.sample
│   ├── commit-msg.sample
│   ├── fsmonitor-watchman.sample
│   ├── post-update.sample
│   ├── pre-applypatch.sample
│   ├── pre-commit.sample
│   ├── pre-merge-commit.sample
│   ├── pre-push.sample
│   ├── pre-rebase.sample
│   ├── pre-receive.sample
│   ├── prepare-commit-msg.sample
│   ├── push-to-checkout.sample
│   ├── sendemail-validate.sample
│   └── update.sample
├── info
│   └── exclude
├── objects
│   ├── info
│   └── pack
└── refs
    ├── heads
    └── tags

9 directories, 18 files
```
（该操作后，Terminal 2 用于显示信息，Terminal 1 用于输入操作）
我们可以看到`.git`文件夹下有很多部分组成。目前我们先关注`objects`部分。为了方便观察与说明，我们先去掉`hooks`：
```bash
rm -r .git/hooks
```
显示为
```bash
.git
├── HEAD
├── config
├── description
├── info
│   └── exclude
├── objects
│   ├── info
│   └── pack
└── refs
    ├── heads
    └── tags
```
## 2. 加入文件
现在我们往仓库中加入文件。
```bash
╭─ ~/git-demo main ──────────────────────────────────────────────── 22:07:21 ─╮
╰─❯ vim 1.txt
```
并在`1.txt`中写入`hello world`。我们发现`.git`文件夹并没有发生任何的改变。这也是合理的，我们只是在项目中加入了一个文件，还没有执行`git`的任何命令。现在，让我们把`1.txt`加入暂存区，正如我们经常做的那样：
```bash
╭─ ~/git-demo main ?1 ───────────────────────────────────────── 28s 22:14:54 ─╮
╰─❯ git add 1.txt                                                            ─╯
警告：在 '1.txt' 的工作拷贝中，下次 Git 接触时 LF 将被 CRLF 替换
```
`.git`文件夹变成了这样：
```bash
.git
├── HEAD
├── config
├── description
├── index
├── info
│   └── exclude
├── objects
│   ├── 3b
│   │   └── 18e512dba79e4c8300dd08aeb37f8e728b8dad
│   ├── info
│   └── pack
└── refs
    ├── heads
    └── tags
```
我们可以看到`.git/objects`文件夹下多了一个内容。那这一长串又是什么？这就涉及到`git`的底层设计哲学了。<br>
在文件保存到`.git`文件夹中前，`git`会对你的文件的所有数据进行哈希处理，生成一个`SHA-1`的哈希值，这个哈希值就是你此次提交数据的**唯一标识符**。在我们的例子中，`git`根据`1.txt`的内容`hello world`生成了一个哈希值`2e3c1c7a3faf540c6490fab43ac83bdfa17400eb`用于标识该文件。我们还可以通过`git hash-object`命令来查看该文件的哈希值：
```bash
╭─ ~/git-demo main +1 ───────────────────────────────────────────── 22:19:58 ─╮
╰─❯ git hash-object -w 1.txt                                                 ─╯
警告：在 '1.txt' 的工作拷贝中，下次 Git 接触时 LF 将被 CRLF 替换
3b18e512dba79e4c8300dd08aeb37f8e728b8dad
```
可以看到，显示的哈希值与我们在`.git/objects`中看到的哈希值是一样的。<br>
根据内容生成标识符有什么好处呢？首先，也是最重要的一点，它能时刻保证数据的完整性。当文件内容发生任何变化，无论该变化有多微小，哈希值都会发生非常大的改变，也就是说，`git`能时刻监控文件的变化。当文件在传输时变得不完整，数据损毁、缺失，`git`也能通过哈希值来检测到。其次，相同的文件内容会生成相同的哈希值，这就意味着`git`能通过哈希值来判断文件是否重复，也可以节省存储空间。比如我们在`git`中加入了一个文件`2.txt`，内容与`1.txt`完全相同：
```bash
vim 2.txt
git add 2.txt
```
我们发现`git`并没有任何变化。说明`git`并没有重复存储相同的文件。而当我们加入一个文件`3.txt`，内容为`hello world!`时，
```bash
vim 3.txt
git add 3.txt
```
显示为
```bash
.git
├── HEAD
├── config
├── description
├── index
├── info
│   └── exclude
├── objects
│   ├── 3b
│   │   └── 18e512dba79e4c8300dd08aeb37f8e728b8dad
│   ├── a0
│   │   └── 423896973644771497bdc03eb99d5281615b51
│   ├── info
│   └── pack
└── refs
    ├── heads
    └── tags
```
我们可以看到，`git`又生成了一个新的哈希值`a0423896973644771497bdc03eb99d5281615b51`。<br>
通过哈希值这个唯一标识符，我们也可以访问到对应的文件内容。我们可以通过`git cat-file`命令来查看:
```bash
╭─ ~/git-demo main +2 ───────────────────────────────────────────── 22:57:02 ─╮
╰─❯ git cat-file -p 3b18                                                     ─╯
hello world

╭─ ~/git-demo main +3 ───────────────────────────────────────────── 23:11:13 ─╮
╰─❯ git cat-file -p a042                                                     ─╯
hello world!
```
在`git`中，文件的内容是以`blob`的形式存储的。`blob`是`git`中最基本的对象类型之一，表示一个二进制大对象（Binary Large Object）。它可以存储任何类型的数据，包括文本、图片、音频等。每个哈希值对应一个`git`对象，我们也可以通过`git cat-file`命令来查看该对象的类型：
```bash
╭─ ~/git-demo main ────────────────────────────────────────────────── 19:28:04 ─╮
╰─❯ git cat-file -t 3b18                                                       ─╯
blob
```
在之后我们会遇到`git`的其他对象类型。
## 3. 提交
现在让我们试着提交一个文件。来看看`.git`文件夹会发生什么变化。
```bash
╭─ ~/git-demo main +3 ─────────────────────────────────────────────── 23:12:45 ─╮
╰─❯ git commit -m "first commit"                                               ─╯
[main（根提交） 757ba86] first commit
 3 files changed, 3 insertions(+)
 create mode 100644 1.txt
 create mode 100644 2.txt
 create mode 100644 3.txt
```
显示为
```bash
.git
├── COMMIT_EDITMSG
├── HEAD
├── config
├── description
├── index
├── info
│   └── exclude
├── logs
│   ├── HEAD
│   └── refs
│       └── heads
│           └── main
├── objects
│   ├── 1e
│   │   └── f3e0cbf75b1f9063d5bf22a027cd35c3b34ae7
│   ├── 3b
│   │   └── 18e512dba79e4c8300dd08aeb37f8e728b8dad
│   ├── 75
│   │   └── 7ba86751bfdf19169210b0bc8c9fa7ca208f07
│   ├── a0
│   │   └── 423896973644771497bdc03eb99d5281615b51
│   ├── info
│   └── pack
└── refs
    ├── heads
    │   └── main
    └── tags
```
可以看到，`.git`文件夹下多了一个`COMMIT_EDITMSG`文件和一个`logs`文件夹。同时，`objects`文件夹下多了两个内容。
让我们使用`git cat-file`命令来查看一下多出来的两条哈希值。
```bash
╭─ ~/git-demo main ────────────────────────────────────────────────── 19:23:44 ─╮
╰─❯ git cat-file -p 1ef3                                                       ─╯
100644 blob 3b18e512dba79e4c8300dd08aeb37f8e728b8dad	1.txt
100644 blob 3b18e512dba79e4c8300dd08aeb37f8e728b8dad	2.txt
100644 blob a0423896973644771497bdc03eb99d5281615b51	3.txt

╭─ ~/git-demo main ────────────────────────────────────────────────── 19:33:47 ─╮
╰─❯ git cat-file -t 1ef3                                                       ─╯
tree
```
可以看到，`1ef3`是一个`tree`对象。在里面保存了三个`blob`对象，分别对应`1.txt`、`2.txt`和`3.txt`,也就是我们这次提交的三个文件。<br>
我们再来看看`757ba8`这个哈希值：
```bash
╭─ ~/git-demo main ────────────────────────────────────────────────── 19:35:22 ─╮
╰─❯ git cat-file -p 757b                                                       ─╯
tree 1ef3e0cbf75b1f9063d5bf22a027cd35c3b34ae7
author zxsheather <zxsheather@sjtu.edu.cn> 1746876224 +0800
committer zxsheather <zxsheather@sjtu.edu.cn> 1746876224 +0800

first commit

╭─ ~/git-demo main ────────────────────────────────────────────────── 19:38:43 ─╮
╰─❯ git cat-file -t 757b                                                       ─╯
commit
```
可以看到，`757b`是一个`commit`对象。它包含了一个指向`tree`对象的指针，指向了我们刚才提交的文件。它还包含了作者的姓名，邮件等，都是配置`git`时填好的。所谓的`1746876224`是一个Unix时间戳,表示自1970年1月1日以来的秒数。`+0800`表示时区偏移量，这里是中国的标准时区，东八区。<br>










