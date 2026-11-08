---
title: "Talking through the walls: WebKit IPC and how to find messages"
date: 2026-10-17 12:00:00
categories: [WebKit]
tags: [webkit, safari, ios, macos, ipc, sandbox, sandbox-escape,
      browser-security, reverse-engineering]
description: >-
    WebKit, Inside Out: how WebKit's processes talk over IPC and how to
    follow one message from its declaration to its handler and its senders,
    with a map of every interface by direction.
media_subpath: /assets/img/posts/2026-10-17-f3_talking_through_the_walls_webkit_ipc/
series: "WebKit, Inside Out"
part: F3
---

WebKit's processes cooperate by sending each other messages. A message is a
way for a less trusted process to ask a more trusted one to do something.
That makes IPC a natural target for sandbox escapes. In this post we look
at how WebKit IPC works, follow a message by hand from its declaration to
its handler and its sender and map who talks to whom.

Everything in this post comes from the macOS Safari 18.5 WebKit release tag
[`WebKit-7621.2.5.11.8`](https://github.com/WebKit/WebKit/tree/WebKit-7621.2.5.11.8),
and every WebKit file named here can be read at that tag. Paths are
relative to `Source/WebKit/` unless they start with `Source/`

## How the processes talk: WebKit IPC

All of this cooperation between processes happens over WebKit's IPC layer
in `Source/WebKit/Platform/IPC/`.

An IPC message can be looked at from two perspectives.

The first is what happens at **build time**. WebKit declares a message in a
`*.messages.in` file and a code generator turns that declaration into C++.
The generated code is only the glue. It provides the message type that
senders use, the code that serializes and deserializes its arguments and
the code on the receiving side that dispatches it to the right handler.
Everything that decides what happens is still handwritten: who sends the
message, with which argument values and what the handler that receives it
checks and does.

The other side of the coin is what happens at **run time**. The sending
process builds the message and serializes its arguments into bytes. It then
sends it one-way with no reply, asynchronously with a reply that arrives
later or synchronously, waiting until the reply arrives. The busiest
interfaces, like graphics, deliver their messages through a shared-memory
stream instead of sending each one separately. On the receiving side, the
bytes are first decoded back into arguments and the generated dispatch code
hands them to the matching handler. The handler then validates what it was
given and proceeds on the message only if everything checks out. If a reply
is expected, it sends it back the same way. If a check fails, the receiver
treats the sender as compromised and usually terminates it.

### Transport

On Apple platforms a connection is represented by the `IPC::Connection`
class, defined in `Platform/IPC/Connection.h` and
`Platform/IPC/cocoa/ConnectionCocoa.mm`. Such a connection is built on Mach
ports and uses XPC [1] to bootstrap and launch the services. Large data,
such as bitmaps and media, moves through shared memory handles rather than
being copied inside messages.

### Messages declarations

Each process-to-process interface is described in a `*.messages.in` file.
An *interface* is one `messages -> Receiver` block in such a file. It names
the receiver and lists the messages that object accepts. A receiver is just
a C++ object in the receiving process. A code generator, located in
`Scripts/generate-message-receiver.py`, turns the file into the C++ code
for both sides, usually during the build. Since the generator is a script
in the tree, we can also run it ourselves. The Safari 18.5 tree has 241
`*.messages.in` files, 25 of which are the code generator's test inputs.

**Serialization**
Message arguments are encoded and decoded by generated serializers and
`Platform/IPC/ArgumentCoders.h`. Serializers are declared in
`*.serialization.in` files and there are 348 in Safari 18.5. Trying to
decode a malformed message should fail, not produce a half-built object.

### Sync, async and streams

Each of the three ways of sending a message has its own call on the sending
side. The WebKit functions used for them are `send` for one-way messages,
`sendWithAsyncReply`/`sendWithPromisedReply` for a reply delivered later
and `sendSync` for a reply the sender waits for, all declared in
`Platform/IPC/Connection.h`. A message's declaration in the `*.messages.in`
file decides which one applies. A message with `-> (<reply arguments>)`
expects a reply and the `Synchronous` attribute makes the sender block for
it. The generator turns `Synchronous` into a compile-time flag on the
message type (`isSync`) and the send functions check it with
`static_assert`, so calling the wrong one doesn't build.

A few declarations still end their reply with an `Async` keyword, for
example `SetPaused(bool paused) -> (bool succeeded) Async` in
`ModelProcessModelPlayerProxy.messages.in`. That keyword seems to be a
leftover. When asynchronous replies were added, a message with a reply was
still synchronous unless it was marked `Async`. Later, the default behavior
flipped and after some time WebKit even removed the attribute from the
generator and from most `*.messages.in` files. According to a commit
message: "If there is a reply and no 'Synchronous' then we can infer that
it is asynchronous" [2]. In the 18.5 tree 13 declarations still carry it,
and the generator ignores it.

A message with neither, like `void Hint(uint32_t target, uint32_t mode)` in
`GPUProcess/graphics/RemoteGraphicsContextGL.messages.in`, is a one-way
message. The WebContent process sends it and carries on without expecting
anything to come back. The leading `void` is only style. The generator's
parser ignores it and most `*.messages.in` files leave it out.

Stream interfaces are declared with the `Stream` keyword, as in `messages
-> RemoteGraphicsContextGL Stream`. Their two ends are
`StreamClientConnection` and `StreamServerConnection`, in
`Platform/IPC/StreamClientConnection.h` and `StreamServerConnection.h`. The
WebContent process appends each message to a ring buffer in shared memory
and the GPU process reads them from it in order. So a page's WebGL call
becomes a record in that ring buffer, which the GPU-process code will
decode and pass with its parameters to ANGLE.

Not every message of a stream interface can travel through the ring buffer,
though. The buffer holds plain bytes, but some arguments are handles to
kernel objects like Mach ports or semaphores, which have to be transferred
by the kernel. Those messages are marked `NotStreamEncodable`, while
`NotStreamEncodableReply` marks a reply that carries such a handle. Both
appear in `RemoteGraphicsContextGL.messages.in`:

```text
void SetSharedVideoFrameMemory(WebCore::SharedMemory::Handle storageHandle) NotStreamEncodable
void PrepareForDisplay(IPC::Semaphore finishedFence) -> (MachSendRight displayBuffer) Synchronous NotStreamEncodable NotStreamEncodableReply
```

For such a message the generated type has `isStreamEncodable = false` and
the stream client writes only a placeholder (`ProcessOutOfStreamMessage`)
into the ring buffer. The message itself is then sent over the regular
connection. The placeholder keeps the order. When the GPU process reaches
it in the stream, it stops reading the stream until that message has
arrived and has been handled.

The table below sums up the kinds of declarations and how each is sent.
All examples come from `Shared/IPCStreamTester.messages.in`, a stream
interface WebKit uses to test its own IPC and the only one in the tree that
has every kind of declaration. Arguments are shortened to `...` for
formatting reasons.

| Declaration | Sending call | Delivery |
|---|---|---|
| `EmptyMessage()` | `send` | ring buffer |
| `AsyncPing(...) -> (...)` | `sendWithAsyncReply` | ring buffer; reply later |
| `SyncMessage(...) -> (...) Synchronous` | `sendSync` | ring buffer, both ways |
| `SyncMessageNotStreamEncodableReply(...) -> (...)`<br>`Synchronous NotStreamEncodableReply` | `sendSync` | reply over the connection |
| `SyncMessageNotStreamEncodableBoth(...) -> (...)`<br>`Synchronous NotStreamEncodable NotStreamEncodableReply` | `sendSync` | placeholder in the ring buffer; message and reply over the connection |

### Validation: MESSAGE_CHECK

Because the sender may be compromised, every receiver must treat message
contents as hostile. WebKit's idiom is the `MESSAGE_CHECK` family of
macros. If for example a size doesn't match a buffer, the receiver
terminates the misbehaving WebContent process instead of trusting it.
The Safari 18.5 tree uses `MESSAGE_CHECK` and its variants, such as
`MESSAGE_CHECK_COMPLETION`, 382 times in `GPUProcess/`, `UIProcess/` and
`NetworkProcess/`. Every one is a spot where WebKit needs to be sure that
things look as they should ;)

