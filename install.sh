#!/usr/bin/env bash

set -euo pipefail


echo "This installation script enables rootless single-user nix installation on MacOS."
echo "  It will install nix store within '$HOME/.local/share/nix'."
echo "  It will use MacOS DYLD library insertion and create wrappers so the location of /nix/store can be faked for nix binaries."
echo "  It will fetch official nix installation, patch it and then use it to install nix."
echo "  It is opinionated and does not provide adjusting the location of the store."
echo "  It is provided as is and there may be unknown quirks."
echo
read -p "Continue, accepting the above? Press any key to confirm, or CTRL-C to quit." < /dev/tty

REQUIRED_COMMANDS=("curl" "make" "git" "tar" "otool" "install_name_tool" "codesign")
COMMANDS_MISSING=

for cmd in ${REQUIRED_COMMANDS[@]}; do
  if ! command -v "$cmd" > /dev/null; then echo "$cmd is required."; COMMANDS_MISSING=1; fi
done

[[ -n $COMMANDS_MISSING ]] && echo "Provide the missing commands above. Exiting..." && exit 1

LIBEXEC="$HOME/.local/share/nix/libexec"
BINDIR="$HOME/.local/share/nix/bin"

WORKDIR=$(mktemp -d)
trap "rm -rf $WORKDIR" EXIT

echo "Installation will proceed in $WORKDIR ..."

cd "$WORKDIR"

NIX_INSTALL_VERSION=${NIX_INSTALL_VERSION:-2.34.8}
[[ "$(arch)" == "arm64" ]] && SYSTEM="aarch64-darwin" || SYSTEM=x86_64-darwin

echo "Fetching nix install scripts ..."

curl -sLO https://releases.nixos.org/nix/nix-$NIX_INSTALL_VERSION/nix-$NIX_INSTALL_VERSION-$SYSTEM.tar.xz
tar xfj nix-$NIX_INSTALL_VERSION-$SYSTEM.tar.xz

NIX_INSTALL_DIR="$WORKDIR/nix-$NIX_INSTALL_VERSION-$SYSTEM"

echo "Fetching macos-rootless patches from branch nix/$NIX_INSTALL_VERSION in https://github.com/Sharsie/nix-macos-rootless.git ..."

git clone --depth 1 --branch "nix/$NIX_INSTALL_VERSION" https://github.com/Sharsie/nix-macos-rootless.git nix-macos-rootless > /dev/null
cp -R nix-macos-rootless/src/ "$NIX_INSTALL_DIR/"

echo "Fetching fakedir from branch hotfix/rootless-nix-install in https://github.com/Sharsie/fakedir.git ..."

git clone --depth 1 --branch hotfix/rootless-nix-install https://github.com/Sharsie/fakedir.git fakedir > /dev/null

echo "Building fakedir ..."

make -C fakedir > /dev/null 2>&1
cp fakedir/libfakedir.dylib "$NIX_INSTALL_DIR"


rewrite_libiconv() {
    # DYLD libraries need to be loaded from all store paths, but contain conflicts
    # libiconv needs both Apple and GNU version, we rewrite GNU .dylib to use a different filename
    #
    # The store holds a libiconv-<version> derivation for both GNU libiconv and Apple's
    # system libiconv stub, and both ship a same-named libiconv.<N>.dylib. GNU's version
    # number isn't stable across nix versions, so instead of pinning it we detect the GNU
    # build by content: its dylib embeds "GNU" strings (copyright/version info), Apple's
    # stub does not.

    gnu_dylib=""
    for candidate in "$NIX_INSTALL_DIR"/store/*-libiconv-*/lib/libiconv.*.dylib; do
        [[ -f "$candidate" && ! -L "$candidate" ]] || continue
        grep -qr GNU "$(dirname $candidate)" 2>/dev/null && { gnu_dylib="$candidate"; break; }
    done

    [[ -n "$gnu_dylib" ]] || { echo "Could not locate GNU libiconv in the store" >&2; exit 1; }

    gnu_dir=$(cd "$(dirname "$gnu_dylib")" && pwd)
    old="/nix/${gnu_dylib#"$NIX_INSTALL_DIR"/}"
    new="/nix/${gnu_dir#"$NIX_INSTALL_DIR"/}/libiconv.g.dylib"

    find "$NIX_INSTALL_DIR/store" -name '*.dylib' -type f  | while read -r f; do
    file "$f" | grep -q Mach-O || continue
    if otool -L "$f" 2>/dev/null | grep -qF "$old"; then
        install_name_tool -change "$old" "$new" "$f" > /dev/null
        codesign -f -s - "$f" > /dev/null
        echo "  Rewrote: $f"
    fi
    done

    ln -sf "$(basename "$gnu_dylib")" "$gnu_dir/libiconv.g.dylib"
}

