---
title: "Frida (Part 2): hooking a real C binary on macOS and iOS"
date: 2026-09-27 15:12:00
categories: [Frida]
tags: [frida, macos, ios, jailbreak, hooking, dynamic-instrumentation,
      reverse-engineering, javascript]
description: >-
    Hooking the same real binary with Frida on macOS and a jailbroken iPad;
    syscall tracing, two pranks, and three mystery open() calls that only
    happen on iOS.
---

This time we will pick an existing binary on the system and hook it with
nothing but Frida. We only have the binary that we can disassemble and
nothing else.

For the tests we have both macOS and iOS - a jailbroken iPad running
`iPadOS 18.1`. Even though we are targeting iPadOS, the jailbreak and the
behavior is exactly the same for iOS.

## Why not just play with a pet?

Well, an animal that I am missing quite a lot on the streets lately is a
cat. So we will play with a `cat`. It is small and performs a very simple
specific task that includes `open()`/`read()`/`write()` of a file. Let's
just attach to it.

```bash
$ frida /bin/cat
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
Failed to attach: unexpected error while preparing target process for injection (get_thread_state returned '(os/kern) protection failure')
```

huh? What is blocking us?

Using `csrutil status` we can ensure that SIP is disabled. Let's check the
code signature:

```bash
codesign -dv /bin/cat
Executable=/bin/cat
Identifier=com.apple.cat
Format=Mach-O universal (x86_64 arm64e)
CodeDirectory v=20400 size=454 flags=0x0(none) hashes=9+2 location=embedded
Platform identifier=15
Signature size=4442
Signed Time=20.07.2024 at 07:24:58
Info.plist=not bound
TeamIdentifier=not set
Sealed Resources=none
Internal requirements count=1 size=64
```

`Platform identifier=15` means it is one of Apple's own platform binaries.
Such binaries get a stricter runtime protection and Frida cannot attach.

This is going to be a bit complicated, so let's simply pick another pet.

## Looking for the G spot

`gcat`, installed using Homebrew, does exactly what `cat` does. It reads a
file and writes it to stdout, it is just part of the GNU coreutils and not
signed by Apple:

```bash
$ codesign -dv `which gcat`
Executable=/opt/homebrew/Cellar/coreutils/9.12/bin/gcat
Identifier=cat
Format=Mach-O thin (arm64)
CodeDirectory v=20400 size=988 flags=0x20002(adhoc,linker-signed) hashes=28+0 location=embedded
Signature=adhoc
Info.plist=not bound
TeamIdentifier=not set
Sealed Resources=none
Internal requirements=none
```

Frida can attach to this without issues.

## One target, two devices

The `GNU coreutils` binary family is available on a jailbroken iOS device
too, through Sileo. Every example gets run on a Mac and an iPad jailbroken
with `palera1n` and `Sileo`.

The core idea is to use `gcat` and print the contents of `/etc/hosts`.

### iPad setup (a little bit)

We have to make sure that our idevice meets the following:

**1. idevice must be jailbroken.**

**2. ssh on the device.**

**3. Install Frida, via Sileo.**
Add Frida's repo if it isn't already there (`https://build.frida.re`), then
install `re.frida.server` from it. It's a `launchd` daemon and starts
automatically, listening on port `27042`.

**4. Install `coreutils`.**
Install it through `Sileo/Procursus`; same package family as on macOS. On
the idevice run `$ dpkg -L coreutils` to locate the installation dir. For
rootless palera1n setup it's under `/var/jb/usr/bin/cat`. On rootless
jailbreaks the real system volume is sealed and read-only, so the jailbreak
installs its own tree under a `/var/jb` prefix on the writable data volume.

**5. Redirect `frida-server` output to a file via its plist.**

Locate the frida server's launch daemon plist:

```bash
$ dpkg -L re.frida.server | grep -i plist
/var/jb/Library/LaunchDaemons/re.frida.server.plist
```

Add or update the two keys that set `stdout` and `stderr`:

```xml
<key>StandardOutPath</key>
<string>/var/jb/tmp/frida-server.log</string>
<key>StandardErrorPath</key>
<string>/var/jb/tmp/frida-server.log</string>
```

Reload the daemon so `launchd` actually picks up the change.

```bash
$ launchctl unload /var/jb/Library/LaunchDaemons/re.frida.server.plist
$ launchctl load /var/jb/Library/LaunchDaemons/re.frida.server.plist
```

And we are all set on the idevice!