## Finding IPC messages ourselves

Any WebKit IPC message can be followed by hand through four places in the
source. They are its **declaration**, the **generated dispatch code**, the
**handler** that runs it and the **code that sends it**. The tools at
the end of this section automate all four.

![The IPC source of one interface](ipc_structure_1_source.svg)
*One IPC interface in the source, between a sender A and a receiver B,
each in its own sandbox. The declaration lives with the receiver; both
processes link the same IPC layer.*

### 1. Declarations: `*.messages.in`

Every IPC interface is a `*.messages.in` file under `Source/WebKit`:

```sh
git ls-files 'Source/WebKit/*.messages.in' | wc -l                                  # 241 in the Safari 18.5 tag
git ls-files 'Source/WebKit/*.messages.in' | grep -v Scripts/webkit/tests | wc -l   # 216 real ones
```

The other 25 are for the code generator's own tests
(`Source/WebKit/Scripts/webkit/tests/`) and aren't real IPC. A typical
file, `GPUProcess/graphics/RemoteGraphicsContextGL.messages.in`, looks like
this:

```text
[
    DispatchedFrom=WebContent,
    DispatchedTo=GPU,
    ...
]
messages -> RemoteGraphicsContextGL Stream {
    ...
    void PixelStorei(uint32_t pname, int32_t param)
    ...
}
```

