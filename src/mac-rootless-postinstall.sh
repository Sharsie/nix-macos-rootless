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


⚠️ 6. ======= Close this terminal =======

  You can load all the PATH edits and all that within this session.
  But seriously. Just close the terminal/tab/whatever and spawn a new one.

EOF
read -p "Press Enter to get rid of this annoyance..." < /dev/tty
