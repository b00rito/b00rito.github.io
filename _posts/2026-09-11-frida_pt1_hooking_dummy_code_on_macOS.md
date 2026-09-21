---
title: "Frida (Part 1): hooking dummy code on macOS"
date: 2026-09-11 21:20:00
categories: [Frida]
tags: [frida, macos, arm64, hooking, dynamic-instrumentation,
      reverse-engineering, javascript]
description: >-
    A hands-on introduction to Frida on macOS/arm64: Intercepting functions
    in a C program, investigating a PAC-related crash and using Stalker as
    a proper solution.
---

This is an introductory blog about frida hooking on macOS. It has been a
few years since I used frida last time, so I would like to refresh my
knowledge a bit and also present it. For the purpose of this blog we will
write dummy programs to play with and monitor their behavior.

`Frida` is an open source dynamic instrumentation toolkit that injects a
JavaScript runtime in a target process. This allows us to inject our own
scripts into the process and intercept any function; also called as
hooking. This gives the potential to bypass checks, replace functions and
trace application code.

We might explore what hooking is and how it works in a future post.

We can install the `frida` toolkit via `pip`:
```bash
$ pip3 install frida-tools
```

The version we are currently working on is:
```bash
$ frida --version
```

## Hooking a C program

### Basic hooking
Let's start with the very basics. We will write a simple program in C that
is printing a string based on the return value of a function. The printing
is repeated in an endless loop:

```c
// clang -o hello_world.c.bin hello_world.c -O0
#include <stdio.h>
#include <unistd.h>

int checkValueA() {
    return 0;
}

int checkValueB() {
    return 1;
}

int checkValueC(uint32_t input) {
    uint32_t res = input << 2;

    printf("[+] Calculation is: %d\n", res);

    return (res & 0xdeadbeef);
}

int
main()
{
    printf("[+] PID: %d\n", getpid());

    while (1) {
        int result = checkValueA();

        if (result) {
            printf("\t:)\n");
        } else {
            printf("\t:(\n");
        }

        sleep(2);
    }

    return 0x14;
}
```

In this example we will set 2 objectives. First we will hook the
`checkValueA` function to `return 1`. This will cause the program to print
the desired `":)"` smily face. Secondly we will try to break out of the
loop once the result is `1` - after the smily is printed for the first
time. This will also terminate the process.

The code can be compiled with command shown in the comment in the first
line. We are using the `-O0` for the compiler to not optimize our target
function in inline assembly instructions. The symbols are not stripped from
the binary, so we are expecting to find a `checkValueA` function name and
the respective disassembly of returning 0x0:

```bash
$ otool -tV hello_world.c.bin | grep -A4 'checkValue'
3:_checkValueA:
4-0000000100003e70      mov     w0, #0x0
5-0000000100003e74      ret
6:_checkValueB:
7-0000000100003e78      mov     w0, #0x1
8-0000000100003e7c      ret
9:_checkValueC:
10-0000000100003e80     sub     sp, sp, #0x20
11-0000000100003e84     stp     x29, x30, [sp, #0x10]
12-0000000100003e88     add     x29, sp, #0x10
13-0000000100003e8c     stur    w0, [x29, #-0x4]
...
44:0000000100003f04     bl      _checkValueA
45-0000000100003f08     str     w0, [sp, #0x8]
46-0000000100003f0c     ldr     w8, [sp, #0x8]
47-0000000100003f10     subs    w8, w8, #0x0
48-0000000100003f14     cset    w8, eq
```
The `checkValueA` disassembly is there, alongside the callsite.

Now we are sure that the function exists and we can get the module and
symbol by name:
```javascript
const moduleName = 'hello_world.c.bin'
const targetFuncName = 'checkValueA'

const module = Process.getModuleByName(moduleName)
const targetFuncPtr = module.getSymbolByName(targetFuncName)

console.log("[+]", targetFuncName, "found at:", targetFuncPtr);
```

After obtaining the function address, we can use the `Interceptor` to
attach to it and do the trick of replacing the code to `return 1`:

```javascript
Interceptor.replace(targetFuncPtr, new NativeCallback(function () {
    return 1;
}, 'bool', []));

```

We can also enclose it in a `try/catch` statement. `Interceptor.replace`
patches the function's entry point to jump into our NativeCallback instead
of executing the original function body, which is never executed until the
`Interceptor` is reverted. The patching takes place in the process memory
during runtime; it is not permanent.

Before and after the function replacement we can actually print the first
16 bytes of the function and verify that the opcodes actually changed.

Putting all these together we end up with a script that looks like:

**`hook_hello_world_01_simple.js`**:
```javascript
const moduleName = 'hello_world.c.bin'
const targetFuncName = 'checkValueA'

const module = Process.getModuleByName(moduleName)
const targetFuncPtr = module.getSymbolByName(targetFuncName)

console.log("[+]", targetFuncName, "found at:", targetFuncPtr);
console.log("[*] Before:");
logInsn(targetFuncPtr, 1);
logInsn(targetFuncPtr.add(0x4), 1);
logInsn(targetFuncPtr.add(0x8), 1);

try {
    Interceptor.replace(targetFuncPtr, new NativeCallback(function () {
        return 1;
    }, 'bool', []));

    console.log("[*] replace() returned normally");
} catch (e) {
    console.log("[!] replace() threw:", e);
}

console.log("[*] After:");
logInsn(targetFuncPtr, 1);
logInsn(targetFuncPtr.add(0x4), 1);
logInsn(targetFuncPtr.add(0x8), 1);
```

To make our lives easier we can create a separate script and name it
`utils.js`, in which we can have a logging function to properly log the
disassembly of an address:

**`utils.js`**:
```javascript
function logInsn(address, tabCnt, printModuleAndFuncName = false) {
    const tabs = '\t'.repeat(tabCnt);
    const insn = Instruction.parse(address);
    const rawBytes = address.readByteArray(insn.size);
    const opcodes = Array.from(new Uint8Array(rawBytes))
        .map(b => b.toString(16).padStart(2, '0'))
        .join('');

    if (printModuleAndFuncName) {
        const mod = Process.findModuleByAddress(address);
        const modName = mod ? mod.name : "??";

        let funcName = "??";

        if (mod) {
            let best = null;

            for (const sym of mod.enumerateSymbols()) {
                if (sym.address.compare(address) <= 0) {
                    if (best === null || sym.address.compare(best.address) > 0) {
                        best = sym;
                    }
                }
            }
            if (best) funcName = best.name;
        }
        console.log(tabs + modName + ":" + funcName, "0x" + address.toString(16) + ":", opcodes, "|", insn);
    } else {
        console.log(tabs + "0x" + address.toString(16) + ":", opcodes, "|", insn);
    }
}
```

The utils script has to be loaded alongside the hook script.

### Running the script and reading the output

To run the hook script we will use 2 different shells. In the first shell
we will run the binary. It will print its `PID` and then start printing the
sad face `:(`. What a shame!

**Terminal 1:**
```bash
$ ./hello_world.c.bin
[+] PID: 82924
        :(
        :(
        :(
        ...
```

In the second shell we run the frida command and inject our script in the
running process:

