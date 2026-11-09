---
title: "Another door: how WebKit's processes communicate without messages"
date: 2026-10-19 12:00:00
categories: [WebKit]
tags: [webkit, safari, ios, macos, ipc, shared-memory, mach, xpc, sandbox,
      sandbox-escape, browser-security]
description: >-
    WebKit, Inside Out: how WebKit's processes share memory, pass
    capabilities, configure each other at launch and talk to system
    services directly, besides their IPC messages.
series: "WebKit, Inside Out"
part: F4
---

WebKit's IPC messages are only one way its processes talk to each other.
They also share memory, hand each other capabilities, configure each other
at launch and talk to system services directly. Each of these can also be
considered attack surface on their own.

Everything in this post comes from the macOS Safari 18.5 WebKit release tag
[`WebKit-7621.2.5.11.8`](https://github.com/WebKit/WebKit/tree/WebKit-7621.2.5.11.8),
and every WebKit file named here can be read at that tag. Paths are
relative to `Source/WebKit/` or to `Source/` when they start with
`WebCore/` or `JavaScriptCore/`.

## 1. Shared memory concepts

The flow of a normal IPC message is that the sender encodes its arguments
into bytes, the kernel carries them across in a Mach message and finally
the receiver decodes its own copy. That is fine for a small amount of data,
but far too slow for bulk data like images or a stream of video. For those,
the two processes share memory instead. One process creates a region of
memory and sends a *handle* to the other. A handle can be a small token the
kernel understands, like a Mach port. With the handle, the receiver can map
the same memory into its own address space. From then on both processes see
the same bytes and the data itself never travels in a message.

WebKit uses several kinds of shared memory, one for each kind of data. An
**IOSurface** is the system's shared buffer for images and the GPU can draw
into it directly. A **ring buffer** is shared memory used as a queue. In
that case, one side keeps writing at the end, while the other keeps reading
from the start and both wrap around when they reach the end of the buffer.
The stream buffer and `SharedCARingBuffer` in the table below are ring
buffers.

Some of the shared memory mechanisms that WebKit uses:

| Mechanism | File | Used for |
|---|---|---|
| `SharedMemory` | `WebCore/platform/SharedMemory.h` | Large buffers and payloads |
| Stream buffer | `Platform/IPC/StreamConnectionBuffer.h` | Drawing commands to the GPU process |
| `ShareableBitmap` | `WebCore/platform/graphics/ShareableBitmap.h` | Images and snapshots |
| IOSurface | `WebCore/platform/graphics/cocoa/IOSurface.mm` | Rendered images between processes |
| `SharedVideoFrame` | `WebProcess/GPU/webrtc/SharedVideoFrame.h` | Video frames, media and WebRTC |
| `SharedCARingBuffer` | `Shared/Cocoa/SharedCARingBuffer.h` | Real-time audio |

## 2. Synchronization without messages

Shared memory needs one more piece. When the writer puts new data into a
shared buffer, the reader has to learn about it and sending a message for
every item would bring back the cost that shared memory avoids. WebKit uses
semaphores for this. A **semaphore** is a small counter kept by the kernel.
When one process signals it, it wakes up the other process that is waiting
on it. WebKit's **IPC semaphores** (`Platform/IPC/IPCSemaphore.h`) are
exchanged once, as a handle, and from then on wake the other side of a
stream buffer or audio ring buffer directly. That avoids one message per
item, which matters for real-time audio and high-rate graphics.

## 3. Capabilities and identities passed inside messages

Some message arguments aren't data at all. They are *capabilities*, like a
specific key that allows a process to do something. On Apple platforms many
of them are Mach ports. A Mach port is a message queue owned by the kernel.
A process that holds a *send right* to a port can send messages to it and
only the process with the *receive right* reads them. A process can get a
right only from the kernel or from another process that hands it over in a
message. Handing over a port therefore hands over the ability to talk to
whoever listens on it.

For a connection, such a thing is the **endpoint**, what a process must
hold to talk to another process. Other arguments are like *identity* tokens
that say, for example, which process something belongs to. Some of them,
like audit tokens, are issued by the kernel, so a receiver can trust them.

These are ordinary message arguments, but what they carry is a *right* or
an *identity*, not data:

- **Connection endpoints.** Processes can't find each other on their own,
  so the UI process brokers their connections. When for example WebContent
  needs the GPU process, it creates a new connection pair
  (`IPC::Connection::createConnectionIdentifierPair`), keeps one end and
  sends the other to the UI process, which forwards it to the GPU process
  (`CreateGPUProcessConnection`). After that, the two processes talk
  directly. On Cocoa these ends are Mach ports and XPC endpoints
  (`Shared/Cocoa/XPCEndpoint.mm`).
- **Sandbox extensions** (`Shared/SandboxExtension.h`) are tokens issued by
  a privileged process so that a sandboxed one can access a specific file
  or service, for example a file the user chose to upload.
- **File handles** (`Platform/IPC/SharedFileHandle.h`) are open file
  descriptors sent instead of paths.
- **Process identity tokens** (`WebCore/platform/ProcessIdentity.h`) are
  passed so that memory allocated by the GPU process for a page is charged
  to the right WebContent process.
- **Audit tokens.** The UI process passes the *presenting application's*
  audit token to the GPU process (`GPUConnectionToWebProcess`), so media
  and audio sessions act on behalf of the right app. Processes also use
  their peers' audit tokens to check entitlements.
- **Accessibility tokens.** On macOS and iOS, the UI process and WebContent
  exchange remote-element tokens (`WebPageCocoa.mm`, `WebViewImpl.mm`) so
  the system accessibility clients can talk to the page's accessibility
  tree in WebContent directly.
- **Object identifiers.** Many GPU process interfaces refer to images,
  fonts and video frames *by ID* instead of by value. Using an ID that the
  sender shouldn't be able to use is a recurring cross-process bug class.

## 4. Launch-time configuration

Before two processes can talk, the second one has to exist. The UI process
starts every helper process, using **XPC**, the system's way of starting
helper services and connecting to them. On macOS each helper is an XPC
service inside the WebKit framework, which the system starts when it is
first asked for. The first thing a new helper receives is not a WebKit
message but a dictionary of settings, before WebKit's own IPC is even set.

That dictionary is the **XPC bootstrap message**
(`UIProcess/Launcher/cocoa/ProcessLauncherCocoa.mm`, received in
`Shared/EntryPointUtilities/Cocoa/XPCService/XPCServiceMain.mm`). Its keys
in 18.5 include `client-identifier`, `client-bundle-identifier`,
`ui-process-name`, `process-identifier`, `OverrideLanguages`,
`ContainerEnvironmentVariables`, `extra-initialization-data` and
security-relevant switches: **`disable-jit`**, **`disable-jit-cage`**,
**`enable-shared-array-buffer`**. This is, for instance, how a WebContent
process learns at birth that it must run without the JIT.

- **How processes are started:** on macOS they're XPC services launched
  through launchd [1]. On iOS 17.4 and later, WebKit launches them as
  ExtensionKit / BrowserEngineKit extensions [2] (`USE_EXTENSIONKIT`,
  `Shared/Cocoa/WKProcessExtension.mm`).
- **How they're kept alive:** the UI process holds or drops process
  assertions with the system's RunningBoard service (`ProcessAssertion`) to
  keep helpers running or let them be suspended.
- **How they're stopped:** the UI process can terminate a helper. That's
  the `MESSAGE_CHECK` response: a WebContent process that sends an invalid
  message is killed.

## 5. Talking to system services directly

A program on macOS or iOS gets much of what it needs from *system daemons*,
background processes that provide fonts, preferences and many other
services. To reach one, a program asks the system's bootstrap server
(`launchd`) for the daemon's **Mach service** by name. That request is a
*Mach lookup*. If it succeeds, the program holds a send right to the daemon
and can send it requests. The sandbox decides which names each process may
look up.

Not everything goes through WebKit's own processes:

- **WebKit's daemons over raw XPC.** `webpushd` (push notifications) and
  the private click measurement / ad-attribution daemon are reached with
  a simpler encoding defined in `Platform/IPC/DaemonConnection.h`.
- **Web Inspector's own channel.** JavaScriptCore's remote inspector talks
  to the system's `webinspectord` over XPC
  (`JavaScriptCore/inspector/remote/cocoa/RemoteInspectorXPCConnection.mm`,
  Mach service `com.apple.webinspector`). It's coordinated with Darwin
  notifications such as `com.apple.webinspectord.available`. This is how
  Safari's Develop menu and remote debugging of a device reach a page's
  JavaScript.
- **Darwin notifications.** WTF's memory-pressure handling subscribes to
  low-level system notifications (`MemoryPressureHandlerCocoa.mm`). Where
  the sandbox blocks them, the UI process subscribes instead and relays
  them as messages (`Messages::WebProcess::PostObserverNotification`, in
  `WebProcessPoolCocoa.mm`).
- **Direct Mach lookups from WebContent.** WebContent's sandbox doesn't
  deny *all* system services. The 18.5 profiles name a short list of Mach
  services, some allowed only conditionally or with reporting:
  - macOS (`com.apple.WebProcess.sb.in`): `com.apple.CARenderServer`,
    `com.apple.windowserver.active`, `com.apple.fonts`,
    `com.apple.webinspector`, `com.apple.pasteboard.1`,
    `com.apple.tccd.system`, `com.apple.trustd.agent` and more;
  - iOS (`com.apple.WebKit.WebContent.sb.in`): `com.apple.CARenderServer`,
    `com.apple.system.notification_center`, `com.apple.webkit.camera`,
    `com.apple.webinspector`, `com.apple.mobilegestalt.xpc` and more.

  Every service on these lists is a channel from the most exposed process
  **straight into a system daemon**, outside WebKit's own validation. That
  makes them attractive targets for a sandbox escape.

## 6. Protocols layered on top of messages

Some features need their own conversation between processes, for example
a page that talks to a worker running in another process. They don't add
a new channel. They define their own messages and carry them inside WebKit
IPC, so each of these features also has to check what arrives at its own
level.

The main ones:

- **Web-platform messaging across processes.** `MessagePort`,
  `BroadcastChannel`, `SharedWorker` and service workers connect pages
  that may live in different WebContent processes. The Networking process
  brokers them (`NetworkBroadcastChannelRegistry`, the message-port
  registries, `WebSWServerConnection`).
- **App-defined messages**: `WKScriptMessageHandler` [3] (page JavaScript
  -> app), `WKBundlePostMessage` and remote objects (injected bundle <->
  app). WebKit carries them; the embedding app defines and must validate
  their contents.
- **Web Inspector front end <-> back end**: JSON protocol messages between
  the inspected page and the inspector UI, which itself runs in another
  WebContent process.
- **Web extensions**: Safari web extension APIs routed between extension
  pages, content scripts and the UI process.

## 7. Other transports

The *transport* is the lowest layer, the channel that carries the bytes of
every message from one process to the other. On Apple platforms it is Mach
ports.

On Linux (GTK, WPE) the same message layer runs over Unix sockets
(`socketpair`, `Platform/IPC/unix/ConnectionUnix.cpp`) instead. Bugs above
the transport usually affect every platform; transport bugs don't.

## Why this matters

WebKit's IPC messages are the most visible sandbox-escape surface, but
they aren't the only one. Shared memory that a compromised WebContent
process can write while the GPU process reads it, such as stream buffers,
deserves the same distrust as a message
argument. Sizes and offsets read from shared memory are a classic place
for "checked once, read twice" bugs, where the writer changes a value
after the reader has checked it. Capabilities are privileges too: a
sandbox extension, a file handle, a connection endpoint or an object ID
that a process shouldn't hold is a sandbox escape without any memory
corruption. And the Mach services that WebContent is still allowed to
look up let it bypass WebKit's validation entirely and talk to system
daemons directly.

## References

- [[1] Apple, XPC documentation](https://developer.apple.com/documentation/xpc)
- [[2] Apple, BrowserEngineKit documentation](https://developer.apple.com/documentation/browserenginekit)
- [[3] Apple, `WKScriptMessageHandler` documentation](https://developer.apple.com/documentation/webkit/wkscriptmessagehandler)

EOF
