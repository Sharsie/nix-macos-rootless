# nix-macos-rootless

Nix on macOS. No daemon, no `/nix`, no `sudo`. Just you and your `$HOME`.

If you can use sudo, don't use this. Seriously. Do multi-user install using sudo. Not everyone is that lucky.

It fakes `/nix/store` into existence via `DYLD_INSERT_LIBRARIES` sorcery and
installs everything into `$HOME/.local/share/nix`. Requires Xcode Command
Line Tools (`xcode-select --install`).

## Install

```sh
curl -sL https://raw.githubusercontent.com/Sharsie/nix-macos-rootless/main/install | bash
```

The installer walks you through the important bits below (PATH, flakes,
how it works) at the end — read it.

## Uninstall

```sh
curl -sL https://raw.githubusercontent.com/Sharsie/nix-macos-rootless/main/uninstall | bash
```

Then remove the `PATH` modifications from your shell profile.

## ⚠️ Add the wrapper dir to your PATH

The install is useless until you do this — add it to your `.bashrc`,
`.zshrc`, or whatever profile file you use:

```sh
export PATH="$HOME/.local/share/nix/bin:$PATH"
```

## ⚠️ Enable flakes

Not enabled by default. Add the following to `~/.config/nix/nix.conf`:

```
experimental-features = nix-command flakes
```

Note: This also enables nix command without having to provide `--extra-experimental-features` every time.

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

## How it works

Nix and everything installed through it still think they live at
`/nix/store`. Wrapper scripts in `$HOME/.local/share/nix/bin` (the `PATH`
entry above) launch binaries with that path rewritten to
`$HOME/.local/share/nix` via DYLD injection — the binaries themselves never
know. New/removed packages regenerate these wrappers automatically, but only
when installed through them (`nix-env`, `nix profile`); other profile
mutations (e.g. from inside a `nix-shell`) need a manual execution of
`$HOME/.local/share/nix/libexec/rehash`.

## License

MIT, see [LICENSE](LICENSE).
