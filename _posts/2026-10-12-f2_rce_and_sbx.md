---
title: "Walls and doors: what RCE and sandbox escape mean in WebKit"
date: 2026-10-12 22:00:00
categories: [WebKit]
tags: [webkit, safari, ios, macos, rce, sandbox-escape, exploit-chains,
      javascriptcore, ipc, lockdown-mode, browser-security]
description: >-
    WebKit, Inside Out: what RCE and SBX mean in WebKit, which process each
    bug lives in, how they combine into exploit chains, and what Lockdown
    Mode takes away.
series: "WebKit, Inside Out"
part: F2
---

WebKit bugs can be distinguished in two categories: an "RCE" and an "SBX".
The core idea behind this is *which process* the bug lives in and *which
wall* it lets an attacker cross. This post defines those words using the
process model from [Inside WebKit: a map of the engine and its
processes]({% post_url 2026-10-11-f1_inside_webkit_the_map %}) [1].

## What is an "RCE"?

In browser security, an **RCE (Remote Code Execution)** usually means that
*a web page can make the WebContent process run attacker controlled code*.
It is called "remote" because all it takes is the victim loading a URL, so
the attack payload is coming from a remote server.

A typical source of a WebContent RCE is memory-safety bugs in code that
processes web content. It means anything a website can send to the browser,
from HTML, CSS and JavaScript to WebAssembly, images, fonts and media.
The main targets are the following:

- **The JavaScript engine (JavaScriptCore).** Especially its optimizing JIT
  compilers, `DFG`/`FTL` for JavaScript [2] and `BBQ`/`OMG` for WebAssembly
  [3]. A JIT (just-in-time compiler) turns frequently run JavaScript or
  WebAssembly into machine code while the page is running. If its
  assumptions about types or object lifetimes are wrong, the generated code
  can misuse memory at full speed.
- **The garbage collector and object lifetimes.** If an object is freed
  while some code still holds a pointer to it, and that pointer is used
  later, we get a use-after-free.
- **Shared infrastructure.** The libpas/bmalloc allocator [4], WTF
  containers, parsers, layout, media decoders.

Getting code execution in WebContent is a big deal on its own. However the
attacker is in the smallest box with the fewest privileges. No network
sockets, no camera, limited files, and on iOS a very restricted set of
reachable system services and kernel APIs [1].

## What is an "SBX"?

An **SBX (sandbox escape)** is any way to turn control of a sandboxed
process into control of something with more privilege. In WebKit terms that
usually means [1]:

- **WebContent -> GPU process**: a bug in GPU-process code that handles
  WebContent's messages. Graphics, WebGL/ANGLE, media and canvas are big
  attack surfaces because they handle large, complex, attacker-shaped
  inputs.
- **WebContent -> UI process**: a bug in the app-side handling of
  `WebPageProxy`/`WebProcessProxy` messages. This is the most valuable,
  because it's the app itself.
- **WebContent -> Networking process**: bugs in storage, cache or loader
  message handling, which could expose other sites' data.
- **Any process -> kernel or system daemon**: OS bugs reachable from the
  sandbox. These are outside WebKit, but often the next link in a chain.

An SBX bug doesn't require the attackers to already control WebContent, but
it's far stronger if they do. A compromised renderer can send *any* IPC
message with *any* arguments, skipping the checks that WebCore would
normally apply before sending. That's why receivers should validate
everything. Any check that lives only on the WebContent side protects
nothing once WebContent is compromised.

## Chains

An attack that combines several bugs is called a chain. A full chain goes
all the way from a web page to kernel code execution. For WebKit, the steps
are:

1. **Renderer RCE.** Memory corruption in WebContent (often JIT or GC),
   turned into code execution. Modern Apple platforms add a lot of
   mitigations there, like pointer authentication (PAC) on arm64e, JIT
   memory that is only writable through tightly controlled paths [5], the
   Gigacage [6] and type-segregated heaps in libpas [4].
2. **Sandbox escape.** From WebContent into the GPU, UI or Networking
   process, or straight into the kernel.
3. **Privilege escalation / persistence.** Usually OS-level, beyond WebKit.

Since 2022 (iOS 16, iPadOS 16 and macOS Ventura), Apple also offers
Lockdown Mode, an optional mode that cuts away risky renderer surfaces.
Apple's announcement says that "Certain complex web technologies, like
just-in-time (JIT) JavaScript compilation, are disabled unless the user
excludes a trusted site from Lockdown Mode" [7][8]. In the WebKit source
code we can see in detail that when a WebContent process is launched in
Lockdown Mode, WebKit's XPC service entry point calls
`JSC::ExecutableAllocator::disableJIT()` and sets `useWasm() = false`,
among other options [9]. So bugs in JSC's JITs and its WebAssembly
implementation are simply unreachable under it.

## Where the walls are

| Wall | What crosses it |
|---|---|
| Web page -> WebContent | Memory-safety bugs in code that processes web content, mostly the JavaScript engine |
| WebContent -> GPU / Networking / UI | Bugs in how those processes handle WebContent's IPC messages |
| WebContent -> anything, without a message | Shared memory, capabilities, direct Mach services |
| WebContent -> the OS | Whatever the sandbox still allows: system calls, drivers, system daemons |

## References

- [[1] Inside WebKit: a map of the engine and its processes]({% post_url 2026-10-11-f1_inside_webkit_the_map %})
- [[2] F. Pizlo, "Speculation in JavaScriptCore", WebKit blog](https://webkit.org/blog/10308/speculation-in-javascriptcore/)
- [[3] JF Bastien et al., "Assembling WebAssembly", WebKit blog](https://webkit.org/blog/7691/webassembly/)
- [[4] libpas documentation, `Source/bmalloc/libpas/Documentation.md` at `WebKit-7621.2.5.11.8`](https://github.com/WebKit/WebKit/blob/WebKit-7621.2.5.11.8/Source/bmalloc/libpas/Documentation.md)
- [[5] Apple, Porting just-in-time compilers to Apple silicon](https://developer.apple.com/documentation/apple-silicon/porting-just-in-time-compilers-to-apple-silicon)
- [[6] Gigacage, `Source/bmalloc/bmalloc/Gigacage.h` at `WebKit-7621.2.5.11.8`](https://github.com/WebKit/WebKit/blob/WebKit-7621.2.5.11.8/Source/bmalloc/bmalloc/Gigacage.h)
- [[7] Apple Newsroom, "Apple expands commitment to protect users from mercenary spyware" (July 2022)](https://www.apple.com/newsroom/2022/07/apple-expands-commitment-to-protect-users-from-mercenary-spyware/)
- [[8] Apple Support, About Lockdown Mode](https://support.apple.com/en-us/105120)
- [[9] Lockdown Mode JSC options, `XPCServiceEntryPoint.mm` lines 197-208 at `WebKit-7621.2.5.11.8`](https://github.com/WebKit/WebKit/blob/WebKit-7621.2.5.11.8/Source/WebKit/Shared/EntryPointUtilities/Cocoa/XPCService/XPCServiceEntryPoint.mm#L197-L208)

EOF
