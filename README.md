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
