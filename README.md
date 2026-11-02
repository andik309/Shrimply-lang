# Shrimply

...insert the description of any new C replacement here...

It doesn't work yet, of course. I'm still working on it, and maybe someday it will greet the world.

## Building from source

Requires Zig 0.16.

## Slightly weird syntax

- Postfix operators:

  ```
  some_pointer.*                   // pointer dereference
  some_optional.?                  // optional unwrap
  some_error_union.!               // error unwrap
  some_function.(...args...)       // function call
  some_function.#(...args...)      // subst intrinsic call
  some_array.[index]               // array/slice indexing
  some_type.{ ...field_values... } // type initialization
  ```

  (I'm not sure about the `catch` and `orelse` operators, maybe they will be something like `some_error.!|err|(...body...)` and `some_optional.?(...body...)`)

- Other operators:

  ```
  Zig                 -> Shrimply

  !operand            -> ~operand (! on a bool does the same as ~ on a u1)
  operand and operand -> operand and operand, operand & operand (see below for why they differ)
  operand or operand  -> operand or operand, operand | operand (see below)
  n/a                 -> n/a, operand ^ operand (don't see below, there is only one variant)
  ```

  [About weird boolean operators](#bools-and-boolean-operators)

- Mutability (~~stolen~~ mostly copied from Rust):

  ```
  []u8                        // Zig: []const u8
  []mut u8                    // Zig: []u8
  let some_constant = 10;     // Zig: const some_constant = 10;
  let mut some_variable = 10; // Zig: var some_variable = 10;
  ```

- Functions and function types:

  ```
  function:      func(param_name1 param_ty1, param_name2 param_ty2, ...; return_ty) ...body...
  // Zig:        fn anonymous(param_name1: param_ty1, param_name2: param_ty2, ...) return_ty { ...body... }

  function type: fn(param_ty1, param_ty2, ...; return_ty)
  // Zig:        fn(param_ty1, param_ty2, ...) return_ty

  // if the return type is omitted, it defaults to void
  ```

  ```
  func(new_value i32) some_static_variable = new_value
  func(new_value i32) { some_static_variable = new_value; }
  // they behave the same way
  ```

## Builtins and intrinsics

- `#some_intrinsic`: a compile-time-only instruction that can't be recreated using ordinary code.\
  Requires its own IR instruction and usually has its own syntax.
- `@some_builtin`: a real object that is defined in ordinary code (usually it lives in the `@builtin` namespace)

Intrinsic examples:

```
#switch(value) {...branches...} // regular switch but evaluated at compile time
#if(condition) ...body... #else ...body... // #else is optional, but if the condition is false this statement returns a void value
#intern(value) // returns a pointer to a statically stored value, equal values share one pointer, value must be compile-time-known
#eval ...body... // evaluates body at compile time
#subst(param_name1 param_ty1, param_name2 param_ty2, ...) ...body...
// substitutes parameters into the body and evaluates it,
// each distinct set of parameters is evaluated only once and the result is cached
```

Builtin examples:

```
bool = @builtin.bool_ = u1;
void = @builtin.void_ = u0;

usize = @builtin.usize_ = #switch(@builtin.target.arch) { ... };
isize = @builtin.isize_ = #switch(@builtin.target.arch) { ... };
@span = @builtin.span_ = struct { begin: ?usize, end: ?usize };

@slice(T) = struct { ptr: [*]T, len: usize };
@mut_slice(T) = struct { ptr: [*]mut T, len: usize };
@slice_aligned(T, Align) = struct { ptr: [*]align(Align) T, len: usize };
@mut_slice_aligned(T, Align) = struct { ptr: [*]align(Align) mut T, len: usize };
```

## Compile time

> [!NOTE]
> In the code it is currently called "inline-time", because I originally planned that all needed evaluations would happen only in the inliner stage. I will rename it to "compile-time" in the future.

The period between the start and the end of the compilation process (only the inliner and optimizer stages can evaluate expressions).

There are some major restrictions compared to runtime (applies only to the inliner stage):

- Static values can't be modified, even mutable ones, because if modifications were allowed, the order of evaluation could matter.
- Pointers are forbidden, but you can use [references](#references).

## Bools and boolean operators

Bools are mentioned in [Builtins and intrinsics](#builtins-and-intrinsics) and they are the reason for some of the [slightly weird syntax](#slightly-weird-syntax) of boolean operators.

Under the hood, `bool` is basically `u1` (just to avoid creating another type for it).

There are two variants of the AND and OR operators: the ones that use a word (`and`, `or`) are lazy, and the ones that use symbols (`&`, `|`) are non-lazy.\
`&` and `|` are just bitwise operators that work on any integer type, including `u1`, so they are non-lazy.

## References

A reference is a type modifier, not a type, so you can't have a reference to a reference.

References are heavily restricted pointers (at compile time the restrictions are much softer).

Accessing a declared value by its name yields a reference to it (its mutability depends on the mutability of the storage).

- At runtime:\
  References exist for two things: assignment, and taking a pointer to a local or static variable. In all other cases the reference is dropped, so they can't be returned, stored, or passed as arguments, and they can't escape the block they were created or obtained in.

- At compile time:\
  References are dropped only when necessary, so they can be returned, stored, or passed as arguments, and they can escape the block they were created or obtained in. But if the value lives shorter than the reference to it, the compiler reports an error.

```
(*SomeType).*           -> #ref SomeType
(*mut SomeType).*       -> #mutref SomeType

([]SomeType)[usize]     -> #ref SomeType
([]mut SomeType)[usize] -> #mutref SomeType
```

### Inheritance of type modifiers

`#ref` and `#mutref` show that it's a reference and not a plain value.

```
(SomeType).member                  -> MemberType
(#ref SomeType).member             -> #ref MemberType
(#mutref SomeType).member          -> #mutref MemberType

#Unref(#ref SomeType)              -> SomeType              // removes #ref and #mutref from type
#unref(instanceOf(#ref SomeType))  -> instanceOf(SomeType)  // removes #ref and #mutref from value

(*SomeType).*                      -> #ref SomeType
&((*SomeType).*)                   -> *SomeType

&(instanceOf(*SomeType).*)         -> instanceOf(*SomeType) // no stack allocation
&(#unref(instanceOf(*SomeType).*)) -> instanceOf(*SomeType) // stack allocation
```

(`&SomeType` returns a value of type `#type` and not a value of type `*const #type`, because pointers are forbidden at compile time)

## Compilation process

There are 9 stages in the compilation process:

1. Lexer:\
   source code -> tokens

2. Parser:\
   tokens -> AST

3. Lowerer:\
   Flattens the AST into a linear sequence of instructions. The only thing it computes is character literals: it converts them to integers (e.g. `'W'` becomes `87`), which also validates them. There is no `char` instruction in IR.

4. Inliner:\
   Inlines all intrinsics (except `#as`). Discards unused values and functions that are never called. Evaluates things that can't be evaluated at runtime. Most checks are done at this stage.

   (In the code this is the first stage, because it runs the lexer, parser, and lowerer for every used file.)

5. Restricter:\
   Restricts IR and produces RIR (restricted IR). Uses values evaluated by the inliner stage. It doesn't check function bodies, it just gives types to every instruction (because they are already checked).

   Example:

   ```
   0: call 1 with (2, 3)
   1: get "some_func"
   2: int_literal 128
   3: int_literal 20
   ...
   ```

   becomes:

   ```
   0: int u8 128
   1: int u8 20
   2: call &1234 (0, 1) // global function index
   ...
   ```

6. Optimizer (optional):\
   Performs constant folding and optimizes the bodies of all functions, as well as calls of functions with the auto calling convention.

   This stage has two modes:

   - Compile-time errors:\
     when it finds an error (e.g. an integer value that doesn't fit its type), it reports a compile error.
   - Runtime errors:\
     when it finds an error, it inserts a runtime error at that place.

7. Codegen:\
   Converts RIR to LLVM IR (when I write my own backend, I'll switch to it).

8. LLVM (in the future: my own backend and its stages)

9. Linking

## Inspiration

- [Zig](https://ziglang.org): most of Shrimply
- [Rust](https://www.rust-lang.org): mutability

# AI usage

There is no code written by AI, but some names (roughly 5%) were chosen by AI. English is not my first language, but I need to understand what every part of the code does, so I need good names for variables and types. AI also checked the English in this README.

If you want to contribute to this project, please don't use AI to write code.