#!/bin/bash
set -e
export LD_LIBRARY_PATH=/var/task/bin:$LD_LIBRARY_PATH
CLAMSCAN_BIN=/var/task/bin/clamscan
LINKER=/var/task/bin/ld-linux-x86-64.so.2
LIBPATH=/var/task/bin
exec "$LINKER" --library-path "$LIBPATH" "$CLAMSCAN_BIN" "$@"