**Terminal 2:**
```bash
$ frida -p $(pgrep hello_world.c.bin) -l utils.js -l hook_hello_world_01_simple.js
     ____
    / _  |   Frida 17.12.0 - A world-class dynamic instrumentation toolkit
   | (_| |
    > _  |   Commands:
   /_/ |_|       help      -> Displays the help system
   . . . .       object?   -> Display information about 'object'
   . . . .       exit/quit -> Exit
   . . . .
   . . . .   More info at https://frida.re/docs/home/
   . . . .
   . . . .   Connected to Local System (id=local)
Attaching...
[+] checkValueA found at: 0x104017e70
[*] Before:
        0x104017e70: 00008052 | mov w0, #0
        0x104017e74: c0035fd6 | ret
        0x104017e78: 20008052 | mov w0, #1
[*] After:
        0x104017e70: 101c00b0 | adrp x16, #0x104398000
        0x104017e74: 00021fd6 | br x16
        0x104017e78: 20008052 | mov w0, #1
[Local::PID::82924 ]->
```

After this, back in the first shell the output will change to the smily
face; phew!

**Terminal 1:**
```bash
        ...
        :(
        :(
        :)
        :)
        ...
```

A few things to comment on the hook script's output:
- The `checkValueA`'s address is what we saw on the `otool` output, if we
    take into account the aslr slide.
- The replace returned normally without any exception.
- The `checkValueA` opcode indeed change. They are actually translated to
    the following assembly instructions:
    before:
    ```arm64
        mov w0, #0          ; checkValueA
        ret 
        mov w0, #1          ; checkValueB
        ret 
    ```

    after:
    ```arm64
        adrp x16, #0x291000 ; checkValueA
        br x16
        mov w0, #1          ; checkValueB
        ret 
    ```
In the "before" assembly, everything is as expected. In the "after",
however, there is a weird indirect branch that has replaced the function.
As we will see in detail in a different post, this is how `frida`
implements the hooking mechanism - by injecting a branch to a different
location that contains the actual hook instructions.

Let's now proceed to the second objective of this example, which is to
print the smily only once, keeping the `checkValueA` hook.

We can take two approaches here.

The first and the simplest is specific to our case, since we have the code
and it does something very very simple. Looking at the source, there is no
other code besides the sleep and the loop that does the printing. The
easiest way to end the loop and terminate the process would be to monitor
the `printf` function and when we spot the smiley in its arguments force an
`exit()`.

The `exit()` function is part of `libSystem.B.dylib` - the macOS/iOS `libc`
- which is always loaded in our program. We can locate its address in the
process and use the `NativeFunction` to wrap the native address to a
callable JS function.

To monitor whether a smiley is printed, we can hook `printf()` and use the
interceptor's `onEnter()` and `onLeave()` callbacks. Using the `onEnter()`
we can stash the format string argument of `printf()` and then use
`onLeave()` to check whether it contains the smiley. In case it does, it
means that it was printed on the screen so we can call `exit()`.

Putting all these together in a simplified script:

**`hook_hello_world_02_print_once_and_exit.js`**:
```javascript
const moduleName = 'hello_world.c.bin'
const targetFuncName = 'checkValueA'

const module = Process.getModuleByName(moduleName)
const targetFuncPtr = module.getSymbolByName(targetFuncName)

const printfPtr = Module.getGlobalExportByName("printf");
const exitPtr = Module.getGlobalExportByName("exit");

const exitFn = new NativeFunction(exitPtr, 'void', ['int']);

console.log("[+]", targetFuncName, "found at:", targetFuncPtr);
console.log("[+] printf() found at:", printfPtr);
console.log("[+] exit() found at:", exitPtr);

Interceptor.replace(targetFuncPtr, new NativeCallback(function () {
    return 1;
}, 'bool', []));
console.log("[*] replace() returned normally");

Interceptor.attach(printfPtr, {
    onEnter(args) {
        // Stash the format string for onLeave
        this.fmt = args[0].readUtf8String();
    },
    onLeave(retval) {
        if (this.fmt && this.fmt.includes(':)')) {
            console.log("[*] :) printed once - exiting with status 0x14");
            exitFn(0x14);
        }
    }
});
```

Running the script as we did earlier, we can see:

**Terminal 1:**
```bash
$ ./hello_world.c.bin
[+] PID: 90071
        :(
        :(
        :(
        :)
$
```

**Terminal 2:**
```bash
$ frida -p $(pgrep hello_world.c.bin) -l hook_hello_world_02_print_once_and_exit.js
     ____
    / _  |   Frida 17.12.0 - A world-class dynamic instrumentation toolkit
   | (_| |
    > _  |   Commands:
   /_/ |_|       help      -> Displays the help system
   . . . .       object?   -> Display information about 'object'
   . . . .       exit/quit -> Exit
   . . . .
   . . . .   More info at https://frida.re/docs/home/
   . . . .
   . . . .   Connected to Local System (id=local)
Attaching...
[+] checkValueA found at: 0x104797e70
[+] printf() found at: 0x187ca82b4
[+] exit() found at: 0x187ca3044
[*] replace() returned normally
[Local::PID::90071 ]-> Process terminated
[Local::PID::90071 ]->

Thank you for using Frida!
```

And voila! Smiley printed once and then process exits.

### Approach 2
The second approach is more generic and requires a bit of assembly reading.
We will try to intercept the callsite of the `printf()` - in this case
`main()` - in order to make it break out of the loop. This could make the
program to execute any other code that could potentially exist after the
loop and thus makes it a stronger approach.

Let's explore `main`'s disassembly first:
```bash
$ otool -tV hello_world.c.bin | grep -A30 'main'
31:_main:
32-0000000100003ed4     sub     sp, sp, #0x20
33-0000000100003ed8     stp     x29, x30, [sp, #0x10]
34-0000000100003edc     add     x29, sp, #0x10
35-0000000100003ee0     stur    wzr, [x29, #-0x4]
36-0000000100003ee4     bl      0x100003f58 ; symbol stub for: _getpid
37-0000000100003ee8     mov     x9, sp
38-0000000100003eec     mov     x8, x0
39-0000000100003ef0     str     x8, [x9]
40-0000000100003ef4     adrp    x0, 0 ; 0x100003000
41-0000000100003ef8     add     x0, x0, #0xf89 ; literal pool for: "[+] PID: %d\n"
42-0000000100003efc     bl      0x100003f4c ; symbol stub for: _printf
43-0000000100003f00     b       0x100003f04
44-0000000100003f04     bl      _checkValueA
45-0000000100003f08     str     w0, [sp, #0x8]
46-0000000100003f0c     ldr     w8, [sp, #0x8]
47-0000000100003f10     subs    w8, w8, #0x0
48-0000000100003f14     cset    w8, eq
49-0000000100003f18     tbnz    w8, #0x0, 0x100003f30
50-0000000100003f1c     b       0x100003f20
51-0000000100003f20     adrp    x0, 0 ; 0x100003000
52-0000000100003f24     add     x0, x0, #0xf96 ; literal pool for: "\t:)\n"
53-0000000100003f28     bl      0x100003f4c ; symbol stub for: _printf
54-0000000100003f2c     b       0x100003f40
55-0000000100003f30     adrp    x0, 0 ; 0x100003000
56-0000000100003f34     add     x0, x0, #0xf9b ; literal pool for: "\t:(\n"
57-0000000100003f38     bl      0x100003f4c ; symbol stub for: _printf
58-0000000100003f3c     b       0x100003f40
59-0000000100003f40     mov     w0, #0x2
60-0000000100003f44     bl      0x100003f64 ; symbol stub for: _sleep
61-0000000100003f48     b       0x100003f04
```