One disclaimer that we have to make for the idevice. `console.log` does not
print anything to the idevice's stdout. The frida client on the Mac only
reads the `.js` file and sends it over USB to the frida-server on the
idevice. The server injects `frida-agent.dylib` into the target process,
and hands the script's source to it. The agent dylib carries a JavaScript
engine, so the script is compiled and executed inside the target process.
That's why `console.log` doesn't print; the agent lives inside `cat`, so
writing to stdout would mean writing to `cat`'s own output stream. Instead
it serializes each message and sends it back to the client, which prints it
on the Mac command line.

On the other hand, `cat`'s output is a plain POSIX file descriptor. `fd 1`
points at whatever the process inherited at exec time. When `cat` is
spawned by frida-server, it inherits frida-server's fd 1, which is
`/var/jb/tmp/frida-server.log` as we set it in the plist.

### Run a frida script on device

Let's use a rather dummy script that does nothing more than using
`console.log()` to print a message:

**`hook_gcat_dummy.js`**:
```javascript
console.log("[+] Hello from frida!");
```

To inject a frida script on a process on the idevice we have to first
locate the device's id and supply it as an argument to frida:

**1. Point Frida at the device instead of local**
We can list the connected devices like this:

```bash
$ frida-ls-devices
Id                                        Type    Name             OS
----------------------------------------  ------  ---------------  --------------
ddc4bfeff46b15dbfc429a850089eaecccc17221  usb     iPad             iPhone OS 18.1
```

And use `-U` to connect to usb device:

```bash
$ frida -U -f /var/jb/usr/bin/cat -l hook_gcat_dummy.js -- /etc/hosts
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
   . . . .   Connected to iPad (id=ddc4bfeff46b15dbfc429a850089eaecccc17221)
Spawning `/var/jb/usr/bin/cat`...
[+] Hello from frida!
Spawned `/var/jb/usr/bin/cat`. Resuming main thread!
[iPad::cat ]-> Process terminated
[iPad::cat ]->

Thank you for using Frida!
```

The script runs correctly. As we can see, the log message is shown on the
client side; nothing is printed on the active ssh session we have on the
idevice.

**2. Tail the log file on the idevice**
From an SSH session on the idevice we can use `tail` to see the hooked
process' output - in this case the output of `cat /etc/hosts`:

```bash
$ tail /var/jb/tmp/frida-server.log
##
# Host Database
#
# localhost is used to configure the loopback interface
# when the system is booting.  Do not change this entry.
##
127.0.0.1       localhost
255.255.255.255 broadcasthost
::1             localhost
```

The tail of the file will always be the same, so we skip presenting it in
every example from now on.

## What's up `G`-`cat`?

Now we have our set-up ready and we can start playing...

### Attempt 1: hook `open()`

In the first script we will hook `open()` and print the path of the file
that is getting opened.

**`hook_gcat_open.js`**:
```javascript
const openPtr = Module.getGlobalExportByName("open");

console.log("[+] open() found at:", openPtr);

Interceptor.attach(openPtr, {
    onEnter(args) {
        this.path = args[0].readUtf8String();
    },
    onLeave(retval) {
        console.log("[*] open(\"" + this.path + "\") ->", retval);
    }
});
```

**macOS:**
```bash
$ frida -f /opt/homebrew/Cellar/coreutils/9.12/bin/gcat -l hook_gcat_open.js -- /etc/hosts
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
Spawning `/opt/homebrew/Cellar/coreutils/9.12/bin/gcat /etc/hosts`...
[+] open() found at: 0x187db0918
Spawned `/opt/homebrew/Cellar/coreutils/9.12/bin/gcat /etc/hosts`. Resuming main thread!
##
# Host Database
#
# localhost is used to configure the loopback interface
# when the system is booting.  Do not change this entry.
##
127.0.0.1       localhost
255.255.255.255 broadcasthost
::1             localhost

[Local::gcat ]-> [*] open("/etc/hosts") -> 0x3
Process terminated
[Local::gcat ]->
```

Exactly the basics we set out to show. `gcat` just uses plain `open()`
directly. We can see one call, the input filename, fd 3.

