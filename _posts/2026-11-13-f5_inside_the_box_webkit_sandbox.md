---
title: "Inside the box: how WebKit's sandbox works"
date: 2026-11-12 22:14:00
categories: [WebKit]
tags: [webkit, safari, ios, macos, sandbox, sandbox-escape, seatbelt, sbpl,
      browser-security, reverse-engineering]
description: >-
    WebKit, Inside Out: how Apple's sandbox confines WebKit's processes,
    what the WebContent profile allows, how WebKit tightens it after launch
    and what a sandbox escape has to get through.
series: "WebKit, Inside Out"
part: F5
---

Everything about WebKit's process model assumes WebContent can't just open
a socket, read the user's files or talk to any system service. The thing
that makes that true is the **sandbox**. Without it, a compromised renderer
would have free userland access. Its code would run under the logged-in
user's own identity, with the same rights as any other program that user
starts. With it, an attacker who gets code running in WebContent still
needs a second bug to get out. That's why we distinguish RCE from SBX at
all.

Here is what that free access would mean. The renderer could read and write
every file the user can, from documents and source code to SSH keys and
other apps' data, apart from the folders that macOS guards with its own
privacy prompts. It could open the files where cookies and website storage
live and take over the user's sessions on every site, not only on the
attacked one. Only the Networking process handles them, one site at a time.
It could open network connections to anywhere, including devices on the
local network and start other programs or leave files behind that run
again later. And it could look up any system service, where the 18.5 macOS
profile allows only 33 named Mach services. Separate processes would still
keep their memory apart and a crash would still take down only one tab, but
the split between them would no longer be a security boundary.

