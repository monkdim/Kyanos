# Clarity — Path Forward

This document tracks **what's next for the Clarity language and toolchain**. The 1.0 development history (Phases 1–55) lives in git. KyanOS-specific work lives in [ROADMAP_OS.md](ROADMAP_OS.md). This file covers the *language*: lexer, parser, interpreter, bytecode VM, type checker, stdlib, CLI, package manager, LSP, native compilation.

---

## Where we are (July 2026)

- **v1.0.0 shipped.** 100% self-hosted; the lexer, parser, interpreter, bytecode VM, type checker, linter, formatter, debugger, profiler, doc generator, package manager, LSP, and shell are all written in Clarity. ~2,750 assertions across 50+ test files, all in Clarity.
- **One binary today, no runtime.** `clarity` ships as a single Bun-compiled executable for macOS and Linux on x64 and ARM64.
- **Native compilation has begun.** `clarity cc <file>` compiles a Clarity program **straight to C, then to a real native binary** — no Bun, no bytecode VM (stage 1: the scalar core). This is the seed of the "no runtime at all" endgame; see v2.0 below.
- **The Python bootstrap is still in `native/`.** It rebuilds the binary from source (`python3 native/transpile.py --bundle` → `bun build --compile`); end users never touch it.

The language is at the point where what's left is selective hardening and the native-compilation build-out — not feature catch-up.

---

## Recently shipped (this cycle)

Cleared during the mid-2026 hardening pass — recorded so the tiers below read accurately:

- **Friendly errors.** `clarity run`/`check` print the offending source line with a `^` caret under the exact column (`errors.clarity`).
- **Type checker caught up.** Wrong argument counts and undefined names (typos) are now flagged before you run — zero false positives across the whole stdlib.
- **Dead commands revived.** `clarity profile`, `clarity debug`, and the **REPL** actually execute code now (all three were no-ops).
- **Bytecode VM correctness.** Fixed the iterator stack leak, the crashing/leaking comprehension compilers, and `try/catch` not catching engine-raised errors (division by zero, undefined variable, bad index).
- **Formatter.** Stopped corrupting strings that contain escapes (`\n`/`\t`/…) — `fmt --write` is safe again.
- **Interpreter.** `for k in someMap` iterates keys (was a run of nulls); comprehensions work over maps and strings.
- **LSP.** Hover now shows user-symbol signatures; **go-to-definition** added.
- **Parser.** Keyword names are usable as bare map keys (`show:`, `type:`…) — the parser can now read its own `lsp.clarity`.
- **Generators actually run.** Calling a `yield`-based function now collects its yields and returns the list (`fib_gen() == [0, 1, 1, 2, 3, 5, 8, 13]`); it previously returned `null` because the yield-collection was never set up at call time.
- **`env(name, default)` honours its default.** A missing environment variable now returns the supplied default (e.g. `env("NOTSET", "") == ""`) instead of `null`, matching the native `cl_env`; this also fixes shell `$VAR` expansion of unset variables.

---

## Concrete gaps still open

### `clarity gen-runtime` would have destroyed the runtime it claimed to generate
Fixed, by retiring the generator. `native/runtime.js` said it was
auto-generated from `stdlib/runtime_spec.clarity` and must not be edited by
hand. It was not, and running `clarity gen-runtime` would have destroyed it.
Measured against the committed runtime, regenerating produced 947 lines where
there are 1132, and:

- **Dropped fourteen exports outright** — the seven `_host_*` framebuffer
  bridges and the seven `_pty_*` terminal bridges, which is to say the
  desktop and everything that draws.
- **Lost `_ffi_read_view`.** The committed `_ffi_read_*` builtins read
  runtime-owned buffers through a `DataView` so a read observes a write made
  through the same view; the generated file has no occurrence of it at all.
- **Broke `type()`.** The committed one checks the `_clarityType` marker and
  puts the `function` test before the `object → "map"` fallback. The generated
  one has neither: every interpreter object, and every function, would answer
  `"map"`.

So the runtime was the source of truth and the spec was a stale copy of it.
The generator, the spec and the `gen-runtime` command are gone, and the
runtime's header now says what is true — including the five other places a new
builtin has to be registered, which `stdlib/test_runtime_surface.clarity`
already enforces. That check is what makes a generator unnecessary: it fails
if a builtin is added to one place and forgotten in another.

This is what PR #38 proposed in June, on the same evidence; it was never
rebased and would no longer merge.

### `clarity cc` evaluated arguments in the opposite order to the interpreter
Fixed. The emitter built every multi-operand construct as one C expression —
`cl_call(f, (Value[]){a, b}, 2)`, a list literal, a map literal, a range, a
binary operator — and C does not define the order in which a function call's
arguments are evaluated. GCC picks right-to-left, so every argument with a
side effect ran backwards relative to `clarity run`: `[bump(), bump()]` was
`[2, 1]` natively against `[1, 2]` interpreted, and `{ "x": bump(), "y":
bump() }` and `str(bump()) + str(bump())` went the same way. Operands are
bound to temporaries in source order now, and only where the order can be
observed, so a construct built from literals and names still emits as one
plain expression. The same change fixed the other half of the question — an
operand that throws must stop the ones after it — and a separate defect in
`and`/`or`, which named their left operand twice in the C ternary and so ran
it twice: after `bump() or false` the counter had gone up two, and the value
handed back was the second call's.

