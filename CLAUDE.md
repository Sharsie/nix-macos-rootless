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
Five root causes, each found the hard way:

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
6. **Relative `..` must be preserved, not lexically eaten.** The resolver
   popped `..` from an empty logical buffer, so `openat(fd, "..")` became
   `openat(fd, ".")`, `chdir("..")` a no-op, `open("../x")` → `open("x")`.
   Two distinct symptom classes, both first seen building nodejs from
   source (`nix develop` on a flake whose nixpkgs pin missed the darwin
   binary cache): (a) gnulib fts (coreutils `chmod -R`, `find`, `du`…)
   keeps only 4 parent fds and re-opens `".."` beyond that depth, then
   verifies dev/ino and reports **ENOENT "disinformation"** on mismatch —
   so any stdenv `unpackPhase` on a >4-deep source tree died with
   `coreutils: fts_read failed: No such file or directory`; (b) tools
   ascending with bare `chdir("..")` got silently stuck, nesting every
   subsequent sibling one level deeper — recognizable as an insane store
   path concatenating half the tree in DFS order
   (`…/bin/lib/node_modules/npm/man/man5/man1/man7/…`), which then blew
   past PATH_MAX and surfaced as nix's `clearing flags of path …: No such
   file or directory` in `canonicalisePathMetaData`. Leading `..` in
   relative paths now stays verbatim (it names the fd/cwd parent, which
   cannot be resolved lexically); absolute `/..` still clamps to `/`.
   Hardened alongside: internal buffers grew to 4 KiB and overlong
   rewrites fail via an unresolvable marker path instead of silent
   PATH_MAX truncation (a truncated path can name a *different existing*
   file — writes/unlinks would hit the wrong target), and the `/.`-prefix
   strip now requires `/./` so root dotfiles like `/.vol/...` aren't
   mangled into relative paths. The path logic lives in fakedir's
   `pathresolve.c`, unit-testable on Linux with `make check` (27 checks;
   run it before shipping any resolver change — no macOS needed).

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
- a *source* build with a deep tree — small trees hide the fts `..` bug
  (fakedir bug 6) because gnulib fts only re-opens `".."` beyond 4 levels.
  Minimal repro inside `nix-shell -p coreutils`:
  `mkdir -p /tmp/d/1/2/3/4/5/6 && chmod -R u+w /tmp/d` — must not print
  `fts_read failed`. Full repro: `nix develop` on a flake that compiles
  nodejs (unpackPhase `chmod -R u+w` over node's source tree).
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