Everything in this post comes from the macOS Safari 18.5 WebKit release tag
[`WebKit-7621.2.5.11.8`](https://github.com/WebKit/WebKit/tree/WebKit-7621.2.5.11.8),
and every WebKit file named here can be read at that tag. Paths are
relative to `Source/WebKit/` or to `Source/` when they start with `WTF/`.

## What the sandbox is

Apple's sandbox ("Seatbelt") is a **kernel-enforced policy**. The kernel
checks every sensitive operation a sandboxed process attempts against the
process's **profile** [1][2]. It is built on the kernel's TrustedBSD
Mandatory Access Control framework (MACF). *Mandatory* means that Apple
sets the policy centrally and a user can't override it, not even for files
they own or created themselves [3]. On iOS it mainly guards the kernel and
its drivers, the system services reachable over IPC and parts of the file
system [3].

The action an app might want to perform is named an **operation**, such as
`iokit-get-properties`. A profile lists operations together with a decision
(allow or deny) and **filters**, which are conditions on the operation [3].
Profiles are written in SBPL, a Scheme-like language. A rule looks like:

```scheme
(deny default)                                      ; start from "nothing is allowed"
(allow mach-lookup (global-name "com.apple.fonts")) ; then allow specific things
(with-filter (lockdown-mode)                        ; conditionally
    (deny dynamic-code-generation))
```

A sample of the operations a profile controls:

- **files:** `file-read*`, `file-write*`;
- **Mach services and messages:** `mach-lookup` (which system services the
  process may even contact) and `mach-message-send`;
- **hardware drivers:** `iokit-open-service`, `iokit-open-user-client`,
  `iokit-get-properties`;
- **system calls:** `syscall-unix`, `syscall-mach`, `sysctl-read`;
- **network:** `network-outbound`;
- **processes:** `process-fork`, `process-exec`;
- **code:** `dynamic-code-generation`, i.e. JIT;
- **preferences and shared memory:** `user-preference-read`,
  `ipc-posix-shm-*`.

## One profile per process

The WebContent, GPU and Networking profiles all include
`Shared/Sandbox/common.sb`, which begins with **`(deny default)`**, so
anything not explicitly allowed is refused. Each process then adds what it
needs. In the 18.5 source:

| Process | Lines (macOS / iOS) | Character |
|---|---|---|
| WebContent | ~2,000 / ~1,500 | The tightest, with no network, few services and allow-listed system calls |
| GPU | ~1,300 / ~1,000 | Mostly IOKit rules (344 on macOS), for graphics and media drivers |
| Networking | ~870 / ~1,000 | Network access and website data, almost no IOKit |
| Daemons | small | Their own profiles; on iOS, Model's includes WebContent's |

The UI process, Safari itself, doesn't get a WebKit profile. It runs in the
app's own sandbox, which is App Sandbox on macOS [4] and `container` plus
exception entitlements on iOS. That's what makes it a valuable escape
target.

## What WebContent may (not) do

Reading the macOS WebContent profile in 18.5,
`WebProcess/com.apple.WebProcess.sb.in`:

- **No network.** The only `network-outbound` rule allows a syslog socket,
  and only on Apple-internal installs. All loads go through the Networking
  process.
- **Almost no writes.** A couple of cache and temp locations, passed in as
  parameters. Writes to `~/Library/Preferences` are explicitly denied, as
  is creating symlinks.
- **No new processes.** `process-fork` and `process-exec` are never
  allowed, so the default deny applies.
- **Allow-listed system calls.** Instead of "everything except dangerous
  calls", the profile lists the Unix and Mach system calls WebContent may
  make, about 19 `syscall-unix` and 8 `syscall-mach` allow blocks. That
  cuts down how much of the **kernel** a compromised renderer can reach.
- **A short list of Mach services**, many of them wrapped in **message
  filters**.
- **Restricted IOKit.** Most driver access is denied outright or removed
  after launch (below).
- **JIT only when allowed.** `dynamic-code-generation` is allowed for the
  JIT, but denied under Lockdown Mode.

## Message filters: narrowing even the allowed services

Allowing a Mach service or IOKit driver at all is coarse, because each one
exposes many operations. In 18.5, WebContent's profile also uses
**`apply-message-filter`** (when the `ENABLE_SANDBOX_MESSAGE_FILTER`
parameter is set) to restrict *which messages* may be sent to an allowed
service or driver. Even when WebContent may talk to a daemon, it can only
invoke the handful of operations it actually needs. That makes the
reachable code in that daemon much smaller and thus the attack surface
beyond WebKit is quite narrow.

## Tightening after launch: state flags

Some access is needed only during startup or only when a feature isn't
handled elsewhere. WebKit's answer is **sandbox state flags**, profile
rules conditioned on a named flag that the process turns on later
(`sandbox_enable_state_flag`). WebKit only ever turns flags *on* and its
sandbox interface (`WTF/wtf/spi/darwin/SandboxSPI.h`) declares no call to
turn one off. In 18.5 the flags are:

`BlockIOKitInWebContentSandbox`, `BlockWebInspectorInWebContentSandbox`,
`BlockMobileAssetInWebContentSandbox`,
`BlockMobileGestaltInWebContentSandbox` (iOS),
`BlockFontServiceInWebContentSandbox`,
`BlockIconServicesInWebContentSandbox`,
`BlockOpenDirectoryInWebContentSandbox` (macOS), plus
`EnableExperimentalSandbox` and QuickLook-related flags.

They're turned on in `WebProcess/WebPage/WebPage.cpp` when a page is
created, from the page's preferences. The clearest example is IOKit, where
**`BlockIOKitInWebContentSandbox` is set only when WebGL, canvas, DOM
rendering and media all run in the GPU process**. That's the security
payoff of moving graphics and media out of the renderer. Once they're out,
WebContent loses its access to hardware drivers, a major kernel attack
surface.

## Lockdown Mode, inside the profile

The macOS WebContent profile defines Lockdown Mode [5] in its own
terms:

```scheme
(define (lockdown-mode)
    (require-not (require-entitlement "com.apple.security.cs.allow-jit")))
(with-filter (lockdown-mode)
    (deny dynamic-code-generation))
```

A Lockdown Mode WebContent process is launched without the JIT entitlement,
alongside the `disable-jit` key in its XPC bootstrap message (set in
`UIProcess/Launcher/cocoa/ProcessLauncherCocoa.mm`). The sandbox then
forbids generating code at all. That's defence in depth, because even a bug
that re-enabled the JIT in the process couldn't make executable memory.

## Measuring before tightening

Many rules carry `(with report)` or `(with telemetry-backtrace)`. They
allow or deny as usual, but also report when they're hit. That's how Apple
learns which accesses real web pages need, so a later release can remove
the rest. That doesn't mean profiles only ever shrink. The attack surface
changes from release to release and can grow too.

## Sandbox extensions: controlled exceptions

A profile is fixed when the process starts. But some of what a process
needs only becomes clear later, while it runs and the profile can't list it
in advance. For that, WebKit uses **sandbox extensions**
(`Shared/SandboxExtension.h`). A more privileged process, usually the UI
process, creates a token that grants access to one specific thing, like a
Mach service to look up. It sends the token over IPC and the sandboxed
process consumes it to put it into effect. From then on, the sandbox allows
that one thing and nothing more.

A common case is a file the user gives to a web page, by choosing it in a
page's upload button or by dragging it onto the page. WebContent's profile
doesn't allow reading the user's files and it can't know in advance which
file the user will choose. The UI process knows because it showed the file
picker or received the drop, so it creates an extension for those files via
`WebPageProxy::didChooseFilesForOpenPanelWithDisplayStringAndIcon` for an
upload and the `PerformDragOperation` message for a drop.

Profiles can also ask for an extension. In the macOS WebContent profile,
opening some IOKit drivers, such as `IOAccelerator`, is allowed only for a
process that holds the `com.apple.webkit.extension.iokit` extension.

An extension works like a permission slip, so the process that issues it
has to be careful. If a compromised WebContent could get the UI process to
issue an extension for the wrong path, that alone would be a sandbox
escape.

## What a sandbox escape has to get through

If we put the pieces together, a "sandbox escape" has a precise meaning. An
attacker with code running in WebContent is limited by this profile. To get
out, they need a bug in something the profile **still lets them reach**:

| Reachable from WebContent | Typical bugs |
|---|---|
| IPC to the GPU, Networking and UI processes | Memory corruption in message handlers, missing validation |
| Shared memory and capabilities | Values changed after the check; an extension, handle or ID it shouldn't hold |
| Allowed Mach services | Bugs in the system daemons it may still contact |
| Allowed system calls and IOKit drivers | Kernel and driver bugs, fewer once IOKit is blocked |

The GPU and Networking processes are also sandboxed, more loosely and
differently. So a bug in them is a step up, not necessarily the end of the
chain. The GPU process's broad IOKit access is exactly why it's such a
valuable intermediate target.

## Reading the profiles

The profiles are plain text in the source tree, at the paths in the table
above. They're worth reading alongside each release's diff. Added `deny`
rules, new state flags and new message filters show where Apple is
tightening and `with report` rules show what's being measured. On a Mac,
Activity Monitor can show which processes are sandboxed (View > Columns >
Sandbox). On iOS, the profiles that actually run are the ones compiled into
`Sandbox.kext` and they can be unpacked and decompiled from the kernelcache
[3].

The `ipsw` tool [6] does that in a few commands, without downloading the
whole firmware. It fetches only the kernelcache, lists the builtin profiles
and decompiles one back to SBPL:

```sh
ipsw download ipsw --device iPhone16,1 --build 22F76 --kernel -y -o .       # iOS 18.5
ipsw sb list <kernelcache>                                                  # the builtin profiles
ipsw sb dec  <kernelcache> com.apple.WebKit.WebContent -O WebContent.sb     # one profile as SBPL
```

The decompiled iOS 18.5 WebContent profile is 2,634 lines long, against
about 1,500 in the source. It contains the files that the source pulls in
with `#include` and the decompiler writes one filter per line. Comparing
the two shows what actually runs on the device.


## References

- [[1] D. Blazakis, "The Apple Sandbox", Black Hat DC 2011](https://www.ise.io/wp-content/uploads/2017/07/apple-sandbox.pdf)
- [[2] J. Levin, "Hack in the (sand)Box"](https://newosxbook.com/files/HITSB.pdf)
- [[3] P. Argyroudis, "Vs com.apple.security.sandbox", CanSecWest 2019](https://census-labs.com/documents/sandbox-argp-csw2019-public.pdf)
- [[4] Apple, App Sandbox documentation](https://developer.apple.com/documentation/security/app-sandbox)
- [[5] Apple Support, About Lockdown Mode](https://support.apple.com/en-us/105120)
- [[6] blacktop, `ipsw`, iOS/macOS research tool](https://github.com/blacktop/ipsw)

EOF