**iPad:**
```bash
$ frida -U -f /var/jb/usr/bin/cat -l hook_gcat_open.js -- /etc/hosts
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
   . . . .   Connected to iPad (id=ddc4bfeff46b15dbfc429a850089eaecccc17221)
Spawning `/var/jb/usr/bin/cat /etc/hosts`...
[+] open() found at: 0x1e62912a8
Spawned `/var/jb/usr/bin/cat /etc/hosts`. Resuming main thread!
[iPad::cat ]-> [*] open("/private/preboot/A283518C2BDFE6F82178AA5E06B8EF07CAEBE6A1585D9B4D940ADA1D06DEF3097A8A85904F7954DE8894597E804F2B2D/jb-wUVoaZ2B/procursus/usr/bin/cat") -> 0x3
[*] open("/private/preboot/A283518C2BDFE6F82178AA5E06B8EF07CAEBE6A1585D9B4D940ADA1D06DEF3097A8A85904F7954DE8894597E804F2B2D/jb-wUVoaZ2B/procursus/usr/bin") -> 0x3
[*] open("/private/preboot/A283518C2BDFE6F82178AA5E06B8EF07CAEBE6A1585D9B4D940ADA1D06DEF3097A8A85904F7954DE8894597E804F2B2D/jb-wUVoaZ2B/procursus/usr/bin/Info.plist") -> 0xffffffffffffffff
[*] open("/etc/hosts") -> 0x3
Process terminated
[iPad::cat ]->

Thank you for using Frida!
```

There are 4 discrete calls to `open()`:
```bash
[*] open("/private/preboot/A283518C.../jb-wUVoaZ2B/procursus/usr/bin/cat") -> 0x3
[*] open("/private/preboot/A283518C.../jb-wUVoaZ2B/procursus/usr/bin") -> 0x3
[*] open("/private/preboot/A283518C.../jb-wUVoaZ2B/procursus/usr/bin/Info.plist") -> 0xffffffffffffffff
[*] open("/etc/hosts") -> 0x3
```

Here things are a bit more complicated. The call at the end seems to be the
real call to `open()` we requested from `cat`, it even matches the macOS
counterpart - `/etc/hosts`, fd 3.

The rest of the three extra `open()` calls are never made on the macOS
example. `cat` is opening its *own* binary path, its containing directory,
then probing for an `Info.plist` that doesn't exist.

What the hell is going on here?

First we play; then we explore ;)

### Attempt 2: `read()`/`write()` chunk sizes

Next we will investigate the calls that are made to `read()`, `write()` and
`fstat()`. We will also log the size of the data read or written.

**`hook_gcat_read_write.js`**:
```javascript
const fstatPtr = Module.getGlobalExportByName("fstat");
const readPtr = Module.getGlobalExportByName("read");
const writePtr = Module.getGlobalExportByName("write");

console.log("[+] fstat() found at:", fstatPtr);
console.log("[+] read() found at:", readPtr);
console.log("[+] write() found at:", writePtr);

Interceptor.attach(fstatPtr, {
    onLeave(retval) {
        console.log("[*] fstat() ->", retval);
    }
});

Interceptor.attach(readPtr, {
    onEnter(args) {
        this.requested = args[2].toInt32();
    },
    onLeave(retval) {
        console.log("[*] read(requested=" + this.requested + ") ->", retval);
    }
});

Interceptor.attach(writePtr, {
    onEnter(args) {
        this.requested = args[2].toInt32();
    },
    onLeave(retval) {
        console.log("[*] write(requested=" + this.requested + ") ->", retval);
    }
});
```

**macOS:**
```bash
$ frida -f /opt/homebrew/Cellar/coreutils/9.12/bin/gcat -l hook_gcat_read_write.js -- /etc/hosts
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
Spawning `/opt/homebrew/Cellar/coreutils/9.12/bin/gcat /etc/hosts`...
[+] fstat() found at: 0x187db320c
[+] read() found at: 0x187da598c
[+] write() found at: 0x187da88ec
Spawned `/opt/homebrew/Cellar/coreutils/9.12/bin/gcat /etc/hosts`. Resuming main thread!
[Local::gcat ]-> [*] fstat() -> 0x0
[*] fstat() -> 0x0
[*] fstat() -> 0x0
[*] fstat() -> 0x0
[*] fstat() -> 0x0
##
# Host Database
#
# localhost is used to configure the loopback interface
# when the system is booting.  Do not change this entry.
##
127.0.0.1       localhost
255.255.255.255 broadcasthost
::1             localhost
[*] fstat() -> 0x0
[*] fstat() -> 0x0
[*] fstat() -> 0x0
[*] fstat() -> 0x0
[*] read(requested=262144) -> 0xed
[*] write(requested=237) -> 0xed
[*] read(requested=262144) -> 0x0
Process terminated
[Local::gcat ]->

Thank you for using Frida!
```

Most of the `fstat()` calls in the trace are not `cat`'s at all. Some of
them happen before the input file is even opened and they come from
`libsystem_c.dylib`.

