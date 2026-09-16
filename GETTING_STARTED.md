# Getting Started with Clarity & KyanOS

This is the practical reference: how to install, write your first program, learn the language, and use the toolchain. If you're looking for the pitch — what Clarity and KyanOS are and why they exist — see the [README](README.md).

## Table of Contents

- [Install Clarity](#install-clarity)
- [Boot KyanOS](#boot-kyanos)
- [Your first Clarity program](#your-first-clarity-program)
- [The CLI](#the-cli)
- [Language tour](#language-tour)
- [Built-in functions](#built-in-functions)
- [Developer tools](#developer-tools)
- [Self-hosting](#self-hosting)
- [Native binary](#native-binary)
- [Project structure](#project-structure)
- [Running tests](#running-tests)

---

## Install Clarity

### Prebuilt binary

One line on macOS or Linux (x64 or ARM64):

```bash
curl -fsSL https://raw.githubusercontent.com/monkdim/Clarity/main/install.sh | bash
```

With Homebrew, from the formula in this repository:

```bash
brew tap monkdim/clarity https://github.com/monkdim/Clarity
brew install monkdim/clarity/clarity
```

Or pick a binary from the [latest release](https://github.com/monkdim/Clarity/releases/latest);
Windows x64 is there as a zip. Check it with `clarity version` and `clarity smoke`.

### Build from source

Requires [Bun](https://bun.sh) (plus Python 3 and `git` for the first bootstrap build):

```bash
curl -fsSL https://bun.sh/install | bash        # install Bun
git clone https://github.com/monkdim/Clarity.git
cd Clarity
python3 native/transpile.py --bundle             # bootstrap the toolchain
bun build --compile native/dist/clarity-entry.js --outfile clarity
```

This produces a `clarity` binary in the repo root. Move it onto your `PATH`
(e.g. `sudo mv clarity /usr/local/bin/`) so the `clarity` command is available
globally.

Once you already have a working `clarity`, you can rebuild and reinstall it in one
step:

```bash
clarity build --install
```

---

## Boot KyanOS

KyanOS is the operating system written in Clarity. The developer workflow targets QEMU; real-hardware boot is a goal, not yet a verified claim. Expect rough edges — the boot-to-desktop path is still stabilizing.

### macOS (with Homebrew)

```bash
brew install qemu zig
git clone https://github.com/monkdim/Clarity.git
cd Clarity
clarity os build       # Build the kernel + freestanding runtime + ISO
clarity os run         # Launch in QEMU with HVF acceleration
```

The first launch boots into the void-black KyanOS splash, fades into the Obsidian desktop (dark glass, signature violet→cyan edge), and pre-pins terminal / files / editor / calc / viewer / monitor to the dock. Theme picker is in **Settings → Appearance** — Obsidian and Quartz are the two Kyan modes; the spring themes (Meadow / Bloom / Watercolor / Midnight) remain as legacy options.

### Linux

```bash
sudo apt install qemu-system-x86 ovmf zig    # Debian / Ubuntu
# or: sudo dnf install qemu-system-x86 edk2-ovmf zig    # Fedora
# or: sudo pacman -S qemu-base edk2-ovmf zig            # Arch
clarity os build && clarity os run
```

The Linux launcher uses KVM when `/dev/kvm` is readable; otherwise it falls back to TCG (slower but functional). UEFI boot is enabled when distro-installed OVMF is found; otherwise it boots BIOS.

### Just want the ISO?

```bash
clarity os build           # Produces dist/claritos.iso (~240 MB)
```

Burn it to a USB stick with Etcher, or boot it in any VM that supports BIOS or UEFI.

### Headless boot test

```bash
clarity os run --headless --boot-test "KyanOS ready."
```

Boots without a graphical window, captures the serial output, and exits successfully when the kernel emits the marker (or non-zero on timeout). Useful for CI.

---

## Your first Clarity program

Create a file called `hello.clarity`:

```
let name = "Clarity"
show "Hello from {name}!"

let nums = [1, 2, 3, 4, 5]
let squares = nums |> map(x => x * x)
show "Squares: {squares}"

fn greet(person) {
    show "Hey {person}, welcome!"
}
greet("Developer")
```

Run it:

```bash
clarity run hello.clarity
```

Or launch the interactive shell:

```bash
clarity shell
```

---

## The CLI

```
clarity run <file>              Run a Clarity program (--fast for bytecode VM)
clarity shell                   Interactive terminal (Clarity + shell commands)
clarity repl                    Basic interactive REPL
clarity check <file>            Check syntax (--types for static type checking)
clarity lint <file|dir>         Lint for common issues
clarity fmt <file|dir>          Format code (--check, --write)
clarity test [dir]              Run test files (test_*.clarity)
clarity debug <file>            Interactive step-through debugger
clarity profile <file>          Profile execution (timing, hotspots, call graph)
clarity doc <file|dir>          Generate docs (--md, --json, -o <file>)
clarity compile <file>          Show bytecode disassembly
clarity tokens <file>           Show lexer output
clarity ast <file>              Show parse tree
clarity init                    Create a new clarity.toml
clarity install                 Install dependencies from clarity.toml
clarity install <pkg>           Add and install a package
clarity publish                 Pack and publish to registry
clarity search <query>          Search the package registry
clarity info <pkg>              Show package info from registry
clarity transpile <file>        Transpile to JavaScript (-o, --bundle)
clarity build                   Build native binary (--all, --target, --install)
clarity smoke                   Run smoke tests on the binary
clarity gen-runtime             Regenerate native/runtime.js from spec
clarity install-self            Install Clarity from source
clarity bench                   Run performance benchmarks
clarity lsp                     Start language server (for editors)
clarity os build                Build the KyanOS kernel + runtime + ISO
clarity os run                  Boot KyanOS in QEMU (HVF on macOS, KVM on Linux)
clarity os iso                  Alias for `os build`
clarity os install              Write ISO to USB stick (manual `dd` for now)
```

---

## Language tour

### Variables

```
let x = 42          -- immutable (default)
mut counter = 0     -- mutable (opt-in)
counter += 1

-- Type annotations (runtime checked)
let name: string = "Alice"
let age: int = 30
```

### Functions

```
fn add(a, b) {
    return a + b
}

-- Lambda shorthand
let double = x => x * 2
let multiply = (a, b) => a * b

-- Rest parameters
fn first(head, ...tail) {
    return head
}

-- Typed functions
fn divide(a: float, b: float) -> float {
    return a / b
}
```

### Pipes

The pipe operator `|>` passes the result as the first argument to the next function:

```
let result = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    |> filter(x => x % 2 == 0)
    |> map(x => x * x)
    |> reduce((a, b) => a + b, 0)
show result  -- 220
```

### Control flow

```
if age >= 18 {
    show "adult"
} elif age >= 13 {
    show "teen"
} else {
    show "child"
}

-- If expressions (ternary)
let label = if age >= 18 { "adult" } else { "minor" }

-- For loops
for item in [1, 2, 3] {
    show item
}
for i in 0..10 {
    show i
}

-- While loops
mut n = 10
while n > 0 {
    n -= 1
}
```

### Pattern matching

```
fn describe(value) {
    match value {
        when 0 { show "zero" }
        when 1 { show "one" }
        when "hello" { show "greeting" }
        else { show "something else: {value}" }
    }
}
```

### Classes & inheritance

```
class Animal {
    fn init(name, sound) {
        this.name = name
        this.sound = sound
    }
    fn speak() {
        show "{this.name} says {this.sound}!"
    }
}

class Dog < Animal {
    fn init(name) {
        this.name = name
        this.sound = "woof"
    }
    fn fetch(item) {
        show "{this.name} fetches the {item}"
    }
}

let dog = Dog("Rex")
dog.speak()       -- Rex says woof!
dog.fetch("ball") -- Rex fetches the ball
```

### Interfaces

```
interface Drawable {
    fn draw()
    fn area() -> float
}

class Circle impl Drawable {
    fn init(r) { this.r = r }
    fn draw() { show "Drawing circle r={this.r}" }
    fn area() { return 3.14159 * this.r * this.r }
}
```

### Enums

```
enum Color { Red, Green, Blue }
show Color.Red     -- 0
show Color.names() -- ["Red", "Green", "Blue"]

enum Status {
    OK = 200
    NotFound = 404
    Error = 500
}
```

### Destructuring & spread

```
let [first, second, ...rest] = [1, 2, 3, 4, 5]
let {name, age} = {name: "Alice", age: 30}

let merged = [...list1, ...list2]
let combined = {...map1, ...map2}
```

### Async / await

```
async fn fetch_data() {
    return 42
}

let result = await fetch_data()
show result
```

### Generators

```
fn fibonacci() {
    mut a = 0
    mut b = 1
    for i in 0..10 {
        yield a
        a, b = b, a + b
    }
}

let fibs = fibonacci()
show fibs  -- [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]
```

### Comprehensions

```
let squares = [x * x for x in 0..10 if x > 3]
let lengths = {name: len(name) for name in ["alice", "bob", "charlie"]}
```

### Error handling

```
try {
    let result = risky_operation()
} catch e {
    show "Error: {e}"
} finally {
    show "Cleanup done"
}

throw "something went wrong"
```

### Decorators

```
fn log(wrapped) {
    return fn(...args) {
        show "calling function"
        let result = wrapped(...args)
        show "done"
        return result
    }
}

@log
fn add(a, b) {
    return a + b
}
```

### Modules

```
import math
show math.sqrt(16)

from math import sqrt, pi
show sqrt(2)

import "utils.clarity"              -- file import
from "helpers" import process_data  -- named import
```

**Built-in modules:** math, json, os, path, random, time, crypto, regex.

### Null safety

```
let value = maybe_null ?? "default"   -- null coalescing
let name = user?.profile?.name        -- optional chaining
```

### Raw strings

```
let path = r"C:\Users\test\new"    -- no escape processing
let regex = r"^\d{3}-\d{4}$"      -- no escape processing
```

---

## Built-in functions

| Function | Description |
|----------|-------------|
| `show` | Print values |
| `len(x)` | Length of string, list, or map |
| `type(x)` | Get type name |
| `str(x)`, `int(x)`, `float(x)`, `bool(x)` | Type conversion |
| `range(n)`, `range(start, end)` | Number sequences |
| `map(list, fn)`, `filter(list, fn)`, `reduce(list, fn, init)` | Collection transforms |
| `sort(list)`, `reverse(list)`, `unique(list)`, `flat(list)` | List operations |
| `push(list, item)`, `pop(list)` | List mutation |
| `keys(map)`, `values(map)`, `entries(map)` | Map access |
| `join(list, sep)`, `split(str, sep)` | String operations |
| `upper(s)`, `lower(s)`, `trim(s)`, `replace(s, a, b)` | String transforms |
| `abs(n)`, `round(n)`, `floor(n)`, `ceil(n)`, `sqrt(n)` | Math |
| `min(list)`, `max(list)`, `sum(list)` | Aggregation |
| `read(path)`, `write(path, data)` | File I/O |
| `ask(prompt)` | Read user input |
| `exit(code)` | Exit with status code |

---

## Developer tools

### Debugger

Interactive step-through debugging with breakpoints, variable inspection, and watch expressions:

```bash
clarity debug app.clarity
```

**Commands:** `step`, `next`, `finish`, `continue`, `break <line>`, `print <expr>`, `eval <code>`, `vars`, `backtrace`, `watch <expr>`, `list`, `help`.

### Profiler

Measure function timing, call counts, and identify hot lines:

```bash
clarity profile app.clarity
```

Outputs a full report with function profile (sorted by time), hot lines with coloured heat bars, and a call graph showing caller / callee relationships.

### Documentation generator

Extract docs from source comments and type annotations:

```bash
clarity doc stdlib/                   # Terminal output
clarity doc stdlib/ --md -o docs.md   # Markdown file
clarity doc stdlib/ --json            # JSON output
```

Supports `--` and `//` doc comments preceding functions, classes, enums, interfaces, and constants.

### Type checker

Static type analysis without running your code:

```bash
clarity check app.clarity --types
```

Infers types from literals, expressions, and 70+ built-in return types. Validates type annotations on variables, function parameters, and return types.

### Linter

Catch common issues with 7 built-in rules:

```bash
clarity lint src/
```

**Rules:** unused variables (W001), mutable-never-reassigned (W002), redeclaration (W003), shadowing (W004), constant conditions (W005), null comparison style (W006), unreachable code (W007).

### Formatter

Consistent code formatting:

```bash
clarity fmt src/ --check    # Check without modifying
clarity fmt src/ --write    # Format in-place
```

### Test runner

Discovers and runs `test_*.clarity` files:

```bash
clarity test              # Run all tests in current directory
clarity test tests/       # Run tests in specific directory
```

### Watch mode

Auto-reload on file changes:

```bash
clarity run app.clarity --watch
```

### Bytecode compiler

Clarity includes a stack-based bytecode compiler and VM with 56 opcodes:

```bash
clarity compile program.clarity
```

### Language server (LSP)

For editor integration (VS Code, etc.):

```bash
clarity lsp
```

Provides real-time diagnostics, hover info for 30+ builtins, and code completion via JSON-RPC 2.0.

### Package manager

```bash
clarity init                         # Create clarity.toml
clarity install                      # Install dependencies
clarity install mylib --path ./libs  # Add local dependency
```

---

## Self-hosting

Clarity is fully self-hosted. The entire toolchain has been rewritten in Clarity:

| Component | File | Description |
|-----------|------|-------------|
| Lexer | `stdlib/lexer.clarity` | Tokenizer — can tokenize its own source |
| Token types | `stdlib/tokens.clarity` | All token types and keywords |
| AST | `stdlib/ast_nodes.clarity` | 49 AST node types |
| Parser | `stdlib/parser.clarity` | Full recursive descent parser |
| Interpreter | `stdlib/interpreter.clarity` | Tree-walking interpreter with full dispatch |
| Runtime | `stdlib/runtime.clarity` | Module system (math, json, os, time) |
| Bytecode | `stdlib/bytecode.clarity` | 58-opcode compiler + stack VM |
| CLI | `stdlib/cli.clarity` | Full command dispatcher (25+ commands) |
| LSP | `stdlib/lsp.clarity` | JSON-RPC language server |
| Package Manager | `stdlib/package.clarity` | TOML parser, dependency management |
| Registry | `stdlib/registry.clarity` | Package registry server |
| Shell | `stdlib/shell.clarity` | Pipe / redirect tokenizer and parser |
| REPL | `stdlib/repl.clarity` | Interactive shell with auto-detect |
| Terminal UI | `stdlib/terminal.clarity` | Colours, cursor control, box drawing |
| Process | `stdlib/process.clarity` | Process execution, PATH, environment |
| Transpiler | `stdlib/transpile.clarity` | Self-hosted Clarity-to-JS transpiler |
| Build | `stdlib/build.clarity` | Self-hosted build pipeline |
| Installer | `stdlib/install.clarity` | Self-hosted installer |

The native binary runs the self-hosted toolchain directly — no Python dependency required.

KyanOS extends this further: the desktop environment, default apps, theme system, ISO packer, QEMU launcher, and release pipeline are all written in Clarity. The kernel is the only Zig component, and even the freestanding userspace runtime (QuickJS host) talks to it through Clarity-defined syscall stubs.

---

## Native binary

Clarity can compile to a standalone native binary with zero Python dependency.

### Building on macOS

```bash
# Install Bun (if not already installed)
curl -fsSL https://bun.sh/install | bash

# Clone and build
git clone https://github.com/monkdim/Clarity.git
cd Clarity/native
bash build.sh

# The binary is in native/dist/
./dist/clarity run ../examples/hello.clarity
```

### Building on Linux

```bash
curl -fsSL https://bun.sh/install | bash
cd Clarity/native
bash build.sh
./dist/clarity run ../examples/hello.clarity
```

### Cross-platform builds

```bash
# Build for all platforms
bash build.sh --all

# Build for a specific target
bash build.sh --target darwin-arm64    # macOS Apple Silicon
bash build.sh --target darwin-x64      # macOS Intel
bash build.sh --target linux-x64       # Linux x64
bash build.sh --target linux-arm64     # Linux ARM64
bash build.sh --target windows-x64     # Windows x64
```

### How it works

1. `native/transpile.py` transpiles all Clarity source to JavaScript.
2. `native/runtime.js` provides the JS runtime shim (I/O, types, collections).
3. Bun compiles the bundled JS to a single native executable.

### Verify the binary

```bash
clarity smoke
```

---

## Project structure

```
Clarity/
  stdlib/                   # The language + KyanOS — 100% Clarity
    lexer.clarity           # Tokenizer
    parser.clarity          # Recursive descent parser
    ast_nodes.clarity       # 49 AST node types
    tokens.clarity          # Token type definitions
    interpreter.clarity     # Tree-walking interpreter
    runtime.clarity         # Module system (math, json, os, time)
    bytecode.clarity        # Bytecode compiler + stack VM
    cli.clarity             # CLI dispatcher
    formatter.clarity       # AST pretty-printer
    linter.clarity          # 7-rule linter
    type_checker.clarity    # Static type checker
    debugger.clarity        # Interactive step-through debugger
    profiler.clarity        # Execution profiler
    docgen.clarity          # Documentation generator
    package.clarity         # Package manager + TOML parser
    registry.clarity        # Package registry server
    lsp.clarity             # Language server (JSON-RPC 2.0)
    shell.clarity           # Pipe / redirect tokenizer and parser
    repl.clarity            # Interactive shell with auto-detect
    terminal.clarity        # Terminal UI (colours, cursor, box drawing)
    process.clarity         # Process execution, PATH, environment
    transpile.clarity       # Self-hosted Clarity-to-JS transpiler
    build.clarity           # Self-hosted build pipeline
    install.clarity         # Self-hosted installer
    runtime_spec.clarity    # Runtime.js spec (single source of truth)
    runtime_gen.clarity     # JS codegen from runtime spec

    -- KyanOS userspace --
    graphics.clarity        # Framebuffer + 2D drawing primitives
    draw.clarity            # Higher-level shapes
    font.clarity            # Bitmap font + text measurement
    input.clarity           # Keyboard / mouse / touch event pipeline
    window.clarity          # Window manager + workspaces
    compositor.clarity      # Damage-tracking compositor
    chrome.clarity          # Window chrome + traffic lights
    ui.clarity              # UI toolkit (buttons, menus, lists, …)
    widgets.clarity         # Higher-level widget library
    layout.clarity          # CSS-like layout engine
    desktop_session.clarity # Login + session management
    display_server.clarity  # Surface allocation + present
    statusbar.clarity       # Top status bar
    dock.clarity            # Bottom dock
    launcher.clarity        # App launcher
    settings.clarity        # System Settings panel
    notify.clarity          # Notification centre
    theme.clarity           # Theme protocol
    theme_meadow.clarity    # Meadow / Bloom / Watercolor light themes
    theme_aurora.clarity    # Midnight (former flagship dark theme)
    theme_registry.clarity  # 4-theme switcher with persistence
    theme_picker.clarity    # Settings → Appearance pane
    wallpapers_spring.clarity   # Asymmetric meadow / bloom / watercolor wallpapers
    branding_modern.clarity     # Drop+Leaf logo, app icon recipes
    boot_splash_modern.clarity  # Asymmetric boot splash

    -- KyanOS apps --
    app_terminal.clarity, app_files.clarity, app_editor.clarity,
    app_calc.clarity, app_viewer.clarity, app_monitor.clarity,
    app_store.clarity, app_manifest.clarity, app_sandbox.clarity,
    browser.clarity, mail.clarity, chat.clarity, ide.clarity,
    docs_app.clarity, playground_app.clarity

    -- KyanOS infrastructure --
    perf_profiler.clarity   # Boot / frame / memory profiles + release gate
    crash_recovery.clarity  # Journal + watchdog + crash dialog
    iso9660.clarity         # Pure-Clarity ISO9660 packer
    qemu_macos.clarity      # QEMU launcher with HVF
    os_build.clarity        # OS image builder library (kernel + runtime → ISO)
    qemu.clarity            # Cross-platform QEMU launcher (macOS HVF / Linux KVM)
    release.clarity         # Release pipeline (validate → gate → publish)
    website_gen.clarity     # KyanOS website generator
    branding.clarity        # Brand tokens (typography, spacing, radius)

    test_*.clarity          # Test suites (50 files, ~2,750 assertions)

  kernel/                   # Zig micro-kernel (multiboot2, x86_64 long mode)
    boot.zig, kernel.zig, paging.zig, gdt.zig, idt.zig,
    syscall.zig, sched.zig, multiboot.zig, …

  runtime/freestanding/     # QuickJS userspace runtime (vendored)

  native/                   # Build tooling (Python bootstrap)
    transpile.py            # Clarity-to-JavaScript transpiler
    parser.py, lexer.py, ast_nodes.py, tokens.py, errors.py
    runtime.js              # Auto-generated JS runtime shim

  examples/                 # Example programs
  editors/                  # Editor integrations (VS Code, TextMate, Linguist)
  registry/                 # Package registry (Dockerfile + compose)
  website/                  # Clarity-powered website + screenshots
  playground/               # Web playground
  docs/                     # HTML documentation
  Formula/                  # Homebrew formula
  .github/workflows/        # CI / CD
  install.sh                # Installation script
  ROADMAP_OS.md             # KyanOS roadmap (Phases 56-76)
  GAPS.md                   # Language development history (Phases 24-48)
  CONTRIBUTING.md           # Contribution guidelines
```

---

## Running tests

```bash
# Run all tests
clarity test stdlib/

# Run specific test suites
clarity run stdlib/test_features.clarity
clarity run stdlib/test_type_checker_full.clarity
clarity run stdlib/test_linter_full.clarity
clarity run stdlib/test_debugger_full.clarity
clarity run stdlib/test_profiler_full.clarity
clarity run stdlib/test_docgen_full.clarity
clarity run stdlib/test_shell.clarity

# KyanOS tests
clarity run stdlib/test_polish.clarity         # Phase 75 — perf, crash, release
clarity run stdlib/test_spring_refresh.clarity # Phase 76 — themes, branding, picker

# Smoke tests (verify the binary)
clarity smoke

# Performance benchmarks (interpreter vs bytecode)
clarity bench
```

**~2,750 self-hosted assertions across 50 test files**, all written in Clarity.

---

## License

GPL-3.0 — see [LICENSE](LICENSE) for details.
