# Alias notice

The execution-model policy is [`DONT_USE_NAN16_C.md`](DONT_USE_NAN16_C.md).

`aarch64/android/core/nan16.c` and `nan_cli` are a host C oracle, not the
raw NaN/0S product runtime. Do not use them as the S1/product gate.