```bash
$ frida -U -f /var/jb/usr/bin/cat -l hook_gcat_read_write.js -- /etc/hosts
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
   . . . .   Connected to iPad (id=ddc4bfeff46b15dbfc429a850089eaecccc17221)
Spawning `/var/jb/usr/bin/cat /etc/hosts`...
[+] fstat() found at: 0x1e628c200
[+] read() found at: 0x1e6290aac
[+] write() found at: 0x1e628ff5c
Spawned `/var/jb/usr/bin/cat /etc/hosts`. Resuming main thread!
[iPad::cat ]-> [*] read(requested=512) -> 0x200
[*] fstat() -> 0x0
[*] fstat() -> 0x0
[*] fstat() -> 0x0
[*] fstat() -> 0x0
[*] fstat() -> 0x0
[*] fstat() -> 0x0
[*] read(requested=262144) -> 0xd5
[*] write(requested=213) -> 0xd5
[*] read(requested=262144) -> 0x0
Process terminated
[iPad::cat ]->

Thank you for using Frida!
```

The output looks slightly different.

## Prank tier

### Confused `cat`

`open()` isn't only called on the file that is `cat`ed. Touching every call
indiscriminately has consequences beyond our hook. We will now try to only
touch the one call we actually mean. The idea would be to replace the
requested file with a file supplied as argument.

Neither path is hardcoded in the script. The file being `cat`ed we can read
straight out of the target's own `argv`. The joke file, though, has to come
from us and frida has a mechanism for that. Using the `-P` flag takes a
JSON blob on the command line and hands it to the agent.

The agent receives it through a convention of `frida-tools`, not via a
frida API. If our script exports a function named `init`, the CLI calls it
as `init(stage, parameters)` once the script is loaded. E.g.:

```javascript
rpc.exports.init = function (stage, params) {
    console.log("[init] stage:", stage);
    console.log("[init] params:", JSON.stringify(params));
};
```

`rpc.exports` itself is the general way an agent exposes functions to
whoever loaded it; `init` just happens to be the name `frida-tools` looks
for. `stage` tells us how we got here - `early` when the process was
spawned with `-f` and has not been resumed yet or `late` when we attached
to something already running with `-p`:

```bash
$ frida -f <cat> -l script.js -P '{"a":1}' -- /etc/hosts
[init] stage: early
[init] params: {"a":1}

$ frida -p $(pgrep -x cat) -l script.js -P '{"a":1}'
[init] stage: late
[init] params: {"a":1}
```

Two details worth keeping in mind. First, top-level code in the script runs
*before* `init` does, so anything that depends on the parameters has to
live inside `init`. This is why the `Interceptor.attach` below sits in
there instead of at the top of the file. Second, in spawn mode `early`
means the hook is installed before the target has executed a single
instruction, which is what makes this prank reliable rather than a race.

**`hook_gcat_confused.js`**:
```javascript
function fileArg() {
    const getArgv = new NativeFunction(Module.getGlobalExportByName('_NSGetArgv'), 'pointer', []);
    const argv = getArgv().readPointer();

    for (let i = 1; ; i++) {
        const slot = argv.add(i * Process.pointerSize).readPointer();

        if (slot.isNull()) {
            return null;
        }

        const arg = slot.readUtf8String();

        if (!arg.startsWith('-')) {
            return arg;
        }
    }
}

rpc.exports.init = function (stage, params) {
    const jokePath = params && params.jokePath;
    const target = fileArg();

    if (!jokePath || !target) {
        console.log("[!] need a file argument and -P '{\"jokePath\":\"/abs/path\"}'");
        return;
    }

    const jokePathNative = Memory.allocUtf8String(jokePath);

    console.log("[+] redirecting", target, "->", jokePath);

    Interceptor.attach(Module.getGlobalExportByName("open"), {
        onEnter(args) {
            if (args[0].readUtf8String() !== target) {
                return;
            }

            console.log("[*] open(\"" + target + "\") - redirected to the joke file");
            args[0] = jokePathNative;
        }
    });
};
```

**macOS:**
```bash
$ frida -f /opt/homebrew/Cellar/coreutils/9.12/bin/gcat -l hook_gcat_confused.js -P '{"jokePath":"always_this.txt"}' -- /etc/hosts
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
Spawning `/opt/homebrew/Cellar/coreutils/9.12/bin/gcat /etc/hosts`...
[+] redirecting /etc/hosts -> always_this.txt
Spawned `/opt/homebrew/Cellar/coreutils/9.12/bin/gcat /etc/hosts`. Resuming main thread!
=^..^=  MEOW!  =^..^=

You asked for a specific file. Frida had other plans.
This is the ONLY file that exists now. Deal with Frida's sketch!
[Local::gcat ]-> [*] open("/etc/hosts") - redirected to the joke file
Process terminated
[Local::gcat ]->

Thank you for using Frida!
```