Something interesting is going on here. Even though we compiled using the
`-O0` flag to avoid any compiler optimizations, the compiler recognizes the
endless loop and omitted the unreachable epilogue entirely. This would
happen for any other code that we could append after the loop, the compiler
optimizes it. Not sure why, maybe we will investigate in the future. This
is a fundamental constraint because we cannot naturally return from main by
patching the back-branch when main has not emitted such a return path. Any
attempt to do so is inventing instructions that the compiler chose not to
generate.

What we could try here is to patch the "loop" `b 0x100003f04` instruction
at `0x100003f48` to a simple `ret`. This will cause the loop to break after
the sleep and actually exit the process.

A way to accomplish this is via the `sleep()` call since it precedes. If we
hook that function and use the `onEnter()` callback, we can actually get
the return address in the `main()` that `sleep()` has to jump back to once
it finishes executing. That jump-back address is none other than
`0x100003f48`

**`hook_hello_world_03_patch_backbranch.js`**:
```javascript
const moduleName = 'hello_world.c.bin'
const targetFuncName = 'checkValueA'

const module = Process.getModuleByName(moduleName)
const targetFuncPtr = module.getSymbolByName(targetFuncName)

const printfPtr = Module.getGlobalExportByName("printf");
const sleepPtr = Module.getGlobalExportByName("sleep");

console.log("[+]", targetFuncName, "found at:", targetFuncPtr);
console.log("[+] printf() found at:", printfPtr);
console.log("[+] sleep() found at:", sleepPtr);

let smileyPrinted = false;

Interceptor.replace(targetFuncPtr, new NativeCallback(function () {
    return 1;
}, 'bool', []));

console.log("[*] replace() returned normally");

Interceptor.attach(printfPtr, {
    onEnter(args) {
        // Stash the format string for onLeave
        this.fmt = args[0].readUtf8String();
    },
    onLeave(retval) {
        if (this.fmt && this.fmt.includes(':)') && !smileyPrinted) {
            smileyPrinted = true;
            console.log("[*] :) printed once - proceed to patching");
        }
    }
});

Interceptor.attach(sleepPtr, {
    onEnter(args) {
        // Stash the return address
        this.retAddr = this.returnAddress;
        console.log(`[*] sleep(${args[0].toInt32()}) called and will return to ${this.retAddr}`);

        if (!smileyPrinted) {
            return;
        }

        console.log(`[*] lr at sleep() call: ${this.context.lr}`);
    },
    onLeave(retval) {
        // smiley not printed yet
        if (!smileyPrinted) {
            return;
        }

        console.log(`[*] Patching back-branch at ${this.retAddr} to RET`);

        Memory.patchCode(this.retAddr, 4, code => {
            new Arm64Writer(code, { pc: this.retAddr }).putRet();
        });

        console.log("[*] After:");
        logInsn(this.retAddr, 1);
        console.log("[*] Loop will break and return");
    }
});
```

And we execute it as usual:

**Terminal 1:**
```bash
$ ./hello_world.c.bin
[+] PID: 24858
        :(
        :(
        :(
        :)
[1]    24858 segmentation fault  ./hello_world.c.bin
```

**Terminal 2:**
```bash
$ frida -p $(pgrep hello_world.c.bin) -l utils.js -l hook_hello_world_03_patch_backbranch.js
     ____
    / _  |   Frida 17.12.0 - A world-class dynamic instrumentation toolkit
   | (_| |
    > _  |   Commands:
   /_/ |_|       help      -> Displays the help system
   . . . .       object?   -> Display information about 'object'
   . . . .       exit/quit -> Exit
   . . . .
   . . . .   More info at https://frida.re/docs/home/
   . . . .
   . . . .   Connected to Local System (id=local)
Attaching...
[+] checkValueA found at: 0x102737e70
[+] printf() found at: 0x187ca82b4
[+] sleep() found at: 0x187c923c8
[*] replace() returned normally
[Local::PID::24858 ]-> [*] :) printed once - proceed to patching
[*] sleep(2) called and will return to 0x102737f48
[*] lr at sleep() call: 0x102737f48
[*] Patching back-branch at 0x102737f48 to RET
[*] After:
        0x102737f48: c0035fd6 | ret
[*] Loop will break and return
Process terminated
[Local::PID::24858 ]->

Thank you for using Frida!
```

Aaand this fails with a segfault! What the hell? Let's investigate...

We simply replaced a branch instruction with a return instruction. Without
getting into much details or semantics, in ARM64 assembly `ret` is just `br
X30`. The code was supposed to branch to a predefined address in the `main`
function - `0x100003f04`. However we patched the instruction, forcing it to
jump to `X30`. All we have to do is figure out what `X30` contains and
patch this as well if possible. Before our patch point, there is the `bl
0x100003f64` instruction that branches to `sleep()`. If we inspect the
disassembly of the last instructions of `sleep()` we see the something like
this:

```arm64
0x187c923c8 <+0>:   pacibsp
0x187c923cc <+4>:   sub    sp, sp, #0x40
0x187c923d0 <+8>:   stp    x20, x19, [sp, #0x20]
0x187c923d4 <+12>:  stp    x29, x30, [sp, #0x30]
0x187c923d8 <+16>:  add    x29, sp, #0x30
...
0x187c92444 <+124>: mov    x0, x19
0x187c92448 <+128>: ldp    x29, x30, [sp, #0x30]    ; restore x30 from stack
0x187c9244c <+132>: ldp    x20, x19, [sp, #0x20]
0x187c92450 <+136>: add    sp, sp, #0x40
0x187c92454 <+140>: retab                           ; authenticate x30 and branch to it
```

In the prologue `X30` is stored on the stack. Later in the epilogue it is
loaded again and the `retab` instruction branches to it (let's ignore the
PAC variant for simplicity).

Here is a walk through of what happens to `X30`:
1. main's loop executes `bl _sleep`
    - `X30` = address of next instruction in main (`0x100003f48`) = our
      patch location
    - CPU jumps to sleep
2. sleep's prologue:
    - creates a stack frame
    - saves `X30` onto the stack
3. sleep does its work ...
4. sleep's epilogue:
    - restores `X30` from stack
    - branches to `X30` = `&(b loop_start)` = our patch location
5. CPU arrives at our patch location
    - `X30` = our patch location    -> THIS is the problem
    - `ret` = `br X30`              -> branches to itself

At the patch site, `X30` holds the address of the patch site itself, which
creates an infinite loop branching to itself.