Things to focus on in each `*.messages.in`:

- The "header attributes" in the `[...]` block before `messages -> Name`:
  - `DispatchedFrom=` and `DispatchedTo=` give the sending and receiving
    process. Newer WebKit annotates every interface; older trees only some.
  - `ExceptionForDispatchedFrom` and similar mark interfaces with more than
    one sender, usually explained in a comment.
- `Stream` marks a shared-memory stream interface.
- There is one message per line. `Name(arguments)` and optionally `->
  (reply arguments)`, plus `Synchronous` when the sender blocks for the
  answer. Some files, like WebGL, write each message with a leading `void`.
- There are per-message attributes in front of a message, such as
  `[EnabledBy=<Preference>]` (only accepted when a feature is on) or
  `[Validator=<Check>]` (an extra check run before the handler).

A `*.messages.in` file belongs to the receiver's side. It declares one
receiver, `messages -> Name` and lists the messages that this receiver
accepts. Basically it describes the receiver's interface and sits next to
the receiver's code. In the Safari 18.5 tree, 214 of the 216 files are in
the same directory as the receiver class's header. For example, the
`GPUProcess/graphics/RemoteGraphicsContextGL.messages.in` sits next to
`RemoteGraphicsContextGL.h`. The sender never includes the file itself; it
uses the C++ generated from it, as the next step shows.

### 2. Generated code: `DerivedSources/WebKit`

During the build process the code generator turns every `*.messages.in`
file into two C++ files. They are named after the interface the file
declares, for example `messages -> RemoteGraphicsContextGL` is declaring
the `RemoteGraphicsContextGL` interface. WebKit's own code calls that name
the "message receiver", because it is also the name of the class in the
receiving process that handles the messages. Both generated files contain
code for every message in that `*.messages.in`:

- `<Interface>Messages.h`, for the **sending** side. One C++ type per
  message, such as `Messages::RemoteGraphicsContextGL::PixelStorei`, which
  carries the message's arguments. Senders create these types and pass
  them to `send`.
- `<Interface>MessageReceiver.cpp`, for the **receiving** side. This is the
  dispatch code. It checks each incoming message's name, decodes its
  arguments and calls the matching handler via `IPC::handleMessage`, from
  `Platform/IPC/HandleMessage.h`.

An example from the code is the `RemoteGraphicsContextGL.messages.in`,
which becomes `RemoteGraphicsContextGLMessages.h` and
`RemoteGraphicsContextGLMessageReceiver.cpp`. There are a few more files
that are shared by all receivers. `MessageNames.h` and `MessageNames.cpp`
number every receiver and every message (`ReceiverName`, `MessageName`) and
`MessageArgumentDescriptions.cpp` describes the arguments of every message.
These files exist for the IPC testing API and logging. After building
WebKit, all of these are in `WebKitBuild/<Config>/DerivedSources/WebKit/`.
A macOS build of the Safari 18.5 tag generates 211 pairs; the other five of
the 216 `*.messages.in` files belong to the Linux and Windows ports.

![The IPC source with the generated files](ipc_structure_2_generated.svg)
*The same interface with the generated code (dashed). At build time the
generator reads the declaration and writes one file for each side.*