For the same to run on iPad we have to create the joke file there and
supply the absolute path on the device as argument. We create it at
`/var/jb/tmp/always_this.txt`.

**iPad**, guard in place:
```bash
$ frida -U -f /var/jb/usr/bin/cat -l hook_gcat_confused.js -P '{"jokePath":"/var/jb/tmp/always_this.txt"}' -- /etc/hosts
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
   . . . .   Connected to iPad (id=ddc4bfeff46b15dbfc429a850089eaecccc17221)
Spawning `/var/jb/usr/bin/cat /etc/hosts`...
[+] redirecting /etc/hosts -> /var/jb/tmp/always_this.txt
Spawned `/var/jb/usr/bin/cat /etc/hosts`. Resuming main thread!
[iPad::cat ]-> [*] open("/etc/hosts") - redirected to the joke file
Process terminated
[iPad::cat ]->

Thank you for using Frida!
```

The joke file's actual content only shows up via the `tail -f` log on
device:

```bash
$ tail /var/jb/tmp/frida-server.log
You asked for a specific file. Frida had other plans.
This is the ONLY file that exists now. Deal with Frida's sketch!
=^..^=  iPad MEOW!  =^..^=
```

### `cat` but it lies

Let's make `write()` to start lying about the file's contents, like it's
losing its words and making no sense :P

**`hook_gcat_lies.js`**:
```javascript
const writePtr = Module.getGlobalExportByName("write");
const CORRUPTION_RATE = 0.1;    // 10% of bytes get mutated

console.log("[+] write() found at:", writePtr);

Interceptor.attach(writePtr, {
    onEnter(args) {
        const buf = args[1];
        const total = args[2].toInt32();
        let corrupted = 0;

        for (let i = 0; i < total; i++) {
            if (Math.random() < CORRUPTION_RATE) {
                buf.add(i).writeU8(Math.floor(Math.random() * 256));
                corrupted++;
            }
        }

        if (corrupted > 0) {
            console.log("[*] write() - corrupted", corrupted, "/", total, "bytes on the way out");
        }
    }
});
```

**macOS:**
```bash
$ frida -f /opt/homebrew/Cellar/coreutils/9.12/bin/gcat -l hook_gcat_lies.js -- always_this.txt
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
Spawning `/opt/homebrew/Cellar/coreutils/9.12/bin/gcat always_this.txt`...
[+] write() found at: 0x187da88ec
Spawned `/opt/homebrew/Cellar/coreutils/9.12/bin/gcat always_this.txt`. Resuming main thread!
=^..^= MEOW!  ^..^=

You askmd foa speHc file. Frida Fad other plDns.
This is theCUNL file that ist now. Dea with Frida's sk4ch!
[Local::gcat ]-> [*] write() - corrupted 20 / 142 bytes on the way out
Process terminated
[Local::gcat ]->

Thank you for using Frida!
```

Hehe nice! Let's now do the same for `/etc/hosts` on the idevice:

**iPad:**
```bash
$ frida -U -f /var/jb/usr/bin/cat -l hook_gcat_lies.js -- /etc/hosts
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
   . . . .   Connected to iPad (id=ddc4bfeff46b15dbfc429a850089eaecccc17221)
Spawning `/var/jb/usr/bin/cat /etc/hosts`...
[+] write() found at: 0x1e628ff5c
Spawned `/var/jb/usr/bin/cat /etc/hosts`. Resuming main thread!
[iPad::cat ]-> [*] write() - corrupted 15 / 213 bytes on the way out
Process terminated
[iPad::cat ]->

Thank you for using Frida!
```

Same hook, same technique, both platforms report success and exit
cleanly with corrupted bytes already on their way out.

## The extra open() on idevice

As we saw earlier, there were 4 discrete calls to `open()` when we hooked
it on the device. For simplicity we will trim the huge path prefix:

```bash
[*] open(".../procursus/usr/bin/cat")           -> 0x3
[*] open(".../procursus/usr/bin")               -> 0x3
[*] open(".../procursus/usr/bin/Info.plist")    -> 0xffffffffffffffff
[*] open("/etc/hosts")                          -> 0x3
```

Comparing it to the behavior on macOS, it is clear that there are 3 extra
`open()` calls that we have no idea where they come from.