On Apple Silicon arm64e this gets worse. `retab` has to authenticate `X30`
before branching to it. This means that whatever is stored in this register
is going to be treated as a signed pointer. If `X30` was overwritten with
something that wasn't properly signed, the authentication will fail.

To verify this claim we can use `onEnter` alongside `this.context` to view
the CPU registers *before* `sleep()`'s own prologue runs:

```javascript
Interceptor.attach(sleepPtr, {
    onEnter(args) {
        if (!smileyPrinted) {
            return;
        }

        console.log(`[*] lr at this sleep() call: ${this.context.lr}`);
    }
});
```

Running this confirms the claim we made reading the disassembly.
`this.context.lr` at that call is the address of the loop's back-branch.

Our next move will be to overwrite `X30` right before `sleep()` returns.

What would be a value that fits though? Since `main` has its epilogue
stripped by the compiler, we could find its caller and directly jump there.
`main()` is actually invoked from `dyld`'s `start()`, so that is our
landing spot.

But how can we locate that address? `main()`'s prologue already saved its
caller's `LR` on the stack and when `sleep()` is called we are still inside
the same `main()` call, meaning `this.context.fp` contains main's frame
pointer. No need to hook `main()`'s entry separately, we can just read it
back off the stack. When we use `onEnter()` API in `sleep`, its stack has
not yet been set - basically we are dealing with `main`s stack frame. So it
is a bit easier to read the stack "backwards" and locate the address that
main has to return to. From what we saw in the disassembly of `main()`
earlier, in the prologue the stack's frame is created. Its size is `0x20`
bytes. `SP` is always pointing at the top of the stack, so the saved `X30`
would be at `SP+0x18` if the stack doesn't change. This makes `SP` a bit
fluid. We have to either keep track of where it points or prefer to use
`X29`, which is the frame pointer that gets updated at the prologue and
never again touched. `X29` points at the bottom of the stack, after the
caller's `X29` and `X30` are stored. This makes `X29` to be only `0x8`
bytes away from the `X30` that was stored in `main`'s prologue. This value
is the `start`'s address that `main` has to jump back to when it returns.

For the actual patching instruction, we will use the `onLeave` API, right
before `retab` runs, and try to update the value of `LR` using
`this.context.lr`. The value in `LR` isn't a plain address, rather it's
`sleep()`'s return address, but PAC *signed*. It is loaded from the stack,
where `pacibsp` signed and stored it in the prologue. Overwriting it with a
plain unsigned address and calling `retab` will try to authenticate
garbage. Keeping that in mind, we will replace the `retab` with a plain
`ret`, just for this one call, right as we enter `sleep()`.

**`hook_hello_world_04_overwrite_sleep_retab.js`**:
```javascript
const moduleName = 'hello_world.c.bin'
const targetFuncName = 'checkValueA'

const module = Process.getModuleByName(moduleName)
const targetFuncPtr = module.getSymbolByName(targetFuncName)

const printfPtr = Module.getGlobalExportByName("printf");
const sleepPtr = Module.getGlobalExportByName("sleep");

let smileyPrinted = false;
let retabPatched = false;

console.log("[+]", targetFuncName, "found at:", targetFuncPtr);
console.log("[+] printf() found at:", printfPtr);
console.log("[+] sleep() found at:", sleepPtr);

console.log("[*] sleep prologue:");
logInsn(sleepPtr, 1);
logInsn(sleepPtr.add(0x4), 1);
logInsn(sleepPtr.add(0x8), 1);

function findRetab(funcStart, maxInsns) {
    let p = funcStart;

    for (let i = 0; i < maxInsns; i++) {
        const insn = Instruction.parse(p);

        if (insn.mnemonic === 'retab' || insn.mnemonic === 'retaa') {
            return insn.address;
        }
        p = insn.next;
    }
    throw new Error('retab not found');
}

const retabAddr = findRetab(sleepPtr, 60);

console.log("[+] sleep()'s retab found. Before patching:");
logInsn(retabAddr, 1);

const dyld = Process.getModuleByName('dyld');
const startFuncAddr = dyld.enumerateSymbols().filter(s => s.name === 'start')[0].address;

console.log("[+] dyld 'start' found at:", startFuncAddr, "(dyld base:", dyld.base, ")");

Interceptor.replace(targetFuncPtr, new NativeCallback(function () {
    return 1;
}, 'bool', []));

console.log("[*] replace() returned normally");

Interceptor.attach(printfPtr, {
    onEnter(args) {
        this.fmt = args[0].readUtf8String();
    },
    onLeave(retval) {
        if (this.fmt && this.fmt.includes(':)') && !smileyPrinted) {
            smileyPrinted = true;
            console.log("[*] :) printed once - proceed to patching");
        }
    }
});

Interceptor.attach(sleepPtr, {
    onEnter(args) {
        if (!smileyPrinted) {
            return;
        }

        console.log("[*] sleep() onEnter - x30 (lr):", this.context.lr);
        console.log("[*] Disassembling this address (main's back-branch):")
        logInsn(this.context.lr, 1);

        const mainFp = this.context.fp;
        this.mainReturnAddr = mainFp.add(0x8).readPointer();      // start's address
        this.callerFp = mainFp.readPointer();
        this.mainSp = mainFp.add(0x10);
        this.shouldRedirect = true;

        console.log("[*] target lr (main's real caller):", this.mainReturnAddr);
        logInsn(this.mainReturnAddr.sub(4), 1);
        logInsn(this.mainReturnAddr, 1);

        console.log("[*] mains's stack:", mainFp, "to", this.mainSp);

        if (!retabPatched) {
            console.log("[*] patching sleep's retab to ret");

            Memory.patchCode(retabAddr, 4, code => {
                new Arm64Writer(code, { pc: retabAddr }).putRet();
            });
            retabPatched = true;

            console.log("[*] retab bytes after patching:");
            logInsn(retabAddr, 1);
        }
    },
    onLeave(retval) {
        if (!this.shouldRedirect) {
            return;
        }

        console.log("[*] onLeave - x30 (lr) before we touch it:", this.context.lr);

        this.context.lr = this.mainReturnAddr;
        this.context.sp = this.mainSp;
        this.context.fp = this.callerFp;

        console.log("[*] onLeave - x30 (lr) after we set it:", this.context.lr);
        console.log("[*] sp now:", this.context.sp, "fp now:", this.context.fp);
    }
});
```

Running it:

**Terminal 1:**
```bash
$ ./hello_world.c.bin
[+] PID: 85161
        :(
        :(
        :(
        :)
[1]    85161 segmentation fault  ./hello_world.c.bin
```

