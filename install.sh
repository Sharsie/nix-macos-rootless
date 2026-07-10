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

make -C fakedir > /dev/null
cp fakedir/libfakedir.dylib "$NIX_INSTALL_DIR"


rewrite_libiconv() {
    # DYLD libraries need to be loaded from all store paths, but contain conflicts
    # libiconv needs both Apple and GNU version, we rewrite GNU .dylib to use a different filename

    gnu_dir=$(cd "$(ls -d "$NIX_INSTALL_DIR"/store/*-libiconv-1.18/lib | head -n 1)" && pwd)
    old="/nix/${gnu_dir#"$NIX_INSTALL_DIR"/}/libiconv.2.dylib"
    new="${old%.2.dylib}.g.dylib"

    find "$NIX_INSTALL_DIR/store" -name '*.dylib' -type f  | while read -r f; do
    file "$f" | grep -q Mach-O || continue
    if otool -L "$f" 2>/dev/null | grep -qF "$old"; then
        install_name_tool -change "$old" "$new" "$f"
        codesign -f -s - "$f"
        echo "  Rewrote: $f"
    fi
    done

    ln -sf libiconv.2.dylib "$gnu_dir/libiconv.g.dylib"
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
}

nix_rehash() {


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

    # Install runtime pieces next to the store so wrappers survive this
    # checkout moving away.
    mkdir -p "$LIBEXEC" "$BINDIR"
    cp -f "$NIX_INSTALL_DIR/libfakedir.dylib" "$LIBEXEC/libfakedir.dylib"
    if [ ! -x "$LIBEXEC/fakedirexec" ] || [ "$NIX_INSTALL_DIR/fakedirexec.c" -nt "$LIBEXEC/fakedirexec" ]; then
        cc -O2 -o "$LIBEXEC/fakedirexec" "$NIX_INSTALL_DIR/fakedirexec.c"
    fi

    profile_bin=$(resolve "$HOME/.nix-profile")/bin
    profile_bin=$(resolve "$profile_bin")

    if [ ! -d "$profile_bin" ]; then
        echo "error: cannot resolve profile bin dir ($profile_bin)" >&2
        exit 1
    fi

    # Wrapper template: one dispatcher, invoked under each command's name.
    cat > "$LIBEXEC/wrapper" <<'EOF'
#!/bin/bash
export FAKEDIR_PATTERN=/nix
export FAKEDIR_TARGET="${FAKEDIR_TARGET:-$HOME/.local/share/nix}"
export DYLD_INSERT_LIBRARIES="$FAKEDIR_TARGET/libexec/libfakedir.dylib"
export NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-$HOME/.nix-profile/etc/ssl/certs/ca-bundle.crt}"
exec "$FAKEDIR_TARGET/libexec/fakedirexec" "$HOME/.nix-profile/bin/$(basename "$0")" "$@"
EOF
    chmod +x "$LIBEXEC/wrapper"

    # Clear stale wrappers, then link one per profile binary.
    find "$BINDIR" -maxdepth 1 -type l -delete
    count=0
    for f in "$profile_bin"/*; do
        name=$(basename "$f")
        ln -sf "$LIBEXEC/wrapper" "$BINDIR/$name"
        count=$((count + 1))
    done

    echo "  Generated $count wrappers in $BINDIR"

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
echo
echo '!!! Make sure PATH contains the wrapper dir: export PATH="'"$BINDIR"':$PATH"'
echo