We don't need a full WebKit build to get this code. The generator is a
Python script in the WebKit repository itself, located under
`Source/WebKit/Scripts/generate-message-receiver.py`. The build simply
calls it with every message receiver listed in
`Source/WebKit/DerivedSources.make`. We can call it standalone and generate
the files for any interface of interest. For example, from an empty
directory, this writes the code for the WebGL interface in under a second:

```sh
python3 ~/WebKit/Source/WebKit/Scripts/generate-message-receiver.py \
    ~/WebKit/Source/WebKit GPUProcess/graphics/RemoteGraphicsContextGL
# -> RemoteGraphicsContextGLMessageReceiver.cpp, RemoteGraphicsContextGLMessages.h,
#    MessageNames.h, MessageNames.cpp, MessageArgumentDescriptions.cpp
```

The first argument is the `Source/WebKit` directory and each further
argument is a receiver, with the path of its `*.messages.in` file being
relative to `Source/WebKit`, without the extension. The generated files are
written to the current directory. Generating a single receiver is enough to
read its code. The shared `MessageNames` files are only complete when all
receivers are generated together.

To automate this a bit, we created `ipc_generate.py` [3], a script that
does the same for every receiver of a given tag or commit. It takes the
receiver list from `DerivedSources.make`, reads the files with `git` so the
checkout stays untouched and writes the output in the same layout as a
build directory.

The generated receiver file is the most reliable way to find a handler,
because it spells out the binding:

```cpp
if (decoder.messageName() == Messages::RemoteGraphicsContextGL::PixelStorei::name())
    return IPC::handleMessage<Messages::RemoteGraphicsContextGL::PixelStorei>(connection, decoder, this, &RemoteGraphicsContextGL::pixelStorei);
```

### 3. The handler

The handler is a method of the receiver class, named after the message with
a lowercase first letter (`PixelStorei` -> `pixelStorei`), as we can see in
the generated binding above. Typically it is ordinary code in the WebKit
source tree written by hand in the receiver's own `.cpp` file. For example,
the handler of the `CookiesForDOM` message is the method
`NetworkConnectionToWebProcess::cookiesForDOM`, defined in
`NetworkProcess/NetworkConnectionToWebProcess.cpp`.

WebGL is an exception. Its handlers aren't handwritten - they are generated
ahead of time by `Tools/Scripts/generate-gpup-webgl` and committed as
`GPUProcess/graphics/RemoteGraphicsContextGLFunctionsGenerated.h`. That
header is then included inside the `RemoteGraphicsContextGL` class.
Searching `RemoteGraphicsContextGL.cpp` for `pixelStorei` finds nothing;
the binding in the generated receiver points to the right method anyway.

The handler is where the receiving process decides whether to trust the
message or not. In the handler we look for `MESSAGE_CHECK` or any other
form of validation the receiver might have. A handler that uses
sender-supplied data without checking it is a classic sandbox-escape
pattern.

### 4. Senders

Senders construct the message type and pass it to `send`, `sendSync` or
`sendWithAsyncReply` (file is reducted):

```sh
$ git grep -n 'Messages::RemoteGraphicsContextGL::PixelStorei' -- Source/WebKit
auto sendResult = send(Messages::RemoteGraphicsContextGL::PixelStorei(pname, param));
```

The directory each hit lives in tells us the sending process:
`WebProcess/` is WebContent, `UIProcess/` is the UI process and so on.

Putting the four steps together, this is the path one message takes at
run time, through the code we just followed:

![One IPC message at run time](ipc_structure_3_runtime.svg)
*An IPC message during run time: built and encoded in A, carried across by
the IPC layer, decoded by the receiver and passed to the handler in B.*

### Tools: `ipc_find.py`, `ipc_map.py` and `ipc_generate.py`

How about introducing a couple of small tools to automate and make faster
the process of following IPC messages in the source code instead of doing
it by hand? Why not. They can be found in the `ipc_tools/` directory of
`webkit_playground` [3], the repository with the supporting files for this
series:

- `ipc_find.py` follows one message or lists one interface
- `ipc_map.py` maps every interface and message of a WebKit version
- `ipc_generate.py` produces the generated IPC code without a WebKit build

