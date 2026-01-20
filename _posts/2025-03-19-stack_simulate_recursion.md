---
layout: post
title: "栈模拟递归的通用解法"
date: 2025-03-19
categories: [技术, 算法]
tags: [数据结构, 递归, 栈]
---
我们知道，递归的过程可以用栈来模拟。但对于一些困难的问题，我们好像很难用栈去写。比如说汉诺塔问题。再比如说:
~~~cpp
int f(int i){
    return i <= 1 ? 1 : f(i-1) + g(i-2);
}
int g(int i){
    return i <= 1 ? 1 : f(i+1) + g(i-1);
}
~~~
在这些例子中，我们该怎么知道什么时候该入队，什么时候该出队呢？比如在第二个例子里，我们调用了`f(i)`,我们并不能把`f(i)`立刻出队。即使`f(i-1)`计算完成，我们还需要等到`g(i-2)`计算完成后才能出队。<br>
此时我们需要持有一种对计算机、程序的一种相当本质的看法：**状态机**。程序运行本质上都是一些状态的转换。我们在运行的过程中保存当前的状态`pc`，然后根据当前不同的状态执行不同的任务。<br>
比如对于第二个例子，我们可以定义此时`f`或`g`所处于的状态为以下四个状态：
~~~cpp
enum State {
    CALL,        // 初始调用 
    CALC_FIRST,  // 计算第一个子表达式
    CALC_SECOND, // 计算第二个子表达式
    RETURN       // 返回结果
};
~~~
我们在栈帧中保存以下几个值：
~~~cpp
struct StackFrame {
    FuncType func; // 当前执行的函数类型
    int i;         // 输入参数
    State state;   // 当前执行状态
    int result;    // 中间结果存储
};
~~~
取出栈顶的元素`top`，根据不同的状态，执行以下不同的任务：
~~~cpp
switch (top.state) {
    case CALL:
        // 处理基本情况
        if (top.i <= 1) {
            top.result = 1;
            top.state = RETURN;
        } else {
            // 设置为计算第一个子表达式的状态
            top.state = CALC_FIRST;
            if (top.func == FUNC_F) {
                // f 函数需要计算 f(i-1)
                callStack.push({FUNC_F, top.i - 1, CALL, 0});
            } else {
                // g 函数需要计算 f(i+1)
                callStack.push({FUNC_F, top.i + 1, CALL, 0});
            }
        }
        break;
        
    case CALC_FIRST:
        // 保存第一个子表达式结果
        top.result = finalResult;
        // 设置为计算第二个子表达式的状态
        top.state = CALC_SECOND;
        if (top.func == FUNC_F) {
            // f 函数需要计算 g(i-2)
            callStack.push({FUNC_G, top.i - 2, CALL, 0});
        } else {
            // g 函数需要计算 g(i-1)
            callStack.push({FUNC_G, top.i - 1, CALL, 0});
        }
        break;
        
    case CALC_SECOND:
        // 计算最终结果 = 第一个子表达式结果 + 第二个子表达式结果
        top.result += finalResult;
        top.state = RETURN;
        break;
        
    case RETURN:
        // 保存当前函数的计算结果
        finalResult = top.result;
        // 完成计算，弹出栈帧
        callStack.pop();
        break;
}
~~~
在其中我们用`finalResult`变量来传递上一个弹出的栈帧所返回的值，将该值传递给调用它的函数.通过保存状态，我们就知道何时该函数该做什么事情。
以下是完整的代码：
~~~cpp
#include <iostream>
#include <stack>

// 定义函数类型
enum FuncType {
    FUNC_F, // f函数
    FUNC_G  // g函数
};

// 定义计算状态
enum State {
    CALL,        // 初始调用
    CALC_FIRST,  // 计算第一个子表达式
    CALC_SECOND, // 计算第二个子表达式
    RETURN       // 返回结果
};

// 栈帧结构，存储每个调用的状态
struct StackFrame {
    FuncType func; // 当前执行的函数类型
    int i;         // 输入参数
    State state;   // 当前执行状态
    int result;    // 中间结果存储
};

// 统一的非递归计算函数
int calculate(FuncType initial_func, int initial_i) {
    std::stack<StackFrame> callStack;
    
    // 将初始调用推入栈中
    callStack.push({initial_func, initial_i, CALL, 0});
    
    int finalResult = 0;
    
    while (!callStack.empty()) {
        // 引用栈顶元素以便修改
        StackFrame& top = callStack.top();
        
        switch (top.state) {
            case CALL:
                // 处理基本情况
                if (top.i <= 1) {
                    top.result = 1;
                    top.state = RETURN;
                } else {
                    // 设置为计算第一个子表达式的状态
                    top.state = CALC_FIRST;
                    if (top.func == FUNC_F) {
                        // f 函数需要计算 f(i-1)
                        callStack.push({FUNC_F, top.i - 1, CALL, 0});
                    } else {
                        // g 函数需要计算 f(i+1)
                        callStack.push({FUNC_F, top.i + 1, CALL, 0});
                    }
                }
                break;
                
            case CALC_FIRST:
                // 保存第一个子表达式结果
                top.result = finalResult;
                // 设置为计算第二个子表达式的状态
                top.state = CALC_SECOND;
                if (top.func == FUNC_F) {
                    // f 函数需要计算 g(i-2)
                    callStack.push({FUNC_G, top.i - 2, CALL, 0});
                } else {
                    // g 函数需要计算 g(i-1)
                    callStack.push({FUNC_G, top.i - 1, CALL, 0});
                }
                break;
                
            case CALC_SECOND:
                // 计算最终结果 = 第一个子表达式结果 + 第二个子表达式结果
                top.result += finalResult;
                top.state = RETURN;
                break;
                
            case RETURN:
                // 保存当前函数的计算结果
                finalResult = top.result;
                // 完成计算，弹出栈帧
                callStack.pop();
                break;
        }
    }
    
    return finalResult;
}

