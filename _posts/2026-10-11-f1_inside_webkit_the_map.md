---
title: "Inside WebKit: a map of the engine and its processes"
date: 2026-10-11 12:00:00
categories: [WebKit]
tags: [webkit, safari, ios, macos, javascriptcore, sandbox,
      browser-security, multiprocess, ipc, reverse-engineering]
description: >-
    WebKit, Inside Out: a map of WebKit's source tree, how to read its
    version numbers, and why the engine runs as several sandboxed
    processes on iOS.
media_subpath: /assets/img/posts/2026-10-11-f1_inside_webkit_the_map/
series: "WebKit, Inside Out"
part: F1
---

*WebKit, Inside Out* is a series about the browser engine behind Safari and
every app that shows web content on Apple's platforms. We will explore how
it's built on the inside, and how attackers try to get *out*, first out of
a web page into the renderer, then out of the renderer's sandbox.

This post gives a rough map of the source tree's layout and explains why
WebKit is several programs rather than one.

## A map of the source tree

The WebKit source code lives at github.com/WebKit/WebKit [1]. In there
Apple pushes release branches like `safari-7621.2.5-branch` and tags like
`WebKit-7621.2.5.11.8` alongside `main` [2]. Some parts of the source code
that are more critical for security work are the following:

| Path | What's there |
|---|---|
| `Source/JavaScriptCore/` | JS + Wasm engine; interpreters, JITs, GC |
| `Source/WTF/` | aka "Web Template Framework"; WebKit's C++ base library |
| `Source/bmalloc/` | Memory allocators, incl. **libpas** |
| `Source/WebCore/` | Web engine; DOM, CSS, layout, media, `platform/` |
| `Source/WebKit/` | Multi-process layer; IPC, sandbox, public API |
| `Source/WebKitLegacy/` | Old WebKit1 API; macOS, iOS `UIWebView` |
| `Source/WebGPU/` | WebGPU on top of Metal |
| `Source/ThirdParty/` | Vendored libs; **ANGLE**, libwebrtc, ... |
| `Tools/Scripts/` | Build/test drivers; `build-webkit`, `run-safari` |
| `Tools/*MiniBrowser/` | Minimal test browsers (macOS, iOS) |
| `JSTests/` | JSC regression and stress tests |
| `LayoutTests/` | Browser-level tests (HTML pages + expected output) |

### Components that stand out

Below are the directories that stand out, because they are complex or often
targeted by attackers.

**JavaScriptCore**:

- `parser/`, `bytecompiler/`, `bytecode/`: JS source -> bytecode.
- `llint/`: the bytecode interpreter, written in a portable assembly
  dialect; `offlineasm/` turns it into real assembly per CPU.
- `jit/`, `dfg/`, `ftl/` + `b3/`: the JIT tiers, from quick (Baseline) to
  heavily optimizing (FTL, with the B3 back end) [3][4].
- `wasm/`: WebAssembly [5]; its own interpreter and JIT tiers (BBQ, OMG).
  The JS-facing API (`WebAssembly.Module`, ...) is in `wasm/js/`.
- `heap/`: the garbage collector (GC), which finds the JS objects nothing
  refers to any more and frees their memory. Its design is called
  *Riptide* and it's a concurrent GC, which "reduces worst-case pause times
  by allowing the app to run concurrently to the collector" [6].
- `runtime/`: built-in objects like `Array`, `Map`, typed arrays, etc.

**WTF and bmalloc** - every process uses them:

- `WTF/wtf/`: containers like `Vector` and `HashMap`, strings, smart
  pointers, threading, `Checked<>` arithmetic.
- `bmalloc/libpas/`: the allocator behind `fastMalloc`, type-segregated
  heaps and much of the JS heap.

**WebCore** - what a web page talks to:

- `dom/`, `html/`, `css/`, `style/`: the document model, its parsers and
  style resolution.
- `rendering/`, `layout/`: styled DOM -> boxes -> pixels.
- `loader/`, `page/`: loading resources; frames and pages.
- `bindings/js/`: glue that exposes DOM objects to JavaScript and lets
  them take part in garbage collection.
- `Modules/`: newer web APIs, one module each; e.g. `mediastream/`,
  `webaudio/`, `WebGPU/`.
