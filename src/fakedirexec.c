/*
 * fakedirexec - fakedir exec trampoline.
 *
 * Build:  cc -O2 -o fakedirexec fakedirexec.c
 *
 * Usage:  fakedirexec <program> [args...]
 *
 * Must be launched with FAKEDIR_PATTERN, FAKEDIR_TARGET and
 * DYLD_INSERT_LIBRARIES=<libfakedir.dylib> set. Being injected itself,
 * its execve() is interposed by libfakedir, which:
 *   - resolves <program> through the fakedir rewrite (so logical
 *     /nix/... paths and symlink chains into them work),
 *   - preloads the program's /nix dylib closure via DYLD_INSERT_LIBRARIES,
 *   - exports the closure's LC_RPATH and library dirs via
 *     DYLD_FALLBACK_LIBRARY_PATH,
 * so the target runs as if /nix existed.
 */
#include <unistd.h>
#include <stdio.h>

extern char **environ;

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: fakedirexec <program> [args...]\n");
        return 2;
    }
    execve(argv[1], argv + 1, environ);
    perror("fakedirexec: execve");
    return 1;
}
