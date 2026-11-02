#!/bin/sh
# This script installs the native binary. It is not part of the CLI runtime.
set -eu

if [ "$#" -ne 4 ]; then
    printf '%s\n' 'Usage: install.sh install|uninstall SOURCE DESTINATION REPLACE' >&2
    exit 2
fi
action=$1
source_file=$2
destination=$3
replace=$4

case "$action" in
    install|uninstall) ;;
    *) printf '%s\n' 'Invalid install action.' >&2; exit 2 ;;
esac
case "$replace" in
    0|1) ;;
    *) printf '%s\n' 'REPLACE must be 0 or 1.' >&2; exit 2 ;;
esac

if [ ! -f "$source_file" ] || [ -L "$source_file" ]; then
    printf '%s\n' 'The source binary must be a regular file.' >&2
    exit 1
fi

if [ "$action" = uninstall ]; then
    if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
        printf '%s\n' 'Asm is not installed at this path.'
        exit 0
    fi
    if [ -L "$destination" ] || ! cmp -s "$source_file" "$destination"; then
        printf '%s\n' 'Refuse to remove a different binary or a symbolic link. Check the path and remove it yourself if required.' >&2
        exit 1
    fi
    rm -- "$destination"
    printf 'Removed %s\n' "$destination"
    exit 0
fi

if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ ! -L "$destination" ] && [ -f "$destination" ] && cmp -s "$source_file" "$destination"; then
        printf 'The same Asm binary is already installed at %s\n' "$destination"
        exit 0
    fi
    if [ "$replace" != 1 ]; then
        printf '%s\n' 'Refuse to replace an existing file. Check the destination. To replace it, use make install REPLACE=1.' >&2
        exit 1
    fi
    if [ -d "$destination" ]; then
        printf '%s\n' 'The destination is a directory. Installation stopped.' >&2
        exit 1
    fi
fi

directory=$(dirname -- "$destination")
install -d -- "$directory"
temporary=$(mktemp "$directory/.asm-install.XXXXXXXX")
trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
install -m 755 -- "$source_file" "$temporary"
if [ "$replace" = 1 ]; then
    if [ "$(uname -s)" = Darwin ]; then
        # rename(2) refuses directory targets and replaces a symlink itself.
        # Perl is a build/install tool, never part of the Asm CLI runtime.
        /usr/bin/perl -e 'rename($ARGV[0], $ARGV[1]) or die "Cannot replace destination: $!\n"' -- "$temporary" "$destination"
    else
        mv -fT -- "$temporary" "$destination"
    fi
else
    # An exclusive hard link prevents a race from replacing another file.
    if [ "$(uname -s)" = Darwin ]; then
        /bin/link "$temporary" "$destination"
    else
        ln -T -- "$temporary" "$destination"
    fi
    rm -- "$temporary"
fi
trap - EXIT HUP INT TERM
printf 'Installed %s\n' "$destination"