To figure out who called it we are going to use `this.returnAddress` to get
the immediate caller and `Thread.backtrace()` to walk the chain.

**`hook_gcat_open_backtrace.js`**:
```javascript
const openPtr = Module.getGlobalExportByName("open");

console.log("[+] open() found at:", openPtr);

Interceptor.attach(openPtr, {
    onEnter(args) {
        this.path = args[0].readUtf8String();

        const retAddr = this.returnAddress;
        const mod = Process.findModuleByAddress(retAddr);

        console.log("\n========================================");
        console.log("[*] open(\"" + this.path + "\")");
        console.log("    immediate caller: " + (mod ? mod.name : "??") + "  @ " + retAddr);

        try {
            const bt = Thread.backtrace(this.context, Backtracer.ACCURATE);
            console.log("    --- backtrace ---");

            bt.forEach(a => {
                const m = Process.findModuleByAddress(a);
                console.log("      " + (m ? m.name : "??") + "  " + DebugSymbol.fromAddress(a));
            });
        } catch (e) {
            console.log("    backtrace failed: " + e.message);
        }
    }
});
```

Running it we get the following output:

**iPad:**
```bash
$ frida -U -f /var/jb/usr/bin/cat -l hook_gcat_open_backtrace.js -- /etc/hosts
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
   . . . .   Connected to iPad (id=ddc4bfeff46b15dbfc429a850089eaecccc17221)
Spawning `/var/jb/usr/bin/cat /etc/hosts`...
[+] open() found at: 0x1e62912a8
Spawned `/var/jb/usr/bin/cat /etc/hosts`. Resuming main thread!
[iPad::cat ]->
========================================
[*] open("/private/preboot/A283518C2BDFE6F82178AA5E06B8EF07CAEBE6A1585D9B4D940ADA1D06DEF3097A8A85904F7954DE8894597E804F2B2D/jb-wUVoaZ2B/procursus/usr/bin/cat")
    immediate caller: CoreFoundation  @ 0x19bffa794
    --- backtrace ---
      CoreFoundation  0x19bffa794 CoreFoundation!_CFBundleGrokFileType
      CoreFoundation  0x19bffa640 CoreFoundation!_CFBundleGrokBinaryType
      CoreFoundation  0x19bf9be28 CoreFoundation!CFBundleGetMainBundle
      CoreFoundation  0x19bf4eed0 CoreFoundation!_CFPrefsGetCacheStringForBundleID
      CoreFoundation  0x19bf60f7c CoreFoundation!normalizeQuintuplet
      CoreFoundation  0x19bf60de0 CoreFoundation!-[_CFXPreferences withSearchListForIdentifier:container:cloudConfigurationURL:perform:]
      CoreFoundation  0x19bf60cfc CoreFoundation!-[_CFXPreferences copyAppValueForKey:identifier:container:configurationURL:]
      CoreFoundation  0x19bf60998 CoreFoundation!_CFPreferencesCopyAppValueWithContainerAndConfiguration
      libintl.8.dylib  0x102249b34 libintl.8.dylib!0x9b34 (0x9b34)
      libintl.8.dylib  0x102248e44 libintl.8.dylib!libintl_setlocale
      cat  0x1021fd6dc cat!main
      dyld  0x1022928ac dyld!start

========================================
[*] open("/private/preboot/A283518C2BDFE6F82178AA5E06B8EF07CAEBE6A1585D9B4D940ADA1D06DEF3097A8A85904F7954DE8894597E804F2B2D/jb-wUVoaZ2B/procursus/usr/bin")
    immediate caller: libxpc.dylib  @ 0x1f8b3b694
    --- backtrace ---
      libxpc.dylib  0x1f8b3b694 libxpc.dylib!_resolve_and_stat_path
      libxpc.dylib  0x1f8b3b7dc libxpc.dylib!_xpc_bundle_resolve_root
      libxpc.dylib  0x1f8b3b0b8 libxpc.dylib!_xpc_bundle_resolve_sync
      libxpc.dylib  0x1f8b3ae04 libxpc.dylib!___xpc_bundle_resolve_block_invoke
      libdispatch.dylib  0x1a351ca8c libdispatch.dylib!_dispatch_client_callout
      libdispatch.dylib  0x1a34c11d8 libdispatch.dylib!_dispatch_once_callout
      libxpc.dylib  0x1f8b3aa54 libxpc.dylib!_xpc_bundle_resolve
      libxpc.dylib  0x1f8b3ac04 libxpc.dylib!xpc_bundle_get_info_dictionary
      libsystem_trace.dylib  0x1b515ba38 libsystem_trace.dylib!_os_trace_init_slow
      libdispatch.dylib  0x1a351ca8c libdispatch.dylib!_dispatch_client_callout
      libdispatch.dylib  0x1a34c11d8 libdispatch.dylib!_dispatch_once_callout
      libsystem_trace.dylib  0x1b514ed68 libsystem_trace.dylib!os_log_create
      CoreFoundation  0x19bfeb4a0 CoreFoundation!___CFBundleLoadingLogger_block_invoke
      libdispatch.dylib  0x1a351ca8c libdispatch.dylib!_dispatch_client_callout
      libdispatch.dylib  0x1a34c11d8 libdispatch.dylib!_dispatch_once_callout
      CoreFoundation  0x19bfe18f8 CoreFoundation!_CFBundleLoadingLogger

========================================
[*] open("/private/preboot/A283518C2BDFE6F82178AA5E06B8EF07CAEBE6A1585D9B4D940ADA1D06DEF3097A8A85904F7954DE8894597E804F2B2D/jb-wUVoaZ2B/procursus/usr/bin/Info.plist")
    immediate caller: libxpc.dylib  @ 0x1f8b3b0fc
    --- backtrace ---
      libxpc.dylib  0x1f8b3b0fc libxpc.dylib!_xpc_bundle_resolve_sync
      libxpc.dylib  0x1f8b3ae04 libxpc.dylib!___xpc_bundle_resolve_block_invoke
      libdispatch.dylib  0x1a351ca8c libdispatch.dylib!_dispatch_client_callout
      libdispatch.dylib  0x1a34c11d8 libdispatch.dylib!_dispatch_once_callout
      libxpc.dylib  0x1f8b3aa54 libxpc.dylib!_xpc_bundle_resolve
      libxpc.dylib  0x1f8b3ac04 libxpc.dylib!xpc_bundle_get_info_dictionary
      libsystem_trace.dylib  0x1b515ba38 libsystem_trace.dylib!_os_trace_init_slow
      libdispatch.dylib  0x1a351ca8c libdispatch.dylib!_dispatch_client_callout
      libdispatch.dylib  0x1a34c11d8 libdispatch.dylib!_dispatch_once_callout
      libsystem_trace.dylib  0x1b514ed68 libsystem_trace.dylib!os_log_create
      CoreFoundation  0x19bfeb4a0 CoreFoundation!___CFBundleLoadingLogger_block_invoke
      libdispatch.dylib  0x1a351ca8c libdispatch.dylib!_dispatch_client_callout
      libdispatch.dylib  0x1a34c11d8 libdispatch.dylib!_dispatch_once_callout
      CoreFoundation  0x19bfe18f8 CoreFoundation!_CFBundleLoadingLogger
      CoreFoundation  0x19bf9be5c CoreFoundation!CFBundleGetMainBundle
      CoreFoundation  0x19bf4eed0 CoreFoundation!_CFPrefsGetCacheStringForBundleID

========================================
[*] open("/etc/hosts")
    immediate caller: cat  @ 0x1021fd9a0
    --- backtrace ---
      cat  0x1021fd9a0 cat!main
      dyld  0x1022928ac dyld!start
Process terminated
[iPad::cat ]->

Thank you for using Frida!
```

