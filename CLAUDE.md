# nix-macos-rootless

Rootless (no sudo, no daemon) single-user Nix on macOS. `install.sh` fetches
the official Nix tarball, patches its installer, and installs everything into
`$HOME/.local/share/nix`, faking `/nix` into existence via
[fakedir](https://github.com/nixie-dev/fakedir) (DYLD interposition).

**`install.sh` is the source of truth for the concrete steps.** This file
explains the architecture, the invariants that must not be broken, and the
debugging knowledge earned while getting this working. Do not duplicate
install steps here.

## Repo layout

- `install.sh` — the entire installer; `curl | bash` entry point (runs from
  `main`, then clones the `nix/<version>` branch matching
  `$NIX_INSTALL_VERSION` for the version-pinned patch files).
- `src/` — files copied into the unpacked nix installer directory:
  - `fakedir.source`, `dyld.source` — env setup sourced *inside the patched
    nix `install` script only* (bootstrap; see below).
  - `fakedirexec.c` — tiny exec trampoline (~15 lines): execs its argument
    with `DYLD_INSERT_LIBRARIES` + `FAKEDIR_*` already in the environment.
- fakedir itself is built from `https://github.com/Sharsie/fakedir`, branch
  `hotfix/rootless-nix-install` — upstream `nixie-dev/fakedir` @ `82bfac1`
  plus our fixes (see "Fakedir bugs fixed" below). The older ToxicPine fork
  commit `ef647a7` is *not* the base; three of its pieces were cherry-picked
  (exec-family coverage, `/bin/sh`→PATH-shell redirect, `rewrite_path` bounds
  hardening) and its Go-toolchain DYLD strip was deliberately rejected (its
  `strstr(path, "-go-")` heuristic false-positives on `*-go-modules` and
  would silently strip injection where needed).

## Architecture — the one insight everything follows from

macOS SIP strips `DYLD_*` environment variables when exec'ing **protected**
binaries (`/bin/sh`, `/usr/bin/*`, …), but **non-protected** binaries
(everything in the store, anything we compile) keep them. Consequences:

- A plain shell can never traverse `/nix` or exec profile binaries — `/nix`
  does not exist for it. This is by design, not a bug to fix.
- Once *one* injected process runs, fakedir's `posix_spawn`/`exec*`
  interposers keep the injection alive in all descendants: they re-insert
  the library and `FAKEDIR_*` vars into the child envp, preload the target's
  `/nix` Mach-O dylib closure via `DYLD_INSERT_LIBRARIES`, and export the
  closure's `LC_RPATH` + dependency dirs as `DYLD_FALLBACK_LIBRARY_PATH`
  (resolves `@rpath/…` and renamed refs without any maintained list).
- Entry into the injected world from a normal shell goes through the
  wrappers in `~/.local/share/nix/bin` (put on PATH): each is a symlink to
  one dispatcher script that sets the env and execs
  `fakedirexec "$HOME/.nix-profile/bin/$(basename "$0")"`.
  Bash *sets* env vars fine inside a protected shell — stripping happens
  only at exec time — so a shell script self-provisioning `DYLD_*` and then
  exec'ing a non-protected trampoline works.

### Rules of thumb (breaking these caused real bugs)

- **Exec binaries by real path; keep store paths in *arguments* logical.**
  Nix's compiled-in store dir is `/nix/store`; fakedir rewrites its file
  accesses. The patched installer execs `$dest/store/...-nix/bin/nix-env`
  (real, so the protected bash can find it) but passes `-i /nix/store/…`
  (logical, so nix accepts it).
- **Builders must be store / non-protected binaries.** `builder = "/bin/sh"`
  works only because fakedir redirects `/bin/sh` spawns to an `sh`/`bash`
  found on PATH. Keep `sandbox = false` (darwin default); the sandbox
  profile would block the redirected paths.
- **Wrappers resolve through `~/.nix-profile` at invocation time**, so
  package *upgrades* need nothing, but *new/removed* binaries need the
  name-sync re-run (`$LIBEXEC/rehash` — it only links
  `$BINDIR/<name> → dispatcher` per profile binary). The wrapper
  dispatcher's EXIT trap does this automatically after `nix-env` and after
  `nix` with `profile` anywhere in the args (over-matching is fine — rehash
  is idempotent), but only when invoked *through the wrappers*; profile
  mutations from elsewhere (e.g. inside a `nix-shell`) need a manual
  `rehash`.
- **Bootstrap vs runtime:** the libiconv rewrite + `dyld.source` fallback
  list exist *only* because the nix `install` script execs store nix
  binaries from a non-injected bash — nix's own dylibs need a static
  fallback path exactly once, and the two same-named libiconvs (Apple +
  GNU) collide in a flat leaf-name lookup, so GNU's install name is
  rewritten to `libiconv.g.dylib`. After install, the trampoline path needs
  neither. GNU libiconv is identified by content (its dylib embeds `GNU`
  strings; Apple's stub doesn't) rather than a pinned version glob, so no
  `*-libiconv-<version>` string needs updating when bumping
  `NIX_INSTALL_VERSION`. `dyld.source` reuses the `libiconv.g.dylib` marker
  install.sh creates rather than re-detecting.
- **In protected shells, symlinks into `/nix` always look dangling.**
  `[ -e ]`, `[ -x ]`, `[ -d ]` follow symlinks, so on a profile entry
  (`hello → /nix/store/…/bin/hello`) they return false in any non-injected
  script — that's the normal case, not corruption. Test `[ -L ]` (or map the
  target textually) instead. The rehash script once used `[ -e ]` as a
  dangling-link filter and, having already cleared `$BINDIR`, deleted every
  wrapper while regenerating zero. Corollary: scripts that rebuild state
  must enumerate *before* they delete, so failure is a no-op.