All three read the WebKit repository with `git` at any tag or commit and
never touch the working tree. The commands below are run from the
`ipc_tools/` directory of `webkit_playground`, with a WebKit checkout in
`~/WebKit`.

**`ipc_find.py`** follows one message through all four steps described
earlier. With `--build-dir` it reads the binding from the generated
receiver code. That can be a WebKit build directory or the output of
`ipc_generate.py`, which is what we use here:

```text
$ python3 ipc_generate.py ~/WebKit WebKit-7621.2.5.11.8 out_ipc_gen
[*] Generating WebKit's IPC code for WebKit-7621.2.5.11.8
    [*] Reading the sources at WebKit-7621.2.5.11.8 with git
    [+] 211 interfaces listed in DerivedSources.make
    [*] Running generate-message-receiver.py
[+] Generated the code of 211 interfaces in out_ipc_gen/DerivedSources/WebKit

$ python3 ipc_find.py --repo ~/WebKit --ref WebKit-7621.2.5.11.8 --build-dir out_ipc_gen PixelStorei
== RemoteGraphicsContextGL::PixelStorei
declared:   Source/WebKit/GPUProcess/graphics/RemoteGraphicsContextGL.messages.in:155
            void PixelStorei(uint32_t pname, int32_t param)
direction:  WebContent -> GPU   [stream interface]
handler:    RemoteGraphicsContextGL::pixelStorei   (bound in out_ipc_gen/DerivedSources/WebKit/RemoteGraphicsContextGLMessageReceiver.cpp)
            Source/WebKit/GPUProcess/graphics/RemoteGraphicsContextGLFunctionsGenerated.h:793: void pixelStorei(uint32_t pname, int32_t param)
            Source/WebKit/WebProcess/GPU/graphics/RemoteGraphicsContextGLProxy.h:189: void pixelStorei(GCGLenum pname, GCGLint param) final;
            Source/WebKit/WebProcess/GPU/graphics/RemoteGraphicsContextGLProxyFunctionsGenerated.cpp:1065: void RemoteGraphicsContextGLProxy::pixelStorei(GCGLenum pname, GCGLint param)
sent from:  1 site(s)
    [WebContent]
        Source/WebKit/WebProcess/GPU/graphics/RemoteGraphicsContextGLProxyFunctionsGenerated.cpp:1069: auto sendResult = send(Messages::RemoteGraphicsContextGL::PixelStorei(pname, param));
```

Given an interface name instead, it lists every message with its kind
(async, async with reply, sync):

```text
$ python3 ipc_find.py --repo ~/WebKit --ref WebKit-7621.2.5.11.8 LogStream
interface LogStream  (Source/WebKit/Shared/LogStream.messages.in)
    direction: (not annotated) -> (not annotated)  [stream]
    1 message:
        LogOnBehalfOfWebContent  (async)
```

**`ipc_find.py`** shows only the annotations in the file. `LogStream` has
none at this tag and `ipc_map.py` below works out its direction.

**`ipc_map.py`** regenerates the whole map for any tag or commit. It writes
files with every IPC interface and message:

```sh
$ python3 ipc_map.py ~/WebKit WebKit-7621.2.5.11.8 out_ipc_map
# out_ipc_map/ipc_summary.md                interfaces and messages per direction (the table below)
# out_ipc_map/ipc_full_table.md             every interface, grouped by direction (Appendix A)
# out_ipc_map/ipc_all_messages_<ref>.md     every message of every interface (Appendix B)
# out_ipc_map/ipc_all_signatures_<ref>.md   every message with its arguments and reply
# out_ipc_map/ipc_map.json                  machine-readable
```

It reads every `*.messages.in` file at the given ref, so the interfaces
and messages always come from that version. Only an interface's
direction, from which process to which, may come from elsewhere. WebKit
added the `DispatchedFrom` and `DispatchedTo` annotations gradually and
at the Safari 18.5 tag 171 of the 216 interfaces have them. For 22 more,
the script borrows the same interface's annotations from `origin/main` and
for 11 it takes the processes whose code sends the interface's messages.
The last 12 come from comments in the files (2) and from a small table we
checked by hand for this release (10). With the same `origin/main`, the
script reproduces this post's tables exactly. For this post the commit
`9c83f601b16c` was used, from 14 October 2026.

### Regenerating the whole map

