#!/bin/sh
# manifest_gate.sh - F16 compatibility entry point; F16b OTS is authoritative.
exec sh tools/ots_gate.sh "$@"