- **The store is read-only.** Any cleanup needs
  `chmod -R u+w ~/.local/share/nix` before `rm -rf`.

## Fakedir bugs fixed (do not regress; lives in Sharsie/fakedir)

The original installer failure (`opening lock file ".../db/big-lock":
Permission denied`) was *not* missing interposition — injection was active.
Each root cause found the hard way:

1. **arm64 variadic ABI.** `open`/`openat` take `mode` variadically; on
   Apple arm64 variadic args go on the stack, named args in registers. The
   interposers declared `mode` as named → read garbage → nix's lock files
   created mode `0000` → EACCES everywhere. Interposers of variadic
   functions must themselves be variadic (`va_arg` only when `O_CREAT`).
2. **`AT_FDCWD` treated as a bitmask** (`flags & AT_FDCWD`; it's the fd
   *value* −2), plus `openat` O_* flags tested against AT_* constants, plus
   `readlinkat`/`symlinkat` wrongly resolving the final component.
3. **Symlink resolution must be a component-by-component walk** (realpath
   style, rewrite applied before *every* kernel probe, ELOOP guard). Nix
   profile chains (`~/.nix-profile → …/profile-N-link →
   /nix/store/…-user-environment → per-file symlinks back into /nix/store`)
   splice logical `/nix` targets into the middle of resolution; a resolver
   that only readlinks prefixes of the original string silently fails
   (first symptom: SSL CA cert "not found" during `nix-channel --update`).
4. **Dylib-closure collection needs dedup.** Nix's dense dylib graph made
   the un-deduplicated `DYLD_INSERT_LIBRARIES` list combinatorial —
   `__strncat_chk` SIGTRAP'd spawned children. Same pass now also collects
   `LC_RPATH` entries into `DYLD_FALLBACK_LIBRARY_PATH` for children.
5. **Shebang handling must not fully resolve the script path** — the kernel
   passes it as `$0` and multi-call scripts (our wrapper dispatcher,
   busybox-style tools) dispatch on its basename. Resolve the parent dirs
   only, keep the leaf name.
6. **Leading `..` in relative paths was eaten by the resolver** —
   `openat(fd, "..")` opened the same dir, `chdir("..")` was a no-op.
   Killed gnulib fts (`fts_read failed` on >4-deep trees, breaking
   `chmod -R` in unpackPhase) and silently *nested* store trees when tools
   ascended with bare `chdir("..")` (a corrupted
   `nodejs/bin/lib/node_modules/npm/man/man5/man1/...` path). Leading `..`
   is now kept verbatim for relative paths; path logic lives in
   `pathresolve.c` with `make check` unit tests — run them after any
   resolver change.
