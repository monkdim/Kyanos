# Clarity: The Complete Beginner's Guide

**From zero to writing real programs — no experience needed.**

---

## Table of Contents

1. [What Is Clarity?](#what-is-clarity)
2. [What Is Programming?](#what-is-programming)
3. [Installing Clarity](#installing-clarity)
4. [Your Very First Program](#your-very-first-program)
5. [The REPL — Your Interactive Playground](#the-repl--your-interactive-playground)
6. [Core Concepts](#core-concepts)
   - [Variables — Storing Information](#variables--storing-information)
   - [Data Types — Kinds of Information](#data-types--kinds-of-information)
   - [Showing Output](#showing-output)
   - [Getting Input](#getting-input)
   - [Comments — Notes to Yourself](#comments--notes-to-yourself)
7. [Math and Operations](#math-and-operations)
8. [Strings — Working with Text](#strings--working-with-text)
9. [Making Decisions (If/Elif/Else)](#making-decisions-ifelifelse)
10. [Loops — Doing Things Repeatedly](#loops--doing-things-repeatedly)
11. [Lists — Collections of Things](#lists--collections-of-things)
12. [Maps — Named Data](#maps--named-data)
13. [Functions — Reusable Blocks of Code](#functions--reusable-blocks-of-code)
14. [Pipes — Chaining Operations](#pipes--chaining-operations)
15. [Pattern Matching](#pattern-matching)
16. [Error Handling](#error-handling)
17. [Classes — Building Your Own Types](#classes--building-your-own-types)
18. [Working with Files](#working-with-files)
19. [Built-in Modules](#built-in-modules)
20. [Built-in Functions Quick Reference](#built-in-functions-quick-reference)
21. [Command Line Reference](#command-line-reference)
22. [Your First Real Project: Contact Book](#your-first-real-project-contact-book)
23. [Common Mistakes and How to Fix Them](#common-mistakes-and-how-to-fix-them)
24. [Where to Go Next](#where-to-go-next)
25. [Glossary](#glossary)

---

## What Is Clarity?

Clarity is a programming language — a way to give instructions to your computer. Think of
it like learning a new language, except instead of talking to people, you're talking to
a machine.

Clarity was designed to be **easy to read and write**, even if you've never programmed
before. Here's a taste:

```
let name = "World"
show "Hello {name}!"
```

That program stores the word "World" in a box called `name`, then prints "Hello World!"
to your screen. That's it. No complicated setup, no confusing symbols.

**Why Clarity?**

- **Readable** — code looks almost like English
- **Simple** — fewer symbols and rules to memorize
- **Powerful** — despite being simple, you can build real things
- **Zero setup headaches** — installs with one command, no extra downloads needed

---

## What Is Programming?

Programming is writing a set of instructions that a computer follows, step by step. It's
like writing a recipe:

1. Get eggs from the fridge
2. Crack two eggs into a bowl
3. Whisk until mixed
4. Pour into a hot pan

A computer follows your "recipe" (your program) exactly as written, from top to bottom.
If you write the steps out of order or forget one, things won't work right — just like
cooking.

**Key idea:** A program is a text file with instructions. You write the instructions, then
tell the computer to run them.

---

## Installing Clarity

> **Heads up — Clarity is early.** A one-click download is on the roadmap, but
> it's not ready yet. For now, installing means **building Clarity from source**.
> It's a handful of commands, laid out step by step below. If you've never used a
> terminal before, that's okay — just copy each command exactly.

### What You Need

- A computer (Windows, Mac, or Linux)
- [Bun](https://bun.sh) — the tool that turns Clarity into a runnable program
- Python 3 — used once, to bootstrap the very first build
- `git` — to download the source code

### Step 1: Open your terminal

- **Windows:** Press `Win + R`, type `cmd`, press Enter
- **Mac:** Press `Cmd + Space`, type "Terminal", press Enter
- **Linux:** Press `Ctrl + Alt + T`

### Step 2: Install Bun

Bun compiles Clarity into a single program. Install it with the one-liner from
[bun.sh](https://bun.sh):

```bash
# Mac / Linux
curl -fsSL https://bun.sh/install | bash

# Windows (PowerShell)
powershell -c "irm bun.sh/install.ps1 | iex"
```

### Step 3: Download and build Clarity

```bash
git clone https://github.com/monkdim/Kyanos.git
cd Clarity
python3 native/transpile.py --bundle
bun build --compile native/dist/clarity-entry.js --outfile clarity
```

That last command produces a `clarity` program in the folder. Move it somewhere on
your `PATH` (e.g. `sudo mv clarity /usr/local/bin/` on Mac/Linux) so you can run it
from anywhere — or just run it as `./clarity` from inside the folder.

### Step 4: Verify it works

```bash
clarity version
```

You should see a version line. You're ready to go.

---

## Your Very First Program

### Step 1: Create a file

Open any text editor (Notepad on Windows, TextEdit on Mac, or any code editor like
VS Code). Create a new file and type:

```
show "Hello, World!"
```

### Step 2: Save the file

Save it as `hello.clarity` somewhere you can find it (like your Desktop or a folder
called `projects`).

**Important:** The file must end with `.clarity`.

### Step 3: Run it

Open your terminal, navigate to where you saved the file, and type:

```bash
clarity run hello.clarity
```

You should see:

```
Hello, World!
```

Congratulations — you just ran your first program!

### What just happened?

- `show` is a command that prints text to the screen
- `"Hello, World!"` is a **string** — a piece of text wrapped in quotes
- Clarity read your file, saw the instruction, and executed it

---

## The REPL — Your Interactive Playground

The REPL (Read-Eval-Print Loop) lets you type Clarity code and see results immediately,
without creating a file. It's perfect for experimenting.

Start it:

```bash
clarity repl
```

You'll see:

```
clarity>
```

Now type things and press Enter:

```
clarity> show "Hello!"
Hello!
clarity> let x = 5 + 3
clarity> show x
8
clarity> show x * 2
16
```

### REPL commands

| Command    | What it does                       |
|------------|------------------------------------|
| `.help`    | Show available commands            |
| `.clear`   | Clear the screen                   |
| `.reset`   | Start fresh (forget all variables) |
| `.env`     | Show all your variables            |
| `.exit`    | Leave the REPL                     |

Use the **up/down arrow keys** to scroll through your previous commands.

To exit the REPL, type `.exit` or press `Ctrl + C`.

---

## Core Concepts

### Variables — Storing Information

A **variable** is a named box that holds a value. You create one with `let`:

```
let age = 25
let name = "Alice"
let pi = 3.14159
```

Now `age` holds `25`, `name` holds `"Alice"`, and `pi` holds `3.14159`.

You can use variables anywhere you'd use the value directly:

```
let price = 10
let quantity = 3
show price * quantity   -- prints 30
```

#### Immutable vs. Mutable

By default, variables **cannot be changed** after creation. This is called **immutable**
(meaning "cannot mutate/change"):

```
let x = 10
x = 20       -- ERROR! Can't change a 'let' variable
```

If you need a variable that CAN change, use `mut` instead of `let`:

```
mut score = 0
score = score + 10   -- OK! 'mut' variables can change
score += 5           -- shorthand for score = score + 5
show score           -- prints 15
```

**Rule of thumb:** Use `let` by default. Only use `mut` when you know the value needs
to change.

### Data Types — Kinds of Information

Every value in Clarity has a **type** — what kind of thing it is:

| Type      | What it is         | Examples                          |
|-----------|--------------------|-----------------------------------|
| `int`     | Whole numbers       | `42`, `0`, `-7`                  |
| `float`   | Decimal numbers     | `3.14`, `0.5`, `-2.7`           |
| `string`  | Text                | `"hello"`, `"Clarity"`, `"123"` |
| `bool`    | True or false       | `true`, `false`                  |
| `list`    | Ordered collection  | `[1, 2, 3]`, `["a", "b"]`      |
| `map`     | Named values        | `{name: "Alice", age: 30}`      |
| `null`    | Nothing / no value  | `null`                           |

You can check a value's type with `type()`:

```
show type(42)        -- "int"
show type("hello")   -- "string"
show type(true)      -- "bool"
show type([1, 2])    -- "list"
```

### Showing Output

`show` prints things to the screen. It can print anything:

```
show "Hello!"            -- text
show 42                  -- a number
show true                -- a boolean
show [1, 2, 3]           -- a list
show "Age:", 25           -- multiple values separated by comma
```

#### String interpolation

You can put variables directly inside text using `{curly braces}`:

```
let name = "Alice"
let age = 30
show "My name is {name} and I am {age} years old"
-- prints: My name is Alice and I am 30 years old
```

You can even put math inside the braces:

```
let x = 10
show "Double is {x * 2}"   -- prints: Double is 20
```

### Getting Input

Use `ask` to get text from the user:

```
let name = ask("What is your name? ")
show "Hello, {name}!"
```

When the program runs, it will wait for the user to type something and press Enter.

Since `ask` always returns text (a string), convert it to a number if needed:

```
let input = ask("Enter a number: ")
let num = int(input)
show "Double: {num * 2}"
```

### Comments — Notes to Yourself

Comments are notes in your code that Clarity ignores. They're for humans reading
the code, not for the computer:

```
-- This is a comment. Clarity ignores this line.

let x = 42  -- comments can go at the end of a line too
```

Comments start with `--` (two dashes). Everything after `--` on that line is ignored.

**Good habit:** Write comments to explain *why* you're doing something, not *what*
you're doing (the code itself shows *what*).

---

## Math and Operations

Clarity supports all the basic math you'd expect:

```
show 10 + 3    -- 13 (addition)
show 10 - 3    -- 7  (subtraction)
show 10 * 3    -- 30 (multiplication)
show 10 / 3    -- 3.333... (division)
show 10 % 3    -- 1  (remainder/modulo — what's left over)
show 2 ** 8    -- 256 (power/exponent — 2 to the 8th)
```

### Order of operations

Just like in regular math, multiplication and division happen before addition and
subtraction. Use parentheses to control the order:

```
show 2 + 3 * 4       -- 14 (3*4 happens first)
show (2 + 3) * 4     -- 20 (2+3 happens first because of parentheses)
```

### Comparison operators

These compare two values and return `true` or `false`:

```
show 5 == 5    -- true  (equal to)
show 5 != 3    -- true  (not equal to)
show 5 > 3     -- true  (greater than)
show 5 < 3     -- false (less than)
show 5 >= 5    -- true  (greater than or equal to)
show 5 <= 3    -- false (less than or equal to)
```

### Logical operators

Combine true/false values:

```
show true and false   -- false (both must be true)
show true or false    -- true  (at least one must be true)
show not true         -- false (flips true to false)
```

### Shorthand operators

When updating a mutable variable:

```
mut x = 10
x += 5     -- same as x = x + 5  (x is now 15)
x -= 3     -- same as x = x - 3  (x is now 12)
x *= 2     -- same as x = x * 2  (x is now 24)
x /= 4     -- same as x = x / 4  (x is now 6)
```

---

## Strings — Working with Text

Strings are text, wrapped in double quotes `"like this"` or single quotes `'like this'`:

```
let greeting = "Hello, World!"
let name = 'Alice'
```

### String interpolation

Put variables and expressions inside strings with `{}`:

```
let item = "coffee"
let price = 4.50
show "One {item} costs ${price}"
-- prints: One coffee costs $4.50
```

### Useful string operations

```
let text = "Hello, Clarity!"

show text.length()              -- 15
show text.upper()               -- "HELLO, CLARITY!"
show text.lower()               -- "hello, clarity!"
show text.contains("Clarity")   -- true
show text.starts("Hello")       -- true
show text.ends("!")             -- true
show text.split(", ")           -- ["Hello", "Clarity!"]

let padded = "  hello  "
show padded.trim()              -- "hello" (removes spaces from edges)

show text.replace("Clarity", "World")  -- "Hello, World!"
```

### Combining strings

```
let first = "Hello"
let second = "World"
show first + " " + second   -- "Hello World"
```

---

## Making Decisions (If/Elif/Else)

Programs often need to make choices. Use `if` to run code only when a condition is true:

```
let age = 20

if age >= 18 {
    show "You are an adult"
}
```

### If/else

Do one thing or another:

```
let temperature = 35

if temperature > 30 {
    show "It's hot outside!"
} else {
    show "It's not too bad."
}
```

### If/elif/else

Check multiple conditions:

```
let score = 85

if score >= 90 {
    show "Grade: A"
} elif score >= 80 {
    show "Grade: B"
} elif score >= 70 {
    show "Grade: C"
} elif score >= 60 {
    show "Grade: D"
} else {
    show "Grade: F"
}
-- prints: Grade: B
```

Clarity checks each condition from top to bottom and runs the **first** one that's true,
then skips the rest.

### If as an expression

You can use `if` to pick a value:

```
let age = 20
let label = if age >= 18 { "adult" } else { "minor" }
show label   -- "adult"
```

---

## Loops — Doing Things Repeatedly

### For loops

Do something for each item in a list:

```
let fruits = ["apple", "banana", "cherry"]

for fruit in fruits {
    show "I like {fruit}"
}
-- prints:
-- I like apple
-- I like banana
-- I like cherry
```

### Counting with ranges

The `..` operator creates a range of numbers:

```
for i in 1..6 {
    show i
}
-- prints: 1, 2, 3, 4, 5
-- note: 6 is NOT included (the range stops before it)
```

You can also use `range()`:

```
for i in range(5) {
    show i
}
-- prints: 0, 1, 2, 3, 4

for i in range(2, 7) {
    show i
}
-- prints: 2, 3, 4, 5, 6
```

### While loops

Keep going as long as a condition is true:

```
mut count = 1

while count <= 5 {
    show "Count: {count}"
    count += 1
}
-- prints Count: 1 through Count: 5
```

**Warning:** If the condition never becomes false, the loop runs forever! Always make
sure something inside the loop changes the condition.

### Break and continue

- `break` — stop the loop immediately
- `continue` — skip to the next iteration

```
-- Print odd numbers, stop at 10
for i in 1..20 {
    if i > 10 { break }        -- stop entirely
    if i % 2 == 0 { continue } -- skip even numbers
    show i
}
-- prints: 1, 3, 5, 7, 9
```

---

## Lists — Collections of Things

A **list** is an ordered collection of values inside square brackets:

```
let colors = ["red", "green", "blue"]
let numbers = [10, 20, 30, 40, 50]
let mixed = [1, "hello", true, 3.14]  -- can mix types
```

### Accessing items

Items are numbered starting from 0 (this is called the **index**):

```
let fruits = ["apple", "banana", "cherry"]
show fruits[0]    -- "apple"  (first item)
show fruits[1]    -- "banana" (second item)
show fruits[2]    -- "cherry" (third item)
```

### Useful list operations

```
let nums = [3, 1, 4, 1, 5]

show len(nums)        -- 5 (how many items)
show sum(nums)        -- 14 (add them all up)
show min(nums)        -- 1 (smallest)
show max(nums)        -- 5 (largest)
show sort(nums)       -- [1, 1, 3, 4, 5]
show reverse(nums)    -- [5, 1, 4, 1, 3]
show unique(nums)     -- [3, 1, 4, 5] (remove duplicates)
```

### Adding and removing items

```
mut fruits = ["apple", "banana"]

push(fruits, "cherry")     -- add to the end
show fruits                -- ["apple", "banana", "cherry"]

let removed = pop(fruits)  -- remove the last item
show removed               -- "cherry"
show fruits                -- ["apple", "banana"]
```

### Searching

```
let names = ["Alice", "Bob", "Charlie", "Diana"]

show contains(names, "Bob")    -- true
show find(names, n => n == "Charlie")  -- "Charlie"
```

### Transforming lists

Three powerful operations you'll use constantly:

```
let numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

-- MAP: transform every item
let doubled = map(numbers, x => x * 2)
show doubled   -- [2, 4, 6, 8, 10, 12, 14, 16, 18, 20]

-- FILTER: keep only items that pass a test
let evens = filter(numbers, x => x % 2 == 0)
show evens   -- [2, 4, 6, 8, 10]

-- REDUCE: combine all items into one value
let total = reduce(numbers, (sum, x) => sum + x, 0)
show total   -- 55
```

**In plain English:**
- `map` = "do this to each item"
- `filter` = "keep only items where this is true"
- `reduce` = "combine everything into one result"

### List comprehensions

A shorthand way to build lists:

```
let squares = [x * x for x in 1..6]
show squares   -- [1, 4, 9, 16, 25]

let evens = [x for x in 1..21 if x % 2 == 0]
show evens   -- [2, 4, 6, 8, 10, 12, 14, 16, 18, 20]
```

---

## Maps — Named Data

A **map** (also called a dictionary or object in other languages) stores data as
name-value pairs:

```
let person = {
    name: "Alice",
    age: 30,
    city: "Austin"
}
```

### Accessing values

```
show person.name    -- "Alice"
show person.age     -- 30
show person.city    -- "Austin"
```

### Useful map operations

```
let person = {name: "Alice", age: 30, city: "Austin"}

show keys(person)      -- ["name", "age", "city"]
show values(person)    -- ["Alice", 30, "Austin"]
show entries(person)   -- [[name, Alice], [age, 30], [city, Austin]]
show len(person)       -- 3
```

### Merging maps

```
let defaults = {color: "blue", size: 10}
let custom = {color: "red", size: 20}
let config = merge(defaults, custom)
show config   -- {color: "red", size: 20}
```

### Nested data

Maps and lists can be nested inside each other:

```
let team = [
    {name: "Alice", role: "engineer"},
    {name: "Bob", role: "designer"},
    {name: "Charlie", role: "manager"}
]

show team[0].name    -- "Alice"
show team[1].role    -- "designer"

for member in team {
    show "{member.name} is a {member.role}"
}
```

---

## Functions — Reusable Blocks of Code

A **function** is a named block of code you can call whenever you need it. Instead of
writing the same code over and over, you write it once in a function and call it by name.

### Defining a function

```
fn greet(name) {
    show "Hello, {name}!"
}

greet("Alice")    -- prints: Hello, Alice!
greet("Bob")      -- prints: Hello, Bob!
```

- `fn` means "I'm defining a function"
- `greet` is the function's name
- `(name)` is the **parameter** — a placeholder for the value you'll pass in
- The code inside `{}` is what runs when you call the function

### Returning values

Functions can give back a result with `return`:

```
fn add(a, b) {
    return a + b
}

let result = add(3, 7)
show result   -- 10
```

### Multiple parameters

```
fn introduce(name, age, city) {
    show "{name} is {age} years old and lives in {city}"
}

introduce("Alice", 30, "Austin")
```

### Functions are values

You can store a function in a variable:

```
let double = fn(x) { return x * 2 }
show double(5)   -- 10
```

### Lambda shorthand

For small, simple functions, use the arrow `=>` syntax:

```
let double = x => x * 2
let add = (a, b) => a + b

show double(5)    -- 10
show add(3, 7)    -- 10
```

### Rest parameters

Collect extra arguments into a list with `...`:

```
fn first(head, ...tail) {
    show "First: {head}"
    show "Rest: {tail}"
}

first(1, 2, 3, 4)
-- prints: First: 1
-- prints: Rest: [2, 3, 4]
```

### Example: building a useful function

```
fn is_even(n) {
    return n % 2 == 0
}

fn fizzbuzz(n) {
    for i in 1..n {
        if i % 15 == 0 {
            show "FizzBuzz"
        } elif i % 3 == 0 {
            show "Fizz"
        } elif i % 5 == 0 {
            show "Buzz"
        } else {
            show i
        }
    }
}

fizzbuzz(16)
```

---

## Pipes — Chaining Operations

The **pipe operator** `|>` is one of Clarity's most powerful features. It takes the
result of one operation and feeds it into the next, like an assembly line.

### Without pipes (hard to read)

```
let result = reverse(sort(filter(numbers, x => x > 5)))
```

You have to read from the inside out — confusing!

### With pipes (easy to read)

```
let result = numbers
    |> filter(x => x > 5)
    |> sort()
    |> reverse()
```

Now you read top to bottom, left to right — much clearer. The data flows through
each step like water through pipes.

### How it works

The `|>` takes whatever is on the left and passes it as the first argument to the
function on the right:

```
-- These two lines do the same thing:
let a = sort(numbers)
let b = numbers |> sort()
```

### Real-world example

```
let people = [
    {name: "Alice", age: 30},
    {name: "Bob", age: 17},
    {name: "Charlie", age: 25},
    {name: "Diana", age: 15},
    {name: "Eve", age: 35}
]

-- Find adult names, sorted
let adults = people
    |> filter(p => p.age >= 18)
    |> map(p => p.name)
    |> sort()

show adults   -- ["Alice", "Charlie", "Eve"]
```

### Number crunching

```
let result = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    |> filter(x => x % 2 == 0)           -- keep evens: [2, 4, 6, 8, 10]
    |> map(x => x * x)                    -- square them: [4, 16, 36, 64, 100]
    |> reduce((sum, x) => sum + x, 0)     -- add up: 220

show result   -- 220
```

---

## Pattern Matching

Pattern matching lets you check a value against multiple possibilities cleanly:

```
fn describe(value) {
    match value {
        when 0 { show "zero" }
        when 1 { show "one" }
        when 2 { show "two" }
        else { show "something else: {value}" }
    }
}

describe(1)    -- prints: one
describe(42)   -- prints: something else: 42
```

### Matching on types

```
fn what_is(x) {
    match type(x) {
        when "int" { show "{x} is a whole number" }
        when "string" { show "{x} is text" }
        when "list" { show "{x} is a list" }
        when "bool" { show "{x} is true/false" }
        else { show "{x} is a {type(x)}" }
    }
}

what_is(42)         -- 42 is a whole number
what_is("hello")    -- hello is text
what_is([1, 2])     -- [1, 2] is a list
```

### Destructuring

Pull values out of lists and maps into individual variables:

```
-- List destructuring
let [first, second, ...rest] = [10, 20, 30, 40, 50]
show first    -- 10
show second   -- 20
show rest     -- [30, 40, 50]

-- Map destructuring
let {name, age} = {name: "Alice", age: 30, city: "NYC"}
show name   -- "Alice"
show age    -- 30
```

### Null safety

Safely handle missing values:

```
let config = {theme: "dark", font_size: 14}

-- Null coalescing: use a default if the value is null
let lang = config?.language ?? "en"
show lang   -- "en" (language wasn't set, so we got the default)

-- Optional chaining: safely access nested values
let theme = config?.theme ?? "light"
show theme   -- "dark"
```

---

## Error Handling

Sometimes things go wrong. Error handling lets your program deal with problems
gracefully instead of crashing:

```
try {
    let result = 10 / 0   -- this will cause an error!
} catch err {
    show "Something went wrong: {err}"
} finally {
    show "This always runs, error or not"
}
```

- `try` — attempt to run this code
- `catch` — if an error happens, run this instead (the error message is in `err`)
- `finally` — (optional) always runs at the end, error or not

### Throwing errors

You can create your own errors with `throw`:

```
fn divide(a, b) {
    if b == 0 {
        throw "Cannot divide by zero!"
    }
    return a / b
}

try {
    show divide(10, 0)
} catch e {
    show "Error: {e}"
}
-- prints: Error: Cannot divide by zero!
```

---

## Classes — Building Your Own Types

A **class** is a blueprint for creating custom data types. Think of it like a cookie
cutter — the class is the cutter, and each cookie you make is an **instance**.

### Your first class

```
class Dog {
    fn init(name, breed) {
        this.name = name
        this.breed = breed
    }

    fn bark() {
        show "{this.name} says: Woof!"
    }

    fn describe() {
        show "{this.name} is a {this.breed}"
    }
}

let myDog = Dog("Rex", "Labrador")
myDog.bark()       -- Rex says: Woof!
myDog.describe()   -- Rex is a Labrador
```

- `fn init(...)` is a special function that runs when you create a new instance
- `this` refers to the current instance

### Inheritance

A class can **inherit** from another class, getting all its abilities plus adding new ones:

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

class Cat < Animal {
    fn init(name) {
        this.name = name
        this.sound = "meow"
    }
    fn purr() {
        show "{this.name} purrs..."
    }
}

let cat = Cat("Whiskers")
cat.speak()   -- Whiskers says meow!
cat.purr()    -- Whiskers purrs...
```

The `<` means "inherits from". `Cat < Animal` means "Cat is a type of Animal."

### Interfaces

An **interface** defines a contract — what methods a class must have:

```
interface Describable {
    fn describe()
}

class Circle impl Describable {
    fn init(radius) {
        this.radius = radius
    }
    fn describe() {
        show "Circle with radius {this.radius}"
    }
}
```

`impl Describable` means "this class promises to have a `describe()` method."

### Enums

**Enums** define a fixed set of named values:

```
enum Color {
    Red = "#FF0000",
    Green = "#00FF00",
    Blue = "#0000FF"
}

show Color.Red       -- "#FF0000"
show Color.names()   -- ["Red", "Green", "Blue"]
```

---

## Working with Files

Clarity can read and write files on your computer:

```
-- Write a file
write("notes.txt", "Hello from Clarity!\nThis is line 2.\n")

-- Read it back
let content = read("notes.txt")
show content

-- Read as a list of lines
let file_lines = lines("notes.txt")
show "Number of lines:", len(file_lines)

for line in file_lines {
    show "  | {line}"
}

-- Append (add to end)
append("notes.txt", "This was added later.\n")

-- Check if a file exists
show exists("notes.txt")    -- true
show exists("nope.txt")     -- false
```

---

## Built-in Modules

Clarity comes with 8 built-in modules you can import:

### math — Math functions

```
import math

show math.sqrt(16)     -- 4.0
show math.pi           -- 3.14159...
show math.sin(0)       -- 0.0
show math.cos(0)       -- 1.0
show math.floor(3.7)   -- 3
show math.ceil(3.2)    -- 4
show math.abs(-5)      -- 5
```

### json — Work with JSON data

```
import json

let data = {name: "Alice", scores: [95, 87, 92]}
let text = json.stringify(data)
show text   -- '{"name": "Alice", "scores": [95, 87, 92]}'

let parsed = json.parse(text)
show parsed.name   -- "Alice"
```

### random — Random numbers

```
import random

show random.int(1, 100)       -- random number from 1 to 100
show random.float(0.0, 1.0)   -- random decimal
show random.choice([1, 2, 3]) -- random item from list
```

### time — Time and delays

```
import time

show time.now()     -- current timestamp
time.sleep(1000)    -- pause for 1 second (1000 milliseconds)
```

### os — Operating system

```
import os

show os.getenv("HOME")   -- your home directory
```

### crypto — Hashing and encoding

```
import crypto

show crypto.sha256("hello")           -- SHA-256 hash
show crypto.md5("hello")              -- MD5 hash
show crypto.base64_encode("hello")    -- base64 encoding
show crypto.base64_decode("aGVsbG8=") -- base64 decoding
```

### regex — Regular expressions

```
import regex

show regex.match(r"^\d+$", "12345")          -- true
show regex.search(r"\d+", "abc 123 def")     -- "123"
show regex.replace(r"\s+", "a  b  c", "-")   -- "a-b-c"
show regex.split(r",\s*", "a, b, c")         -- ["a", "b", "c"]
```

### path — File path operations

```
import path

show path.join("folder", "file.txt")   -- "folder/file.txt"
show path.ext("photo.png")             -- ".png"
show path.basename("/home/user/file.txt")  -- "file.txt"
```

---

## Built-in Functions Quick Reference

Here's every built-in function available without importing anything:

### Output and Input

| Function | What it does | Example |
|----------|-------------|---------|
| `show` | Print to screen | `show "hello"` |
| `ask(prompt)` | Get text from user | `let name = ask("Name? ")` |

### Type Conversion

| Function | What it does | Example |
|----------|-------------|---------|
| `str(x)` | Convert to text | `str(42)` → `"42"` |
| `int(x)` | Convert to whole number | `int("42")` → `42` |
| `float(x)` | Convert to decimal | `float("3.14")` → `3.14` |
| `bool(x)` | Convert to true/false | `bool(0)` → `false` |
| `type(x)` | Get the type name | `type(42)` → `"int"` |

### Collections

| Function | What it does | Example |
|----------|-------------|---------|
| `len(x)` | Count items | `len([1,2,3])` → `3` |
| `push(list, item)` | Add to end | `push(fruits, "pear")` |
| `pop(list)` | Remove from end | `pop(fruits)` |
| `sort(list)` | Sort items | `sort([3,1,2])` → `[1,2,3]` |
| `reverse(list)` | Reverse order | `reverse([1,2,3])` → `[3,2,1]` |
| `unique(list)` | Remove duplicates | `unique([1,1,2])` → `[1,2]` |
| `flat(list)` | Flatten nested lists | `flat([[1,2],[3]])` → `[1,2,3]` |
| `contains(x, item)` | Check if item exists | `contains([1,2], 2)` → `true` |
| `range(n)` | Numbers 0 to n-1 | `range(5)` → `[0,1,2,3,4]` |
| `range(a, b)` | Numbers a to b-1 | `range(2,5)` → `[2,3,4]` |

### Functional (transform data)

| Function | What it does | Example |
|----------|-------------|---------|
| `map(list, fn)` | Transform each item | `map([1,2,3], x => x*2)` → `[2,4,6]` |
| `filter(list, fn)` | Keep matching items | `filter([1,2,3,4], x => x>2)` → `[3,4]` |
| `reduce(list, fn, init)` | Combine into one | `reduce([1,2,3], (a,b) => a+b, 0)` → `6` |
| `each(list, fn)` | Do something per item | `each(names, n => show n)` |
| `find(list, fn)` | First matching item | `find([1,2,3], x => x>1)` → `2` |
| `every(list, fn)` | All match? | `every([2,4,6], x => x%2==0)` → `true` |
| `some(list, fn)` | Any match? | `some([1,2,3], x => x>2)` → `true` |

### Map (dictionary) operations

| Function | What it does | Example |
|----------|-------------|---------|
| `keys(map)` | Get all keys | `keys({a:1, b:2})` → `["a","b"]` |
| `values(map)` | Get all values | `values({a:1, b:2})` → `[1, 2]` |
| `entries(map)` | Get key-value pairs | `entries({a:1})` → `[["a",1]]` |
| `merge(m1, m2)` | Combine maps | `merge({a:1}, {b:2})` |

### String operations

| Function | What it does | Example |
|----------|-------------|---------|
| `upper(s)` | UPPERCASE | `upper("hi")` → `"HI"` |
| `lower(s)` | lowercase | `lower("HI")` → `"hi"` |
| `trim(s)` | Remove whitespace | `trim("  hi  ")` → `"hi"` |
| `replace(s, a, b)` | Replace text | `replace("hi", "hi", "bye")` → `"bye"` |
| `split(s, sep)` | Split into list | `split("a,b,c", ",")` → `["a","b","c"]` |
| `join(list, sep)` | Join into string | `join(["a","b"], "-")` → `"a-b"` |

### Math

| Function | What it does | Example |
|----------|-------------|---------|
| `abs(n)` | Absolute value | `abs(-5)` → `5` |
| `round(n)` | Round to nearest | `round(3.7)` → `4` |
| `floor(n)` | Round down | `floor(3.7)` → `3` |
| `ceil(n)` | Round up | `ceil(3.2)` → `4` |
| `sqrt(n)` | Square root | `sqrt(16)` → `4` |
| `min(list)` | Smallest value | `min([3,1,2])` → `1` |
| `max(list)` | Largest value | `max([3,1,2])` → `3` |
| `sum(list)` | Add all values | `sum([1,2,3])` → `6` |

### File operations

| Function | What it does | Example |
|----------|-------------|---------|
| `read(path)` | Read entire file | `let text = read("file.txt")` |
| `write(path, data)` | Write to file | `write("file.txt", "hello")` |
| `append(path, data)` | Add to end of file | `append("log.txt", "new line\n")` |
| `lines(path)` | Read as list of lines | `let rows = lines("data.csv")` |
| `exists(path)` | Check if file exists | `exists("config.txt")` → `true` |

---

## Command Line Reference

Every way to use the `clarity` command:

| Command | What it does |
|---------|-------------|
| `clarity run file.clarity` | Run a program |
| `clarity repl` | Start interactive mode |
| `clarity check file.clarity` | Check for syntax errors without running |
| `clarity compile file.clarity` | Show the compiled bytecode (advanced) |
| `clarity tokens file.clarity` | Show how the lexer reads your code (debug) |
| `clarity ast file.clarity` | Show the parse tree (debug) |
| `clarity init` | Create a new project (makes `clarity.toml`) |
| `clarity install` | Install project dependencies |
| `clarity lsp` | Start the language server for editor integration |
| `clarity help` | Show help |
| `clarity version` | Show version |

---

## Your First Real Project: Contact Book

Let's put it all together and build something real — a simple contact book that
stores names and phone numbers.

Create a file called `contacts.clarity`:

```
-- contacts.clarity — A simple contact book

mut contacts = []

fn add_contact(name, phone) {
    push(contacts, {name: name, phone: phone})
    show "Added {name}!"
}

fn find_contact(search_name) {
    let result = find(contacts, c => c.name == search_name)
    if result != null {
        show "Found: {result.name} — {result.phone}"
    } else {
        show "No contact named '{search_name}'"
    }
}

fn list_contacts() {
    if len(contacts) == 0 {
        show "No contacts yet."
        return null
    }
    show "--- Contact Book ({len(contacts)} contacts) ---"
    for c in contacts {
        show "  {c.name}: {c.phone}"
    }
    show "---"
}

fn remove_contact(name) {
    let before = len(contacts)
    contacts = filter(contacts, c => c.name != name)
    if len(contacts) < before {
        show "Removed {name}"
    } else {
        show "No contact named '{name}'"
    }
}

-- Build our contact book
add_contact("Alice", "555-0101")
add_contact("Bob", "555-0102")
add_contact("Charlie", "555-0103")

list_contacts()

show ""
find_contact("Bob")

show ""
remove_contact("Bob")
list_contacts()
```

Run it:

```bash
clarity run contacts.clarity
```

Output:

```
Added Alice!
Added Bob!
Added Charlie!
--- Contact Book (3 contacts) ---
  Alice: 555-0101
  Bob: 555-0102
  Charlie: 555-0103
---

Found: Bob — 555-0102

Removed Bob
--- Contact Book (2 contacts) ---
  Alice: 555-0101
  Charlie: 555-0103
---
```

### What you just learned by building this

- **Variables** (`mut contacts = []`)
- **Functions** (`fn add_contact(...)`)
- **Lists** and list operations (`push`, `filter`, `find`)
- **Maps** (`{name: name, phone: phone}`)
- **If/else** decisions
- **For loops**
- **String interpolation** (`"Found: {result.name}"`)

---

## Common Mistakes and How to Fix Them

### 1. Trying to change a `let` variable

```
let x = 10
x = 20   -- ERROR!
```

**Fix:** Use `mut` if the value needs to change:

```
mut x = 10
x = 20   -- OK
```

### 2. Forgetting curly braces

```
if x > 5
    show "big"    -- ERROR! Missing braces
```

**Fix:** Always use `{ }` around code blocks:

```
if x > 5 {
    show "big"
}
```

### 3. Off-by-one with ranges

```
for i in 1..5 {
    show i
}
-- prints 1, 2, 3, 4 (NOT 5!)
```

The end of a range is **exclusive** (not included). If you want 1 through 5:

```
for i in 1..6 {
    show i
}
-- prints 1, 2, 3, 4, 5
```

### 4. List indexes start at 0

```
let fruits = ["apple", "banana", "cherry"]
show fruits[1]   -- "banana" (NOT "apple")
show fruits[0]   -- "apple" (first item is index 0)
```

### 5. Forgetting to convert input to numbers

```
let n = ask("Number: ")
show n + 1   -- ERROR or unexpected result (n is a string)
```

**Fix:** Convert with `int()` or `float()`:

```
let n = int(ask("Number: "))
show n + 1   -- correct
```

### 6. Infinite while loop

```
mut x = 0
while x < 10 {
    show x
    -- forgot to increment x! This runs forever.
}
```

**Fix:** Make sure the condition can eventually become false:

```
mut x = 0
while x < 10 {
    show x
    x += 1    -- now x eventually reaches 10 and the loop stops
}
```

---

## Where to Go Next

Now that you know the basics, here are ideas to keep learning:

### Practice projects (easiest to hardest)

1. **Number Guessing Game** — generate a random number and let the user guess
2. **Calculator** — ask for two numbers and an operation, show the result
3. **To-Do List** — add, list, and remove tasks
4. **Word Counter** — read a file and count how many times each word appears
5. **Quiz App** — ask multiple choice questions and keep score
6. **Simple Web Server** — use `serve()` to build a tiny website

### Explore the examples

Clarity comes with example programs in the `examples/` folder:

| File | What it shows |
|------|--------------|
| `hello.clarity` | Variables, lists, loops, functions |
| `functions.clarity` | Functions, closures, recursion, pipes |
| `control_flow.clarity` | If/elif/else, for, while, break/continue, try/catch |
| `data.clarity` | Maps, lists, strings, data transformation |
| `pipes_and_lambdas.clarity` | Pipe operator, lambdas, comprehensions |
| `patterns.clarity` | Pattern matching, destructuring, null safety |
| `classes.clarity` | Classes, inheritance, interfaces, enums |
| `types.clarity` | Type annotations, interfaces, raw strings |
| `async_generators.clarity` | Async/await, generators, decorators |
| `fileio.clarity` | Reading, writing, and processing files |
| `web_server.clarity` | A simple HTTP web server |

Run any of them with:

```bash
clarity run examples/hello.clarity
```

### Read the full README

The project README (`README.md`) contains the complete language reference with every
feature documented.

---

## Glossary

| Term | Definition |
|------|-----------|
| **Variable** | A named container that holds a value (`let x = 10`) |
| **Immutable** | Cannot be changed after creation (`let`) |
| **Mutable** | Can be changed after creation (`mut`) |
| **String** | A piece of text (`"hello"`) |
| **Integer (int)** | A whole number (`42`) |
| **Float** | A decimal number (`3.14`) |
| **Boolean (bool)** | A true/false value (`true`, `false`) |
| **List** | An ordered collection of values (`[1, 2, 3]`) |
| **Map** | A collection of name-value pairs (`{name: "Alice"}`) |
| **Function** | A reusable block of code (`fn greet(name) { ... }`) |
| **Parameter** | A variable in a function definition (`name` in `fn greet(name)`) |
| **Argument** | The value you pass when calling a function (`"Alice"` in `greet("Alice")`) |
| **Return** | Give a result back from a function (`return 42`) |
| **Loop** | Code that repeats (`for`, `while`) |
| **Condition** | A true/false test (`x > 5`) |
| **Index** | The position of an item in a list (starts at 0) |
| **Lambda** | A short anonymous function (`x => x * 2`) |
| **Pipe** | The `\|>` operator that chains operations together |
| **Class** | A blueprint for creating custom data types |
| **Instance** | An object created from a class |
| **Inheritance** | A class getting abilities from a parent class (`Dog < Animal`) |
| **Interface** | A contract specifying what methods a class must have |
| **Enum** | A fixed set of named values |
| **Module** | A package of related functions you can import (`import math`) |
| **REPL** | Read-Eval-Print Loop — an interactive coding environment |
| **Syntax** | The rules for how code must be written |
| **Runtime error** | An error that happens when the program runs |
| **Null** | A special value meaning "nothing" or "no value" |

---

*Happy coding!*