**Terminal 2:**
```bash
$ frida -p $(pgrep hello_world.c.bin) -l utils.js -l hook_hello_world_04_overwrite_sleep_retab.js
     ____
    / _  |   Frida 17.12.0 - A world-class dynamic instrumentation toolkit
   | (_| |
    > _  |   Commands:
   /_/ |_|       help      -> Displays the help system
   . . . .       object?   -> Display information about 'object'
   . . . .       exit/quit -> Exit
   . . . .
   . . . .   More info at https://frida.re/docs/home/
   . . . .
   . . . .   Connected to Local System (id=local)
Attaching...
[+] checkValueA found at: 0x102843e70
[+] printf() found at: 0x187ca82b4
[+] sleep() found at: 0x187c923c8
[*] sleep prologue:
        0x187c923c8: 7f2303d5 | pacibsp
        0x187c923cc: ff0301d1 | sub sp, sp, #0x40
        0x187c923d0: f44f02a9 | stp x20, x19, [sp, #0x20]
[+] sleep()'s retab found. Before patching:
        0x187c92454: ff0f5fd6 | retab
[+] dyld 'start' found at: 0x187a5a7a8 (dyld base: 0x187a55000 )
[*] replace() returned normally
[Local::PID::85161 ]-> [*] :) printed once - proceed to patching
[*] sleep() onEnter - x30 (lr): 0x102843f48
[*] Disassembling this address (main's back-branch):
        0x102843f48: efffff17 | b #0x102843f04
[*] target lr (main's real caller): 0x187a5b154
        0x187a5b150: 9f0a3fd6 | blraaz x20
        0x187a5b154: f40300aa | mov x20, x0
[*] mains's stack: 0x16d5bf130 to 0x16d5bf140
[*] patching sleep's retab to ret
[*] retab bytes after patching:
        0x187c92454: c0035fd6 | ret
Process terminated
[Local::PID::85161 ]->

Thank you for using Frida!
```

And we segfault again! If we notice the log messages in the script and what
is actually printed, the log messages used in `sleep`'s `onLeave` are not
shown at all. When we check the target process's shell, we get:

```bash
$ echo $?
139
```

`139` is `128 + 11` which translates to `SIGSEGV`. This time we are facing
a real crash, and `frida`'s console gave zero indication of it. A crash
report is generated by the OS and we can inspect it to get an idea of what
happened: `~/Library/Logs/DiagnosticReports/hello_world.c.bin-*.ips`.
Reading it with a text editor we can get a lot of valuable information.
However, for our crash the interesting part is this:

```json
"exception" : {
    "codes":"0x0000000000000001, 0x4436800103fc8110",
    "rawCodes":[1,4915256785171677456],
    "type":"EXC_BAD_ACCESS",
    "signal":"SIGSEGV",
    "subtype":"KERN_INVALID_ADDRESS at 0x4436800103fc8110 -> 0x0000000103fc8110 (possible pointer authentication failure)"},
```

The message emphasizes potential PAC failure. This makes total sense taking
into account that we replaced a PAC `retab` instruction with a "non PAC"
`ret` instruction. The loaded `X30` from the stack has a legit PAC code
attached at the address it is holding. The `PAC` is `0xba13` sitting on top
of an address is exactly what a signature tag looks like. The decoded
address would be `0x0000000102dd0110`. However, this address has nothing to
do with `dyld` or `start` function or what we tried to patch it with. Huh?

Maybe this address is relevant to frida's own mechanism implementation.

One idea that immediately comes to mind is to also patch the `pacibsp`
instruction out in `sleep`'s prologue, so `X30` is never PAC signed at all.
This would leave us with a "non PAC" related address of interest, that we
can simply jump to and do the job.

To do so we need to be careful and find the proper spot or do a proper
handling. `sleepPtr` prologue will be replaced by frida with code that
branches to `frida`'s internal trampoline mechanism to handle hooking. This
might be the address that we saw earlier and didn't make much sense. So
using that address and start patching will only make things wrong and
certainly break. The best idea would be to patch the instruction somewhere
at the beginning of the script, where `sleep` is not touched yet. When time
comes for `sleep` to get hooked, it will be pac-independent; at least in
theory xd.

**`hook_hello_world_04_overwrite_sleep_retab_paciasp.js`**:
```javascript
// snippet
console.log("[*] sleep's first insn before patch:");
logInsn(sleepPtr, 1);
logInsn(sleepPtr.add(0x4), 1);
logInsn(sleepPtr.add(0x8), 1);

Memory.patchCode(sleepPtr, 4, code => {
    new Arm64Writer(code, { pc: sleepPtr }).putNop();
});

console.log("[*] pacibsp -> nop done:");
logInsn(sleepPtr, 1);
logInsn(sleepPtr.add(0x4), 1);
logInsn(sleepPtr.add(0x8), 1);

Memory.patchCode(retabAddr, 4, code => {
    new Arm64Writer(code, { pc: retabAddr }).putRet();
});

console.log("[*] retab -> ret done:");
logInsn(retabAddr, 1);
```

Aaaand we crash again!

Similar crash, PAC related.

We need to figure out something else!

### A different idea: sign X30 properly

Since patching `retab` away doesn't work, how about setting `X30` to the
value we want to, at the beginning of `sleep`, before `pacibsp`? The
instruction will simply sign whatever is inside `X30`; it doesn't know
whether that's the real caller's address or something we put there
ourselves. Later, the unmodified `retab` authenticates it correctly and we
have a matched signature, no patching required anywhere. One more thing
that we should take into account fixing are the `SP`/`FP` registers that
keep track of the stack frames. These should be intact in `onEnter` since
sleep has its own stack frame set and used. `onLeave` is the place to go
for such work, when sleep's job is done.

**`hook_hello_world_05_overwrite_sleep_updateX30andsign.js`**:
```javascript
Interceptor.attach(sleepPtr, {
    onEnter(args) {
        if (!smileyPrinted || armed) {
            return;
        }

        armed = true;
        const mainFp = this.context.fp;
        this.mainReturnAddr = mainFp.add(8).readPointer();
        this.callerFp = mainFp.readPointer();
        this.mainSp = mainFp.add(0x10);

        console.log(`[*] onEnter - x30 (lr) right now: ${this.context.lr}`);
        this.context.lr = this.mainReturnAddr;   // before pacibsp runs

        console.log(`[*] onEnter - x30 (lr) after we set it: ${this.context.lr}`);
    },
    onLeave(retval) {
        if (this.mainSp === undefined) {
            return;
        }

        console.log(`[*] onLeave - x30 (lr): ${this.context.lr}`);

        // lr NOT touched here - only sp/fp, late
        this.context.sp = this.mainSp;
        this.context.fp = this.callerFp;
    }
});
```

Nothing else touched. When we run it, we see:

**Terminal 1:**
```bash
$ ./hello_world.c.bin
[+] PID: 99314
        :(
        :(
        :)
        :)
```

**Terminal 2:**
```bash
$ frida -p $(pgrep hello_world.c.bin) -l hook_hello_world_05_overwrite_sleep_updateX30andsign.js
     ____
    / _  |   Frida 17.12.0 - A world-class dynamic instrumentation toolkit
   | (_| |
    > _  |   Commands:
   /_/ |_|       help      -> Displays the help system
   . . . .       object?   -> Display information about 'object'
   . . . .       exit/quit -> Exit
   . . . .
   . . . .   More info at https://frida.re/docs/home/
   . . . .
   . . . .   Connected to Local System (id=local)
[+] checkValueA found at: 0x104ccbe70
[+] printf() found at: 0x187ca82b4
[+] sleep() found at: 0x187c923c8
[+] dyld 'start' found at: 0x187a5a7a8 (dyld base: 0x187a55000 )
[*] replace() returned normally
[Local::PID::99314 ]-> [*] :) printed once - proceed to patching
[*] onEnter - X30 (LR) original: 0x104ccbf48
[*] onEnter - X30 (LR) updated: 0x187a5b154
[*] onLeave - X30 (LR): 0x1f59000106450110
[*] ---
[*] onLeave - SP: 0x16b137120
[*] onLeave - FP: 0x16b137130
[*] onLeave - new SP: 0x16b137140
[*] onLeave - new FP: 0x16b137360
```