7. **`$DARWIN_EXTSN` symbol variants bypass plain-name interposers.**
   Anything compiled with `_DARWIN_C_SOURCE` (all of nixpkgs) binds
   `fopen$DARWIN_EXTSN` / `realpath$DARWIN_EXTSN`, not `fopen`/`realpath`.
   CPython opens the main script via `fopen$DARWIN_EXTSN`, so
   `python script.py` got ENOENT on every /nix path while builtin `open()`
   worked — killed every nodejs configurePhase. `$` can't appear in a C
   identifier: declare the real symbol via `__asm("_fopen$DARWIN_EXTSN")`
   and hand-roll the interpose tuple. When hunting this class of bug,
   `nm -u <binary> | grep '\$'` shows which variants a binary binds.
8. **AF_UNIX socket paths ride inside `struct sockaddr_un`**, invisible to
   every path interposer — `nix store gc` couldn't bind
   `/nix/var/nix/gc-socket/socket`. `bind`/`connect` now rewrite
   `sun_path` for AF_UNIX addresses under the pattern (hand-rolled, no
   global lock across the real call — a blocking `connect` must not stall
   other interposed syscalls; ENAMETOOLONG instead of truncating).
9. **Paths inside posix_spawn file actions are consumed at spawn time**,
   after the `posix_spawn` interposer has run — they must be rewritten
   when *added* (`posix_spawn_file_actions_addchdir_np`/`addopen`). libuv
   spawns with a `cwd` option this way, i.e. every Node.js
   `child_process` call passing `cwd` — the chdir hit the real /nix and
   the spawn died with ENOENT (first symptom: nodejs checkPhase,
   `test-embedding.js`, `spawnSync` returning no stdio at all).
10. **`getcwd(NULL, 0)` callers saw the real path.** The interposer's
    reverse rewrite went through `strlcpy(..., size)`; under the
    malloc-contract (`buf == NULL`, `size` may be 0) that copies zero
    bytes, so bash-style callers got the real store prefix as `$PWD`
    while fixed-buffer callers (python) got the logical one. Rewrite
    into a fresh allocation for the NULL-buf case.
11. **`scandir` never hits the `opendir` interposer** (libc-internal
    calls): Node's `fs.readdir`/`fs.rm -r` (libuv `uv_fs_scandir`) got
    ENOENT on every /nix path — ~150 nodejs checkPhase failures from
    this one gap. The real scandir *re-enters* our interposers, so the
    lock must be dropped across it (getcwd rule). The `mkstemp` family
    mutates its template in place: resolve parent-only, run the real
    call on a rewritten copy, map the filled-in result back into the
    caller's buffer.
12. **`pathconf` returns `long` and follows symlinks.** Interposed as
    `int` with parent-only resolve: a dangling-in-the-real-tree link
    made the real call return −1, which reached 64-bit callers as
    4294967295 — libuv sizes readlink buffers with it → kernel EINVAL →
    every `fs.readlink`/`fs.symlink`/`realpath` consumer in Node broke
    (20 tests from one wrong prototype). When interposing, match the
    real signature *exactly*; `nm` won't catch return-type mismatches.
13. **Directory watching (FSEvents) needs dlsym interception.** libuv
    dlopens CoreServices and calls `FSEventStreamCreate` through a
    dlsym'd pointer — DYLD interposition can't rebind that. fakedir
    interposes `dlsym` and returns a shim that rewrites watch paths
    (logical→real) and wraps the event callback (real→logical, since
    callers prefix-filter events against the logical path). fakedir
    must never *link* CF — that would pull CF into every injected
    process, and CF is not fork-safe.
14. **`sun_path` is 104 bytes and the real prefix is ~30 bytes longer
    than `/nix`**, so legal logical socket paths overflow it. `bind`
    falls back to a short `/tmp/.fakedir-sock-*` socket plus a symlink
    at the requested path; `connect` to one of *our* bound sockets
    resolves through that planted symlink to the short `/tmp` name and
    never overflows. `connect` to any *other* over-long target (a caller
    probing an arbitrary /nix path — a regular file, a missing path, an
    unlistened socket) must still reach the kernel so it reports the true
    error a rooted install would (ENOTSOCK / ENOENT / ECONNREFUSED), not
    ENAMETOOLONG: plant a short temporary `/tmp/.fakedir-sock-c*` symlink
    to the real path, connect through it, unlink it (this was the last
    nodejs checkPhase failure, `test-net-pipe-connect-errors`, connecting
    to a regular file in a build TMPDIR under /nix). `lstat` reports the
    bind shim as the socket it leads to (it keys on the link *target*
    prefix, so the connect shims — which point into /nix — don't trip
    it). Oversize paths in general (≥ PATH_MAX) still pass through
    resolution verbatim so the kernel reports ENAMETOOLONG like a rooted
    install would; `dladdr` reverse-maps `dli_fname` so backtraces show
    logical paths.