- `platform/`: the OS abstraction. WebCore's logic is written once;
  graphics, network, audio etc. Get one implementation per system like
  `platform/cocoa/` for `mac/`/`ios/`, `glib/` for Linux.
- `PAL/`: "Platform Abstraction Layer"; thin wrappers that load Apple
  frameworks and private APIs at runtime ("soft-linking").

**WebKit, the multi-process layer**:

- `UIProcess/`, `WebProcess/`, `NetworkProcess/`, `GPUProcess/`: one
  directory per process.
- `Platform/IPC/`: the IPC system between the processes.
- `Resources/SandboxProfiles/`, `Shared/Sandbox/`: the sandbox profiles.
- `UIProcess/API/Cocoa/`: the public API apps use to embed web content;
  `WKWebView`, `WKWebViewConfiguration`, ... [7] Safari and every in-app
  browser are built on it.

**Graphics, media, real-time** (mostly the GPU process):

- WebGL: `WebCore/html/canvas/` (the API) -> `WebCore/platform/graphics/
  angle/` -> `WebKit/GPUProcess/graphics/` -> `ThirdParty/ANGLE/`.
  ANGLE [8] is Google's library that implements OpenGL ES (what WebGL is
  based on) on top of other graphics APIs; on Apple platforms that's
  **Metal** [9], Apple's own low-level GPU API.
- WebGPU: the newer web standard for GPU graphics and compute [10].
  `Source/WebGPU/WebGPU/` implements it on Metal; `WebGPU/WGSL/` compiles
  its shader language.
- Media: `WebCore/html/HTMLMediaElement*`, the AVFoundation [11] back end
  in `WebCore/platform/graphics/avfoundation/`, playback in
  `WebKit/GPUProcess/media/`.
- WebRTC [12] (real-time audio/video, e.g. video calls): Google's
  `ThirdParty/libwebrtc/`, plus glue in `WebCore/Modules/mediastream/` and
  `WebKit/{NetworkProcess,GPUProcess}/webrtc/`.

### Reading a version number

WebKit's version numbers can be confusing, because tag version names are
different from Apple's framework versions. Sometimes specific iOS
subversions are not tagged in the public repo, so we have to make guesses
based on the commits that sit between the closest available tags.

In the source every build carries a five-part version, set in
`Configurations/Version.xcconfig` [13]. At the tag `WebKit-7621.2.5.11.8`:

```text
MAJOR_VERSION = 621;
MINOR_VERSION = 2;
TINY_VERSION = 5;
MICRO_VERSION = 11;
NANO_VERSION = 8;
FULL_VERSION = $(MAJOR_VERSION).$(MINOR_VERSION).$(TINY_VERSION).$(MICRO_VERSION).$(NANO_VERSION);

SOURCE_VERSION = $(MAJOR_VERSION).$(MINOR_VERSION).$(TINY_VERSION).$(MICRO_VERSION).$(NANO_VERSION);
```

The same file defines the version that the *installed* frameworks report:
a platform prefix followed by those five parts.

```text
SYSTEM_VERSION_PREFIX_macosx_140000 = 19;
SYSTEM_VERSION_PREFIX_macosx_150000 = 20;
SYSTEM_VERSION_PREFIX_macosx_160000 = 21;
SYSTEM_VERSION_PREFIX[sdk=iphone*] = 8;
BUNDLE_VERSION_Production = $(SYSTEM_VERSION_PREFIX)$(FULL_VERSION);
```

So on iOS the prefix is `8`, on macOS 14 it's `19`, on macOS 15 `20`, and
so on. Local builds don't get a prefix; they report `621.2.5.11.8+`.

Apple's **tags** put a `7` in front of the same five parts:
`WebKit-7621.2.5.11.8`. That `7` is a naming convention - every tag has it
- however it isn't defined in the file.

**Which release is which.** Apple publishes, for each OS release, which
WebKit tag it shipped (`release.json` in `apple-oss-distributions/
distribution-macOS` and `distribution-iOS` [14][15]). A few entries:

| OS release | WebKit tag it shipped |
|---|---|
| macOS 14.6 | `WebKit-7618.3.11.11.5` |
| macOS 15.5 | `WebKit-7621.2.5.11.8` |
| macOS 26.0 | `WebKit-7622.1.22.11.14` |
| iOS 18.5 | `WebKit-7621.2.5.10.10` |
| iOS 26.0 | `WebKit-7622.1.22.10.9` |

