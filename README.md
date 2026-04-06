# Inspex

**Parse, don't validate.** `conform/2` returns a *shaped* value on success — coercions applied, data restructured — not just `true`. Specs are composable structs, not modules. Write a spec once; use it to validate, generate test data, check function signatures, and produce typespecs.

[![Hex.pm](https://img.shields.io/hexpm/v/inspex.svg)](https://hex.pm/packages/inspex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/inspex)

---

## Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Primitives](#primitives)
- [Named Constraints](#named-constraints)
- [Combinators](#combinators)
- [Schemas](#schemas)
- [Registry](#registry)
- [Coercion](#coercion)
- [Generators](#generators)
- [Function Signatures](#function-signatures)
- [Typespec Bridge](#typespec-bridge)
- [Testing](#testing)
- [Compared to Alternatives](#compared-to-alternatives)
- [AI Agent Reference](#ai-agent-reference)

---

## Installation

```elixir
# mix.exs
def deps do
  [
    {:inspex, "~> 0.1"}
  ]
end
```

inspex runs a registry under its own supervision tree — no configuration needed; it starts automatically with your application.

---

## Quick Start

```elixir
import Inspex

user = schema(%{
  required(:name)  => string(:filled?),
  required(:email) => string(:filled?, format: ~r/@/),
  required(:age)   => integer(gte?: 18),
  optional(:role)  => atom(in?: [:admin, :user, :guest])
})

Inspex.conform(user, %{name: "Mark", email: "mark@x.com", age: 33})
#=> {:ok, %{name: "Mark", email: "mark@x.com", age: 33}}

Inspex.conform(user, %{name: "", age: 15})
#=> {:error, [
#=>   %Inspex.Error{path: [:name],  message: "must be filled"},
#=>   %Inspex.Error{path: [:email], message: "key :email must be present"},
#=>   %Inspex.Error{path: [:age],   message: "must be >= 18"}
#=> ]}
```

**Three entry points:**

| Function | Returns |
|----------|---------|
| `Inspex.conform(spec, value)` | `{:ok, shaped_value}` or `{:error, [Error.t()]}` |
| `Inspex.valid?(spec, value)` | `boolean()` |
| `Inspex.explain(spec, value)` | `ExplainResult.t()` with a formatted string |

```elixir
result = Inspex.explain(user, %{name: "", age: 15})
result.valid?     #=> false
IO.puts result.formatted
# :name: must be filled
# :email: key :email must be present
# :age: must be >= 18
```

---

## Primitives

```elixir
import Inspex

string()     # any binary
integer()    # any integer
float()      # any float
number()     # integer or float
boolean()    # true or false
atom()       # any atom
map()        # any map
list()       # any list
any()        # any value — always conforms
nil_spec()   # nil only
```

---

## Named Constraints

Named constraints are introspectable (the generator can read them) and composable.

```elixir
# String constraints
string(:filled?)                          # non-empty
string(min_length: 3)                     # byte length >= 3
string(max_length: 50)                    # byte length <= 50
string(size?: 5)                          # byte length == 5
string(format: ~r/^\d{4}$/)              # regex match
string(:filled?, format: ~r/@/)           # shorthand atom + keyword list

# Integer constraints
integer(gt?: 0)                           # > 0
integer(gte?: 0)                          # >= 0  (→ non_neg_integer() in typespec)
integer(gt?: 0, lte?: 100)               # 1 to 100
integer(gte?: 1, lte?: 100)              # → 1..100 in typespec
integer(in?: [1, 2, 3])                  # membership

# Float constraints
float(gt?: 0.0)
float(gte?: 0.0, lte?: 1.0)

# Atom constraints
atom(in?: [:admin, :user, :guest])       # → :admin | :user | :guest in typespec
```

---

## Combinators

### `all_of/1` — intersection

All specs must conform. The **output** of each is the **input** to the next — enabling lightweight transformation pipelines.

```elixir
all_of([integer(), spec(&(&1 > 0))])             # positive integer
all_of([string(), string(:filled?)])             # non-empty string
all_of([
  coerce(integer(), from: :string),              # coerce string → integer
  spec(&(rem(&1, 2) == 0))                       # then check even
])
```

### `any_of/1` — union

Tries specs in order, returns the first success.

```elixir
any_of([integer(), string()])    # accepts integer or string
any_of([nil_spec(), integer()])  # nullable integer (prefer maybe/1)
```

### `not_spec/1` — complement

```elixir
all_of([string(), not_spec(string(:filled?))])   # empty string only
```

### `maybe/1` — nullable

`nil` passes unconditionally. Non-nil values are validated against the inner spec.

```elixir
maybe(string(:filled?))      # nil or non-empty string
maybe(integer(gte?: 0))      # nil or non-negative integer
maybe(ref(:address))         # nil or a valid address schema
```

### `list_of/1` — typed list

Validates every element. Errors **accumulate across all elements** — no short-circuiting.

```elixir
list_of(integer(gte?: 0))
# [1, 2, 3]    → {:ok, [1, 2, 3]}
# [1, -1, 3]   → {:error, [%Error{path: [1], message: "must be >= 0"}]}
# [1, -1, -2]  → {:error, [errors at index 1 and index 2]}
```

### `cond_spec/2-3` — conditional branching

Applies one branch based on a predicate. Unlike `any_of`, makes a decision then conforms exactly one branch.

```elixir
# Physical orders need a shipping address; digital orders don't
cond_spec(
  fn order -> order.type == :physical end,
  ref(:address_schema),
  nil_spec()
)

# else_spec defaults to any() if omitted
cond_spec(&is_binary/1, string(:filled?))
```

### `spec/1` — arbitrary predicate

For cases named constraints can't express. Opaque to the generator — supply `:gen` explicitly if needed.

```elixir
spec(&is_integer/1)                                           # guard function
spec(&(&1 > 0))                                               # capture
spec(fn n -> rem(n, 2) == 0 end)                             # anonymous function
spec(is_integer() and &(&1 > 0))                             # guard + capture shorthand
spec(&is_integer/1, gen: StreamData.integer(1..1000))        # with explicit generator
```

### `coerce/2` — coercion wrapper

See [Coercion](#coercion) for the full reference. Coercions are combinators — they compose freely.

```elixir
coerce(integer(gte?: 0), from: :string)    # parse then validate
maybe(coerce(integer(), from: :string))    # nil passes; string coerces
list_of(coerce(integer(), from: :string))  # coerce every element
```

---

## Schemas

### `schema/1` — closed map

Extra keys not declared in the schema are rejected. Errors **accumulate across all keys** in one pass.

```elixir
user_schema = schema(%{
  required(:name)    => string(:filled?),
  required(:email)   => string(:filled?, format: ~r/@/),
  required(:age)     => integer(gte?: 0),
  optional(:role)    => atom(in?: [:admin, :user]),
  optional(:address) => schema(%{
    required(:street) => string(:filled?),
    required(:zip)    => string(size?: 5)
  })
})

Inspex.conform(user_schema, %{
  name: "Mark",
  email: "mark@x.com",
  age: 33,
  address: %{street: "1 Main St", zip: "22701"}
})
#=> {:ok, %{name: "Mark", email: "mark@x.com", age: 33,
#=>         address: %{street: "1 Main St", zip: "22701"}}}
```

### `open_schema/1` — extra keys pass through

```elixir
base = open_schema(%{required(:id) => integer(gt?: 0)})

Inspex.conform(base, %{id: 1, extra: "anything"})
#=> {:ok, %{id: 1, extra: "anything"}}
```

### `ref/1` — lazy registry reference

Resolved at conform-time, not build-time. Enables circular schemas.

```elixir
defspec :tree_node, schema(%{
  required(:value)    => integer(),
  optional(:children) => list_of(ref(:tree_node))   # circular — works fine
})

Inspex.conform(ref(:tree_node), %{
  value: 1,
  children: [
    %{value: 2, children: []},
    %{value: 3}
  ]
})
#=> {:ok, %{value: 1, children: [%{value: 2, children: []}, %{value: 3}]}}
```

---

## Registry

### `defspec` — globally named spec

```elixir
defmodule MyApp.Specs do
  import Inspex

  defspec :email,    string(:filled?, format: ~r/@/)
  defspec :username, string(:filled?, min_length: 3, max_length: 32)
  defspec :age,      integer(gte?: 0, lte?: 150)
  defspec :role,     atom(in?: [:admin, :user, :guest])
end
```

Reference with `ref/1` from anywhere in the codebase:

```elixir
schema(%{
  required(:email)    => ref(:email),
  required(:username) => ref(:username),
  required(:age)      => ref(:age),
  optional(:role)     => ref(:role)
})
```

### `defschema` — named validator functions

Generates `name/1` → `{:ok, shaped} | {:error, errors}` and `name!/1` → shaped value or raises `ConformError`.

```elixir
defmodule MyApp.Schemas do
  import Inspex

  defschema :user do
    schema(%{
      required(:name)  => string(:filled?),
      required(:email) => ref(:email),
      required(:age)   => integer(gte?: 18),
      optional(:role)  => atom(in?: [:admin, :user])
    })
  end

  defschema :create_params do
    schema(%{
      required(:email)    => coerce(ref(:email),    from: :string),
      required(:age)      => coerce(integer(gte?: 18), from: :string),
      optional(:username) => coerce(ref(:username), from: :string)
    })
  end
end

MyApp.Schemas.user(%{name: "Mark", email: "m@x.com", age: 33})
#=> {:ok, %{name: "Mark", email: "m@x.com", age: 33}}

MyApp.Schemas.user!(%{name: "", age: 15})
#=> raises Inspex.ConformError
```

---

## Coercion

`coerce/2` wraps a spec with a pre-processing step.

**Pipeline:** `raw value → coerce → type check → constraints → {:ok, coerced value}`

Coercion failure produces `%Error{predicate: :coerce}` and skips downstream checks.

### Custom function

```elixir
coerce(integer(), fn
  v when is_binary(v) ->
    case Integer.parse(String.trim(v)) do
      {n, ""} -> {:ok, n}
      _       -> {:error, "not a valid integer string: #{inspect(v)}"}
    end
  v when is_integer(v) -> {:ok, v}
  v -> {:error, "cannot coerce #{inspect(v)} to integer"}
end)
```

### Built-in shorthand — `from: source_type`

All built-in coercions are **idempotent** — already-correct values pass through unchanged.

```elixir
coerce(integer(),  from: :string)   # "42"   → 42      (trims whitespace)
coerce(float(),    from: :string)   # "3.14" → 3.14    (integers pass as floats)
coerce(boolean(),  from: :string)   # "true" → true    (yes/1/on also work)
coerce(atom(),     from: :string)   # "ok"   → :ok     (existing atoms only — safe)
coerce(float(),    from: :integer)  # 42     → 42.0
coerce(string(),   from: :integer)  # 42     → "42"
coerce(boolean(),  from: :integer)  # 0      → false, 1 → true (others fail)
coerce(string(),   from: :atom)     # :ok    → "ok"
coerce(integer(),  from: :float)    # 3.7    → 3       (truncates toward zero)
coerce(string(),   from: :float)    # 3.14   → "3.14"
```

### User-extensible coercion registry

Register at application startup. User coercions take **precedence over built-ins** for the same `{source, target}` pair.

```elixir
# In Application.start/2 or a @on_load:
Inspex.Coercions.register({:decimal, :float}, fn
  %Decimal{} = d  -> {:ok, Decimal.to_float(d)}
  v when is_float(v) -> {:ok, v}
  v -> {:error, "cannot coerce #{inspect(v)} to float"}
end)

# Then anywhere in your app:
coerce(float(gt?: 0.0), from: :decimal)
```

`:persistent_term` backs the registry — reads are free, writes trigger a GC pass. Register once at startup, not in hot paths.

### Composition patterns

```elixir
# Nullable coercion
maybe(coerce(integer(gte?: 0), from: :string))
# nil → {:ok, nil}  |  "42" → {:ok, 42}  |  "-5" → {:error, gte? failure}

# HTTP params / form data schema
http_params = schema(%{
  required(:age)    => coerce(integer(gte?: 18), from: :string),
  required(:active) => coerce(boolean(),          from: :string),
  required(:score)  => coerce(float(gt?: 0.0),   from: :string),
  optional(:role)   => coerce(atom(in?: [:admin, :user]), from: :string)
})

Inspex.conform(http_params, %{age: "25", active: "true", score: "9.5", role: "admin"})
#=> {:ok, %{age: 25, active: true, score: 9.5, role: :admin}}

# Coercion in list_of — every element is coerced
list_of(coerce(integer(), from: :string))
# ["1", "2", "3"] → {:ok, [1, 2, 3]}
```

---

## Generators

`gen/1` infers a `StreamData` generator from any spec. Available in `:dev` and `:test` — zero overhead in `:prod`.

```elixir
import Inspex

gen(string(:filled?))                        # non-empty strings
gen(integer(gte?: 0, lte?: 100))            # integers 0–100
gen(atom(in?: [:admin, :user]))             # :admin or :user
gen(maybe(integer()))                        # nil | integer
gen(list_of(string(:filled?)))              # list of non-empty strings
gen(any_of([integer(), string()]))          # integer | string
gen(schema(%{
  required(:name) => string(:filled?),
  required(:age)  => integer(gte?: 0)
}))                                          # map matching the schema
```

Use with `ExUnitProperties`:

```elixir
defmodule MyApp.SpecTest do
  use ExUnitProperties
  import Inspex

  property "conform is idempotent for valid values" do
    spec = schema(%{
      required(:email) => string(:filled?, format: ~r/@/),
      required(:age)   => integer(gte?: 0, lte?: 150)
    })

    check all value <- gen(spec) do
      {:ok, shaped} = Inspex.conform(spec, value)
      assert Inspex.conform(spec, shaped) == {:ok, shaped}
    end
  end
end
```

Custom generator for opaque specs — supply `:gen` explicitly:

```elixir
even = spec(&(rem(&1, 2) == 0), gen: StreamData.map(StreamData.integer(), &(&1 * 2)))
gen(even)   # generates even integers
```

---

## Function Signatures

`use Inspex.Signature` enables runtime validation in `:dev` and `:test`. **Zero overhead in `:prod`** — the macro compiles the wrappers away entirely.

### Basic usage

```elixir
defmodule MyApp.Users do
  use Inspex.Signature

  signature args: [string(:filled?), integer(gte?: 18)],
            ret:  boolean()
  def register(email, age) do
    # impl — receives validated arguments
    true
  end
end

MyApp.Users.register("mark@x.com", 33)   #=> true
MyApp.Users.register("", 33)             #=> raises SignatureError
MyApp.Users.register("mark@x.com", 15)  #=> raises SignatureError
```

### Options

| Key | Validates |
|-----|-----------|
| `:args` | List of specs, one per argument, positional |
| `:ret`  | Return value |
| `:fn`   | `{coerced_args_list, return_value}` — input/output relationships |

```elixir
# :fn — return must be >= first argument
signature args: [integer(), integer()],
          ret:  integer(),
          fn:   spec(fn {[a, _b], ret} -> ret >= a end)
def add(a, b), do: a + b
```

### Multi-clause functions

Declare `signature` once, before the **first** clause only.

```elixir
signature args: [integer()], ret: integer()
def factorial(0), do: 1
def factorial(n) when n > 0, do: n * factorial(n - 1)
```

### Coercion threading

When `:args` specs include coercions, **the coerced values are forwarded to the impl** — not the originals.

```elixir
signature args: [coerce(integer(gte?: 0), from: :string)],
          ret:  string()
def double(n), do: Integer.to_string(n * 2)

MyApp.double("5")    #=> "10"   — impl receives integer 5, not string "5"
MyApp.double(5)      #=> "10"   — already integer, passes through
MyApp.double("bad")  #=> raises SignatureError
```

### Path errors

**All failing arguments are collected in one raise.** Nested schema field failures include the full path down to the failing field.

```elixir
signature args: [schema(%{
                  required(:email) => string(:filled?, format: ~r/@/),
                  required(:name)  => string(:filled?)
                })],
          ret: boolean()
def create(params), do: true

MyApp.create(%{email: "bad", name: ""})
# raises Inspex.SignatureError:
#   MyApp.create/1 argument error:
#     argument[0][:email]: format must match ~r/@/
#     argument[0][:name]: must be filled

# SignatureError.errors contains:
# [
#   %Inspex.Error{path: [{:arg, 0}, :email], message: "format must match ~r/@/"},
#   %Inspex.Error{path: [{:arg, 0}, :name],  message: "must be filled"}
# ]
```

---

## Typespec Bridge

Converts inspex specs to quoted Elixir typespec AST. Bridges runtime validation and the compile-time type system — specs become the single source of truth for both.

### `to_typespec/1`

```elixir
import Inspex
alias Macro

Macro.to_string(Inspex.to_typespec(integer(gte?: 0)))            #=> "non_neg_integer()"
Macro.to_string(Inspex.to_typespec(integer(gt?: 0)))             #=> "pos_integer()"
Macro.to_string(Inspex.to_typespec(integer(gte?: 1, lte?: 100))) #=> "1..100"
Macro.to_string(Inspex.to_typespec(atom(in?: [:a, :b])))         #=> ":a | :b"
Macro.to_string(Inspex.to_typespec(maybe(string())))             #=> "String.t() | nil"
Macro.to_string(Inspex.to_typespec(list_of(integer())))          #=> "[integer()]"
Macro.to_string(Inspex.to_typespec(ref(:email)))                 #=> "email()"
Macro.to_string(Inspex.to_typespec(any_of([string(), integer()]))) #=> "String.t() | integer()"

Macro.to_string(Inspex.to_typespec(schema(%{
  required(:name) => string(),
  optional(:age)  => integer(gte?: 0)
})))
#=> "%{required(:name) => String.t(), optional(:age) => non_neg_integer()}"
```

### Fidelity table

| Inspex spec | Elixir typespec | Fidelity |
|-------------|-----------------|----------|
| `string()` | `String.t()` | exact |
| `integer(gte?: 0)` | `non_neg_integer()` | exact |
| `integer(gt?: 0)` | `pos_integer()` | exact |
| `integer(gte?: a, lte?: b)` | `a..b` | exact |
| `integer(in?: [1, 2, 3])` | `1 \| 2 \| 3` | exact |
| `atom(in?: [:a, :b])` | `:a \| :b` | exact |
| `float()` / `number()` / `boolean()` / `atom()` | same | exact |
| `nil_spec()` | `nil` | exact |
| `maybe(s)` | `T \| nil` | exact |
| `list_of(s)` | `[T]` | exact |
| `any_of([s1, s2])` | `T1 \| T2` | exact |
| `ref(:name)` | `name()` | exact |
| `schema(%{...})` / `open_schema` | `%{required(:k) => T, ...}` | exact |
| `string(:filled?)` | `String.t()` | lossy — constraint elided |
| `all_of([s1, s2])` | first typed spec's type | lossy — intersection unsupported |
| `cond_spec(f, s1, s2)` | `T1 \| T2` | lossy — predicate elided |
| `not_spec(s)` | `term()` | inexpressible |
| `coerce(s, ...)` | target type only | lossy — input type omitted |

### `typespec_lossiness/1`

```elixir
Inspex.typespec_lossiness(string(:filled?))
#=> [{:constraint_not_expressible, "filled?: true has no typespec equivalent"}]

Inspex.typespec_lossiness(not_spec(integer()))
#=> [{:negation_not_expressible, "not_spec has no typespec equivalent; term() used"}]

Inspex.typespec_lossiness(integer(gte?: 0, lte?: 100))
#=> []   # lossless
```

### `@type` generation

`defspec` and `defschema` accept `type: true` to auto-generate a `@type` declaration. Lossy constraints emit **compile-time warnings** pointing to the call site.

```elixir
import Inspex

defspec :user_id,   integer(gte?: 1),   type: true
# @type user_id :: pos_integer()

defspec :email,     string(:filled?, format: ~r/@/), type: true
# @type email :: String.t()
# warning: defspec :email type: format: ~r"/@/" has no typespec equivalent

defschema :profile, type: true do
  schema(%{
    required(:name)  => string(:filled?),
    required(:age)   => integer(gte?: 0),
    optional(:role)  => atom(in?: [:admin, :user])
  })
end
# @type profile :: %{required(:name) => String.t(),
#                    required(:age) => non_neg_integer(),
#                    optional(:role) => :admin | :user}
```

For macro injection, `Inspex.Typespec.type_ast/2` returns the `@type` declaration AST directly:

```elixir
ast = Inspex.Typespec.type_ast(:my_type, integer(gte?: 0))
# Inject into a module at compile time:
Module.eval_quoted(MyModule, ast)
```

---

## Testing

### Process-local registry for async tests

Never use `Inspex.Registry.clear/0` in async tests — it clears the global ETS table. Use the process-local overlay instead.

```elixir
defmodule MyApp.SpecTest do
  use ExUnit.Case, async: true
  import Inspex

  setup do
    on_exit(&Inspex.Registry.clear_local/0)
    :ok
  end

  test "ref resolves to a locally registered spec" do
    Inspex.Registry.register_local(:test_email, string(:filled?, format: ~r/@/))
    spec = schema(%{required(:email) => ref(:test_email)})

    assert {:ok, _}    = Inspex.conform(spec, %{email: "a@b.com"})
    assert {:error, _} = Inspex.conform(spec, %{email: "bad"})
  end
end
```

### Property-based testing

```elixir
defmodule MyApp.PropertyTest do
  use ExUnitProperties
  import Inspex

  property "generated values always conform" do
    spec = schema(%{
      required(:name)  => string(:filled?),
      required(:age)   => integer(gte?: 0, lte?: 150),
      optional(:score) => float(gte?: 0.0, lte?: 1.0)
    })

    check all value <- gen(spec) do
      assert {:ok, _} = Inspex.conform(spec, value)
    end
  end

  property "conform is idempotent for valid values" do
    spec = string(:filled?)

    check all value <- gen(spec) do
      {:ok, shaped} = Inspex.conform(spec, value)
      assert Inspex.conform(spec, shaped) == {:ok, shaped}
    end
  end
end
```

---

## Compared to Alternatives

| | inspex | Norm | Drops | Peri |
|-|--------|------|-------|------|
| Parse, don't validate | ✓ | ✓ | ✓ | ✓ |
| Named constraints | ✓ | — | ✓ | ✓ |
| Generator inference | ✓ | — | — | — |
| Function signatures | ✓ | ✓ | — | — |
| Coercion pipeline | ✓ | — | ✓ | — |
| User coercion registry | ✓ | — | — | — |
| Typespec bridge | ✓ | — | — | — |
| `@type` generation | ✓ | — | — | — |
| Circular schemas (`ref`) | ✓ | — | — | — |
| Prod zero-overhead signatures | ✓ | — | ✓ | ✓ |
| Accumulating schema errors | ✓ | ✓ | ✓ | ✓ |

---

## AI Agent Reference

This section is structured for machine consumption. Complete API surface, all constraint names, error formats, and behavioural guarantees.

### Module map

| Module | Purpose |
|--------|---------|
| `Inspex` | Primary API — `import Inspex` |
| `Inspex.Signature` | Function signature validation — `use Inspex.Signature` in module |
| `Inspex.Typespec` | Spec → typespec AST conversion |
| `Inspex.Coercions` | Coercion functions + user registry |
| `Inspex.Registry` | Named spec registry (ETS + process-local) |
| `Inspex.Gen` | Generator inference (dev/test only) |
| `Inspex.Error` | Validation failure struct |
| `Inspex.SignatureError` | Raised on signature violation |
| `Inspex.ConformError` | Raised by `defschema name!/1` |

### Complete `Inspex` function signatures

```elixir
# Primitive builders (all accept keyword constraints)
string()  | string(atom) | string(atom, kw) | string(kw)
integer() | integer(atom) | integer(atom, kw) | integer(kw)
float()   | float(atom)   | float(atom, kw)   | float(kw)
number()  | boolean() | map() | list() | any() | nil_spec()
atom()    | atom(kw)

# Combinators
all_of([conformable()])                          :: All.t()
any_of([conformable()])                          :: Any.t()
not_spec(conformable())                          :: Not.t()
maybe(conformable())                             :: Maybe.t()
list_of(conformable())                           :: ListOf.t()
cond_spec(pred_fn, if_spec)                      :: Cond.t()
cond_spec(pred_fn, if_spec, else_spec)           :: Cond.t()
coerce(Spec.t(), (term -> {:ok, t} | {:error, s})) :: Spec.t()
coerce(Spec.t(), from: source_atom)              :: Spec.t()
ref(atom)                                        :: Ref.t()
spec(pred_or_guard_expr)                         :: Spec.t()
spec(pred_or_guard_expr, gen: StreamData.t())    :: Spec.t()

# Schema
schema(%{schema_key => conformable()})           :: Schema.t()
open_schema(%{schema_key => conformable()})      :: Schema.t()
required(atom)   # → SchemaKey used as map key in schema/1
optional(atom)   # → SchemaKey used as map key in schema/1

# Registration (macros — expand at compile time)
defspec name_atom, spec_expr
defspec name_atom, spec_expr, type: true
defschema name_atom do spec_expr end
defschema name_atom, type: true do spec_expr end

# Validation
Inspex.conform(conformable(), term()) :: {:ok, term()} | {:error, [Error.t()]}
Inspex.valid?(conformable(), term())  :: boolean()
Inspex.explain(conformable(), term()) :: ExplainResult.t()

# Generator (dev/test only — raises in prod)
Inspex.gen(conformable()) :: StreamData.t()

# Typespec
Inspex.to_typespec(conformable())         :: Macro.t()
Inspex.typespec_lossiness(conformable())  :: [{atom(), String.t()}]
Inspex.Typespec.type_ast(atom, conformable()) :: Macro.t()
```

### All named constraints by type

```
# String
:filled?           non-empty — byte_size > 0
min_length: n      byte_size >= n
max_length: n      byte_size <= n
size?: n           byte_size == n
format: ~r/regex/  must match regex

# Integer / Float / Number
gt?:  n            > n
gte?: n            >= n
lt?:  n            < n
lte?: n            <= n
in?:  [values]     member of list (integer or atom)

# Atom
in?: [atoms]       member of atom list
```

### All built-in coercion pairs

```
{:string,  :integer}   Integer.parse, trims whitespace, strict (no trailing chars)
{:string,  :float}     Float.parse; integers pass through as floats
{:string,  :boolean}   true/yes/1/on → true; false/no/0/off → false (case-insensitive)
{:string,  :atom}      String.to_existing_atom — safe against atom table exhaustion
{:string,  :number}    same as {:string, :float}
{:integer, :float}     n * 1.0
{:integer, :string}    Integer.to_string
{:integer, :boolean}   0 → false, 1 → true; any other integer → error
{:atom,    :string}    Atom.to_string; nil → error (nil is an atom in Elixir)
{:float,   :integer}   trunc/1 — truncates toward zero; 3.7 → 3, -3.7 → -3
{:float,   :string}    "#{v}"
```

All coercions are idempotent: values already of the target type pass through unchanged.

### `Inspex.Error` struct

```elixir
%Inspex.Error{
  path:      [atom() | non_neg_integer()],
  # [] = root-level failure
  # [:email] = top-level key failure
  # [:address, :zip] = nested key failure
  # [:items, 2, :name] = list element nested failure

  predicate: atom() | nil,
  # named constraints: :filled?, :gte?, :gt?, :lte?, :lt?, :format, :in?,
  #                    :min_length, :max_length, :size?, :coerce
  # arbitrary spec:    nil

  value:     term(),   # the value that failed (after coercion if any)
  message:   String.t(),
  meta:      map()
}

# String.Chars impl:
to_string(%Error{path: [], message: "must be a map"})
#=> "must be a map"

to_string(%Error{path: [:address, :zip], message: "must be 5 characters"})
#=> ":address.:zip: must be 5 characters"

to_string(%Error{path: [:items, 2, :name], message: "must be filled"})
#=> ":items.[2].:name: must be filled"
```

### `Inspex.SignatureError` struct

```elixir
%Inspex.SignatureError{
  module:   module(),
  function: atom(),
  arity:    non_neg_integer(),
  kind:     :args | :ret | :fn,
  errors:   [Inspex.Error.t()]
}

# Error path prefixes injected by Inspex.Signature:
# {:arg, 0}  → "argument[0]"   for args errors
# :ret        → "return"         for ret errors
# :fn         → "fn"             for fn errors

# Example paths in errors:
[{:arg, 0}]            # root-level arg failure (wrong type, etc.)
[{:arg, 0}, :email]    # arg 0 is a schema; :email field failed
[{:arg, 0}, :items, 2] # arg 0 is a schema; items[2] failed
[:ret]                 # return value root-level failure
[:ret, :name]          # return is a schema; :name field failed

# Exception.message/1 format:
"MyApp.Users.register/2 argument error:\n  argument[0][:email]: must be filled\n  argument[1]: must be >= 18"
```

### `Inspex.Registry` API

```elixir
# Global ETS-backed (survives process restarts)
Inspex.Registry.register(name :: atom, spec :: conformable()) :: :ok
Inspex.Registry.unregister(name :: atom)                      :: :ok
Inspex.Registry.fetch!(name :: atom)                          :: conformable()  # raises if missing
Inspex.Registry.registered?(name :: atom)                     :: boolean()
Inspex.Registry.all()                                         :: %{atom => conformable()}
Inspex.Registry.clear()                                       :: :ok  # DANGER: global, avoid in async tests

# Process-local overlay (for async-safe test isolation)
Inspex.Registry.register_local(name :: atom, spec :: conformable()) :: :ok
Inspex.Registry.unregister_local(name :: atom)                      :: :ok
Inspex.Registry.clear_local()                                       :: :ok  # safe in on_exit
```

`fetch!/1` checks the process-local overlay first, then the global ETS table.

### `Inspex.Coercions` API

```elixir
Inspex.Coercions.register({source :: atom, target :: atom}, fun :: (term -> {:ok, t} | {:error, s})) :: :ok
Inspex.Coercions.registered() :: %{{atom, atom} => function()}
Inspex.Coercions.lookup(source :: atom, target :: atom) :: function()
# Raises ArgumentError if no coercion exists (programming error, not data error)
```

### Typespec lossiness reasons

```
:constraint_not_expressible     string constraints: filled?, format:, min_length:, max_length:, size?
:intersection_not_expressible   all_of: first typed spec used, rest ignored
:negation_not_expressible       not_spec: falls back to term()
:predicate_not_expressible      cond_spec: predicate fn lost; union of branches used
:coercion_not_expressible       coerce: only target type appears; input type not represented
```

### Type union — the `conformable()` type

```
conformable() =
  Inspex.Spec        # primitives and coerce wrappers
  | Inspex.All       # all_of
  | Inspex.Any       # any_of
  | Inspex.Not       # not_spec
  | Inspex.Maybe     # maybe
  | Inspex.Ref       # ref
  | Inspex.ListOf    # list_of
  | Inspex.Cond      # cond_spec
  | Inspex.Schema    # schema / open_schema
```

### Behavioural guarantees

1. **`conform/2` is the single entry point.** `valid?/2` calls it and discards the value. `explain/2` calls it and formats the errors.

2. **Specs are plain structs.** Store in module attributes, pass to functions, compose freely. No hidden state, no registration required unless you use `ref/1`.

3. **`all_of/1` pipelines.** Each spec's shaped output is the next spec's input. Coercions in position 0 transform the value for subsequent specs.

4. **`ref/1` is lazy.** Resolved at `conform/2` call time. Use for forward references and circular schemas. Must be registered before `conform/2` is called (not before the spec is built).

5. **Schema errors accumulate.** `schema/1`, `open_schema/1`, `list_of/1`, and `__coerce_and_check_args__` never short-circuit — all failures are returned at once.

6. **`defspec`/`defschema` with `type: true` requires evaluable spec expressions.** `Code.eval_quoted` runs at macro expansion time with the caller's `Macro.Env`. Spec expressions must be evaluable with the caller's imports. Variables from the surrounding runtime scope are not available.

7. **`signature` is prod-safe.** `Mix.env()` is checked at macro expansion time. In `:prod`, `signature/1` is a no-op and `def` delegates directly to `Kernel.def`. Never guard signature calls with `Mix.env()` yourself.

8. **Coercion registry is global and permanent.** `Inspex.Coercions.register/2` uses `:persistent_term`. There is no `unregister`. Call once at startup; never in tests or hot paths.

9. **Process-local registry for test isolation.** Use `register_local/2` + `clear_local/0` in `on_exit`. `clear/0` clears the global ETS table — safe only in synchronous (non-async) test setup.

10. **`gen/1` raises in `:prod`.** Keep generator calls in `:dev`/`:test` code. For conditional use, guard with `if Mix.env() != :prod`.