Starting with `.../procursus/usr/bin/cat`, the first call after `main` in
the backtrace is `libintl_setlocale`. So it has to do with the locale. The
other 2? As we notice the backtrace is cut off. This happens because
according to documentation, the generated backtrace is currently limited to
16 frames and is not adjustable without recompiling Frida. The real stack
continues below what we see.

Let's hook `libintl_setlocale` entry and exit and print `open()` calls in
between. This would be one way to verify if the rest 2 `open` calls are
also coming from the setlocale.

**`hook_setlocale_window.js`**:
```javascript
let depth = 0;

Interceptor.attach(Module.getGlobalExportByName("libintl_setlocale"), {
    onEnter(args) {
        depth++;
        console.log(">>> libintl_setlocale() ENTER");
    },
    onLeave(retval) {
        console.log("<<< libintl_setlocale() LEAVE");
        depth--;
    }
});

Interceptor.attach(Module.getGlobalExportByName("open"), {
    onEnter(args) {
        this.path = args[0].readUtf8String();
    },
    onLeave(retval) {
        const where = (depth > 0) ? "INSIDE setlocale" : "outside";
        console.log("    open(\"" + this.path + "\") -> " + retval.toInt32()
                    + "   [" + where + "]");
    }
});
```

**iPad:**
```bash
$ frida -U -f /var/jb/usr/bin/cat -l hook_setlocale_window.js -- /etc/hosts
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
   . . . .   Connected to iPad (id=ddc4bfeff46b15dbfc429a850089eaecccc17221)
Spawned `/var/jb/usr/bin/cat /etc/hosts`. Resuming main thread!
[iPad::cat ]-> >>> libintl_setlocale() ENTER
    open("/private/preboot/A283518C2BDFE6F82178AA5E06B8EF07CAEBE6A1585D9B4D940ADA1D06DEF3097A8A85904F7954DE8894597E804F2B2D/jb-wUVoaZ2B/procursus/usr/bin/cat") -> 3   [INSIDE setlocale]
    open("/private/preboot/A283518C2BDFE6F82178AA5E06B8EF07CAEBE6A1585D9B4D940ADA1D06DEF3097A8A85904F7954DE8894597E804F2B2D/jb-wUVoaZ2B/procursus/usr/bin") -> 3   [INSIDE setlocale]
    open("/private/preboot/A283518C2BDFE6F82178AA5E06B8EF07CAEBE6A1585D9B4D940ADA1D06DEF3097A8A85904F7954DE8894597E804F2B2D/jb-wUVoaZ2B/procursus/usr/bin/Info.plist") -> -1   [INSIDE setlocale]
<<< libintl_setlocale() LEAVE
    open("/etc/hosts") -> 3   [outside]
Process terminated
[iPad::cat ]->

Thank you for using Frida!
```

