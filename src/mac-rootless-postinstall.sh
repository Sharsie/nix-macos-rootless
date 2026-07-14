#!/usr/bin/env bash

set -euo pipefail

cat <<EOF
===============================
Rootless installation complete.
===============================

⚠️⚠️⚠️ READ THIS CAREFULLY! ⚠️⚠️⚠️
Lets go through some important information.
EOF
read -n 1 -s -r -p "Press any key to continue..." < /dev/tty

cat <<EOF


⚠️ 1. ======= PATH env variable must contain nix paths! =======

  Your shell profile (e.g. ~/.profile, ~/.zshrc, ~/.bash_profile) needs to have nix paths added to PATH!

  Official nix installation script will try to do this for you if you are using any of the well-known shell .rc/profile files.

  Open your shell profile file and verify there's a line with '# added by Nix installer'

  If not, nix installer prints out instructions to do this when it finishes. Refer to the output above ⚠️⚠️⚠️ READ THIS CAREFULLY! ⚠️⚠️⚠️️.

EOF
read -p "Press Enter to confirm you've checked the shell profile you are using and it either contains the line, or you added it...." < /dev/tty

cat <<EOF


⚠️ 2. ======= You MUST add the following to your shell profile =======
  This is in addition to what nix installer requires:


export PATH="\$HOME/.local/share/nix/bin:\$PATH"


EOF
read -p "Press Enter to confirm you added the line above to your shell profile..." < /dev/tty


cat <<EOF


⚠️ 3. ======= It is STRONGLY recommended that you enable nix command and nix flakes =======

  Create or edit a file at '$HOME/.config/nix/nix.conf'.

  Add the following contents:


experimental-features = nix-command flakes


  This will allow you to run subset of 'nix' commands and the use of flakes without using '--extra-experimental-features' for every command.

  Trust me. You want this. 99% of the internets use flakes. It's de-facto standard. Even if marked experimental.

EOF
read -n 1 -s -r -p "Press Enter to confirm you did whatever your heart desired..." < /dev/tty

cat <<EOF


⚠️ 4. ======= nix and packages installed through nix have /nix directory rewritten to a different path =======

  The programs will refer to '/nix/store'.
  Internally, this will be rewritten to '$HOME/.local/share/nix'.
  The programs don't know. And cannot see the difference.
  Whenever you see output referring to '/nix', you can substitute it with '$HOME/.local/share/nix' when using non-nix tooling (e.g. 'ls', 'cat').

EOF
read -n 1 -s -r -p "Press any key to acknowledge..." < /dev/tty

cat <<EOF


⚠️ 5. ======= This installation script creates trampolines! =======

  Every package install or nix profile update triggers a hook.
  The hook wraps all your nix-installed binaries (including nix itself) in a shell script.
  The shell scripts sets up the path-rewriting mentioned previously.

  Without this, the binaries will not work.

  The hook is installed in '$HOME/.local/share/nix/libexec/rehash', refer to it for more info.

EOF
read -n 1 -s -r -p "Press any key to acknowledge..." < /dev/tty

cat <<EOF


⚠️ 6. ======= Upgrading nix and tooling =======

  To save yourself the trouble a year from now, I recommend you convert current installation of nix and cacert
  to be tracked by your nix profile as flakes.

  This will enable you to easily upgrade at any point in the future without having to think about it.

  The steps are as follows:

  1. Add nix to your profile. You already have it. But statically installed. This converts it to a profile-managed flake:

  nix profile add nixpkgs#nix --priority 4

  2. Remove the one we installed (yes, the name is the same, don't worry about it):

  nix profile remove nix

  3. Do the same with cacerts:

  nix profile add nixpkgs#cacert --priority 4
  nix profile remove nss-cacert


  Note: This will convert your profile to a new format and will prevent you from using nix-env to manage the environment.
  This is ok, just do it. Use nix profile from now on.


EOF
read -n 1 -s -r -p "Press any key to acknowledge..." < /dev/tty

cat <<EOF


⚠️ 7. ======= Close this terminal =======

  You can load all the PATH edits and all that within this session.
  But seriously. Just close the terminal/tab/whatever and spawn a new one.

  If you need to review any of the information provided, go to the GitHub repo and refer to src/mac-rootless-postinstall.sh.

  You can also just rerun this with
  curl -sL https://raw.githubusercontent.com/Sharsie/nix-macos-rootless/refs/heads/main/src/mac-rootless-postinstall.sh | bash

EOF
read -p "Press Enter to get rid of this annoyance..." < /dev/tty