15. **`my_dlopen` held `_lock` across the real `dlopen`.** It dropped the
    lock before the `macho_add_dependencies` closure walk, but that walk
    goes through `my_open`, whose contract is enter-locked / drop only
    across the blocking real open / *re-lock on exit*. Called unlocked,
    `my_open` returned with `_lock` held, so the real `dlopen` ran under
    the lock — and `dlopen` executes the image's initializers, which
    re-enter our `dlopen` interposer. nix's libtbb initializer dlopens
    tbbmalloc, whose initializer dlopens again; the inner call blocked
    forever on the leaked lock. *Every* basic nix command hung at startup
    (`nix path-info`, `nix build`). Fix: collect the resolved dependency
    closure under the lock (dedup + record-before-recurse, so cycles
    terminate), copy it out, release the lock, then `dlopen` each entry
    plus the target unlocked. Same rule as bugs 4/10/11 — never hold
    `_lock` across a call that re-enters the interposers, and `dlopen` is
    the worst offender because its re-entry is the loader running arbitrary
    initializers.
16. **The `mkstemp` family resolved templates outside the pattern.**
    `mkstemp`/`mkostemp`/`mkdtemp` ran `resolve_symlink_parent` on *every*
    template. On macOS `/tmp` is a symlink to `/private/tmp`, so a non-/nix
    template like `/tmp/nix-shell.XXXXXX` resolved *longer* than the
    caller's buffer; the real call then succeeded, but `tmpl_writeback`
    (which refuses to overflow the caller's `template`) saw the logical
    result was longer and failed the whole call with ENAMETOOLONG, deleting
    the just-created file. `nix develop` builds its rc file exactly this way,
    so entering *any* dev shell died with "creating temporary file
    '/tmp/nix-shell.XXXXXX': File name too long". Fix: fakedir only rewrites
    paths under the pattern, so a template not starting with it needs no
    resolution and no writeback — pass it straight to the real call. (First
    bug hit *after* the store, in the `nix develop`/`nix run` layer.)
17. **The `/bin/sh` redirect only searched PATH.** To keep injection alive,
    fakedir redirects a `/bin/sh` exec to a non-protected sh/bash (a
    protected `/bin/sh` strips DYLD_* and loses the /nix view). It only
    looked on PATH, which is fine inside a build/dev-shell (stdenv bash is
    there) but not for npm/pnpm `.bin/*` shims — `#!/bin/sh` scripts that
    `exec node`, run with a minimal PATH (a `nix run` wrapper exporting only
    nodejs/bin + pnpm/bin, no shell). PATH had no sh, the real protected
    `/bin/sh` ran the shim, `/nix` was invisible, and `exec node` died
    "node: not found" (exit 127) — `nix run` of a Slidev deck installed fine
    then failed to launch. A rooted install is immune (real /nix, so even a
    protected /bin/sh finds the store node). Fix: when PATH yields no shell,
    scan the store once for any bash and use its `bin/sh` (a store binary
    keeps injection); returns a logical /nix path so normal rewriting
    applies. Every `#!/bin/sh`-execs-a-store-binary tool depends on this.

Known flake, not a fakedir bug: stdenv bash on darwin initializes
CoreFoundation via gettext's `libintl_setlocale` (no `LANG`/`LC_ALL` in
the build env → it consults CF preferences), and the ENOEXEC fallback
interprets shebang-less scripts in a *forked* copy of that bash —
CF-after-fork can SIGSEGV in CFPrefs/os_log (seen once in a nodejs
configurePhase; the identical phase passed on retry).

