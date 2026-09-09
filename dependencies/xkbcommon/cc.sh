#!/bin/sh
# Meson's stdin preprocessing probe needs an explicit source language with Zig.
for arg do
    if [ "$arg" = "-E" ]; then
        exec /opt/zig/zig cc -x c "$@"
    fi
done
exec /opt/zig/zig cc "$@"