What happens to `X30` here? The value is totally different! `onEnter` sets
it, and by `onLeave` it's already something else. `onLeave`'s own body is
just logging it, nothing written to `X30`. Are we facing a frida internal
issue once again? An intuitive thought would be that declaring an `onLeave`
handler on a function that ends in `retab` makes frida to place its own
address into `X30` before `pacibsp` ever runs. Doesn't matter what
`onLeave`'s body does or doesn't do with `X30` - the damage might have
happen earlier than that.

Damn!

### A detour: don't touch `sleep()` at all

One more idea would be to create our own small trampoline, from `sleep()`'s
`onEnter()`. The trampoline will be quite simple and use `br` instruction
to jump to main's caller, after `sleep` will have been executed normally.
The idea is to forcefully jump back to `start` and make the process finish
execution.

The trampoline assembly looks like this:
```arm64
ldr X16, mainReturnAddress
ldr X17, callerFp
mov X29, X17
ldr X17, mainSP
mov SP, X17
br X16
```

The trampoline exists to put the CPU into the state main's caller expects,
then jump there without ever touching `X30`/`retab`. `X29` gets restored to
the caller's frame. `SP` is set last since changing it is the point of no
return. At the end we are using `BR X16` since we already know the exact
destination.

**`hook_hello_world_06_detour.js`**:
```javascript
// snippet
const trampoline = Memory.alloc(64);
const w = new Arm64Writer(trampoline, { pc: trampoline });

w.putLdrRegAddress('x16', mainReturnAddr);
w.putLdrRegAddress('x17', callerFp);
w.putMovRegReg('x29', 'x17');
w.putLdrRegAddress('x17', mainSp);
w.putMovRegReg('sp', 'x17');
w.putBrReg('x16');
w.flush();

Memory.protect(trampoline, 64, 'rx');       // hmm

Memory.patchCode(backBranchAddr, 4, code => {
    new Arm64Writer(code, { pc: backBranchAddr }).putBImm(trampoline);
});
```

**Terminal 1:**
```bash
$ ./hello_world.c.bin
[+] PID: 2795
        :(
        :(
        :)
        :)
[1]    2795 bus error  ./hello_world.c.bin
```

**Terminal 2:**
```bash
$ frida -p $(pgrep hello_world.c.bin) -l hook_hello_world_06_detour.js
     ____
    / _  |   Frida 17.12.0 - A world-class dynamic instrumentation toolkit
   | (_| |
    > _  |   Commands:
   /_/ |_|       help      -> Displays the help system
   . . . .       object?   -> Display information about 'object'
   . . . .       exit/quit -> Exit
   . . . .
   . . . .   More info at https://frida.re/docs/home/
   . . . .
   . . . .   Connected to Local System (id=local)
Attaching...
[+] main found at: 0x100f03ed4
[+] checkValueA found at: 0x100f03e70
[+] printf() found at: 0x187ca82b4
[+] sleep() found at: 0x187c923c8
[*] main's loop back-branch: 0x100f03f48
        0x100f03f48: efffff17 | b #0x100f03f04
[+] dyld 'start' found at: 0x187a5a7a8 (dyld base: 0x187a55000 )
[*] replace() returned normally
[Local::PID::2795 ]-> [*] :) printed once - proceed to patching
[*] target: 0x187a5b154 sp: 0x16eeff140 fp: 0x16eeff360
[*] mainFp: 0x16eeff130
[*] trampoline written at: 0x1011594e0
        0x1011594e0: d0000058 | ldr x16, #0x1011594f8
        0x1011594e4: f1000058 | ldr x17, #0x101159500
        0x1011594e8: fd0311aa | mov x29, x17
        0x1011594ec: f1000058 | ldr x17, #0x101159508
        0x1011594f0: 3f020091 | mov sp, x17
        0x1011594f4: 00021fd6 | br x16
[*] main's back-branch redirected to trampoline

Thank you for using Frida!
```

And we crashed again!

At this point we might be a bit low on ideas so we will visit the frida
documentation or maybe have a chit chat with our pal claude to see if we
are missing something...

### Stalker, not Interceptor

`Interceptor` works by patching or relocating specific addresses.
Everything we tried so far was either something frida probably also needed
for its own purposes or something it couldn't safely relocate.

A totally different approach has to be taken, potentially using different
frida APIs, with which we can in theory achieve easier what we want.

Bingo!

`Stalker` is a tool for a different job. It traces a thread's execution
instruction-by-instruction rather than hooking function at entry or exit.
It recompiles each basic block into fresh memory before the thread runs it,
which can also be instrumented. Then redirects execution there transparent
to the target and lets us modify along the way. This means that we are
following the execution order; like live tracing the instruction that get
executed in real time. A significant difference is that it is implemented
as one continuous instrumentation pass instead of two separate hooks.

`Stalker.follow(threadId, { transform })` starts stalking the threadId or
the current thread if omitted.

`transform(iterator)` fires once per instruction:
- `iterator.next()` pulls the next real instruction
- `iterator.keep()` emits that instruction into the recompiled block
- `iterator.putCallout(fn)` injects a JS callback at that point, given a
  `CpuContext`

A basic syntax looks like this:
```javascript
Stalker.follow(threadId, {
    transform(iterator) {
        let insn;
        while ((insn = iterator.next()) !== null) {
            if (insn.address.equals(targetAddr)) {
                iterator.putCallout(context => {
                    // read/write regs
                });
            }
            iterator.keep();
        }
    }
});
```

`Stalker.unfollow(threadId)` and `Stalker.flush()` stop tracing and flush
pending events for cleanup.

If we take a minute to think about this concept, it basically solves all
the problems we had above. As a showcase we will start with the idea of
setting `LR` in `sleep` before `pacibsp` and fix up `SP`/`FP` right before
`retab`:

