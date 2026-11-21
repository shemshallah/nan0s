# Python on NaN/0S

Status: **Py-M1 subset running in-guest**. `src/tests/py_m1_test.nas`
embeds a small Python interpreter written in C; ncc compiles that C to NaN16
and runs it. The Python source is a guest string. There is no host Python in
the execution path.

## What Py-M1 supports

- integer and floating-point literals, variables, assignment
- `+ - * /`, unary `-`, parentheses, comparisons `< <= > >= == !=`
- `print(...)` with string literals and numeric expressions
- `if <expr>:` with a one-statement body on the following indented line
- `#` comments and `pass`

Example (the gate input):

```python
x = 2
y = 3
print("x+y =", x + y)
print((x + y) * 4 / 2)
print(1 + 2 * 3)
if x < y:
 print("yes")
if x > y:
 print("no")
z = -x + 10
print(z)
x = x * 5
print(x)
print("done")
```

Gate: `tools/py_m1.sh`.

## Not yet implemented

- strings as first-class values, lists, tuples, dicts, sets
- `while`, `for`, `range`, `break`, `continue`
- functions, `def`, `return`, closures, classes, exceptions
- imports and the Python standard library
- integer/float type distinction (all numbers are doubles in Py-M1)
- an interactive `py` command in the GUI terminal / path filesystem scripts

## Roadmap

1. **Py-M2**: a proper tokenizer + AST in C, string values, `while`/`for`,
   `range`, and integer/float tagging.
2. **Py-M3**: functions, `def`/`return`, lists/dicts, and a small builtin set
   (`len`, `str`, `int`, `float`, `range`).
3. **Py-M4**: REPL integration (a `py` command in the NaN/0S terminal) and
   Python source files in the path/NPAF store.
4. **Py-M5**: a bytecode compiler and VM in NaN16 for larger programs, then a
   stdlib subset.

The C implementation is a bootstrap, not the endpoint: the same interpreter
semantics can later be moved to raw NaN16 or to a bytecode VM without changing
the Python surface.
