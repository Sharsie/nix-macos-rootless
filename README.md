# nix-macos-rootless

Nix on macOS. No daemon, no `/nix`, no `sudo`. Just you and your `$HOME`.

If you can use sudo, don't use this. Seriously. Do multi-user install using sudo. Not everyone is that lucky.

```sh
curl -sL https://raw.githubusercontent.com/Sharsie/nix-macos-rootless/main/install.sh | bash
```

## ⚠️ Add the wrapper dir to your PATH

The install is useless until you do this. Once it finishes, it prints the
exact line — but here it is anyway, add it to your .bashrc, .zshrc or whatever.

```sh
export PATH="$HOME/.local/share/nix/bin:$PATH"
```

That's it. It fakes `/nix/store` into existence via `DYLD_INSERT_LIBRARIES`
sorcery and installs everything into `$HOME/.local/share/nix`.

Requires Xcode Command Line Tools (`xcode-select --install`).

## Enable flakes

This installer does not enable flakes and nix command by default.

Add the following to `~/.config/nix/nix.conf`

```
experimental-features = nix-command flakes
```

## Upgrading

The installer adds nix (and its CA bundle) to your profile as plain store
paths, which `nix profile upgrade` can't track. One-time fix (needs flakes,
see above) — add the flake-based packages *before* removing the old ones, in
this order (nix needs itself to run, and removing the certs first would break
SSL for the download that replaces them):

```sh
nix profile add nixpkgs#nix --priority 4      # shadows the old one (avoids file conflicts)
nix profile remove nix                        # the entry without a flake origin
nix profile add nixpkgs#cacert --priority 4
nix profile remove nss-cacert
```

From then on, upgrading is just:

```sh
nix profile upgrade --all
```

Note: the first mutating `nix profile` command converts the profile to the
new format — `nix-env` refuses to work with it afterwards. That's a nix
thing, not this installer's; stick with `nix profile` from then on. It's the right choice.

## Caveats

- This is a workaround, not an officially supported Nix install mode.
- Store location is fixed to `$HOME/.local/share/nix` — not configurable.
- Does not work with MacOS protected binaries. i.e. you can't just `ls /nix/store`. Replace paths, e.g. `ls $HOME/.local/share/nix/store`
- Every time a global package is installed (`nix-env`) or profile updated (`nix profile`),
  the wrapper symlinks in `$HOME/.local/share/nix/bin` are regenerated automatically —
  but only when you invoke those commands through the wrappers (i.e. via the `PATH` entry
  above). If you mutate the profile any other way (e.g. calling `nix-env` from inside a
  `nix-shell`), new or removed commands won't be picked up until you run
  `$HOME/.local/share/nix/libexec/rehash` yourself.

## Uninstallation

Remove the `PATH` line from your shell profile.

```sh
curl -sL https://raw.githubusercontent.com/Sharsie/nix-macos-rootless/main/uninstall.sh | bash
```

## License

MIT, see [LICENSE](LICENSE).