Known flake, not a fakedir bug: the nodejs checkPhase's load-sensitive
sequential tests — `test-cpu-prof-name`, `test-performance-eventloopdelay`
(and likely other perf/profiler ones) — **time out** (~900 s, SIGTERM /
exit −15, not an assertion failure) when a CPU core is pinned during the
run. The usual culprit is **XProtect** (Apple's malware scanner) chewing
through the thousands of freshly-built store files at ~90 % of a core right
as checkPhase starts. They pass instantly standalone on an idle machine, so
this is pure CPU contention, not injection overhead. Diagnosis: a `timeout`
stack with a ~900 000 ms `duration_ms`; confirm with
`ps aux | sort -nrk3 | head` (look for `XProtect`/`XprotectService`). Fix:
just rebuild once the machine is idle. Can't be skipped via `CI_SKIP_TESTS`
without changing the drv hash (the profile pins the checked output), so the
build genuinely has to pass these.

## Debugging toolbox

- `FAKEDIR_DEBUG=1` — fakedir traces every rewrite/resolve/spawn to stderr.
- Crashed children leave `.ips` reports in
  `~/Library/Logs/DiagnosticReports/` — the crashing frame + backtrace
  identified both the SIGTRAP (bug 4) and injection kills. A copied
  *platform* binary dying instantly with exit 137/SIGKILL means library
  validation rejected the injection — that path is a dead end, use store
  binaries.
- `otool -L` (dependencies) and `otool -l` (grep `LC_RPATH`) for dylib
  resolution issues; `codesign -f -s -` after any `install_name_tool` edit.
- Suspected syscall/ABI issues: write a 10-line C probe and compare
  behavior with and without `DYLD_INSERT_LIBRARIES` — that's how the
  variadic-mode bug (0644 arriving as 0654/0050) was proven.
- `which foo` returning nothing inside a working `nix-shell` is *expected*:
  `/usr/bin/which` is protected and can't see `/nix`. Use the shell
  builtins `command -v` / `type`, which run inside the injected shell.
- **Replacing `libfakedir.dylib`: `rm` first, then `cp`.** An in-place `cp`
  over a dylib that running processes have mapped invalidates the cached
  code signature on that vnode — every subsequently injected process dies
  with SIGKILL (exit 137) at exec, indistinguishable from library
  validation. `rm && cp` gives the file a fresh inode; `codesign -f -s -`
  after building doesn't hurt.
- `nix-store --verify --check-contents` reports GNU libiconv and its
  dependents (libunistring, libidn2, libpsl as of 2026-07-10) as
  "modified": that's install.sh's deliberate bootstrap rewrite to
  `libiconv.g.dylib` (install name + dependents' load commands), not
  corruption. Confirm with
  `otool -L <lib> | grep libiconv.g` before suspecting anything else.

## Testing a change from zero

```sh
# wipe (store is read-only!)
chmod -R u+w ~/.local/share/nix 2>/dev/null
rm -rf ~/.local/share/nix ~/.local/state/nix ~/.nix-profile ~/.nix-defexpr ~/.nix-channels

./install.sh   # or the curl|bash line from README
export PATH="$HOME/.local/share/nix/bin:$PATH"
```

Verification checklist (all were green as of 2026-07-10, nix 2.34.8,
aarch64-darwin):

- install completes with no errors, `nix --version` via wrapper works
- binary cache substitution: `nix-env -iA nixpkgs.hello` (auto-rehash via
  the wrapper trap, no manual step) → `hello` prints
- `nix-shell -p hello --run hello`
- a local `nix-build` (store-binary builder; and one with
  `builder = "/bin/sh"` to cover the redirect)
- `nix-store --verify` passes (store contents stay byte-identical to a
  rooted install — symlink targets remain logical `/nix/…`, so NAR hashes
  and signatures hold)

## Known limitations

- Protected system binaries never see `/nix` (no `ls /nix/store` from a
  plain shell). Working as intended.
- Store location fixed to `$HOME/.local/share/nix`.
- Wrapper name-sync is automatic only for `nix-env`/`nix profile` run
  through the wrappers; other profile mutations need a manual
  `$LIBEXEC/rehash`.
- Go toolchain DYLD handling unresolved (see rejected cherry-pick above) —
  revisit with a tighter heuristic when building Go packages matters.
- Fallbacks if fakedir ever hits a wall: build nix from source with
  `--with-store-dir=$HOME/…` (loses the binary cache) or a Lima/UTM VM.
  Neither is currently needed.
