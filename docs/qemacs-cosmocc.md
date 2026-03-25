# Building qemacs with cosmocc

Build [qemacs](https://github.com/qemacs/qemacs) (Quick Emacs) as an
Actually Portable Executable using [cosmocc](https://github.com/jart/cosmopolitan).

The result is a single binary that runs natively on Linux, macOS, Windows,
FreeBSD, OpenBSD, and NetBSD on both x86_64 and aarch64.

## Prerequisites

- curl, unzip, git, make
- ~500MB disk for the cosmocc toolchain

## Quick start

```sh
./scripts/build-qemacs.sh
```

The output binary is `o/qemacs/qe` — a fat APE binary.

## Manual steps

### 1. Download cosmocc

```sh
mkdir -p o/cosmocc
curl -fsSL -o o/cosmocc/cosmocc.zip https://cosmo.zip/pub/cosmocc/cosmocc.zip
cd o/cosmocc && unzip -qo cosmocc.zip && cd ../..
export PATH="$PWD/o/cosmocc/bin:$PATH"
```

### 2. Clone qemacs

```sh
git clone https://github.com/qemacs/qemacs.git o/qemacs/src
```

### 3. Configure

qemacs has a custom configure script. Disable X11, plugins, and other
features that depend on system libraries not available in cosmocc:

```sh
cd o/qemacs/src
./configure \
    --cc=cosmocc \
    --disable-x11 \
    --disable-xv \
    --disable-xshm \
    --disable-html \
    --disable-plugins \
    --disable-ffmpeg \
    --prefix=/opt/cosmos
```

### 4. Build

```sh
make -j qe
```

If the full build has issues, try the tiny target which builds a minimal
terminal-only editor:

```sh
make -j tqe
```

Or use the single-file amalgamation build (bypasses the Makefile object
rules entirely):

```sh
cosmocc -O2 -funsigned-char -DCONFIG_TINY -o qe tqe.c -lm
```

### 5. Test

The resulting binary is a polyglot executable:

```sh
./qe              # runs on current OS
./qe --strace     # with cosmo syscall tracing
./qe --ftrace     # with cosmo function tracing
```

## Build output

The build produces:
- `qe_g` / `tqe_g` — unstripped APE binary (use this one)
- `qe` / `tqe` — stripped by system strip (breaks APE format)
- `.dbg` / `.aarch64.elf` — platform-specific ELF binaries

The build script copies the `_g` (unstripped) version since the system
`strip` doesn't understand the APE polyglot format.

## Running the binary

APE binaries need the APE loader on first run. Options:

```sh
# Option 1: use the APE loader directly
o/cosmocc/bin/ape-x86_64.elf o/qemacs/qe

# Option 2: assimilate to native ELF (loses portability)
o/cosmocc/bin/assimilate o/qemacs/qe
./o/qemacs/qe

# Option 3: install the APE loader system-wide (one-time)
sudo cp o/cosmocc/bin/ape-x86_64.elf /usr/bin/ape
sudo sh -c "echo ':APE:M::MZqFpD::/usr/bin/ape:' > /proc/sys/fs/binfmt_misc/register"
```

## Troubleshooting

### System strip breaks APE binary

The Makefile runs `strip -s -R .comment -R .note` using the host strip,
which doesn't understand APE format. Use the unstripped `_g` variant
instead (the build script handles this automatically).

### configure fails to detect cosmocc

The configure script looks for `clang`, `gcc`, `tcc` by default. Use
`--cc=cosmocc` explicitly.

### Linker errors for X11 / shared libraries

cosmocc produces static binaries only. Ensure all GUI features are
disabled via the configure flags above.

### Plugin / dlopen errors

cosmocc does not support dynamic loading. Use `--disable-plugins`.

## Why qemacs + cosmocc

qemacs is an ideal candidate for cosmocc because:
- Pure C with minimal dependencies
- Built-in VT100 terminal support (no ncurses)
- Small codebase (~50 source files)
- No GUI required for terminal mode
- MIT licensed
