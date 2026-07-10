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

## Caveats

- This is a workaround, not an officially supported Nix install mode.
- Store location is fixed to `$HOME/.local/share/nix` — not configurable.
- No uninstaller. To remove: delete `$HOME/.local/share/nix` and drop the
  `PATH` line. `chmod -R u+w $HOME/.local/share/nix` before deleting.
- Does not work with MacOS protected binaries. i.e. you can't just `ls /nix/store`

## License

MIT, see [LICENSE](LICENSE).
