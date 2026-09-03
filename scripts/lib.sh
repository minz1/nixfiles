#!/usr/bin/env bash
# Shared helpers — source this file, do not execute it directly.

# Find a writable tmpfs directory suitable for staging secrets in RAM; prints the path to stdout, exits non-zero if none found.
find_ram_dir() {
    local dir
    for dir in "/run/user/$(id -u)" "/run" "/dev/shm"; do
        if [ -d "$dir" ] && [ -w "$dir" ] && [ "$(stat -f -c %T "$dir")" == "tmpfs" ]; then
            echo "$dir"
            return 0
        fi
    done
    echo "ERROR: No writable tmpfs found. Checked: /run/user/$(id -u), /run, /dev/shm" >&2
    echo "On WSL, ensure /run/user/$(id -u) is mounted or /dev/shm is tmpfs." >&2
    return 1
}