`7621.2.5` is therefore the 18.5 generation, and its macOS and iOS builds
differ in the fourth part. `.11` is for macOS, while `.10` for iOS. That
split is an observation from Apple's data, not a documented rule.

**Example** on a Mac running macOS 14.7.1:

```console
$ defaults read /System/Library/Frameworks/WebKit.framework/Resources/Info.plist CFBundleVersion
19618.3.11.11.5
```

- `19` is the macOS 14 prefix from `Version.xcconfig`.
- `618.3.11.11.5` is the five-part version. The tag `WebKit-7618.3.11.11.5`
  exists, and its `Version.xcconfig` has exactly those values (618, 3, 11,
  11, 5).
- Apple's `release.json` for macOS 14.6 lists `WebKit-7618.3.11.11.5`. That
  is the WebKit of Safari 17.6, which is what this Mac's Safari reports;
  Safari updates install separately from macOS on older releases.

## WebKit's multiprocess model

When we open a page in Safari, e.g. on an iPhone, we are running several
cooperating processes:

![WebKit's processes and their sandboxes](webkit_processes_sandbox_v8_base.svg)
*The UI process launches and supervises the others. Each process runs in
its own sandbox and on iOS every one is also checked against the platform
profile; the OS runs underneath.*

| Process | Binary |
|---|---|
| UI | Safari, or any app embedding `WKWebView` |
| WebContent | `com.apple.WebKit.WebContent` |
| Networking | `com.apple.WebKit.Networking` |
| GPU | `com.apple.WebKit.GPU` |
| Helpers | `com.apple.WebKit.Model`, `webpushd`, `adattributiond` |

In the source tree, these map almost one-to-one onto directories in
`Source/WebKit/`: `UIProcess/`, `WebProcess/`, `NetworkProcess/`,
`GPUProcess/`, `ModelProcess/`, `webpushd/`. Each sandboxed process has its
own sandbox profile; the iOS ones live in
`Source/WebKit/Resources/SandboxProfiles/ios/` [16] (for example
`com.apple.WebKit.WebContent.sb.in`, `com.apple.WebKit.GPU.sb.in`,
`com.apple.WebKit.Networking.sb.in`).

On iOS 18.7.3, every process is checked against the platform profile,
plus its own sandbox. The names come from the iOS 18.7.3 kernelcache,
listed and decompiled with `ipsw sb` [17][18][19], and from the
entitlements WebKit gives each of its processes [20]. The UI rows come
from MobileSafari's own entitlements, extracted from the iOS 18.7.3 IPSW:

| Process | Sandbox |
|---|---|
| UI (Safari) | App sandbox + exception entitlements |
| WebContent | `com.apple.WebKit.WebContent` |
| Networking | `com.apple.WebKit.Networking` |
| GPU | `com.apple.WebKit.GPU` |
| Model | `com.apple.WebKit.Model` |
| webpushd | `com.apple.WebKit.webpushd` |
| adattributiond | `com.apple.WebKit.adattributiond` |

### Why split things up?

The process split landed in 2010 with WebKit2. WebKit's own WebKit2
overview says the isolated web process "can deliver benefits in
responsiveness, robustness, security (through the potential to sandbox the
web process) and better use of multicore CPUs" [21]. The Networking
process followed in 2012 [22]. The GPU process code was added in 2019, and
its first commit says it "will specifically gate access to IOKit and a few
media-related daemons" [23].

Another way to view it is that the WebContent process can eventually be
compromised. It runs the most attacker-controlled input in the system
(arbitrary HTML, CSS, JavaScript, WebAssembly, images, fonts) through
millions of lines of C++ and several just-in-time compilers. So WebKit
places WebContent in the smallest possible box. For basic functionalities
it has to communicate with the other processes. For example:

- It can't open network sockets. It asks the Networking process.
- It can't talk to the GPU or media hardware directly. It asks the GPU
  process.
- It can't read arbitrary files, launch processes, or reach most system
  services. The sandbox profile denies them.
- It doesn't hold the user's cookies wholesale. The Networking process
  mediates storage per site.

The sandbox profile shows this directly. The iOS 18.7.3 WebContent profile,
decompiled from the kernelcache [17], has a top-level
`(deny iokit-open-user-client)` and `(deny iokit-open-service)`. Its only
outbound network rule is for the kernel control socket
`com.apple.flow-divert`, not for network connections, and nothing allows
it to start or fork processes.

Every capability that a renderer needs but shouldn't hold directly moves
into a separate process that **receives requests from WebContent and
validates them**.

*Versions:* paths and numbers here come from the macOS Safari 18.5 release
tag, `WebKit-7621.2.5.11.8` in github.com/WebKit/WebKit. Sandbox names and
rules come from the iOS 18.7.3 kernelcache. Names and counts drift between
releases; the structure changes slowly.

## References

- [[1] WebKit source repository](https://github.com/WebKit/WebKit)
- [[2] Tag `WebKit-7621.2.5.11.8` (Safari 18.5)](https://github.com/WebKit/WebKit/tree/WebKit-7621.2.5.11.8)
- [[3] F. Pizlo, "Speculation in JavaScriptCore", WebKit blog](https://webkit.org/blog/10308/speculation-in-javascriptcore/)
- [[4] F. Pizlo, "Introducing the B3 JIT Compiler", WebKit blog](https://webkit.org/blog/5852/introducing-the-b3-jit-compiler/)
- [[5] WebAssembly](https://webassembly.org/)
- [[6] F. Pizlo, "Introducing Riptide: WebKit's Retreating Wavefront Concurrent Garbage Collector", WebKit blog](https://webkit.org/blog/7122/introducing-riptide-webkits-retreating-wavefront-concurrent-garbage-collector/)
- [[7] Apple, `WKWebView` documentation](https://developer.apple.com/documentation/webkit/wkwebview)
- [[8] ANGLE](https://chromium.googlesource.com/angle/angle)
- [[9] Apple, Metal](https://developer.apple.com/metal/)
- [[10] W3C, WebGPU specification](https://www.w3.org/TR/webgpu/)
- [[11] Apple, AVFoundation](https://developer.apple.com/av-foundation/)
- [[12] WebRTC](https://webrtc.org/)
- [[13] `Configurations/Version.xcconfig` at `WebKit-7621.2.5.11.8`](https://github.com/WebKit/WebKit/blob/WebKit-7621.2.5.11.8/Configurations/Version.xcconfig)
- [[14] Apple, macOS release components (`release.json`)](https://github.com/apple-oss-distributions/distribution-macOS)
- [[15] Apple, iOS release components (`release.json`)](https://github.com/apple-oss-distributions/distribution-iOS)
- [[16] iOS sandbox profiles at `WebKit-7621.2.5.11.8`](https://github.com/WebKit/WebKit/tree/WebKit-7621.2.5.11.8/Source/WebKit/Resources/SandboxProfiles/ios);
  shared sandbox rules (`common.sb`, ...) in [`Source/WebKit/Shared/Sandbox`](https://github.com/WebKit/WebKit/tree/WebKit-7621.2.5.11.8/Source/WebKit/Shared/Sandbox)
- [[17] blacktop, `ipsw` (`ipsw sb list` / `ipsw sb dec`)](https://github.com/blacktop/ipsw)
- [[18] Cellebrite Labs, SandBlaster (iOS 18 fork), used to cross-check](https://github.com/cellebrite-labs/sandblaster)
- [[19] "The iOS sandbox: profiles, Seatbelt and sandbox escapes" (platform profile plus per-process profile)](https://sigreturn.com/blog/ios-sandbox/)
- [[20] `Source/WebKit/Scripts/process-entitlements.sh` (`com.apple.private.sandbox.profile` per process)](https://github.com/WebKit/WebKit/blob/WebKit-7621.2.5.11.8/Source/WebKit/Scripts/process-entitlements.sh)
- [[21] WebKit2 overview, trac.webkit.org](https://trac.webkit.org/wiki/WebKit2)
- [[22] "Add a NetworkProcess to WebKit2", WebKit bug 98537 (Oct 2012)](https://bugs.webkit.org/show_bug.cgi?id=98537)
- [[23] "Introduce a GPU process", WebKit bug 204343 (Dec 2019)](https://bugs.webkit.org/show_bug.cgi?id=204343);
  first commit [2d9d0c575ad7](https://github.com/WebKit/WebKit/commit/2d9d0c575ad7)

EOF