patch_install() {
    echo "  Removing the condition preventing macos install with --no-daemon"
    awk '/if \[ "\$OS" = "Darwin" \]; then/{buf=$0"\n";intask=1;next} intask{buf=buf $0"\n"; if($0 ~ /^[[:space:]]*fi[[:space:]]*$/){if(buf !~/no-daemon installs are no-longer supported/) printf "%s", buf; intask=0; buf=""} next} {print}' "$NIX_INSTALL_DIR/install" > "$NIX_INSTALL_DIR/install.tmp"
    mv "$NIX_INSTALL_DIR/install.tmp" "$NIX_INSTALL_DIR/install"

    echo "  Patching the script to source fakedir and dyld and prevent sudo"
    awk '
    !done && /dest=/ {
        print "source \"$(dirname \"$0\")/fakedir.source\""
        print "source \"$(dirname \"$0\")/dyld.source\""
        print "NIX_BECOME=\" \""
        done=1
    }
    { print }
    ' "$NIX_INSTALL_DIR/install" > "$NIX_INSTALL_DIR/install.tmp"
    mv "$NIX_INSTALL_DIR/install.tmp" "$NIX_INSTALL_DIR/install"

    echo "  Changing dest to use fakedir's destination"
    sed -i '' 's/^\([[:space:]]*\)dest=.*$/\1dest="$FAKEDIR_TARGET"/' "$NIX_INSTALL_DIR/install"

    echo "  Changing /nix/store to use fakedir's store path"
    sed -i '' 's|/nix/store|$FAKEDIR_TARGET/store|g' "$NIX_INSTALL_DIR/install"

    # Store paths passed as *arguments* to nix commands must stay in logical
    # /nix/store form: nix's compiled-in store dir is /nix/store and fakedir
    # rewrites its filesystem accesses. Only the script's own file operations
    # (mkdir/cp/chmod via protected system binaries) and the exec of nix
    # binaries by the (protected, non-fakedir) shell need real paths.
    echo "  Keeping logical /nix/store paths for nix command arguments"
    sed -i '' 's|-i "\$nix"|-i "/nix${nix#"$FAKEDIR_TARGET"}"|' "$NIX_INSTALL_DIR/install"
    sed -i '' 's|-i "\$cacert"|-i "/nix${cacert#"$FAKEDIR_TARGET"}"|' "$NIX_INSTALL_DIR/install"

    chmod +x "$NIX_INSTALL_DIR/install"
}

