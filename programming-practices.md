# Swift Programming Best Practices — Reference Guide

> Sources: [Swift API Design Guidelines (Apple)](https://www.swift.org/documentation/api-design-guidelines/) · [Google Swift Style Guide](https://google.github.io/swift/)

This document distils the most important rules from authoritative Swift style and API design references. Rules are grouped by concern.

---

## 1. Fundamentals

- **Clarity at the point of use** is the primary goal. APIs are declared once but read many times.
- Clarity is more important than brevity. Short code is a side-effect of good design, not a target.
- Write a `///` documentation comment for every `public` and `open` declaration.
- If you struggle to describe your API in simple terms, the design is probably wrong.

---

## 2. Naming

### 2.1 General conventions

- Types and protocols → `UpperCamelCase`
- Everything else (functions, variables, constants, enum cases) → `lowerCamelCase`
- Acronyms that appear as ALL-CAPS in English are uniformly cased: `urlRequest`, `httpMethod`, `userSMTPServer`
- No Hungarian notation (`kConstant`, `gGlobal`) — global constants are `lowerCamelCase`

### 2.2 Promote clear usage

- Include all words needed to avoid ambiguity: `remove(at: index)` not `remove(index)`
- Omit words that merely repeat type information: `remove(_ member: Element)` not `removeElement(_ member: Element)`
- Name variables by their **role**, not their type: `var greeting` not `var string`
- Precede weakly-typed parameters with a noun describing their role: `addObserver(_:forKeyPath:)` not `add(_:for:)`

### 2.3 Strive for fluent usage

- Method names should form grammatical English phrases at the call site:
  - `x.insert(y, at: z)` — reads "insert y at z"
  - `x.sort()` / `z = x.sorted()` — verb imperative for mutating; past participle for nonmutating
- Factory methods start with `make`: `makeIterator()`
- Boolean properties/methods read as assertions: `isEmpty`, `intersects(_:)`

### 2.4 Protocols

- Protocols describing *what something is* → noun: `Collection`, `Iterator`
- Protocols describing *capability* → `…able` / `…ible` / `…ing` suffix: `Equatable`, `Sendable`, `ProgressReporting`

### 2.5 Argument labels

- Omit labels when arguments are not usefully distinguishable: `min(x, y)`
- Omit the first label for value-preserving type conversions: `Int64(someUInt32)`
- When the first argument is a prepositional phrase, use that preposition as the label: `x.removeBoxes(havingLength: 12)`

---

## 3. Source File Structure

- One primary type per file; file name matches the type name.
- Extensions adding protocol conformance: `MyType+MyProtocol.swift`
- Import only what you need; import whole modules, not individual declarations.
- Import order (lexicographic within groups, one blank line between groups):
  1. Module imports
  2. Individual declaration imports (`func`, `struct`, etc.)
  3. `@testable` imports (test files only)
- Use `// MARK: - Section Name` to divide logical sections within a type.

---

## 4. Formatting

| Rule | Value |
|------|-------|
| Column limit | 100 characters |
| Indentation | 2 spaces (no tabs) |
| Semicolons | Never |
| Braces | K&R style — opening brace on same line |
| Trailing commas | Required in multi-line array/dict literals |

### 4.1 Line wrapping

- If an expression fits on one line, keep it on one line.
- Comma-delimited lists are either all-horizontal or all-vertical (one element per line).
- Continuation lines indented +2 from the original line.

### 4.2 Key formatting rules

```swift
// ✅ Parentheses omitted around top-level condition
if x == 0 { ... }

// ✅ switch cases at same indent level as switch
switch order {
case .ascending:
    print("Ascending")
}

// ✅ Trailing closure syntax when single closure argument
let squares = [1, 2, 3].map { $0 * $0 }

// ✅ Trailing commas in multi-line literals
let keys = [
    "bufferSize",
    "encoding",   // trailing comma required
]
```

---

## 5. Types and Declarations

### 5.1 Shorthand types

Always use shorthand: `[Int]`, `[String: Int]`, `Int?` — never `Array<Int>`, `Dictionary<String, Int>`, `Optional<Int>`.

Return type `Void` in closures; omit `-> Void` in `func` declarations.

### 5.2 Properties

Omit the `get` block for read-only computed properties:
```swift
// ✅
var totalCost: Int { items.reduce(0) { $0 + $1.cost } }
```

### 5.3 Nesting and namespacing

Nest related types inside their owning type (error enums, sub-types).

Use a caseless `enum` — not a `struct` with `private init()` — to create a namespace:
```swift
enum AppConstants {
    static let maxRetries = 3
}
```

### 5.4 Access levels

- Specify access level on each member, not on an extension as a whole.
- Prefer `private`/`fileprivate` for information hiding over underscore prefixes.

---

## 6. Control Flow

### 6.1 Use `guard` for early exits

`guard` removes nesting and keeps the happy path flush-left:
```swift
// ✅
guard let value = optionalValue else { return }
// main logic here, not nested
```

### 6.2 `for-where` instead of `if` inside a loop

```swift
// ✅
for item in collection where item.isActive { process(item) }
```

### 6.3 `switch` / `fallthrough`

Combine cases into comma-delimited lists or ranges instead of chaining `fallthrough`.

---

## 7. Optionals and Error Handling

### 7.1 Optionals

- Use `Optional` for expected "no value" outcomes (e.g. element not found).
- Use `if value != nil` when only testing presence, not binding.
- Never use sentinel values (−1, empty string) where `Optional` communicates intent more clearly.
- Implicitly unwrapped optionals (`!`) only for IBOutlets and properties set before first use (`viewDidLoad`).

### 7.2 Force unwrap / force cast

Strongly avoid. When unavoidable, add an inline comment explaining the invariant:
```swift
// Safe: rawValue comes from a controlled data source that only emits valid cases.
return SomeEnum(rawValue: value)!
```

### 7.3 Error types

Use `throws` + `do-catch` for multiple distinct failure states. Use `Optional` for single, obvious failure (e.g. `Int(_:)`). Avoid `try!` in production except for programmer-error-only initialisation of literals.

---

## 8. Documentation Comments

Use triple-slash `///` exclusively (no `/** */` block comments).

```swift
/// Returns the sum of the numbers in the given array.
///
/// - Parameter numbers: The numbers to sum.
/// - Returns: The sum of the numbers.
func sum(_ numbers: [Int]) -> Int { ... }
```

- Summary: single sentence fragment, ends with a period.
- Use `- Parameter(s):`, `- Returns:`, `- Throws:` tags in that order.
- Document every `open` and `public` declaration.
- Do not document what is already obvious from the declaration.

---

## 9. Programming Practices

| Rule | Notes |
|------|-------|
| No compiler warnings | Fix or suppress with an explanation |
| Prefer standard arithmetic operators | Use masking `&+` only for intentional overflow (crypto, hash) |
| No custom operators unless domain-established | Prefer readable function calls |
| Overload operators only when semantically equivalent | `==` for `Equatable`, arithmetic for `Matrix` |
| One `let`/`var` per statement | Exception: tuple destructuring |
| Prefer `enum` for namespacing | Caseless `enum` over `struct` with private init |

---

## 10. Swift-Specific Patterns

### 10.1 Concurrency

- Prefer `async/await` over completion handlers for all new network code.
- Apply `@MainActor` to view-models and any type that exclusively touches the main thread.
- Mark types that cross actor boundaries as `Sendable`.

### 10.2 `ObservableObject` / `@Observable`

- Keep `@Observable` / `@MainActor` view-models free of Foundation-only logic.
- Never use `DispatchQueue` in new code — use `Task` and structured concurrency.

### 10.3 Dependency injection

- Pass dependencies through `init` parameters, not singletons.
- Type dependencies as protocols, not concrete types (see DIP in [solid-principles.md](solid-principles.md)).

---

## Further Reading

- [Swift API Design Guidelines — Apple](https://www.swift.org/documentation/api-design-guidelines/)
- [Google Swift Style Guide](https://google.github.io/swift/)
- [swift-format — Apple](https://github.com/apple/swift-format)
- [SOLID Principles](solid-principles.md)