**`hook_hello_world_07_stalker.js`**:
```javascript
const moduleName = 'hello_world.c.bin'
const targetFuncName = 'checkValueA'

const module = Process.getModuleByName(moduleName)
const targetFuncPtr = module.getSymbolByName(targetFuncName)

const mainPtr = Module.getGlobalExportByName("main");
const printfPtr = Module.getGlobalExportByName("printf");
const sleepPtr = Module.getGlobalExportByName("sleep");

let smileyPrinted = false;

console.log("[+] main() found at:", mainPtr);
console.log("[+]", targetFuncName, "found at:", targetFuncPtr);
console.log("[+] printf() found at:", printfPtr);
console.log("[+] sleep() found at:", sleepPtr);

// sleep's prologue
console.log("[*] sleep prologue:");
logInsn(sleepPtr, 1);
logInsn(sleepPtr.add(0x4), 1);
logInsn(sleepPtr.add(0x8), 1);

function findRetab(funcStart, maxInsns) {
    let p = funcStart;

    for (let i = 0; i < maxInsns; i++) {
        const insn = Instruction.parse(p);

        if (insn.mnemonic === 'retab' || insn.mnemonic === 'retaa') {
            return insn.address;
        }
        p = insn.next;
    }
    throw new Error('retab not found');
}

const retabAddr = findRetab(sleepPtr, 60);
console.log("[+] sleep()'s retab found. Before patching:");
logInsn(retabAddr, 1);

let mainReturnAddr = null;
let callerFp = null;
let mainSp = null;

Interceptor.replace(targetFuncPtr, new NativeCallback(function () {
    return 1;
}, 'bool', []));

console.log("[*] replace() returned normally");

Interceptor.attach(printfPtr, {
    onEnter(args) {
        // Stash the format string for onLeave
        this.fmt = args[0].readUtf8String();
    },
    onLeave(retval) {
        if (this.fmt && this.fmt.includes(':)') && !smileyPrinted) {
            smileyPrinted = true;
            console.log("[*] :) printed once - starting Stalker.follow");

            // create a stalker
            Stalker.follow(Process.getCurrentThreadId(), {
                transform(iterator) {
                    let insn;

                    while ((insn = iterator.next()) !== null) {
                        // logInsn(insn.address, 1, true);

                        if (insn.address.equals(sleepPtr)) {
                            iterator.putCallout(context => {
                                console.log("[*] stalker @ sleep entry - X30:", context.lr);

                                const mainFp = context.fp;
                                mainReturnAddr = mainFp.add(8).readPointer();
                                callerFp = mainFp.readPointer();
                                mainSp = mainFp.add(0x10);

                                // set X30 before pacibsp runs
                                context.lr = mainReturnAddr;

                                console.log("[*] stalker @ sleep entry - updated X30 before pacibsp:", context.lr);
                                console.log("[*] stalker @ sleep entry - target SP:", mainSp, "target FP:", callerFp);
                            });
                        } else if (insn.address.equals(retabAddr)) {
                            iterator.putCallout(context => {
                                if (mainReturnAddr === null) {
                                    return;
                                }

                                console.log("[*] stalker @ retab - X30:", context.lr);

                                context.sp = mainSp;
                                context.fp = callerFp;

                                console.log("[*] stalker @ retab - target SP:", context.sp, "target FP:", context.fp);

                                Stalker.unfollow(Process.getCurrentThreadId());
                            });
                        }
                        iterator.keep();
                    }
                }
            });
        }
    }
});
```

`iterator.keep()` re-emits every instruction unchanged. We are not touching
`pacibsp` or `retab` at all, just slipping a callback in before certain
addresses execute.

When we run it:

**Terminal 1:**
```bash
$ ./hello_world.c.bin
[+] PID: 24895
        :(
        :(
        :)
$ echo $?
0
```

**Terminal 2:**
```bash
$ frida -p $(pgrep hello_world.c.bin) -l utils.js -l hook_hello_world_07_stalker.js
     ____
    / _  |   Frida 17.12.0 - A world-class dynamic instrumentation toolkit
   | (_| |
    > _  |   Commands:
   /_/ |_|       help      -> Displays the help system
   . . . .       object?   -> Display information about 'object'
   . . . .       exit/quit -> Exit
   . . . .
   . . . .   More info at https://frida.re/docs/home/
   . . . .
   . . . .   Connected to Local System (id=local)
Attaching...
[+] main() found at: 0x1005d3ed4
[+] checkValueA found at: 0x1005d3e70
[+] printf() found at: 0x187ca82b4
[+] sleep() found at: 0x187c923c8
[*] sleep prologue:
        0x187c923c8: 7f2303d5 | pacibsp
        0x187c923cc: ff0301d1 | sub sp, sp, #0x40
        0x187c923d0: f44f02a9 | stp x20, x19, [sp, #0x20]
[+] sleep()'s retab found. Before patching:
        0x187c92454: ff0f5fd6 | retab
[*] replace() returned normally
[Local::PID::24895 ]-> [*] :) printed once - starting Stalker.follow
[*] stalker @ sleep entry - X30: 0x1005d3f48
[*] stalker @ sleep entry - updated X30 before pacibsp: 0x187a5b154
[*] stalker @ sleep entry - target SP: 0x16f82f140 target FP: 0x16f82f360
[*] stalker @ retab - X30: 0x1a39800187a5b154
[*] stalker @ retab - target SP: 0x16f82f140 target FP: 0x16f82f360
Process terminated
[Local::PID::24895 ]->
```

The `X30` value at `retab`, after stripping the PAC bits off the front is
`0x187a5b154`, exactly the address we injected. The `pacibsp` indeed did
sign it.

If we uncomment the `logInsn()` call we will see the whole "journey" that
the `stalker` takes until our job is done. Abstractly we can describe it in
the following phases:

Phase 1: unresolved symbols and module name. This is probably frida's own
internal bookkeeping cleaning up after the `printf` `onLeave` callback
returns.

Phase 2: unresolved symbols and module name again. This time there is a big
block of code that reloads every register, `X1-X30`, `Q0-Q31`. It ends with
an indirect jump to `ret X16`. This could be the `Interceptor`'s
context-restore epilogue for the printf hook.

Phase 3: `hello_world.c.bin:main`, the code resumes after the `printf` call
and sets up the sleep duration. Then jumps to the stub for `sleep`, which
will in turn jump to the real `sleep` function in `libsystem`.

Phase 4: `libsystem_c.dylib:sleep`'s actual prologue, which is `sleepPtr`.
The interceptor has already done its job and `X30` is updated before
`pacibsp`.

Phase 5: the mechanism of `sleep` under the hood, invoking system calls and
mach traps to perform the desired behavior.

Phase 6: `sleep`'s epilogue that executes `retab` at `retabAddr`. `SP/FP`
get fixed up and then the stalker's job is over.

Following the stalker approach step by step makes it more clear that this
approach is different and does the job actually. The output of the script
verifies that it ran without any errors and the main process terminated
successfully, printing the smiley exactly one time.

Mission accomplished!

### Play more with the C program

Now we can play a bit more. We will set 2 new objectives to practice.

First we will try to replace the invocation of `checkValueA` with
`checkValueB`, which returns `true` by default.

The second objective will be to replace the invocation of `checkValueA`
with `checkValueC`, after intercepting the function `checkValueC` to return
true. In this case we want to keep the function body intact and only change
the return value to true.

Needless to say that the respective symbols exist in the binary, so we dive
straight into the hook script.

#### Scenario `B`
`checkValueB` takes no arguments and always returns `1`, so if we can make
`main()` call it instead of `checkValueA`, we don't need to touch either
function at all, just the callsite in `main`.