nix_rehash() {

    # Install runtime pieces next to the store so wrappers survive this
    # checkout moving away.
    mkdir -p "$LIBEXEC" "$BINDIR"
    cp -f "$NIX_INSTALL_DIR/libfakedir.dylib" "$LIBEXEC/libfakedir.dylib"
    if [ ! -x "$LIBEXEC/fakedirexec" ] || [ "$NIX_INSTALL_DIR/fakedirexec.c" -nt "$LIBEXEC/fakedirexec" ]; then
        cc -O2 -o "$LIBEXEC/fakedirexec" "$NIX_INSTALL_DIR/fakedirexec.c"
    fi

    # Standalone rehash script, installed next to the store so it keeps
    # working after this checkout is gone. It rebuilds $BINDIR wrappers
    # from whatever is currently in $HOME/.nix-profile/bin. Called here
    # for the initial install, and by the wrapper dispatcher below after
    # nix-env / nix profile mutate the profile, so users never have to
    # run it by hand.
    cat > "$LIBEXEC/rehash" <<'EOF'
#!/bin/bash
set -euo pipefail

LIBEXEC="$HOME/.local/share/nix/libexec"
BINDIR="$HOME/.local/share/nix/bin"

# Resolve a path textually across the logical /nix boundary.
resolve() {
    local p=$1 t
    local guard=0
    while t=$(readlink "$p" 2>/dev/null); do
        case "$t" in
            /nix/*) p="$HOME/.local/share/nix${t#/nix}" ;;
            /*)     p="$t" ;;
            *)      p="$(dirname "$p")/$t" ;;
        esac
        guard=$((guard + 1))
        [ "$guard" -gt 40 ] && break
    done
    printf '%s\n' "$p"
}

profile_bin=$(resolve "$HOME/.nix-profile")/bin
profile_bin=$(resolve "$profile_bin")

if [ ! -d "$profile_bin" ]; then
    echo "error: cannot resolve profile bin dir ($profile_bin)" >&2
    exit 1
fi

# Enumerate profile binaries BEFORE touching $BINDIR, so a failed
# enumeration is a no-op instead of wiping every wrapper. Profile entries
# are symlinks to logical /nix/store/... targets, which this (protected,
# non-injected) shell cannot resolve — so a dangling-looking symlink is the
# NORMAL case here. -L must count as present; only skip entries that are
# neither a symlink nor a real file.
names=()
for f in "$profile_bin"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    names+=("$(basename "$f")")
done

if [ "${#names[@]}" -eq 0 ]; then
    echo "error: no binaries found in $profile_bin; leaving existing wrappers untouched" >&2
    exit 1
fi

# Clear stale wrappers, then link one per profile binary.
find "$BINDIR" -maxdepth 1 -type l -delete
for name in "${names[@]}"; do
    ln -sf "$LIBEXEC/wrapper" "$BINDIR/$name"
done

echo "  Generated ${#names[@]} wrappers in $BINDIR"
EOF
    chmod +x "$LIBEXEC/rehash"

    # Wrapper template: one dispatcher, invoked under each command's name.
    # It runs the real binary (rather than exec-replacing itself, which
    # would leave no shell around to run anything afterward) so an EXIT
    # trap can trigger a rehash for the two entry points that mutate
    # $HOME/.nix-profile: `nix-env` and `nix profile`. This is what makes
    # newly (un)installed packages usable without the user re-running
    # rehash manually. The trap runs on every exit path (normal or
    # signalled) and bash preserves the pre-trap exit status automatically,
    # so there's no manual status-capturing to get wrong.
    #
    # Kept on #!/bin/bash (a fixed absolute path) rather than
    # #!/usr/bin/env bash on purpose: if the nix profile ever provides its
    # own "bash" (e.g. `nix-env -i bash`), $BINDIR/bash is a symlink to
    # this very wrapper, and $BINDIR sits ahead of /bin on PATH. `env`
    # resolves its argument via PATH at exec time, so it would find that
    # wrapper before the real bash and recurse into itself.
    cat > "$LIBEXEC/wrapper" <<'EOF'
#!/bin/bash
export FAKEDIR_PATTERN=/nix
export FAKEDIR_TARGET="${FAKEDIR_TARGET:-$HOME/.local/share/nix}"
export DYLD_INSERT_LIBRARIES="$FAKEDIR_TARGET/libexec/libfakedir.dylib"
export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt}"

name=$(basename "$0")

# Inline trap body (not a function) so "$*" here is still the wrapper's own
# argument list, not a fresh, empty positional-parameter scope. For `nix`,
# match "profile" anywhere in the args rather than requiring it to be $1:
# global flags may precede the subcommand (nix --some-flag profile install),
# and a spurious rehash on a false match is idempotent and harmless.
# Silence rehash stdout only — if it ever errors, that must reach the user,
# not vanish (a silent rehash failure once wiped every wrapper invisibly).
trap '
    case "$name" in
        nix-env) "$FAKEDIR_TARGET/libexec/rehash" > /dev/null ;;
        nix)     case " $* " in *" profile "*) "$FAKEDIR_TARGET/libexec/rehash" > /dev/null ;; esac ;;
    esac
' EXIT

"$FAKEDIR_TARGET/libexec/fakedirexec" "$HOME/.nix-profile/bin/$name" "$@"
EOF
    chmod +x "$LIBEXEC/wrapper"

    "$LIBEXEC/rehash"
}

echo "Rewriting libiconv libraries in the downloaded nix store to allow installation to proceed ..."
rewrite_libiconv

echo "Patching installation script ..."
patch_install

echo "Running nix install with --no-daemon ..."
"$NIX_INSTALL_DIR"/install --no-daemon

echo "Patching nix installation ..."
nix_rehash

echo "==============================="
echo "Installation complete."
echo 'Please add the line'
echo
echo 'export PATH="'"$BINDIR"':$PATH"'
echo
echo 'to your shell profile (e.g. ~/.profile, ~/.zshrc, ~/.bashrc)'
echo
