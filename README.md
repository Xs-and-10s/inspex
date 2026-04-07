# Gladius

**Parse, don't validate.** `conform/2` returns a *shaped* value on success — coercions applied, transforms run, data restructured — not just `true`. Specs are composable structs, not modules. Write a spec once; use it to validate, generate test data, check function signatures, and produce typespecs.

[![Hex.pm](https://img.shields.io/hexpm/v/gladius.svg)](https://hex.pm/packages/gladius)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/gladius)

---

## Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Primitives](#primitives)
- [Named Constraints](#named-constraints)
- [Combinators](#combinators)
- [Schemas](#schemas)
- [Default Values](#default-values)
- [Post-Validation Transforms](#post-validation-transforms)
- [Struct Validation](#struct-validation)
- [Custom Error Messages](#custom-error-messages)
- [Ordered Schemas](#ordered-schemas)
- [JSON Schema Export](#json-schema-export)
- [Schema Extension](#schema-extension)
- [Partial Schemas](#partial-schemas)
- [Cross-Field Validation](#cross-field-validation)
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
    {:gladius, "~> 0.6"}
  ]
end
```

Gladius runs a registry under its own supervision tree — no configuration needed; it starts automatically with your application.

---

## Quick Start

```elixir
import Gladius

user = schema(%{
  required(:name)  => string(:filled?),
  required(:email) => string(:filled?, format: ~r/@/),
  required(:age)   => integer(gte?: 18),
  optional(:role)  => atom(in?: [:admin, :user, :guest])
})

Gladius.conform(user, %{name: "Mark", email: "mark@x.com", age: 33})
#=> {:ok, %{name: "Mark", email: "mark@x.com", age: 33}}

Gladius.conform(user, %{name: "", age: 15})
#=> {:error, [
#=>   %Gladius.Error{path: [:name],  message: "must be filled"},
#=>   %Gladius.Error{path: [:email], message: "key :email must be present"},
#=>   %Gladius.Error{path: [:age],   message: "must be >= 18"}
#=> ]}
```

**Three entry points:**

| Function | Returns |
|----------|---------|
| `Gladius.conform(spec, value)` | `{:ok, shaped_value}` or `{:error, [Error.t()]}` |
| `Gladius.valid?(spec, value)` | `boolean()` |
| `Gladius.explain(spec, value)` | `ExplainResult.t()` with a formatted string |

```elixir
result = Gladius.explain(user, %{name: "", age: 15})
result.valid?     #=> false
IO.puts result.formatted
# :name: must be filled
# :email: key :email must be present
# :age: must be >= 18
```

---

## Primitives

```elixir
import Gladius

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

Applies one branch based on a predicate.

```elixir
cond_spec(
  fn order -> order.type == :physical end,
  ref(:address_schema),
  nil_spec()
)

# else_spec defaults to any() if omitted
cond_spec(&is_binary/1, string(:filled?))
```

### `spec/1` — arbitrary predicate

```elixir
spec(&is_integer/1)
spec(&(&1 > 0))
spec(fn n -> rem(n, 2) == 0 end)
spec(is_integer() and &(&1 > 0))
spec(&is_integer/1, gen: StreamData.integer(1..1000))
```

### `coerce/2` — coercion wrapper

See [Coercion](#coercion) for the full reference.

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
```

### `open_schema/1` — extra keys pass through

```elixir
base = open_schema(%{required(:id) => integer(gt?: 0)})

Gladius.conform(base, %{id: 1, extra: "anything"})
#=> {:ok, %{id: 1, extra: "anything"}}
```

### `ref/1` — lazy registry reference

Resolved at conform-time. Enables circular schemas.

```elixir
defspec :tree_node, schema(%{
  required(:value)    => integer(),
  optional(:children) => list_of(ref(:tree_node))
})
```

---

## Ordered Schemas

`schema/1` and `open_schema/1` accept either a map (`%{}`) or a list of
2-tuples (`[]`). **Lists preserve declaration order** — use them when field
order matters for introspection, JSON Schema export, or form rendering.

```elixir
# Map — field order is NOT guaranteed (Elixir map literals are unordered)
schema(%{
  required(:name)  => string(:filled?),
  required(:email) => string(:filled?, format: ~r/@/),
  required(:age)   => integer(gte?: 0)
})

# List — field order IS preserved
schema([
  {required(:name),  string(:filled?)},
  {required(:email), string(:filled?, format: ~r/@/)},
  {required(:age),   integer(gte?: 0)}
])
```

The list form uses standard Elixir 2-tuple syntax. `{required(:field), spec}` and
`{optional(:field), spec}` are the two forms. Bare atom keys `{:field, spec}` are
treated as required.

Both forms return an identical `%Gladius.Schema{}` — all other functions
(`conform/2`, `extend/2`, `selection/2`, `validate/2`, `Gladius.Schema.fields/1`,
`Gladius.Ecto.changeset/2`) work identically on both.

When to use each:
- **Map** — quick schemas where order is irrelevant (most validation use cases)
- **List** — schemas that drive form field order, API documentation, or admin UIs

---

## JSON Schema Export

`Gladius.Schema.to_json_schema/2` converts any Gladius spec or schema to a
JSON Schema (draft 2020-12) map. Encode with Jason or Poison as normal.

```elixir
import Gladius

address = schema([
  {required(:street), string(:filled?)},
  {required(:zip),    string(size?: 5, message: "must be exactly 5 characters")},
  {optional(:city),   string()}
])

user = schema([
  {required(:name),    string(:filled?)},
  {required(:age),     integer(gte?: 18)},
  {optional(:role),    atom(in?: [:admin, :user])},
  {optional(:address), address}
])

Gladius.Schema.to_json_schema(user, title: "User")
#=> %{
#=>   "$schema"  => "https://json-schema.org/draft/2020-12/schema",
#=>   "title"    => "User",
#=>   "type"     => "object",
#=>   "properties" => %{
#=>     "name"    => %{"type" => "string", "minLength" => 1},
#=>     "age"     => %{"type" => "integer", "minimum" => 18},
#=>     "role"    => %{"enum" => ["admin", "user"]},
#=>     "address" => %{
#=>       "type" => "object",
#=>       "properties" => %{
#=>         "street" => %{"type" => "string", "minLength" => 1},
#=>         "zip"    => %{"type" => "string", "minLength" => 5, "maxLength" => 5},
#=>         "city"   => %{"type" => "string"}
#=>       },
#=>       "required"             => ["street", "zip"],
#=>       "additionalProperties" => false
#=>     }
#=>   },
#=>   "required"             => ["name", "age"],
#=>   "additionalProperties" => false
#=> }
```

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `:title` | — | Adds `"title"` to the root object |
| `:description` | — | Adds `"description"` to the root object |
| `:schema_header` | `true` | Include `"$schema"` URI at root |

### Spec → JSON Schema mapping

| Gladius | JSON Schema |
|---------|------------|
| `string(:filled?)` | `{"type": "string", "minLength": 1}` |
| `string(size?: 5)` | `{"type": "string", "minLength": 5, "maxLength": 5}` |
| `string(format: ~r/re/)` | `{"type": "string", "pattern": "re"}` |
| `integer(gte?: 0)` | `{"type": "integer", "minimum": 0}` |
| `integer(gt?: 0)` | `{"type": "integer", "exclusiveMinimum": 0}` |
| `integer(in?: [1,2])` | `{"enum": [1, 2]}` |
| `float()` / `number()` | `{"type": "number"}` |
| `boolean()` | `{"type": "boolean"}` |
| `atom(in?: [:a, :b])` | `{"enum": ["a", "b"]}` |
| `nil_spec()` | `{"type": "null"}` |
| `any()` | `{}` |
| `list_of(inner)` | `{"type": "array", "items": inner}` |
| `maybe(inner)` | `{"oneOf": [{"type": "null"}, inner]}` |
| `all_of([s1, s2])` | `{"allOf": [s1, s2]}` |
| `any_of([s1, s2])` | `{"anyOf": [s1, s2]}` |
| `not_spec(inner)` | `{"not": inner}` |
| `default(inner, val)` | inner + `"default": val` |
| `transform(inner, _)` | inner (transform is a runtime concern) |
| `coerce(inner, _)` | inner (output type; coercion is a runtime concern) |
| `validate(inner, _)` | inner (cross-field rules have no JSON Schema form) |
| `schema(%{...})` | `{"type": "object", "properties": {...}, "required": [...], "additionalProperties": false}` |
| `open_schema(%{...})` | same with `"additionalProperties": true` |
| `spec(pred)` | `{"description": "custom predicate — no JSON Schema equivalent"}` |
| `ref(:name)` | resolved and inlined |

### Encoding with Jason

```elixir
Jason.encode!(Gladius.Schema.to_json_schema(user_schema, title: "User"))
```

The output contains only JSON-safe values (string keys, no atoms except
`true`/`false`/`nil`) and can be passed directly to Jason without a custom
encoder.

---

## Schema Extension

`extend/2` builds a new schema from an existing one from an existing one, overriding or adding keys.
Extension keys take precedence over same-named base keys. Base key order is
preserved; new keys are appended after.

```elixir
base = schema(%{
  required(:name)  => string(:filled?),
  required(:email) => string(:filled?, format: ~r/@/),
  required(:age)   => integer(gte?: 0)
})

# Add fields
with_role = extend(base, %{optional(:role) => atom(in?: [:admin, :user])})

# Override a field's spec
adult_only = extend(base, %{required(:age) => integer(gte?: 18)})

# Change required → optional (or vice versa)
optional_email = extend(base, %{optional(:email) => string()})
```

### `open?` inheritance

`extend/2` inherits `open?` from the base schema. Override with the `open:` option:

```elixir
extend(base, %{optional(:bio) => string()}, open?: true)
```

### The create / update / patch pattern

A single base schema drives all three variants with no duplication:

```elixir
base = schema(%{
  required(:name)  => string(:filled?),
  required(:email) => string(:filled?, format: ~r/@/),
  required(:age)   => integer(gte?: 0)
})

create = extend(base, %{required(:password) => string(min_length: 8)})
update = extend(base, %{optional(:role) => atom(in?: [:admin, :user])})
patch  = selection(update, [:name, :email, :age, :role])
```

A change to `base` propagates automatically to `create`, `update`, and `patch`.

### Chaining extends

`extend/2` can be called on an already-extended schema:

```elixir
admin_schema =
  base
  |> extend(%{optional(:role)       => atom(in?: [:admin, :user])})
  |> extend(%{optional(:department) => string(:filled?)})
```

---

## Default Values

`default/2` injects a fallback value when an optional key is absent. The fallback is injected as-is — the inner spec only runs when the key is **present**.

```elixir
schema(%{
  required(:name)    => string(:filled?),
  optional(:role)    => default(atom(in?: [:admin, :user, :guest]), :user),
  optional(:retries) => default(integer(gte?: 0), 3),
  optional(:tags)    => default(list_of(string(:filled?)), [])
})

Gladius.conform(schema, %{name: "Mark"})
#=> {:ok, %{name: "Mark", role: :user, retries: 3, tags: []}}
```

**Semantics:**
- Key absent → fallback injected directly; inner spec not run
- Key present → inner spec validates the provided value normally
- Invalid provided value → error returned; default does not rescue it
- Required key → `default/2` has no effect on absence; missing required keys always error

`default/2` accepts any conformable as its inner spec:

```elixir
optional(:coords)  => default(schema(%{required(:x) => integer()}), %{x: 0})
optional(:ref)     => default(maybe(string(:filled?)), nil)
optional(:wrapped) => default(ref(:address), %{street: "unknown", zip: "00000"})
```

---

## Post-Validation Transforms

`transform/2` applies a function to the shaped value **after** validation succeeds. It never runs on invalid data.

**Pipeline:** `raw → coerce → validate → transform → {:ok, result}`

```elixir
# Normalize strings at the boundary
email_spec = transform(string(:filled?, format: ~r/@/), &String.downcase/1)
name_spec  = transform(string(:filled?), &String.trim/1)

schema(%{
  required(:name)  => name_spec,
  required(:email) => email_spec
})

Gladius.conform(schema, %{name: "  Mark  ", email: "MARK@X.COM"})
#=> {:ok, %{name: "Mark", email: "mark@x.com"}}
```

Chain transforms with pipe — `transform/2` is spec-first for exactly this reason:

```elixir
string(:filled?)
|> transform(&String.trim/1)
|> transform(&String.downcase/1)
```

Enrich a schema output:

```elixir
transform(
  schema(%{required(:name) => string(:filled?)}),
  fn m -> Map.put(m, :slug, String.downcase(m.name)) end
)
```

**Error handling:** if the transform function raises, the exception is caught and returned as `%Gladius.Error{predicate: :transform, message: "transform failed: ..."}`. The caller never crashes.

**With defaults:** when `default/2` wraps a `transform/2`, the default value bypasses the transform entirely (consistent with bypassing the inner spec):

```elixir
optional(:name) => default(transform(string(:filled?), &String.trim/1), "anon")
# key absent → "anon" injected, trim never runs
# key present → trimmed and validated normally
```

---

## Struct Validation

### Structs as input to `conform/2`

`conform/2` accepts any Elixir struct directly — no `Map.from_struct/1` needed. The output is a plain map.

```elixir
defmodule User do
  defstruct [:name, :email, :age]
end

s = schema(%{
  required(:name)  => transform(string(:filled?), &String.trim/1),
  required(:email) => string(:filled?, format: ~r/@/)
})

Gladius.conform(s, %User{name: "  Mark  ", email: "mark@x.com"})
#=> {:ok, %{name: "Mark", email: "mark@x.com"}}
```

`valid?/2` and `explain/2` accept structs the same way.

### `conform_struct/2` — validate and re-wrap

When you need the shaped output back in the original struct type:

```elixir
Gladius.conform_struct(s, %User{name: "  Mark  ", email: "mark@x.com"})
#=> {:ok, %User{name: "Mark", email: "mark@x.com"}}
```

Coercions and transforms are reflected in the returned struct:

```elixir
s = schema(%{
  required(:name) => transform(string(:filled?), &String.trim/1),
  required(:age)  => coerce(integer(), from: :string)
})

Gladius.conform_struct(s, %User{name: "  Mark  ", age: "33"})
#=> {:ok, %User{name: "Mark", age: 33}}
```

Errors are the same `{:error, [%Gladius.Error{}]}` format as `conform/2`. A plain map (non-struct) input returns an error immediately.

### `defschema struct: true` — schema + struct in one

Defines the validator functions **and** a matching output struct in a single declaration. The struct module is named `<CallerModule>.<PascalName>Schema`.

```elixir
defmodule MyApp.Schemas do
  import Gladius

  defschema :point, struct: true do
    schema(%{
      required(:x) => integer(),
      required(:y) => integer()
    })
  end

  defschema :person, struct: true do
    schema(%{
      required(:name)  => transform(string(:filled?), &String.trim/1),
      optional(:score) => default(integer(gte?: 0), 0)
    })
  end
end

MyApp.Schemas.point(%{x: 3, y: 4})
#=> {:ok, %MyApp.Schemas.PointSchema{x: 3, y: 4}}

MyApp.Schemas.person(%{name: "  Mark  "})
#=> {:ok, %MyApp.Schemas.PersonSchema{name: "Mark", score: 0}}

MyApp.Schemas.point!(%{x: "bad", y: 0})
#=> raises Gladius.ConformError
```

Transforms run before struct wrapping; defaults are injected before struct wrapping.

---

## Custom Error Messages

Every spec builder and combinator accepts a `message:` option that overrides the generated error string for any failure of that spec.

```elixir
# String override — returned as-is, bypasses translator
string(:filled?, message: "can't be blank")
integer(gte?: 18, message: "you must be at least 18")
coerce(integer(), from: :string, message: "must be a valid number")
transform(string(), &String.trim/1, message: "normalization failed")
maybe(string(:filled?), message: "must be a non-empty string or nil")
```

### Tuple form — i18n aware

For internationalized applications, pass a `{domain, msgid, bindings}` tuple. Without a configured translator the `msgid` is used as-is. With a translator it is dispatched for translation.

```elixir
string(:filled?, message: {"errors", "can't be blank", []})
integer(gte?: 18, message: {"errors", "must be at least %{min}", [min: 18]})
```

### Configuring a translator

```elixir
# config/config.exs
config :gladius, translator: MyApp.GladiusTranslator

defmodule MyApp.GladiusTranslator do
  @behaviour Gladius.Translator

  @impl Gladius.Translator
  def translate(domain, msgid, bindings) do
    # Gettext, LLM translation, or anything else
    Gettext.dgettext(MyAppWeb.Gettext, domain || "errors", msgid, bindings)
  end
end
```

### Structured error metadata

Every `%Gladius.Error{}` now carries `message_key` and `message_bindings` so translators and custom renderers can work from structured data rather than matching on English strings:

```elixir
{:error, [error]} = conform(integer(gte?: 18), 15)
error.message_key      #=> :gte?
error.message_bindings #=> [min: 18]
error.message          #=> "must be >= 18"  (or translated if configured)
```

---

## Partial Schemas

`selection/2` returns a new schema containing only the named fields, all made optional. The primary use case is PATCH endpoints — validate whatever subset of fields the client chose to send.

```elixir
user_schema = schema(%{
  required(:name)  => string(:filled?),
  required(:email) => string(:filled?, format: ~r/@/),
  required(:age)   => integer(gte?: 0),
  optional(:role)  => atom(in?: [:admin, :user])
})

patch = selection(user_schema, [:name, :email, :age, :role])

Gladius.conform(patch, %{})              #=> {:ok, %{}}        # nothing sent — ok
Gladius.conform(patch, %{name: "Mark"}) #=> {:ok, %{name: "Mark"}}  # partial — ok
Gladius.conform(patch, %{age: -1})      #=> {:error, [...]}    # present but invalid
```

**Semantics:**
- Selected keys absent from input → omitted from output, no error
- Selected keys present → validated by their original spec (coercions, transforms, defaults all apply)
- Keys not in the selection → rejected as unknown (closed schema; prevents mass-assignment)
- `open?` is inherited from the source schema

---

## Cross-Field Validation

`validate/2` attaches validation rules that run **after** the inner spec fully passes. Rules receive the shaped output and can produce errors referencing any field.

```elixir
schema(%{
  required(:start_date) => string(:filled?),
  required(:end_date)   => string(:filled?)
})
|> validate(fn %{start_date: s, end_date: e} ->
  if e >= s, do: :ok, else: {:error, :end_date, "must be on or after start date"}
end)
```

Chain multiple rules — all run and all errors accumulate:

```elixir
schema(%{
  required(:password) => string(:filled?),
  required(:confirm)  => string(:filled?)
})
|> validate(fn %{password: p, confirm: c} ->
  if p == c, do: :ok, else: {:error, :base, "passwords do not match"}
end)
|> validate(&check_password_strength/1)
```

**Rule return values:**

```elixir
:ok                                               # passes
{:error, :field_name, "message"}                  # single named-field error
{:error, :base, "message"}                        # schema-level error
{:error, [{:field_a, "msg"}, {:field_b, "msg"}]}  # multiple errors
```

**Semantics:**
- Rules only run when the inner spec **fully** passes — never on partial data
- All rules always run; errors accumulate across all of them (no short-circuiting)
- Exceptions from rule functions are caught and returned as `%Error{predicate: :validate}`
- Rules receive the **shaped** output — coercions and transforms have already run

---

## Ecto Integration

`Gladius.Ecto` is an optional module (guarded by `Code.ensure_loaded?(Ecto.Changeset)`)
that converts a Gladius schema into an `Ecto.Changeset`. Add `{:ecto, "~> 3.0"}` to
your deps alongside Gladius — Phoenix apps already have it.

### Schemaless changeset

```elixir
schema = schema(%{
  required(:name)  => string(:filled?),
  required(:email) => transform(string(:filled?, format: ~r/@/), &String.downcase/1),
  required(:age)   => coerce(integer(gte?: 18), from: :string),
  optional(:role)  => default(atom(in?: [:admin, :user]), :user)
})

Gladius.Ecto.changeset(schema, params)
#=> %Ecto.Changeset{valid?: true,
#=>   changes: %{name: "Mark", email: "mark@x.com", age: 33, role: :user}}
```

### Update workflow

```elixir
user = %User{name: "Mark", email: "mark@x.com", age: 33}
Gladius.Ecto.changeset(schema, %{age: "40"}, user)
#=> %Ecto.Changeset{valid?: true, changes: %{age: 40}}
```

### Nested schemas — `inputs_for` compatible

When a field's spec is (or wraps) a `%Gladius.Schema{}`, `changeset/2-3` builds
a nested `%Ecto.Changeset{}` for that field and registers it as an Ecto embedded
type (`{:parameterized, Ecto.Embedded, ...}`). This makes it compatible with
Phoenix `inputs_for/4` in LiveView without any extra configuration.

```elixir
address_schema = schema(%{
  required(:street) => string(:filled?),
  required(:zip)    => string(size?: 5)
})

user_schema = schema(%{
  required(:name)    => string(:filled?),
  required(:address) => address_schema
})

cs = Gladius.Ecto.changeset(user_schema, params)

# Nested changeset — Phoenix inputs_for reads this
cs.changes.address         #=> %Ecto.Changeset{valid?: true, ...}
cs.types[:address]         #=> {:embed, %Ecto.Embedded{cardinality: :one, field: :address}}
```

### Lists of embedded schemas

`list_of(schema(...))` produces a list of nested changesets registered as a
`:many` cardinality embed — compatible with `inputs_for` over collections:

```elixir
schema(%{
  required(:name) => string(:filled?),
  required(:tags) => list_of(schema(%{required(:name) => string(:filled?)}))
})

cs = Gladius.Ecto.changeset(s, params)
cs.changes.tags   #=> [%Ecto.Changeset{}, %Ecto.Changeset{}, ...]
cs.types[:tags]   #=> {:embed, %Ecto.Embedded{cardinality: :many, field: :tags}}
```

### Phoenix LiveView — full working example

```elixir
defmodule MyAppWeb.UserFormLive do
  use MyAppWeb, :live_view   # imports CoreComponents including input/1
  import Gladius

  # ⚠ Schemas must be functions, NOT module attributes.
  # Coercions and transforms contain anonymous functions that Elixir cannot
  # escape at compile time. Storing them in @attr raises ArgumentError.
  defp address_schema do
    schema(%{
      required(:street) => string(:filled?),
      required(:zip)    => string(size?: 5, message: "must be exactly 5 characters")
    })
  end

  defp user_schema do
    schema(%{
      required(:name)    => transform(string(:filled?), &String.trim/1),
      required(:email)   => transform(string(:filled?, format: ~r/@/), &String.downcase/1),
      required(:age)     => coerce(integer(gte?: 18), from: :string, message: "must be a number"),
      required(:address) => address_schema()
    })
  end

  def mount(_params, _session, socket) do
    # changeset/2 auto-seeds embed fields — no manual %{address: %{}} needed
    form = Gladius.Ecto.changeset(user_schema(), %{}) |> to_form(as: :user)
    {:ok, assign(socket, form: form)}
  end

  def handle_event("validate", %{"_target" => target, "user" => params}, socket) do
    # Gladius.Ecto strips _unused_* and _persistent_id keys automatically
    form =
      Gladius.Ecto.changeset(user_schema(), params)
      |> Map.put(:action, :validate)
      |> to_form(as: :user)
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("submit", %{"user" => params}, socket) do
    case Gladius.Ecto.changeset(user_schema(), params) do
      %{valid?: true} = cs ->
        shaped = Ecto.Changeset.apply_changes(cs)
        {:noreply, assign(socket, form: cs |> to_form(as: :user), result: shaped)}
      cs ->
        {:noreply, assign(socket, form: cs |> Map.put(:action, :validate) |> to_form(as: :user))}
    end
  end

  def render(assigns) do
    ~H"""
    <%!-- as={:user} is required — schemaless changesets have no struct name to derive from --%>
    <.form for={@form} as={:user} phx-change="validate" phx-submit="submit">
      <.input field={@form[:name]} type="text" />
      <.input field={@form[:email]} type="email" />
      <.input field={@form[:age]} type="text" />

      <%!-- inputs_for works — embed type is declared automatically --%>
      <.inputs_for :let={addr} field={@form[:address]}>
        <.input field={addr[:street]} type="text" />
        <.input field={addr[:zip]} type="text" />
      </.inputs_for>

      <button type="submit">Save</button>
    </.form>
    """
  end
end
```

**Required patterns for Phoenix LiveView:**

1. **Schemas as functions** — never `@module_attr`. Coercions and transforms contain anonymous functions that cannot be escaped at compile time.
2. **`as:` on the form** — `<.form for={@form} as={:user}>`. Schemaless changesets have no struct name; Phoenix cannot derive it automatically.
3. **`to_form(changeset, as: :user)`** — store a `%Phoenix.HTML.Form{}` in assigns, not the raw changeset. The `input` component requires a form, not a changeset.
4. **`_target`-based error filtering** — use the `_target` param from `phx-change` events to only show errors for the field the user just touched, avoiding premature full-form errors.
5. **`Gladius.Ecto` strips Phoenix internals** — `_unused_*`, `_persistent_id`, and `_target` keys are removed automatically before conforming.

### Error traversal

Use `Gladius.Ecto.traverse_errors/2` to recursively collect errors from nested
changesets. Ecto's built-in `traverse_errors/2` only recurses into declared
embed/assoc fields and will not find errors in Gladius nested changesets.

```elixir
Gladius.Ecto.traverse_errors(cs, fn {msg, _opts} -> msg end)
#=> %{name: ["can't be blank"], address: %{zip: ["must be exactly 5 characters"]}}

# For list embeds, the field maps to a list of error maps:
#=> %{tags: [%{}, %{name: ["must be filled"]}]}
```

### Composing with Ecto validators

The returned changeset is a plain `%Ecto.Changeset{}` — pipe Ecto validators after:

```elixir
params
|> Gladius.Ecto.changeset(schema)
|> Ecto.Changeset.unique_constraint(:email)
|> Repo.insert()
```

---

## Registry

### `defspec` — globally named spec

```elixir
defmodule MyApp.Specs do
  import Gladius

  defspec :email,    string(:filled?, format: ~r/@/)
  defspec :username, string(:filled?, min_length: 3, max_length: 32)
  defspec :age,      integer(gte?: 0, lte?: 150)
  defspec :role,     atom(in?: [:admin, :user, :guest])
end
```

Reference with `ref/1` from anywhere:

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
  import Gladius

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
      required(:email) => coerce(ref(:email), from: :string),
      required(:age)   => coerce(integer(gte?: 18), from: :string)
    })
  end
end

MyApp.Schemas.user(%{name: "Mark", email: "m@x.com", age: 33})
#=> {:ok, %{name: "Mark", email: "m@x.com", age: 33}}

MyApp.Schemas.user!(%{name: "", age: 15})
#=> raises Gladius.ConformError
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
coerce(integer(),  from: :string)   # "42"   → 42
coerce(float(),    from: :string)   # "3.14" → 3.14
coerce(boolean(),  from: :string)   # "true" → true  (yes/1/on also work)
coerce(atom(),     from: :string)   # "ok"   → :ok   (existing atoms only)
coerce(float(),    from: :integer)  # 42     → 42.0
coerce(string(),   from: :integer)  # 42     → "42"
coerce(boolean(),  from: :integer)  # 0      → false, 1 → true
coerce(string(),   from: :atom)     # :ok    → "ok"
coerce(integer(),  from: :float)    # 3.7    → 3
coerce(string(),   from: :float)    # 3.14   → "3.14"
```

### User-extensible coercion registry

```elixir
Gladius.Coercions.register({:decimal, :float}, fn
  %Decimal{} = d     -> {:ok, Decimal.to_float(d)}
  v when is_float(v) -> {:ok, v}
  v -> {:error, "cannot coerce #{inspect(v)} to float"}
end)

coerce(float(gt?: 0.0), from: :decimal)
```

### Composition patterns

```elixir
# HTTP params / form data
http_params = schema(%{
  required(:age)    => coerce(integer(gte?: 18), from: :string),
  required(:active) => coerce(boolean(),          from: :string),
  required(:score)  => coerce(float(gt?: 0.0),   from: :string),
  optional(:role)   => coerce(atom(in?: [:admin, :user]), from: :string)
})

Gladius.conform(http_params, %{age: "25", active: "true", score: "9.5", role: "admin"})
#=> {:ok, %{age: 25, active: true, score: 9.5, role: :admin}}

# Coerce every list element
list_of(coerce(integer(), from: :string))
# ["1", "2", "3"] → {:ok, [1, 2, 3]}
```

---

## Generators

`gen/1` infers a `StreamData` generator from any spec. Available in `:dev` and `:test` — zero overhead in `:prod`.

```elixir
gen(string(:filled?))
gen(integer(gte?: 0, lte?: 100))
gen(atom(in?: [:admin, :user]))
gen(maybe(integer()))
gen(list_of(string(:filled?)))
gen(any_of([integer(), string()]))
gen(schema(%{required(:name) => string(:filled?), required(:age) => integer(gte?: 0)}))
gen(default(integer(gte?: 0), 0))    # delegates to inner spec
gen(transform(integer(), &(&1 * 2))) # delegates to inner spec
```

Use with `ExUnitProperties`:

```elixir
defmodule MyApp.PropertyTest do
  use ExUnitProperties
  import Gladius

  property "conform is idempotent for valid values" do
    spec = schema(%{
      required(:email) => string(:filled?, format: ~r/@/),
      required(:age)   => integer(gte?: 0, lte?: 150)
    })

    check all value <- gen(spec) do
      {:ok, shaped} = Gladius.conform(spec, value)
      assert Gladius.conform(spec, shaped) == {:ok, shaped}
    end
  end
end
```

---

## Function Signatures

`use Gladius.Signature` enables runtime validation in `:dev` and `:test`. **Zero overhead in `:prod`.**

```elixir
defmodule MyApp.Users do
  use Gladius.Signature

  signature args: [string(:filled?), integer(gte?: 18)],
            ret:  boolean()
  def register(email, age) do
    true
  end
end

MyApp.Users.register("mark@x.com", 33)   #=> true
MyApp.Users.register("", 33)             #=> raises SignatureError
```

### Options

| Key | Validates |
|-----|-----------|
| `:args` | List of specs, one per argument, positional |
| `:ret`  | Return value |
| `:fn`   | `{coerced_args_list, return_value}` — input/output relationships |

### Coercion threading

When `:args` specs include coercions, **coerced values are forwarded to the impl**.

```elixir
signature args: [coerce(integer(gte?: 0), from: :string)],
          ret:  string()
def double(n), do: Integer.to_string(n * 2)

MyApp.double("5")   #=> "10"
```

### Path errors

All failing arguments are collected in one raise, with full nested paths:

```elixir
signature args: [schema(%{
                  required(:email) => string(:filled?, format: ~r/@/),
                  required(:name)  => string(:filled?)
                })],
          ret: boolean()
def create(params), do: true

MyApp.create(%{email: "bad", name: ""})
# raises Gladius.SignatureError:
#   argument[0][:email]: format must match ~r/@/
#   argument[0][:name]: must be filled
```

---

## Typespec Bridge

```elixir
Macro.to_string(Gladius.to_typespec(integer(gte?: 0)))             #=> "non_neg_integer()"
Macro.to_string(Gladius.to_typespec(integer(gt?: 0)))              #=> "pos_integer()"
Macro.to_string(Gladius.to_typespec(integer(gte?: 1, lte?: 100)))  #=> "1..100"
Macro.to_string(Gladius.to_typespec(atom(in?: [:a, :b])))          #=> ":a | :b"
Macro.to_string(Gladius.to_typespec(maybe(string())))              #=> "String.t() | nil"
Macro.to_string(Gladius.to_typespec(default(integer(), 0)))        #=> "integer()"
Macro.to_string(Gladius.to_typespec(transform(string(), &String.trim/1))) #=> "String.t()"
```

### `@type` generation

```elixir
defspec :user_id, integer(gte?: 1), type: true
# @type user_id :: pos_integer()

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

---

## Testing

### Process-local registry for async tests

```elixir
defmodule MyApp.SpecTest do
  use ExUnit.Case, async: true
  import Gladius

  setup do
    on_exit(&Gladius.Registry.clear_local/0)
    :ok
  end

  test "ref resolves to a locally registered spec" do
    Gladius.Registry.register_local(:test_email, string(:filled?, format: ~r/@/))
    spec = schema(%{required(:email) => ref(:test_email)})

    assert {:ok, _}    = Gladius.conform(spec, %{email: "a@b.com"})
    assert {:error, _} = Gladius.conform(spec, %{email: "bad"})
  end
end
```

### Property-based testing

```elixir
property "generated values always conform" do
  spec = schema(%{
    required(:name)  => string(:filled?),
    required(:age)   => integer(gte?: 0, lte?: 150),
    optional(:score) => float(gte?: 0.0, lte?: 1.0)
  })

  check all value <- gen(spec) do
    assert {:ok, _} = Gladius.conform(spec, value)
  end
end
```

---

## Compared to Alternatives

| | gladius | Norm | Drops | Peri |
|-|--------|------|-------|------|
| Parse, don't validate | ✓ | ✓ | ✓ | ✓ |
| Named constraints | ✓ | — | ✓ | ✓ |
| Generator inference | ✓ | — | — | — |
| Function signatures | ✓ | ✓ | — | — |
| Coercion pipeline | ✓ | — | ✓ | — |
| User coercion registry | ✓ | — | — | — |
| Default values | ✓ | — | — | ✓ |
| Post-validation transforms | ✓ | — | — | — |
| Struct validation | ✓ | — | — | — |
| Ecto integration | ✓ | — | — | ✓ |
| Ecto nested embeds (`inputs_for`) | ✓ | — | — | — |
| Schema introspection (`fields/1`) | ✓ | — | — | — |
| JSON Schema export | ✓ | — | — | — |
| Ordered schema construction | ✓ | — | — | — |
| Custom error messages | ✓ | — | — | — |
| Schema extension (`extend`) | ✓ | — | — | — |
| Partial schemas (`selection`) | ✓ | ✓ | — | — |
| Cross-field validation | ✓ | — | — | ✓ |
| i18n / translator hook | ✓ | — | — | — |
| Typespec bridge | ✓ | — | — | — |
| `@type` generation | ✓ | — | — | — |
| Circular schemas (`ref`) | ✓ | — | — | — |
| Prod zero-overhead signatures | ✓ | — | ✓ | ✓ |
| Accumulating schema errors | ✓ | ✓ | ✓ | ✓ |

---

## AI Agent Reference

### Module map

| Module | Purpose |
|--------|---------|
| `Gladius` | Primary API — `import Gladius` |
| `Gladius.Signature` | Function signature validation — `use Gladius.Signature` |
| `Gladius.Typespec` | Spec → typespec AST conversion |
| `Gladius.Coercions` | Coercion functions + user registry |
| `Gladius.Registry` | Named spec registry (ETS + process-local) |
| `Gladius.Gen` | Generator inference (dev/test only) |
| `Gladius.Error` | Validation failure struct |
| `Gladius.SignatureError` | Raised on signature violation |
| `Gladius.ConformError` | Raised by `defschema name!/1` |
| `Gladius.Schema` | Runtime schema introspection — `fields/1`, `field_names/1`, etc. |
| `Gladius.Translator` | Behaviour for plugging in a custom message translator |
| `Gladius.Ecto` | Optional Ecto changeset integration |

### Complete `Gladius` function signatures

```elixir
# Primitive builders (all accept keyword constraints)
string()  | string(atom) | string(atom, kw) | string(kw)
integer() | integer(atom) | integer(atom, kw) | integer(kw)
float()   | float(atom)   | float(atom, kw)   | float(kw)
number()  | boolean() | map() | list() | any() | nil_spec()
atom()    | atom(kw)

# Combinators
all_of([conformable()])                            :: All.t()
any_of([conformable()])                            :: Any.t()
not_spec(conformable())                            :: Not.t()
maybe(conformable())                               :: Maybe.t()
list_of(conformable())                             :: ListOf.t()
cond_spec(pred_fn, if_spec)                        :: Cond.t()
cond_spec(pred_fn, if_spec, else_spec)             :: Cond.t()
coerce(Spec.t(), (term -> {:ok, t} | {:error, s})) :: Spec.t()
coerce(Spec.t(), from: source_atom)                :: Spec.t()
default(conformable(), term())                     :: Default.t()
transform(conformable(), (term() -> term()))       :: Transform.t()
ref(atom)                                          :: Ref.t()
spec(pred_or_guard_expr)                           :: Spec.t()
spec(pred_or_guard_expr, gen: StreamData.t())      :: Spec.t()

# Schema
schema(%{schema_key => conformable()})             :: Schema.t()
open_schema(%{schema_key => conformable()})        :: Schema.t()
required(atom)
optional(atom)

# Registration (macros)
defspec name_atom, spec_expr
defspec name_atom, spec_expr, type: true
defschema name_atom do spec_expr end
defschema name_atom, type: true do spec_expr end
defschema name_atom, struct: true do spec_expr end

# Validation
Gladius.conform(conformable(), term())        :: {:ok, term()} | {:error, [Error.t()]}
Gladius.conform_struct(conformable(), struct()) :: {:ok, struct()} | {:error, [Error.t()]}
Gladius.valid?(conformable(), term())         :: boolean()
Gladius.explain(conformable(), term())        :: ExplainResult.t()

# Generator (dev/test only)
Gladius.gen(conformable()) :: StreamData.t()

# Typespec
Gladius.to_typespec(conformable())             :: Macro.t()
Gladius.typespec_lossiness(conformable())      :: [{atom(), String.t()}]
Gladius.Typespec.type_ast(atom, conformable()) :: Macro.t()
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
{:string,  :integer}
{:string,  :float}
{:string,  :boolean}   true/yes/1/on → true; false/no/0/off → false
{:string,  :atom}      String.to_existing_atom — safe
{:string,  :number}    same as {:string, :float}
{:integer, :float}
{:integer, :string}
{:integer, :boolean}   0 → false, 1 → true; others → error
{:atom,    :string}    nil → error (nil is an atom in Elixir)
{:float,   :integer}   trunc/1 — truncates toward zero
{:float,   :string}
```

All coercions are idempotent.

### `default/2` semantics

```
default(spec, value)

Key absent  + optional  → value injected; spec not run
Key absent  + required  → missing-key error; default ignored
Key present             → spec validates the provided value; value ignored
Invalid provided value  → error returned; value does not rescue it
Ref pointing to Default → resolved at conform-time; default injection works
```

### `transform/2` semantics

```
transform(spec, fun)

Pipeline: raw → conform(spec) → fun.(shaped) → {:ok, result}

Validation fails    → {:error, errors} passed through; fun never called
fun.(shaped) raises → {:error, [%Error{predicate: :transform, ...}]}
fun.(shaped) ok     → {:ok, fun_return_value}

Chaining:   spec |> transform(f) |> transform(g)  — g receives output of f
With coerce: coerce runs before validate; transform runs after
With default: absent key bypasses both inner spec and transform
```

### `selection/2` semantics

```
selection(schema, field_names)

Selected field absent  → omitted from output; no error
Selected field present → validated by original spec; all coercions/transforms apply
Non-selected field     → unknown-key error (closed schema); passes through (open schema)
open? inherited        → selection of open_schema is also open
```

### `validate/2` semantics

```
validate(spec, rule_fn)  — attaches one rule
Multiple calls           → all rules appended to same %Validate{}; no nesting

rule_fn return values:
  :ok                                → passes
  {:error, :field, "msg"}            → single field error
  {:error, :base, "msg"}             → root-level error (path: [])
  {:error, [{:field, "msg"}, ...]}   → multiple errors

Rules run only when inner spec fully passes.
All rules run; errors accumulate (no short-circuit).
Exceptions caught → %Error{predicate: :validate}.
```

### `conform_struct/2` semantics

```
conform_struct(spec, struct)

Non-struct input → {:error, [%Error{message: "conform_struct/2 requires a struct..."}]}
Valid struct     → {:ok, struct(original_module, shaped_map)}
Invalid struct   → {:error, [%Gladius.Error{}]}  — same format as conform/2
```

### `defschema struct: true` behaviour

```
defschema :point, struct: true do
  schema(%{required(:x) => integer(), required(:y) => integer()})
end

Generated:
  - Module <CallerModule>.PointSchema with defstruct [:x, :y]
  - def point(data)  :: {:ok, %PointSchema{}} | {:error, [Error.t()]}
  - def point!(data) :: %PointSchema{} | raises ConformError

Struct field names derived from schema key names at compile time.
Transforms and defaults run before struct wrapping.
```

### `Gladius.Error` struct

```elixir
%Gladius.Error{
  path:             [atom() | non_neg_integer()],
  predicate:        atom() | nil,
  # :filled?, :gte?, :gt?, :lte?, :lt?, :format, :in?,
  # :min_length, :max_length, :size?, :coerce, :transform, :validate
  value:            term(),
  message:          String.t(),          # translated if translator configured
  message_key:      atom() | nil,        # predicate key for translator lookup
  message_bindings: keyword(),           # dynamic values (e.g. [min: 18])
  meta:             map()
}
```

### Type union — the `conformable()` type

```
conformable() =
  Gladius.Spec        # primitives and coerce wrappers
  | Gladius.All       # all_of
  | Gladius.Any       # any_of
  | Gladius.Not       # not_spec
  | Gladius.Maybe     # maybe
  | Gladius.Ref       # ref
  | Gladius.ListOf    # list_of
  | Gladius.Cond      # cond_spec
  | Gladius.Schema    # schema / open_schema
  | Gladius.Default   # default
  | Gladius.Transform # transform
  | Gladius.Validate  # validate
  | Gladius.Schema    # selection (returns a %Schema{})
```

### `Gladius.Registry` API

```elixir
Gladius.Registry.register(name, spec)          :: :ok
Gladius.Registry.unregister(name)              :: :ok
Gladius.Registry.fetch!(name)                  :: conformable()
Gladius.Registry.registered?(name)             :: boolean()
Gladius.Registry.all()                         :: %{atom => conformable()}
Gladius.Registry.clear()                       :: :ok  # DANGER: global

Gladius.Registry.register_local(name, spec)    :: :ok
Gladius.Registry.unregister_local(name)        :: :ok
Gladius.Registry.clear_local()                 :: :ok
```

`fetch!/1` checks process-local overlay first, then global ETS.

### `Gladius.Coercions` API

```elixir
Gladius.Coercions.register({source, target}, fun) :: :ok
Gladius.Coercions.registered()                    :: %{{atom, atom} => function()}
Gladius.Coercions.lookup(source, target)           :: function()
```

### `Gladius.Schema` introspection API

```elixir
Gladius.Schema.fields(conformable())          :: [%{name: atom(), required: boolean(), spec: conformable()}]
Gladius.Schema.required_fields(conformable()) :: [field_descriptor()]
Gladius.Schema.optional_fields(conformable()) :: [field_descriptor()]
Gladius.Schema.field_names(conformable())     :: [atom()]
Gladius.Schema.schema?(conformable())         :: boolean()
Gladius.Schema.open?(conformable())           :: boolean()
Gladius.Schema.to_json_schema(conformable())  :: map()
Gladius.Schema.to_json_schema(conformable(), title: string(), description: string(), schema_header: boolean()) :: map()
```

All functions accept any conformable wrapping a `%Schema{}` — `validate/2`, `default/2`,
`transform/2`, `maybe/1`, and `ref/1` are all unwrapped transparently.
Raises `ArgumentError` if no schema is found.
Field order reflects the order keys were passed — note that Elixir map literals
do not guarantee insertion order; use keyword-list style if order matters.

### `Gladius.Ecto` API

```elixir
# Changeset building
Gladius.Ecto.changeset(Schema.t(), map())                    :: Ecto.Changeset.t()
Gladius.Ecto.changeset(Schema.t(), map(), map() | struct())  :: Ecto.Changeset.t()

# Error traversal — handles nested changesets from Gladius.Ecto.changeset/2-3
Gladius.Ecto.traverse_errors(Ecto.Changeset.t(), (tuple() -> term())) :: map()
```

**Nested changeset type declarations (injected after `cast/4`):**
- `%Schema{}` field → `{:embed, %Ecto.Embedded{cardinality: :one, field: name}}`
- `list_of(schema)` field → `{:embed, %Ecto.Embedded{cardinality: :many, field: name}}`
- `maybe(schema)` field → not registered as embed; nil is a valid value

**Auto-seed:** `changeset/2` infers `%{}` / `[]` seeds for embed fields in `data` so `inputs_for` can find them without a `KeyError`. Pass an explicit base to `changeset/3` to override.

### `extend/2-3` semantics

```
extend(base_schema, extension_map)
extend(base_schema, extension_map, open?: boolean)

Extension key present in base → spec and required? overridden in-place; position preserved
Extension key not in base     → appended after all base keys
open?                         → inherited from base unless overridden via opts
```

### Behavioural guarantees

1. `conform/2` is the single entry point. `valid?/2` and `explain/2` call it internally.
2. Specs are plain structs — store in variables, pass to functions, compose freely.
3. `all_of/1` pipelines shaped values through each spec in order.
4. `ref/1` is lazy — resolved at `conform/2` call time, not at spec build time.
5. Schema errors accumulate — `schema/1`, `open_schema/1`, `list_of/1` never short-circuit.
6. `default/2` fallbacks are never re-validated — injected as-is when a key is absent.
7. `transform/2` never runs on invalid data and never crashes the caller — exceptions become `%Error{predicate: :transform}`.
8. `conform/2` accepts structs transparently — `Map.from_struct/1` is applied automatically. Use `conform_struct/2` to re-wrap the output.
9. `defschema struct: true` — struct fields are inferred from schema keys at compile time via `Code.eval_quoted`.
10. `signature` is prod-safe — compiles away entirely in `:prod`.
11. Coercion registry is global and permanent — `Gladius.Coercions.register/2` uses `:persistent_term`. Call once at startup.
12. `gen/1` raises in `:prod`.
13. `message:` overrides all error messages from a spec — string values bypass the translator; `{domain, msgid, bindings}` tuples are dispatched through it. `message_key` and `message_bindings` on `%Error{}` are always populated from the underlying failure regardless of override.
14. `selection/2` returns a `%Gladius.Schema{}` — all selected keys are optional; original specs (coercions, transforms, defaults, messages) are preserved. Non-selected keys in input are rejected by closed schemas.
15. `validate/2` rules run only when the inner spec fully passes. All rules run; errors accumulate. Exceptions in rules are caught and returned as `%Error{predicate: :validate}`. Multiple `validate/2` calls chain by appending to the same `%Validate{}` struct, not nesting.
16. `Gladius.Ecto.traverse_errors/2` recursively collects errors from nested changesets. Use it instead of `Ecto.Changeset.traverse_errors/2` — Ecto's built-in only recurses into declared embed/assoc fields.
17. `extend/2` never mutates the base schema — it always returns a new `%Schema{}`. Base key order is preserved; extension keys that override base keys stay at the base key's position; new extension keys are appended.
18. `Gladius.Ecto.changeset/2` auto-seeds `%{}` for single-schema embed fields and `[]` for `list_of(schema)` fields in `changeset.data`, so `inputs_for` never raises `KeyError`. `maybe(schema)` fields are not seeded — nil is a valid value.
19. `Gladius.Ecto` automatically strips Phoenix LiveView bookkeeping keys (`_unused_*`, `_persistent_id`) from params before conforming. Application code does not need to clean params manually.
20. `Gladius.Schema.fields/1` and related introspection functions return descriptors reflecting the declared schema — useful for admin UI generation, OpenAPI export, and dynamic form building.
21. `schema/1` and `open_schema/1` accept a list of `{schema_key, conformable()}` 2-tuples in addition to a map. List input preserves declaration order; map input does not guarantee order.
22. `Gladius.Schema.to_json_schema/2` output contains only JSON-safe values (string keys, no atoms except `true`/`false`/`nil`). Pass directly to `Jason.encode!/1` without a custom encoder. The `"$schema"` URI targets draft 2020-12.
