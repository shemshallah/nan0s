#!/bin/sh
# tools/s1_image_runner.sh - one-image x86_64 S1 runner for suite gates.
exec "$(dirname "$0")/s1_runner.sh" --img "$1" --mem 128 --steps 200000000 --serial