Or to make it a bit more clean:
```bash
>>> libintl_setlocale() ENTER
    open(".../procursus/usr/bin/cat")           -> 3    [INSIDE setlocale]
    open(".../procursus/usr/bin")               -> 3    [INSIDE setlocale]
    open(".../procursus/usr/bin/Info.plist")    -> -1   [INSIDE setlocale]
<<< libintl_setlocale() LEAVE
    open("/etc/hosts") -> 3   [outside]
```

So all the 3 extra `open()` calls have to do with locale!

### What is a locale anyway

A locale is a bundle of regional conventions that a program consults so it
can treat text the way a local user expects. For example which bytes count
as letters and how to change their case, whether today is `12/25/2025` or
`25.12.2025` and which language the program's own messages should be
printed in. A name like `en_US.UTF-8` spells out all three parts of the
answer - language `en`, region `US`, encoding `UTF-8`.

These conventions are data files on disk, under `/usr/share/locale` and
`setlocale()` is the call that goes and reads them.

`gcat` calls `setlocale(LC_ALL, "")` early in `main()`. It makes `--help`
come out in the user's language, and makes text handling follow the user's
conventions. An empty string means to get the locale information from the
environment.

An idea that comes into mind is that iOS/iPadOS is localized through
`NSLocale`/`CFLocale`. It reads the user's choices from `Settings ->
General -> Language & Region` and pulls translated strings out of `.lproj`
folders inside app bundles. The POSIX locale database is a separate system
that exists to serve C programs calling `setlocale()`. On iOS/iPadOS it is
not shipped:

```bash
$ echo "macOS:" `ls /usr/share/locale/ | wc -l`
macOS: 207

$ echo "iPadOS:" `ls /usr/share/locale/ | wc -l`
iPadOS: 1
```

iPadOS has 1 entry for `UTF-8`.

So `gcat` asks the POSIX system for a locale but finds nothing usable. Then
`gettext` falls back to asking CoreFoundation, which means bootstrapping
CF's bundle machinery. The bootstrapping involves opening the executable,
opening the directory it lives in, and looking for an `Info.plist` that a
loose binary in `usr/bin` was never going to have.

## Wrap-up

What's new in this round is the cross-platform approach. The same scripts,
unmodified except for one guard we needed on both platforms anyway, run
identically on a Mac and a jailbroken iPad. The interesting differences
turned out to be about the *platform*. Extra `open()`/`read()` calls around
process launch on iOS that don't exist on macOS.

Also getting `frida-server`'s output somewhere useful took a real detour
through `launchd` plists. Worth remembering that half the work of hooking a
second platform is just getting the plumbing to a point where you can see
how the data flows.

## References

- [Frida](https://frida.re/)
- [Frida for iOS (build.frida.re)](https://build.frida.re/)
- [palera1n](https://palera.in/)
- [Sileo](https://getsileo.app/)
- [Procursus](https://github.com/ProcursusTeam/Procursus)
- [Scripts for this post](https://github.com/b00rito/frida_playground.git)

EOF