**`hook_hello_world_08_checkValueB.js`**:
```javascript
const moduleName = 'hello_world.c.bin'

const module = Process.getModuleByName(moduleName)
const mainPtr = module.getSymbolByName('main')
const checkValueAPtr = module.getSymbolByName('checkValueA')
const checkValueBPtr = module.getSymbolByName('checkValueB')

console.log("[+] main found at:", mainPtr);
console.log("[+] checkValueA found at:", checkValueAPtr);
console.log("[+] checkValueB found at:", checkValueBPtr);

// walk main's instructions looking for the `bl` that targets funcPtr
function findCallSite(funcStart, targetPtr, maxInsns) {
    let p = funcStart;

    for (let i = 0; i < maxInsns; i++) {
        const insn = Instruction.parse(p);

        if (insn.mnemonic === 'bl' && ptr(insn.opStr.replace('#', '')).equals(targetPtr)) {
            return insn.address;
        }
        p = insn.next;
    }
    throw new Error('call site not found');
}

const callSite = findCallSite(mainPtr, checkValueAPtr, 20);

console.log("[+] bl checkValueA found at:", callSite);

Memory.patchCode(callSite, 4, code => {
    new Arm64Writer(code, { pc: callSite }).putBlImm(checkValueBPtr);
});

console.log("[*] call site patched; checkValueB replaced checkValueA");
```

`Arm64Writer.putBlImm()` emits a real instruction in place. This time
there's no register state to set, because `bl` writes the return address in
`X30` and that address is the instruction after our patch:

**Terminal 1:**
```bash
$ ./hello_world.c.bin
[+] PID: 60430
        :(
        :(
        :)
        :)
        :)
    ...
```

**Terminal 2:**
```bash
$ frida -p $(pgrep hello_world.c.bin) -l hook_hello_world_08_checkValueB.js
     ____
    / _  |   Frida 17.12.0 - A world-class dynamic instrumentation toolkit
   | (_| |
    > _  |   Commands:
   /_/ |_|       help      -> Displays the help system
   . . . .       object?   -> Display information about 'object'
   . . . .       exit/quit -> Exit
   . . . .
   . . . .   More info at https://frida.re/docs/home/
   . . . .
   . . . .   Connected to Local System (id=local)
Attaching...
[+] main found at: 0x104757ed4
[+] checkValueA found at: 0x104757e70
[+] checkValueB found at: 0x104757e78
[+] bl checkValueA found at: 0x104757f04
[*] call site patched; checkValueB replaced checkValueA
[Local::PID::60430 ]-> Process terminated
[Local::PID::60430 ]->

Thank you for using Frida!
```

Back in terminal 1, the sad face never prints again; we patched the
`checkValue` call site so every iteration goes straight to `:)` forever.
The process just keeps running, nothing calls `exit()`.

#### Scenario `C`

Second objective is to use `checkValueC(uint32_t input)`. This function
shifts `input`, prints the result, and returns `input << 2 & 0xdeadbeef`.
We want main() to call it instead of `checkValueA`, *and* we want it to
always count as true, but without losing that `printf`. Using
`Interceptor.replace` would throw away the body along with the check.
`Interceptor.attach`'s `onLeave` would be the right tool here, because we
have to let the real function run and then rewrite just the return value.

**`hook_hello_world_09_checkValueC.js`**:
```javascript
const moduleName = 'hello_world.c.bin'

const module = Process.getModuleByName(moduleName)
const mainPtr = module.getSymbolByName('main')
const checkValueAPtr = module.getSymbolByName('checkValueA')
const checkValueCPtr = module.getSymbolByName('checkValueC')

console.log("[+] main found at:", mainPtr);
console.log("[+] checkValueA found at:", checkValueAPtr);
console.log("[+] checkValueC found at:", checkValueCPtr);

// walk main's instructions looking for the `bl` that targets funcPtr
function findCallSite(funcStart, targetPtr, maxInsns) {
    let p = funcStart;

    for (let i = 0; i < maxInsns; i++) {
        const insn = Instruction.parse(p);

        if (insn.mnemonic === 'bl' && ptr(insn.opStr.replace('#', '')).equals(targetPtr)) {
            return insn.address;
        }
        p = insn.next;
    }
    throw new Error('call site not found');
}

const callSite = findCallSite(mainPtr, checkValueAPtr, 20);

console.log("[+] bl checkValueA found at:", callSite);

// keep checkValueC body intact and only override what it returns
Interceptor.attach(checkValueCPtr, {
    onLeave(retval) {
        console.log("[*] checkValueC initial return value:", retval, "- forcing true");

        retval.replace(1);
    }
});

// patch the call site in main() to call checkValueC
Memory.patchCode(callSite, 4, code => {
    new Arm64Writer(code, { pc: callSite }).putBlImm(checkValueCPtr);
});

console.log("[*] call site patched; checkValueC replaced checkValueA");
```

When we run it, the script never stops, it keeps going:

**Terminal 1:**
```bash
$ ./hello_world.c.bin
[+] PID: 61069
        :(
[+] Calculation is: 0
        :)
[+] Calculation is: 0
        :)
[+] Calculation is: 0
        :)
    ...
```

**Terminal 2:**
```bash
$ frida -p $(pgrep hello_world.c.bin) -l hook_hello_world_09_checkValueC.js
     ____
    / _  |   Frida 17.12.0 - A world-class dynamic instrumentation toolkit
   | (_| |
    > _  |   Commands:
   /_/ |_|       help      -> Displays the help system
   . . . .       object?   -> Display information about 'object'
   . . . .       exit/quit -> Exit
   . . . .
   . . . .   More info at https://frida.re/docs/home/
   . . . .
   . . . .   Connected to Local System (id=local)
Attaching...
[+] main found at: 0x104dffed4
[+] checkValueA found at: 0x104dffe70
[+] checkValueC found at: 0x104dffe80
[+] bl checkValueA found at: 0x104dfff04
[*] call site patched; checkValueC replaced checkValueA
[Local::PID::61069 ]-> [*] checkValueC initial return value: 0x0 - forcing true
[*] checkValueC initial return value: 0x0 - forcing true
[*] checkValueC initial return value: 0x0 - forcing true
[*] checkValueC initial return value: 0x0 - forcing true
...
```

In terminal 1, `checkValueC`'s `printf` message shows up right before every
`:)`. The function's real body is still running, it just never returns
false.

## Epilogue

That wraps up this first post on hooking on macOS. We tried to cover basic
topics on dummy examples, like replacing a function, patching a return
value, redirecting execution, retargeting a call site entirely without
touching anything in the functions. Frida is quite a powerful tool that has
a plethora of functionalities. In a future post we might explore more of
them, like tracing and anti-instrumentation.

Also we might take a moment to look under the hood and explore in depth its
mechanisms.

In the github repo below there are all the scripts with extra logs and a
few comments, which were stripped here for simplicity.

That's all folks!

---
https://frida.re/
https://github.com/b00rito/frida_playground.git
https://armconverter.com/?disasm&code=00+00+80+52%0Ac0+03+5f+d6%0A20+00+80+52%0Ac0+03+5f+d6%0A%0A90+14+00+b0%0A00+02+1f+d6%0A20+00+80+52%0Ac0+03+5f+d6

EOF