// f 函数的非递归实现
int f_non_recursive(int i) {
    return calculate(FUNC_F, i);
}

// g 函数的非递归实现
int g_non_recursive(int i) {
    return calculate(FUNC_G, i);
}

int main() {
    int n = 5;
    std::cout << "f(" << n << ") = " << f_non_recursive(n) << std::endl;
    std::cout << "g(" << n << ") = " << g_non_recursive(n) << std::endl;
    return 0;
}
~~~
汉诺塔问题其实也类似。<br>
这是汉诺塔问题的递归写法:
~~~cpp
#include<iostream>
#include<stack>
using namespace std;

// 定义操作状态枚举，用于模拟递归过程中的不同阶段
enum Operation{
    MOVE_N_1_TO_AUX,  // 将n-1个盘子从源柱移动到辅助柱
    MOVE_N_TO_TAR,    // 将第n个盘子（最大的）从源柱移动到目标柱
    MOVE_AUX_TO_TAR,  // 将n-1个盘子从辅助柱移动到目标柱
    RETURN           // 当前操作完成，返回结果
};

// 定义栈帧结构体，存储每次"函数调用"的状态和参数
struct StackFrame{
    int n;           // 当前要移动的盘子数量
    char source;     // 源柱子
    char auxiliary;  // 辅助柱子
    char target;     // 目标柱子
    Operation state; // 当前执行状态
    int result;      // 存储移动次数结果
};

// 非递归实现汉诺塔问题，返回值为移动次数
int Hanoi(int n, char source, char auxiliary, char target){
    // 创建调用栈，用于模拟递归过程
    stack<StackFrame> callStack;
    
    // 将初始调用推入栈中，初始状态为移动n-1个盘子到辅助柱
    callStack.push({n, source, auxiliary, target, MOVE_N_1_TO_AUX, 0});
    
    // 存储最终结果（总移动次数）
    int finalResult = 0;
    
    // 当栈不为空时，继续处理
    while(!callStack.empty()){
        // 引用栈顶元素以便修改
        StackFrame &top = callStack.top();
        
        // 根据当前状态执行相应操作
        switch (top.state){
            case MOVE_N_1_TO_AUX:{
                // 基本情况：只有一个盘子时，直接移动到目标柱
                if(top.n == 1){
                    cout << top.source << "->" << top.target << endl;
                    top.result = 1;  // 记录移动一次
                    top.state = RETURN;  // 设置状态为返回
                }else{
                    // 将n-1个盘子从源柱移到辅助柱（先记录下一步操作）
                    top.state = MOVE_N_TO_TAR;  // 更新当前栈帧的下一状态
                    
                    // 创建新的栈帧处理子问题：将n-1个盘子从source移到auxiliary，以target为辅助
                    callStack.push({top.n - 1, top.source, top.target, top.auxiliary, MOVE_N_1_TO_AUX, 0});
                }
                break;
            }
            case MOVE_N_TO_TAR:{
                // 将第一子问题的结果加到当前结果中
                top.result += finalResult;
                
                // 更新状态为移动辅助柱上的盘子到目标柱
                top.state = MOVE_AUX_TO_TAR;
                
                // 移动最大的盘子从源柱到目标柱
                cout << top.source << "->" << top.target << endl;
                top.result++;  // 记录这次移动
                
                // 创建新的栈帧处理第二子问题：将n-1个盘子从auxiliary移到source，以target为辅助
                callStack.push({top.n - 1, top.auxiliary, top.source, top.target, MOVE_N_1_TO_AUX, 0});
                break;
            }
            case MOVE_AUX_TO_TAR:{
                // 将第二子问题的结果加到当前结果中
                top.result += finalResult;
                
                // 所有操作完成，设置状态为返回
                top.state = RETURN;
                break;
            }
            case RETURN:{
                // 保存当前栈帧的结果
                finalResult = top.result;
                
                // 弹出已完成的栈帧
                callStack.pop();
            }
        }
    }
    
    // 返回汉诺塔问题的总移动次数
    return finalResult;
}

int main(){
    // 设置盘子数量
    int n = 3;
    
    // 调用Hanoi函数，设定三根柱子为A、B、C
    int result = Hanoi(n, 'A', 'B', 'C');
    
    // 输出移动总次数
    cout << "count:" << result;
    return 0;
}
~~~