### `display()` and `repr()` were reachable before they worked
Fixed. Both were runtime exports no program could call until the builtin
tables were reconciled (PR #149); registering them turned out to have exposed
three defects at once. Each engine registered *the runtime's* `display`, which
does not know what that engine's instance objects are: it fell into its
generic-object branch and walked instance → class → method closures →
environment → instance, so `display(Q())` for any class blew the interpreter's
stack and produced an empty error body under `--fast`. And `clarity cc` had no
`display`/`repr` builtin at all, so a program calling one failed with a C
compiler error about an undeclared `v_display`. They go through each engine's
own display now, and are diffed across all three.

### `==` in native builds compared collections by pointer
Fixed. `cl_eq` compared a list or a map by its address, so `[1, 2] == [1, 2]`
was `false` in a `clarity cc` binary and `true` in both other engines — every
native program that compared collections was silently wrong, including every
`match` arm whose pattern is a list. And every pointer-backed value fell
through to a comparison of the Value's integer field, which is `0` in all of
them, so *any two closures were equal*. Lists and maps compare by contents
now (element-wise in order; by key regardless of insertion order), instances
and closures by identity, as everywhere else. A top-level function named as a
value gets one closure built once, so `f == f` is true rather than comparing
two freshly made ones.

### Indexing and property access disagreed across the three engines
Fixed. `clarity cc` answered `null` for every mistake: indexing `null`, reading
a property of `null`, an index past either end of a list or a string, a
property an object does not have. A compiled program carried the mistake
onwards instead of stopping at it, and a `try` written to catch exactly that
never fired. The bytecode VM answered `null` for a read past either end, so a
program that walked off the end kept going under `--fast` and stopped under
`clarity run`, and it refused to index an instance at all. `?.` did not
compile natively, and in the VM it guarded only a null object where the
interpreter answers null for any failure. All three agree now, over a
twenty-five case matrix.

**Found by that change:** the VM did not short-circuit `and` or `or` — it
compiled both sides and then combined them, so `false and side()` *called*
`side()`. It was invisible while a read past the end answered null, because
the standard library's own guard (`if len(items) == 1 and type(items[0]) ==
"list"`, in `collections.clarity`) reads `items[0]` of an empty list and got
null for it. The moment that became an error, `Set()` stopped working under
`--fast`. Both operators jump now.

### A host error printed as `{}`
Fixed. A stack overflow is not a Clarity throw: it arrives as a host error
object whose properties are not enumerable, so `str()` rendered it as an empty
map and both engines told the program it had failed without telling it
anything else — `Clarity Error in x.clarity:` followed by `{}`. The name and
the message were there all along and just had to be asked for; a Clarity map
that happens to carry a `message` key is told apart by having that key among
its own.

### `...` did not spread in the bytecode VM
Fixed. `...xs` compiled to the value alone, so whatever was assembling the
values around it took the list whole rather than opening it out:
`[1, ...[2, 3], 4]` was `[1, [2, 3], 4]` under `--fast`, and
`f(...[1, 2, 3])` passed one list and two nulls. A spread in a *map* was
worse — `{...m, "b": 2}` crashed the VM's compiler with a host TypeError
about `node.node_type`, because the pair has no key node to compile — so a
program using it did not run at all. `...` marks its value now and the list,
map and call assemblers open the mark out, on the interpreter's rules
including its leniency about `f(...5)` and its refusal of `[1, ...5]`.

### `clarity cc` refused destructuring, spread, decorators and `await`
Fixed. `let [a, b] = pair`, `a, b = b, a` and `...` in a call, a list or a map
were compile-time refusals, and so were `await` and a decorator — which is why
two files in `examples/` did not compile. All seventeen do now, and a codegen
case compiles each of them so the claim cannot go stale quietly. Found while
diffing the examples' native output against the interpreter's, and fixed
alongside: `show a, b` printed one value per line rather than one line with a
space; dividing by zero answered 0 instead of raising the error both other
engines raise; NaN printed as C's `-nan`; a function held in a map or a field
was not callable (`counter.next()` where counter is a map of closures); and a
callee that is any other expression (`fns[i](x)`) was refused outright.

### A list's and a string's builtin methods meant three different things
Fixed. `xs.length` and `"ab".upper` were a callable method in the interpreter,
a plain value in the bytecode VM, and nothing at all in a compiled binary. The
practical half of that was worse than the display: **every one of the thirty
method calls threw under `run --fast`** — `xs.sort()`, `s.split(" ")`,
`s.trim()` — and every one of them answered `null` from `clarity cc`, because
`cl_dispatch` looked only for a user class's method. All three engines now
have the interpreter's set, with its errors, and a method named without being
called is bound to its receiver so `let f = s.upper; f()` works everywhere.
Found on the way: the interpreter's *number* methods (`n.abs()`, `n.str()`)
could never be reached, because the branch tested for a type named "number"
and `type(5)` is `"int"`.

**Still different, and recorded rather than fixed:** *displaying* a function
value. `show f` for a lambda is `<fn <anonymous>>` interpreted and
`<fn <lambda>>` under `--fast`; a builtin is `<builtin>` interpreted,
`<fn anonymous>` in the VM and `<closure>` natively. Behaviour agrees; the
name each engine prints does not.

### A local that shadowed a global was ignored in native builds
Fixed. Every branch that resolved a *called* name in the C backend looked at
the module's functions, classes and builtins, and never at what was in scope:

```clarity
fn helper(x) { return x * 2 }
fn outer(helper) { return helper(7) }
show outer(fn(v) { return v + 300 })   -- interpreter 307, clarity cc 14
```

The same for a `let`, a loop variable, a catch binding and a destructured
name, and for builtins too — `fn(len) { return len(5) }` called the builtin.
And `local_names` was only ever populated for a plain function, so even the
branches that did consult it were wrong inside a class method or a closure.
A name in scope is what a call means now, whatever else the name refers to at
module level. Calling something that is not a function also raises the
interpreter's error rather than answering null.

### An instance did not read like its fields
Fixed. Every engine agrees an instance reads like the map of its fields — that
is why indexing one works, and why `for k in keys(p) { p[k] }` is the idiom.
Except that it did not hold:

```clarity
class A { fn init(n) { this.n = n } }
let a = A(5)
a.extra = 9

show sort(keys(a))   -- run ["extra","n"], cc ["extra","n"],
                     --   --fast ["_clarityType","klass","properties"]
show len(a)          -- run 3, cc 0, --fast 3
```

**The VM leaked its own representation** from `keys`, `values`, `entries` and
`has`, so that loop walked the engine's internals and read three values the
program never wrote. Silently wrong data, not an error. It goes through the
same normalisation the interpreter's `_unwrap_props` does now.

**`len(instance)` was wrong everywhere, in three different ways.** The
interpreter answered **3 whatever the instance held** — it forwarded to the
host `len()`, which counts the ClarityInstance's own three internal
properties, so a one-field instance and a three-field instance both said 3.
The VM matched it by the same accident; the native backend said 0, because
`cl_length` had no `T_OBJECT` case. Here the interpreter was not a
specification to copy: 3 is an implementation detail leaking, and it
contradicted `keys()` in the same engine. All three now answer the field
count, so `len(a) == len(keys(a))`.

**A class method taken as a value** — `let f = d.speak` — raised
`Dog has no property 'speak'` in a native build, where both other engines bind
it to its receiver. `cl_get_field` looked only in the field map; it now finds
the method and hands back a closure carrying the receiver, through the same
bound-method machinery a list's, a string's and an enum's methods already use.

### An unknown name in a native build was a C compiler error
Fixed. A name that resolved to nothing was emitted as `v_name` and left to the
C compiler:

```clarity
fn f() { return nope }
```
```
clarity run   NameError: 'nope' is not defined (line 1)
clarity cc    /tmp/x.c:1812:19: error: 'v_nope' undeclared (first use in this function)
                1812 |   { Value __rv0 = v_nope; ...
```

An error about generated code, naming a variable the program never wrote, at a
line in a file it never saw. The backend now knows what is in scope — the
current function, the scopes a closure is nested inside, module level, and the
builtins — and says so itself: `native compile: 'nope' is not defined
(line 1)`. The same for `x = 5` where nothing declared `x`, and for calling a
name that resolves to nothing.

And an import that asks for a name its module does not declare is now refused
where the modules are flattened, naming both:

```
native compile: 'nosuchthing' not found in '…/stdlib/bits.clarity', imported by <main>
```

It used to reach the backend as a name nothing declared, and the best it could
say was that the name is not defined — true, but not that the import was the
reason.

This check can only *add* refusals, so the risk is refusing a program that
works. Against that: a case compiling every binding form the language has —
a parameter, a local, a loop variable, a catch binding, a destructured name, a
module-level binding, a top-level function, a class, an enum, a real import, a
rest parameter, a comprehension variable and a name two closures deep — plus
the 319 codegen cases, which include compiling every file in `examples/`.

### A compiled binary would not say where an error happened
Fixed. Every engine-raised error in a native build carried the interpreter's
words and dropped its line:

```clarity
try { show 1 / 0 } catch e { show str(e) }
-- clarity run  RuntimeError: Division by zero (line 1)
-- run --fast   RuntimeError: Division by zero (line 1)
-- clarity cc   RuntimeError: Division by zero
```

Every statement now records the line it starts on, and `cl_throw` adds it —
to a string opening with one of the engine's own prefixes, and only when it
does not already say a line. A program's own `throw "boom"` carries no line in
any engine, and an error passing out through several frames keeps the line it
was first given rather than collecting one per frame.

A call puts the caller's line back on the way out, or an error *after* a call
blamed wherever the callee happened to finish — `C().missing` reported the
last line of C's constructor.

One more found while checking this, and fixed with it: **calling a method an
instance does not have answered `null`** in a compiled binary, where both
other engines raise `RuntimeError: D has no property 'nope'`. Reading a
missing property already raised it; the call form fell through to null, so a
compiled program carried the mistake onwards and a `try` written to catch
exactly this never fired.

### An enum was not a value in native builds
Fixed. `clarity cc` compiled an enum as a compile-time table and nothing else,
so a bare mention of one named a C variable that did not exist:

```clarity
enum C { A = 1, B = 2 }
show C      -- clarity run <enum C>, run --fast <enum C>
            -- clarity cc  error: 'v_C' undeclared (first use in this function)
```

The same for `str(C)`, `type(C)`, passing an enum to a function, or putting one
in a list — and a raw C compiler error rather than a Clarity one, so it read as
a compiler bug rather than as the gap it was.

An enum is a runtime value now (`T_ENUM`, holding its name and its members),
with the interpreter's four methods (`values`, `names`, `entries`, `has`), its
`<enum C>` display, its `"enum"` type name, its error for a member that does
not exist, and its refusal of a subscript — an enum is not a map. A member read
through a value (`let e = C` then `e.A`) resolves at run time; a member read
where the enum is *named* still resolves while compiling, which is faster and
keeps the compile-time error for a member that does not exist.

One divergence stays, and it is not about enums: a compiled binary carries no
`(line N)` on any runtime error, where the other two engines now do. Filed
separately, since it is the same for every error kind.

### Four of the seventeen examples did not run under `--fast`
Fixed. Running every file in `examples/` under both engines and diffing found
four that differ — the shop window of the language, on one of its own
engines:

- **`async_generators.clarity` died in the VM's compiler** with
  `TypeError: undefined is not an object (evaluating 'node.node_type')`.
  `compile_DecoratedStatement` read `node.statement`; the parser calls the
  field `target`. So *every* decorated function was a compiler crash under
  `--fast`.
- **`patterns.clarity` printed `42 is a unknown`.** The VM's `_type_name`
  ended in `return "unknown"` where the interpreter's `cl_type_name` ends in
  `return t`, and the host already distinguishes `int` from `float` — so the
  `t == "number"` branch above it never fires and every number fell through to
  `"unknown"`. `match type(x) { when "int" ... }` took no arm.
- **`classes.clarity` called null.** The VM compiled an enum to a plain map,
  so `Color.Red` worked by accident and `Color.names()` was `null()`. There is
  a `VMEnum` now, with the interpreter's four methods (`values`, `names`,
  `entries`, `has`), its `<enum C>` display, its `"enum"` type name and its
  error for a member that does not exist. A subscript is refused, as it is
  under `clarity run` — an enum is not a map.
- **`control_flow.clarity` lost a line number.** An engine-raised error
  carried the interpreter's words but never its line, so
  `RuntimeError: Division by zero` where `clarity run` says
  `... (line 46)`. The line is added once, on the way out of the instruction
  that raised it, to a string opening with one of the engine's own prefixes —
  a program's own `throw "boom"` still carries no line, in either engine.

Also fixed on the way: the VM said `RuntimeError: Not callable: 5` where both
other engines say `TypeError: 'int' is not callable`, and
`RuntimeError: Cannot index into VMEnum` where the interpreter names the
language's type, not the engine's.

All seventeen examples now produce identical output under `clarity run` and
`run --fast`. `clarity cc` compiles all seventeen, and the one thing it still
cannot do with an enum — use it as a *value*, as in `show C` — is filed.

### The bytecode VM had no block scoping
Fixed. `run --fast` kept every binding of a call in one flat map, so no block
scoped at all — not an `if` body, a loop body, a `try`, a `catch`, a `finally`,
a `match` arm or a comprehension:

```clarity
for z in [1, 2, 3] { }
show z                          -- clarity run NameError, run --fast 3

let y = 99
for y in [1, 2] { }
show y                          -- clarity run 99, run --fast 2

mut fs = []
for k in [1, 2, 3] { push(fs, fn() { return k }) }
show [f() for f in fs]          -- clarity run [1, 2, 3], run --fast [3, 3, 3]
```

The second is the damaging one: an ordinary loop over a name that already
exists silently overwrote it under one engine and not the other. The third is
the same fault seen from the other side — every closure made in the loop
captured the one map, so all three answered the last value.

A frame now holds a stack of scopes: `locals` is the innermost and `parents`
the blocks around it. `PUSH_SCOPE` and `POP_SCOPE` bracket every block form,
a loop body gets a fresh one *per iteration* (so a closure captures that
round's variable, as it does under `clarity run`), and a closure captures the
chain rather than one map. `break` and `continue` close the blocks between
themselves and their loop, the same way they already ran the finallys; an
error thrown from inside a block lands in the catch with that block closed,
because the handler records how deep it was.

Assignment follows the same chain now — it used to check only the frame's flat
map and then enclosing *frames*, never what the call had captured, so writing
to a captured variable made a new local instead of writing through.

Four of the seventeen files in `examples/` still do not run the same under
`--fast`; all four predate this and are filed separately.

### Slicing meant three different things, and `clarity cc` meant none of them
Fixed, with one question left open. `xs[1..3]` did not compile at all —
`SliceExpression` had no case in the C backend — and the two engines that did
compile it disagreed:

```clarity
let s = "hello"
show s[1..3]        -- clarity run ["e", "l"], run --fast "el"
let m = {"a": 1}
show m[0..1]        -- clarity run [null], run --fast RuntimeError: Cannot slice map
let xs = [10, 20, 30, 40]
show xs[null..2]    -- clarity run [10, 20], run --fast [null, 20]
```

All three now run the loop the interpreter runs, on the same values, so the
answers agree into the corners — including a negative start counting from the
end, a bound that is not a number, and a missing bound decided by the runtime
*value* rather than by whether the source wrote one.

**Open, and it is a language question rather than an engine one (see the task
list):** the interpreter implements a slice by walking the value with the
language's own indexing, and three things fall out of that rather than out of
a decision.

- **A string slice is a list of characters, but `.slice()` is a substring.**
  `s[1..3]` is `["e", "l"]` and `s.slice(1, 3)` is `"el"` — the same operation,
  two spellings, two answers. Every mainstream language gives the substring,
  and so does the method; the subscript is the odd one out. Slicing is
  documented nowhere, so there is nothing to appeal to.
- **Out of range depends on how deep the interpreter is nested.**
  `len(xs[-100..2])` is 102 run directly and an `Index -100 out of bounds`
  error one interpreter layer down, because `_slice_range` inherits whatever
  `lst[i]` means where it is running. Neither answer is a specification. The
  suites deliberately do not assert this corner.
- **`m[0..1]` on a map answers `[null]`** rather than refusing, because `m[0]`
  is null and the loop pushes it.

Matching the interpreter is what the three engines owe each other, and that
part is done. What a slice *should* mean is the owner's call, and until it is
made the three at least say the same thing.

### Comprehensions and nested functions in the three engines
Fixed. A comprehension did not compile at all — `clarity cc` answered
`unsupported expression ComprehensionExpression` — and a nested `fn`
statement was compiled as though the name were a top-level function, so it
did not see the enclosing scope:

```clarity
show [y * 2 for y in [1, 2, 3]]        -- interpreter [2, 4, 6], clarity cc refused
fn f(n) {
    let bump = 10
    fn add(x) { return x + bump }      -- clarity cc did not see bump
    return add(n)
}
```

Both compile now. A comprehension becomes a loop inside a statement
expression, over the same normalised sequence a `for` walks (a map by its
keys, a string by its characters), and its loop variable is declared inside
those braces, so it is scoped to the comprehension and an outer name it
shadows survives. A nested `fn` becomes a local closure. A nested `fn` that
*calls itself* is refused by name: the closure is built from the values in
scope and its own name is not one of them yet, which needs by-reference
capture — the same v2.0 item as by-reference scalar capture — and refusing it
beats emitting a call to a variable the closure never captured.

Three more things this turned up:

- **`{k: v for k, v in entries(m)}` did not run under `--fast` at all.** The
  bytecode VM refused every multi-variable map comprehension. It compiles one
  now, through a `COMP_BIND` opcode carrying the interpreter's rule: a list
  item is taken apart element by element with null past its end, anything
  else goes whole to the first target and leaves the rest *unbound*, so
  reading one raises the NameError `clarity run` raises.
- **The VM worded an undefined name differently.** `RuntimeError: Undefined
  variable: q` against the interpreter's `NameError: 'q' is not defined
  (line 7)`, with no line at all — so a program that caught the error and
  showed it read differently under `--fast`. Same words, same line now.
- **`o?.a`, `await x` and `yield x` were missing from the C backend's
  free-variable walk.** A closure over one of them never captured the name it
  read, and the emitted C named a variable nothing declared — a C compiler
  error about code the program did write, just not where the compiler looked.

Still open, and filed: the VM has no block scoping at all, so a comprehension
or `for` variable leaks and can clobber an outer name of the same name under
`--fast`. And `clarity cc` still refuses `SliceExpression` (`xs[1..3]`).

### A builtin's argument count was a C compiler error, and a name that shadows a builtin was the builtin
Fixed. `_builtin_call` matches a name *together with a count*, and a call that
matched no branch fell through to `cl_call(v_<name>, ...)` — the same
undeclared-identifier failure the unknown-name work above removed, reached
through arity instead of through the name:

```clarity
show sort([3, 1, 2], fn(a, b) { return b - a })
```
```
clarity run   [-5, 1, 2, 3, 10]
clarity cc    /tmp/x.c:1862:19: error: 'v_sort' undeclared (first use in this function)
                1862 |   cl_show(cl_call(v_sort, (Value[]){v_xs, cl_closure_new(...)}, 2));
```

The same for `len("ab", "cd")`, `upper("a", "b")` and `str(7, 8)`. There are 101
builtins, and with the fallback removed 94 of them reach the output as
`cl_call(v_<name>, ...)` when called with four arguments, and 94 go unrefused
when called with none. This was not one call; it was every call that did not
happen to be written at an arity the emitter special-cases.

The two halves get the two answers the interpreter gives:

- **Surplus arguments are dropped, not skipped.** The interpreter evaluates
  every argument expression and then binds only the parameters the builtin
  declares, so `sort(xs, bump())` sorts *and* bumps. Two or more operands with
  anything impure among them already go through `_ordered_parts`, which binds
  each of them to a temporary in source order; dropping the surplus from the
  call leaves its evaluation in place. Verified with a counter in all three
  engines.
- **Too few is refused by name.** There is nothing to emit, and the
  interpreter's own answer is not a semantics worth matching — it reaches the
  host function short a value and reports it in the host's words
  (`upper()` gives "undefined is not an object (evaluating 's.toUpperCase')",
  `sort()` gives "Spread syntax requires ...iterable not be null or
  undefined"). So `clarity cc` says `native compile: upper() takes 1 argument,
  given 0 (line 1)`, the way it already refuses an undefined identifier.

The arities a builtin takes are read out of `_builtin_call` by asking it — a
probe per count on the one path that needs it, which is a call it has already
refused. A second list written by hand would have drifted out of step with the
first one the next time an arity was added, which is the failure the
`_NATIVE_BUILTINS` cross-check above exists to catch.

Two whole-table cases hold the line: every declared builtin called with four
arguments in one program, whose output must not contain `v_<name>` for any of
them, and every declared builtin called with none, whose refusal must name
each one that needs an argument. The first also catches the reverse of the
existing cross-check — a name in the table that `_builtin_call` never emits at
any count.

Finding it turned up the other half of the same question: which thing a
builtin's name calls when the program binds it. The builtin was tried before
the program's own bindings, so it won at any count it happens to take —

```clarity
fn sort(xs) { return "mine" }
show sort([3, 1, 2])
```
```
clarity run   mine
clarity cc    [1, 2, 3]
```

— and the same for `let upper = fn(s) { ... }` and for a captured outer local.
It only lost at a count the builtin does not take, which is why the arity work
above is what exposed it. A local, a class and a decorated name already won;
the order now runs through every binding the backend knows about before it
reaches the builtins, which is the order `_name_known` already lists them in.
The pattern is not hypothetical: three files in `stdlib/` define their own
`fn max(a, b)`, and every call to it was compiled as the builtin.

Still open, and filed: `sort(xs, cmp)` now compiles, but **the comparator is
ignored in every engine** — `sort` takes one parameter everywhere, so the
second argument is evaluated and discarded. And ordering comparisons on lists
and maps disagree: `[10] < [9]` is true under `run` and `--fast` (the host
compares "10" and "9" as strings) and false under `cc` (both sides number to
zero), so `sort` on a list of lists reorders in two engines and not the third.

### A number in a native build was a different number, and printed differently
Fixed, in four connected places.

**The reference documented an exponent the scanner never read.**
`docs/reference.html` has listed `1.5e10` and `2.0E-3` as float literals for
as long as there has been a reference. `read_number` scanned digits, one dot
and `_` separators and stopped, so:

```clarity
let x = 1.5e10
```
```
NameError: 'e10' is not defined (line 1)
```

`show 2.0E-3` was worse: it printed `2` and then failed on `E`. The scanner
takes `e`/`E`, an optional sign and at least one digit now. Anything short of
that is left alone, so `1e` is still the number 1 followed by the name `e` —
which the standard library defines as Euler's number — and `1e+1` is 10, as
it is in every language that has the syntax. One lexer serves all three
engines, so the parse is fixed once.

**Past 2^53 a native build held a different number.** The backend emitted
`cl_int(...)` for any whole number however large, and C's long wrapped:

```clarity
show 100000000000000000000
show 0xFFFFFFFFFFFFFFFF
show 4611686018427387904 * 4
show 9223372036854775807 + 1
```
```
clarity run   100000000000000000000   18446744073709552000   18446744073709552000   9223372036854776000
clarity cc    7766279631452241920     384                    384                    -9223372036854775615
```

Every number the other two engines have is a double, so the boundary that
matches them is 2^53-1 and not LONG_MAX — between the two a long is *more*
precise than the double they parsed, which is a difference in the other
direction. A literal outside the range is emitted as a double, and `+`, `-`,
`*`, `**` and `int()` hand back a double when their result leaves it. The
bitwise operators keep their own 32-bit rule, which is JavaScript's and was
already matched.

**And it printed the number differently.** The float path was `%g` at the
shortest precision that round-trips, which gets the digits right and the rest
wrong:

| | `clarity run` | `clarity cc` |
|---|---|---|
| `1e18` | `1000000000000000000` | `1e+18` |
| `1e20` | `100000000000000000000` | `1e+20` |
| `1e-6` | `0.000001` | `1e-06` |
| `1e-7` | `1e-7` | `1e-07` |
| `2 ** 62` | `4611686018427388000` | `4611686018427387904` |

JavaScript writes a number in fixed notation while its decimal exponent keeps
it inside 1e-6 .. 1e21 and in exponential notation outside that; `%g` switches
at the precision instead, spells the exponent with a leading zero, and a long
prints all its digits where a double would have been rounded. `cl_num_text`
takes the shortest round-tripping *scientific* form — which gives the digits
and the decimal exponent in one call — and places the point by JavaScript's
four cases.

**And `1.5 & 3` was 0.** A bitwise operand goes through JavaScript's ToInt32
in both other engines; the native helpers read `a.i`, which is right only for
a T_INT — a T_FLOAT carries its value in `.f` and leaves `.i` at zero. That
was already wrong for `1.5 & 3`, and it became wrong for sha256 the moment an
integer result that leaves the exact range started coming back as a float:
`test_sha256`'s published digests were the first thing the change broke, which
is the test doing its job. The operands go through a real ToInt32 now, and a
left shift is done on the unsigned value so that `1 << 31` is not undefined in
C.

**Which needed `%e` in the freestanding libc**, where the emitted C is linked
for KyanOS. `printf.c` had `%g` and not `%e`, so the first build printed the
format string: `2 %.17 -3 3`. It has `%e`/`%E` now, over the same exact-digits
`cl_dtoa` its `%g` already used, and `stdlib/test_libc.clarity` — which links
a compiled program against that libc and diffs it against the interpreter —
is what caught it. `float_probe`, which diffs this library's float conversions
against the host's over a fixed sweep and four thousand random bit patterns,
covers `%e` too now; removing the conversion again fails it at line 1.

### Mid-run garbage collection kills a program on darwin-arm64
`CLARITY_GC=1` turns on mid-run collection in a compiled binary. On
darwin-arm64 a program that holds **two** live allocations across a collection
is killed: it compiles, links, runs and dies with no output on either stream.
The one-allocation cases in the codegen suite pass on the same runner, and
linux-x64 and linux-arm64 both pass every case, so this is Apple's toolchain
rather than arm64 as such.

It was found by the evaluation-order change, which shifted where temporaries
live and turned `enum_string_members_gc` red there. Things that did **not**
fix it: putting every sequenced temporary and the collection accumulator in
`volatile` storage, and building the collection through a named local one
statement at a time. Things that could not reproduce it: gcc and clang at
`-O2` on x86-64, including with the threshold lowered so that a collection
runs at nearly every allocation.

This is the instability the collector already documents — conservative stack
scanning is optimiser- and ABI-sensitive — and the fix is the precise
(shadow-stack) collector on the v2.0 roadmap, not another guess at where
clang put a value. Until then the suite's `same_gc` cases compile and run on
darwin with the default arena, which is what ships there, and only the
mid-run collection goes unchecked on that one platform.

### Brand-domain / naming
`stdlib/branding.clarity` carries the brand name and domain in one place and the site is generated from it, so the KyanOS rename moved the whole set at once. The domain is the GitHub Pages URL REBRAND.md names as the interim (`monkdim.github.io/Kyanos`); a real domain is a purchase, not a code change, and `BRAND_DOMAIN` is the single line it lands on.

---

## v1.1 — Language hardening (largely done; finish the tail)

- **Error messages** — ✅ source line + caret for lexer/parser errors. **Remaining:** give *runtime* errors a column too, so the caret works there like it does for parse errors (they carry a line but no column today).
- **Type checker** — ✅ arity + undefined-name checks landed. **Remaining:** a written soundness audit of the gradual-typing escape hatches (catalogue what's intentionally loose vs. an actual hole).
- **Bytecode VM** — ✅ the two engines are now held to one semantics by a parity suite. `stdlib/test_parity.clarity` runs 74 programs through the tree-walking interpreter and the VM and requires identical output, the way the native compiler's suite has always diffed native against the interpreter. It found seven things wrong with the VM, all reproducible on the v1.0.1 release binary with `clarity run <file> --fast`: string interpolation was not implemented at all (`show "n is {n}"` printed the braces), `break` left its iterator on the stack and corrupted the enclosing loop, `finally` was never compiled, `return` from inside a `try` escaped as an uncaught signal, `break` and `continue` out of a `try` skipped its `finally`, a `try` left early by any of the three left its handler registered so the next call at the same frame depth jumped into a catch block belonging to a function that had already returned (a throw after such a return was swallowed and the program exited 0), and reading a property an instance does not have returned null where the interpreter names the class and stops. All seven are fixed. **Remaining:** benchmark interpreter vs. VM across the example suite and document/close any hot-path regressions.
- **`clarity fmt` parity** — ✅ the escape-corruption bug is fixed. **Remaining:** byte-for-byte reproduction of the hand-formatted stdlib.
- **`clarity test` ergonomics** — open: `--only` focus mode, `--watch`, a parallel runner, per-file wall-clock.

---

## v1.2 — Toolchain & ecosystem polish

- **LSP** — ✅ hover types + go-to-definition (same file). **Remaining:** rename, cross-file go-to-definition, and code actions for the seven lint rules.
- **Package manager.** Lockfile spec, integrity hashes, offline mode, mirror support. The registry server exists; the client side is the gap.
- **Doc generator.** Cross-references between modules, search index, dark-mode CSS.
- **Debugger.** ✅ runs again. **Remaining:** conditional breakpoints, watch expressions, step-into-builtins gating.
- **Profiler.** ✅ runs again. **Remaining:** flamegraph SVG output; sub-line resolution.

---

## v2.0 — Native compilation, WASM & FFI

The headline track. Each item is scoped large enough to grow in stages.

- **Native compilation (Clarity → C → binary).** *In progress.* `clarity cc` compiles the scalar core (stage 1); lists, maps, `for`-loops over lists/maps/strings/ranges, indexing + index-assignment, and the common builtins (`len`/`push`/`str`/`int`/`float`/`range`/`keys`/`has`/`contains`) (stage 2); classes — instances (class + field map), methods with runtime dispatch, constructors, `this` field access, `to_string`/default display, single inheritance (stage 3); closures — `fn` expressions hoisted to C functions with by-value free-variable capture, called through `cl_call`, plus native `map`/`filter`/`reduce`/`each` (stage 4); centralised allocation behind one `cl_alloc` hook (stage 5); **and a conservative mark-sweep GC** — each allocation is tracked and the whole set is freed at exit, so the default runtime is the leak-free arena (safe on every platform). Setting `CLARITY_GC` turns on *mid-run* collection: the collector flushes registers, scans the C stack + object interiors for pointers, marks the reachable set, and frees the rest, so a long-running program reclaims mid-run (churning ~240 MB of garbage holds at ~3 MB RSS). Its mark phase binary-searches an address-sorted snapshot of the live set — O(n log n) per collection, so a 25k-live-object churn runs in ~0.06 s (vs >60 s for a per-word linear scan). Mid-run collection is **off by default and experimental**: conservative stack scanning is optimiser/ABI sensitive and showed instability under clang -O2 on arm64. Collections, instances, and functional pipelines render exactly like the interpreter; every codegen test compiles the C and diffs native output against the tree-walking interpreter (47 cases). **Next (the path to default-on GC):** a **precise collector** — emit an explicit shadow stack of live roots instead of conservatively scanning the C stack — which removes the platform fragility; plus by-reference scalar capture in closures. Endgame: `clarity build` emits a native binary with **no Bun**. (This supersedes the stalled Zig `runtime/native_vm/` bet — the C path is fully buildable and testable in CI, and produces compiled code rather than a bytecode interpreter in a binary.)
- **Native app stdlib (the "build real apps as native binaries" track).** *In progress.* The compiler core is done (stages 1–6); the work now is making real apps compile, since `clarity cc` previously supported no I/O. Two strategies: **native C builtins** for OS primitives (emit libc calls) and **pure-Clarity stdlib** for logic (compiles for free once the primitives exist, and drops the host-tool/Bun dependency). **Stage 7 (done):** string ops (upper/lower/trim/split/join/replace/starts/ends/substring/char_at/char_code/from_char_code/index_of/pad_left/pad_right/chars/repeat/is_*), file I/O (read/write/append/exists/lines), and process basics (env/args/exit) — all libc-backed; `main` takes argc/argv. A real `wc` CLI now compiles to a standalone ELF. **Stage 8 (done):** process — `exec` (popen), `exec_full` (fork + two pipes → `{stdout, stderr, exit_code}`), `sleep`, `time` — and math (`abs`/`floor`/`ceil`/`round`/`sqrt`/`sin`/`cos`/`tan`/`log`/`min`/`max`/`sum`); native float display now prints the shortest round-tripping form (`3.14`, not `3.1400000000000001`). Interpreter parity fixes landed alongside (`pad_left`/`pad_right`/`hash` registered; `round(n, d)` honours the decimals arg). **Stage 9 (done):** JSON — a recursive-descent `json_parse` (objects→maps, arrays→lists, string escapes + `\uXXXX`→UTF-8, int/float) and a `json_string` serialiser matching `JSON.stringify` (compact, insertion order), over an amortised-O(n) string builder; a native tool reads a JSON config and emits JSON. **Stage 10 (done):** the binary-data foundation for RE tools & game mods — `read_bytes`/`write_bytes` (a file ↔ a list of ints 0..255, matching the interpreter) and the **bitwise operators** (`&` `|` `^` `<<` `>>`), so pure-Clarity code can parse and emit binary formats. A native file-type sniffer now `read_bytes`-es a file, matches magic bytes, and little-endian-decodes a header field (correctly IDs the `clarity` binary as ELF x86-64), compiled to a standalone binary. Bitwise ops match the interpreter's **JS 32-bit-signed** semantics (operands truncated to `int32`, shift counts masked to 5 bits) — pinned by a test that decodes a u32 with bit 31 set; native reproduces the interpreter's negative wrap exactly. **Stage 11 (done):** native FFI — `ffi_sym`/`ffi_call` resolve a symbol via `dlsym(RTLD_DEFAULT)` and call it through a typed shim (`sig` = `<ret><args>`, `l`/`d`/`s`/`v`), so a compiled binary calls C directly. A native demo calls libc `strlen`/`abs`/`toupper`/`getpid` and prints their results. The dlfcn helpers are dead-code-eliminated at `-O2` unless the program uses FFI, so non-FFI binaries still link with `-lm` alone on every platform; FFI binaries add **`-ldl` on Linux** (a harmless stub on modern glibc, the real libdl on older; macOS gets `dlsym` from libSystem). Native-only tested (the interpreter's FFI is a separate Bun-based surface). *Known limit:* `RTLD_DEFAULT` only resolves symbols in *loaded* libraries — libc is always loaded, but a symbol from a library the program never otherwise references (e.g. libm's `pow` under the linker's default `--as-needed`) won't be found; an explicit `ffi_open(path)` for arbitrary shared libraries fixes this (added in stage 16). **Stage 12 (done) — first Track B (RE tooling) increment:** the byte-buffer toolkit `stdlib/bytes.clarity` — endianness readers (`u8`; `u16`/`u32`/`u64` little- and big-endian; signed `i8`/`i16le`/`i32le`), matching writers (`put_u16le`/`put_u32le`/…), hex formatting (`hex_byte`/`to_hex`/`hexdump`), a bounds-clamped `slice`, and **AOB/signature scanning** (`parse_pattern` with `??`/`?`/`*` wildcards → `match_at`/`find_pattern`/`find_all`/`scan`/`scan_all`). It's **pure Clarity over the stage-10 byte + bitwise primitives**, so it compiles under `clarity cc` for free — *zero* new runtime builtins, the "pure-Clarity stdlib compiles for free" thesis in action. Unsigned multi-byte reads use arithmetic (multiply/add), not `<< 24`, so `u32le`/`u32be` come back *unsigned* (0..2^32-1) rather than sign-wrapping under the 32-bit-signed bitwise semantics; `u64le` is exact to 2^53. A native `examples/sigscan.clarity` compiles with `clarity cc` to a standalone ELF and AOB-scans `/bin/ls` for a wildcarded signature. The codegen suite compiles the real toolkit bodies and diffs native vs interpreter (7 new cases → C codegen 86; `test_bytes.clarity` adds 49 interpreter assertions). **Stage 13 (done) — live-process memory access:** the new native builtin `read_mem(pid, addr, len)` `pread`s another process's `/proc/<pid>/mem` (pid≤0 = self) into a byte list, so a compiled tool can read a running target's memory; region enumeration (`mem_regions`, `find_region`, `scan_process`) is pure-Clarity in `stdlib/procmem.clarity`, parsing `/proc/<pid>/maps`. `examples/memscan.clarity` compiles with `clarity cc` and AOB-scans a live process's readable regions for a wildcarded signature (chunked reads with pattern-length overlap so a match straddling a chunk edge is still found), printing absolute addresses. This is the first stage to add a native builtin *and* an interpreter builtin together — `read_mem` was registered in all five places a builtin lives (`native/runtime.js`, `runtime_spec.clarity`, `interpreter.clarity`, `type_checker.clarity`, and both transpiler import headers). Linux-only (it reads `/proc`); on macOS/elsewhere `read_mem` and `mem_regions` return empties, so callers degrade gracefully, and the native codegen check is Linux-gated. **Also fixed here:** native `read`/`lines` (`cl_read_file`) sized files via `ftell`, which reports 0 for `/proc` virtual files — it now reads in a growing loop to real EOF, so `read`/`lines` work on `/proc/<pid>/maps` (and pipes/FIFOs). Verification: `test_procmem.clarity` adds 16 interpreter assertions (Linux-gated, self-memory only so no ptrace needed — it reads its own ELF header from live memory and confirms it matches the on-disk file); one Linux-gated native codegen case reads the compiled binary's own memory and confirms the ELF magic (→ C codegen 87). *Address display in `memscan` uses arithmetic, not bitwise shifts, since addresses are 48-bit and `>>` is 32-bit-signed — a live illustration of the 64-bit-bitwise follow-up below.* **Stage 14 (done) — the write side:** the native+interpreter builtin `write_mem(pid, addr, bytes)` `pwrite`s into a target's `/proc/<pid>/mem` (pid≤0 = self) and returns the byte count (0 on failure), completing the read/write memory story — the trainer counterpart to `read_mem`. `stdlib/procmem.clarity` gains `patch_first(pid, sig, new_bytes)` (find a signature, poke the first hit); `examples/memtrainer.clarity` compiles with `clarity cc` and runs the full read → locate → write → verify loop (holds a "score" as a heap string, finds it by signature in its own writable memory, patches it, and reads the new value back). Registered in the same five builtin sites as `read_mem`. Verification: `test_procmem.clarity` +3 assertions (write-back round-trip + graceful-failure, self-only), and two native codegen cases — a portable error-path check (`write_mem` to an unmapped address returns 0 everywhere) and a Linux-gated live-mutation proof that overwrites a heap string's byte and confirms the change (→ C codegen 89). Writing self needs no ptrace; writing another process needs ptrace permission and a writable target page. **Stage 15 (done) — 64-bit-capable bit manipulation:** `stdlib/bits.clarity`, a pure-Clarity module that does correct bit work on non-negative integers up to **2^53** — covering the whole 48-bit userspace address space and every u32/u48 field, where the plain `&`/`|`/`^`/`<<`/`>>` operators (32-bit-signed) would mangle results. `shl`/`shr`/`mask`/`get_bits`/`bit`/`pow2` are pure arithmetic (`*`/`/`/`%`); `band`/`bor`/`bxor` split each operand into its low/high 32-bit halves, apply the existing 32-bit operator to each, and recombine (the halves' bit patterns are correct regardless of the operator's signed interpretation); `to_hex(x, digits)` formats via arithmetic, so a 48-bit address prints correctly (the fix the `memscan`/`memtrainer` address display needed inline). Compiles for free under `clarity cc` — zero new builtins — and every function is diffed native vs interpreter (4 codegen cases → C codegen 93; `test_bits.clarity` adds 30 interpreter assertions). `examples/elf64info.clarity` decodes an ELF64 header's 64-bit entry point / offsets (u64le + to_hex) and compiles standalone. This resolves the *practical* half of the 64-bit gap (RE field/pointer/address math to 2^53); full u64 (bit 63) still needs a bignum path — see follow-ups. **Stage 16 (done) — native FFI `ffi_open`:** `ffi_open(path)` `dlopen`s a shared library with `RTLD_GLOBAL`, folding its symbols into the scope `RTLD_DEFAULT` searches, so `ffi_sym`/`ffi_call` can now bind **any** C library — not just ones the program already references. This closes the stage-11 known limit: under the linker's default `--as-needed`, a compiled binary that only calls `pow` via FFI never loads libm, so `ffi_sym("pow")` returned 0; after `ffi_open("libm.so.6")` it resolves and `ffi_call("pow", "ddd", [2.0, 10.0])` returns 1024. It's the on-ramp to real RE/mod library integrations (a disassembler like Capstone, a game's own `.so`). Native-only (the interpreter's FFI is the separate Bun `bun:ffi` surface) and added to `c_codegen.clarity` only (helper `cl_ffi_open` + dispatch + `_NATIVE_BUILTINS`). Verification: `examples/ffi_libm.clarity` compiles with `clarity cc` and calls libm `pow`/`sqrt`/`floor`; one Linux-gated native codegen case proves the before/after resolvability (→ C codegen 94). **Stage 17 (done) — native FFI usable for real libraries:** `ffi_call` now has a **generic word-argument path** — any mix of `l` (int), `p` (pointer/address), and `s` (cstring) args goes through one 6-word prototype (valid on the SysV-x86-64 and AArch64 integer-register ABIs, where surplus prototype args are harmless), replacing the old fixed signature table; and **raw buffers** — `ffi_buffer(n)` / `ffi_read(ptr,n)` / `ffi_write(ptr,bytes)` / `ffi_free(ptr)` (malloc-backed, off the GC heap) let a call pass a pointer to memory Clarity owns (an out-param, a struct, a byte region). Together these are the marshalling layer a pointer-heavy C library needs — the concrete prerequisite the disassembly on-ramp actually turned out to require (Capstone's `cs_open`/`cs_disasm` are all pointer/struct/out-params, which `ffi_open` alone couldn't drive). Native-only, confined to `c_codegen.clarity`. Verified: `examples/ffi_buffer.clarity` strcpy/strcat into a native buffer, `strlen`s it via a pointer, and reads the bytes back ("hello, clarity"); two portable native codegen cases (libc memset/memcpy) prove the pointer + buffer path, and the stage-11 strlen/abs/toupper cases still pass through the new generic caller (→ C codegen 96). *Not for variadic callees, and float args ('d') keep their dedicated prototypes (separate register class).* **Stage 18 (done) — function hooking:** `stdlib/hook.clarity` patches a live function's code so it returns a chosen value (`hook_return`/`unhook`/`ret_patch`/`patch`), built on stage-14 `write_mem` — writing through `/proc/<pid>/mem` reaches read-only *executable* pages (the mechanism a debugger uses for breakpoints), so a compiled tool can inline-patch a running function: the core of a trainer/RE hook. `examples/hookdemo.clarity` resolves libc `abs` via FFI, patches its prologue in this process's own `.text` so it returns 42 for any input, then restores it. **x86-64 Linux only:** the patch is x86-64 machine code (`mov eax, imm32; ret`), and self-modifying code on arm64 additionally needs instruction-cache maintenance not reachable yet — `ret_patch` returns [] on other arches so `hook_return` reports failure instead of corrupting code. Native-only (target resolution uses `ffi_sym`); verified by an x86-64-Linux-gated codegen case that hooks `abs` to return 99 and restores it (→ C codegen 97). **Stage 19 (done) — binary-format DSL:** `stdlib/binformat.clarity` describes a binary layout as a list of field specs (`{name, type}` for scalars — `u8`/`i8`/`u16le`/`u16be`/`i16le`/`u32le`/`u32be`/`i32le`/`u64le` — plus `{type:"bytes", len}` and `{type:"pad", len}`), then `parse(format, buf, start)` reads bytes into a map of values and `emit(format, values)` builds the bytes back, with `sizeof`. Pure Clarity over `bytes.clarity`, so it compiles for free (bareword map keys and map index-assign both compile natively). This is the "describe/parse/emit a binary format" pillar — save files, packets, asset formats, executable headers — alongside scanning (`bytes.clarity`) and live memory (`procmem.clarity`). `examples/binformat_demo.clarity` round-trips a packet header and declaratively parses a real ELF64 header from `/bin/ls`. Verified: `test_binformat.clarity` 23 interpreter assertions (round-trip, endianness, signed, pad/bytes, parse-at-offset, ELF64) and a native codegen round-trip case diffed against the interpreter (→ C codegen 98). **Stage 20 (done) — disassembly on-ramp:** `stdlib/capstone.clarity` binds **libcapstone** at runtime through the native FFI (`ffi_open` + buffers) and decodes machine code into instructions — `disasm_x64(code, addr)` / `disasm_at(code, addr, arch, mode)` return a list of `{addr, size, mnemonic, op_str}`, `format_insn` renders one. It reads `cs_disasm`'s `cs_insn` array out of native memory at the right field offsets, chosen from the runtime `cs_version` (Capstone 4 vs 5 differ: `bytes[16]`→`[24]` shifts `mnemonic`/`op_str` and grows `sizeof` 240→248; `address`@8 and `size`@16 are stable). `examples/disasm.clarity` disassembles a static x86-64 snippet **and a live libc `abs()`** read straight from its address (`ffi_sym` → `read_mem` → decode: `endbr64; mov eax, edi; neg eax; cmovs eax, edi; ret`) — the whole RE loop in native Clarity. Native-only (the interpreter has no `ffi_*`); CI installs `libcapstone-dev` on the Linux runners and a Linux-gated codegen case decodes `push rbp; mov rbp,rsp; mov eax,0x2a; ret` and checks the mnemonics (Capstone cross-disassembles, so this runs on both linux-x64 and linux-arm64; macOS has no capstone and skips → C codegen 99). `test_capstone.clarity` validates the module parses and its pure helper/constants. **Next:** a proper trampoline detour (jump-to-replacement, not just a forced return) and arm64 hooking (with i-cache flush) are the remaining hooking follow-ups; **Next:** hooking/detours (GOT/PLT patching, now feasible via `write_mem`) and a disassembly on-ramp (bind a Capstone-class engine via `ffi_open`) for RE; on the trunk, sockets → HTTP client/server → TLS → crypto/DB for network services; GUI last (needs a graphics stack). *Follow-ups:* **`clarity cc` is single-file** — it doesn't resolve module imports, so native programs can't yet `from "bytes.clarity" import …` and must inline what they use (the sigscan example does); import flattening for native builds is the next Track B ergonomics step. Explicit-library `ffi_open` (stage 16) and pointer/buffer marshalling + a generic word-arg caller (stage 17) are **done**; what remains in the *native* FFI shim is float args mixed with pointers (floats still use dedicated `d`/`dd`/`ddd` prototypes), struct-by-value, and variadic callees — a full libffi-style path would cover all three, but the current path handles the pointer-heavy integer APIs real RE libraries use. `stdlib/ffi.clarity` already does structs/pointers on the interpreter (bun:ffi) surface. **64-bit bitwise** — `stdlib/bits.clarity` (stage 15) now covers bit work to 2^53 via arithmetic/decomposition, which handles 48-bit addresses and u32/u48 fields; what remains is (a) the *operators* `&`/`|`/`^`/`<<`/`>>` themselves are still 32-bit-signed (making them 64-bit is a breaking change to core semantics across interpreter + VM + native), and (b) true bit-63 u64 needs a bignum/numeric-tower path in the interpreter (JS doubles top out at 2^53). Both are larger, deliberate efforts than a stage. `args()` under `clarity run script.clarity <args>` now returns the program's own arguments, as a native binary's does; the CLI sets them in each engine before the file runs, and the smoke suite checks both. Found while doing that: `native/runtime.js` says it is generated from `stdlib/runtime_spec.clarity` and must not be edited by hand, but the two have drifted apart; `clarity gen-runtime` rewrites 651 lines of the checked-in file and drops functions it carries. The spec is documentation of the runtime, not its source, until one of them is made the truth. Every capability is verified by compiling the generated C and diffing native output against the interpreter (or, for FFI, against a known-good expected string).
- **C FFI maturity.** `stdlib/ffi.clarity` handles libc-shaped APIs, natural-aligned structs, and Clarity-function callbacks (a real `qsort` comparator round-trips in the test suite). Now also covers **bulk numeric arrays** (`read_array`/`write_array`, `ffi.array`), **nested structs**, and **contiguous struct arrays** (`StructDef.array(n).at(i)` views share the parent buffer) — the array-ownership piece that the `llama.cpp` on-ramp needs for tensor/logit buffers. **Remaining:** fixed-size array *fields* inside structs (`char name[16]`), union layout, and passing structs by value (vs. by pointer). Driven by what real integrations (e.g. `llama.cpp` for the Hearth app in [ROADMAP_OS.md](ROADMAP_OS.md)) actually need.
- **WebAssembly target.** `clarity build --target wasm` → a `.wasm` module plus glue, so Clarity runs in browsers without the JS transpile step. (`wasm-ld` / the LLVM tools are already available in the dev image.)

---

## Out of scope (decided no)

- **Macros / metaprogramming.** Pattern matching + decorators + the AST module cover the cases macros usually solve.
- **Generics with monomorphisation.** Gradual typing + duck-typed runtime covers polymorphism; a static generic system would blow up the type-checker spec.
- **A second syntax.** No "Clarity Lite," no s-expression front-end, no significant-whitespace mode. One syntax, one toolchain.

---

## How to contribute

1. Pick something from **Concrete gaps** or the **v1.1 / v1.2** tails.
2. Write the change in Clarity, in `stdlib/` (or `native/runtime.js` for builtins — mind the drift note above).
3. Add a test in the relevant `test_*.clarity`.
4. `clarity test stdlib/` should stay green.
5. Open a PR. CI runs darwin-arm64 + linux-x64 + linux-arm64.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the developer workflow.