The summary table below and both appendices came from that one command. To
map a newer WebKit or to diff two releases' IPC surfaces, we run it on each
tag and compare the outputs. The interfaces, messages and signatures in
each output come from that tag. The directions of an older tree may come
from `origin/main`, so a change of direction between two outputs is only a
hint.

## The IPC surface by direction

A process's sandbox decides what it can reach directly. Through IPC it can
still ask another process to act for it. Every direction that messages flow
to is a door between two sandboxes. For security, the question is which
messages each process can send to each other process.

The Safari 18.5 tag has 216 interfaces with 3413 messages, 262 of them
synchronous. They come from the `*.messages.in` files in`Source/WebKit`,
without the code generator's test inputs. 13 messages are declared twice in
the same interface, once per platform under different `#if` branches, so
there are 3400 distinct pairs of interface and message. The 216 files are
more than the receivers that `ipc_generate.py` reported, which are the ones
`DerivedSources.make` lists for the build. `RemoteWCLayerTreeHost`,
`AcceleratedBackingStoreDMABuf`, `AcceleratedSurfaceDMABuf` and
`SystemSettingsManager` are only built for the Windows and Linux ports and
`UserMediaCaptureManager` has a second file for the Linux ports.

In the table below, the source is the process that sends the messages and
the destination is the process that receives and handles them. How each
direction was found is described with `ipc_map.py` above and the Notes
column of Appendix A [4] says it for every interface.

### Summary by direction

![IPC between WebKit's processes, one arrow per direction](webkit_processes_ipc_v2.svg)
*Every IPC direction between WebKit's processes in the Safari 18.5 tag*

| Source -> Destination | Interfaces | Messages |
|---|---|---|
| WebContent -> UI | 36 | 780 |
| WebContent -> GPU | 64 | 845 |
| WebContent -> Networking | 17 | 266 |
| WebContent -> Model | 3 | 17 |
| UI -> WebContent | 41 | 920 |
| UI -> GPU | 2 | 42 |
| UI -> Networking | 6 | 210 |
| UI -> Model | 2 | 13 |
| UI -> webpushd | 1 | 22 |
| GPU -> WebContent | 22 | 112 |
| GPU -> UI | 1 | 11 |
| Networking -> WebContent | 16 | 627 |
| Networking -> UI | 4 | 66 |
| Networking -> webpushd | 1 | 22 |
| Model -> WebContent | 2 | 6 |
| Model -> UI | 1 | 4 |
| test harness -> any process | 5 | 27 |

Interfaces with more than one direction are counted in each of their rows.

For an SBX, the rows that matter the most are those with WebContent as the
source, meaning **WebContent -> GPU, -> UI, -> Networking and -> Model**. A
compromised renderer can potentially send these messages with arbitrary
arguments, so every handler on the other side can then be part of the
sandbox-escape surface. WebContent -> GPU is the largest, with 64
interfaces and 845 messages, 581 of them on stream interfaces. WebGL's
`RemoteGraphicsContextGL` alone accepts 295. The rows into WebContent are
how the trusted processes drive the renderer. The renderer only receives on
them, so they are not part of its escape surface.

### Wrap them all

Appendix A [4] lists every interface by direction, with its message count
and defining file. Appendix B [5] lists every message of every interface.
Both come from the same `ipc_map.py` run. As a check, all 3363 distinct
messages that the Safari 18.5 source sends by name, as
`Messages::<Interface>::<Message>`, appear in the generated lists. That
count leaves out the code generator's test outputs, helper names such as
`messageReceiverName` and one message named only in a code comment.

## References

- [[1] Apple, XPC documentation](https://developer.apple.com/documentation/xpc)
- [[2] "Remove unnecessary Async attribute in .messages.in files", WebKit bug 237491, commit 8057faf90035 (March 2022)](https://github.com/WebKit/WebKit/commit/8057faf90035)
- [[3] webkit_playground, `ipc_tools/` (`ipc_find.py`, `ipc_map.py`, `ipc_generate.py`)](https://github.com/b00rito/webkit_playground/tree/main/ipc_tools)
- [[4] Appendix A: every WebKit IPC interface]({% link appendices/f3_a_ipc_interfaces.md %})
- [[5] Appendix B: every WebKit IPC message]({% link appendices/f3_b_ipc_messages.md %})

EOF
