# Changelog

All notable changes to Gladius are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Gladius adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.6.0] — Unreleased

### Added

#### Ordered schema construction — list input for `schema/1` and `open_schema/1`

`schema/1` and `open_schema/1` now accept a list of `{schema_key, conformable()}`
2-tuples in addition to a map. List input preserves declaration order; map input
does not guarantee order (Elixir map literals are unordered).

```elixir
# Map — field order is NOT guaranteed
schema(%{
  required(:name)  => string(:filled?),
  required(:email) => string(:filled?),
  required(:age)   => integer(gte?: 0)
})

# List — field order IS preserved
schema([
  {required(:name),  string(:filled?)},
  {required(:email), string(:filled?)},
  {required(:age),   integer(gte?: 0)}
])
```

Both forms return an identical `%Gladius.Schema{}` — all existing functions
(`conform/2`, `extend/2`, `selection/2`, `validate/2`, `Gladius.Schema.fields/1`,
`Gladius.Ecto.changeset/2`, and `Gladius.Schema.to_json_schema/2`) work
identically on both. Fully backward compatible — existing map-based schemas
require no changes.

Use list input when field order matters: form field rendering, JSON Schema
`"required"` array order, admin UI column order, API documentation.

#### JSON Schema export — `Gladius.Schema.to_json_schema/2`

New `Gladius.Schema.to_json_schema/2` converts any Gladius spec or schema
to a JSON Schema (draft 2020-12) map. Accepts any conformable wrapping a
`%Gladius.Schema{}`, or any primitive spec.

```elixir
Gladius.Schema.to_json_schema(user_schema, title: "User")
#=> %{
#=>   "$schema"  => "https://json-schema.org/draft/2020-12/schema",
#=>   "title"    => "User",
#=>   "type"     => "object",
#=>   "properties" => %{ ... },
#=>   "required"             => ["name", "age"],
#=>   "additionalProperties" => false
#=> }
```

Options: `:title`, `:description`, `:schema_header` (default: `true`).

**Spec mapping highlights:**
- String constraints → `minLength`, `maxLength`, `pattern`
- Integer/float constraints → `minimum`, `exclusiveMinimum`, `maximum`, `exclusiveMaximum`
- `atom(in?: [:a, :b])` → `{"enum": ["a", "b"]}` (atom values stringified)
- `maybe(inner)` → `{"oneOf": [{"type": "null"}, inner]}`
- `default(inner, val)` → inner schema + `"default": val`
- `transform/2`, `coerce/2`, `validate/2` → transparent (inner spec emitted)
- `spec(pred)` → `{"description": "custom predicate — no JSON Schema equivalent"}`
- Nested schemas → inlined (no `$ref` / `$defs`)

Output contains only JSON-safe values — pass directly to `Jason.encode!/1`.

The new module `Gladius.JsonSchema` implements the conversion. `Gladius.Schema.to_json_schema/2` is the public entry point.

### Changed

- `schema/1` and `open_schema/1` — guard widened from `when is_map(key_map)` to
  `when is_map(key_map) or is_list(key_map)`. Fully backward compatible.

---

## [0.5.0] — Unreleased

### Added

#### Schema introspection — `Gladius.Schema`

New module `Gladius.Schema` with runtime introspection functions. All functions
accept any conformable wrapping a `%Gladius.Schema{}` — `validate/2`, `default/2`,
`transform/2`, `maybe/1`, and `ref/1` are unwrapped transparently.

```elixir
import Gladius

s = schema(%{
  required(:name)  => string(:filled?),
  required(:email) => string(:filled?, format: ~r/@/),
  optional(:role)  => atom(in?: [:admin, :user])
})

Gladius.Schema.fields(s)
#=> [%{name: :name, required: true, spec: ...},
#=>  %{name: :email, required: true, spec: ...},
#=>  %{name: :role, required: false, spec: ...}]

Gladius.Schema.field_names(s)      #=> [:name, :email, :role]
Gladius.Schema.required_fields(s)  #=> [%{name: :name, ...}, %{name: :email, ...}]
Gladius.Schema.optional_fields(s)  #=> [%{name: :role, ...}]
Gladius.Schema.schema?(s)          #=> true
Gladius.Schema.open?(s)            #=> false
```

Useful for admin UI generation, OpenAPI/JSON Schema export, and dynamic form building.

### Fixed

#### `Gladius.Ecto` — battle-tested against a real Phoenix LiveView app

A full integration test against Phoenix 1.8 / LiveView 1.1 / phoenix_ecto 4.7
revealed and fixed several issues. All fixes are in `Gladius.Ecto` — application
code does not change.

**`_unused_*` / `_persistent_id` params caused `CastError`**

Phoenix LiveView injects internal bookkeeping keys into form params:
`_unused_<field>` (tracks touched state), `_persistent_id` (list embed identity),
and `_target` (which field triggered `phx-change`). After partial atomization by
`Gladius.Ecto`, these produced mixed atom/string key maps that Ecto rejected with
`CastError`. `Gladius.Ecto.changeset/2-3` now strips these keys automatically
before conforming. Application code does not need a `clean_params` helper.

**Auto-seed for embed fields**

`changeset/2` (no explicit base) now infers empty seeds for embed fields:
- `%Schema{}` fields → `%{}` in `changeset.data`
- `list_of(schema)` fields → `[]` in `changeset.data`
- `maybe(schema)` fields → not seeded (nil is a valid value)

Without seeds, `phoenix_ecto`'s `inputs_for` raises `KeyError` when looking up
the embed field in `changeset.data`. Application code no longer needs to pass
`%{address: %{}, tags: []}` as the base argument.

**`{:embed, %Ecto.Embedded{}}` not `{:parameterized, Ecto.Embedded, ...}`**

The embed type injected into `changeset.types` was using the wrong tag. `phoenix_ecto`'s
`inputs_for` matches on `{:embed, struct}` or `{:assoc, struct}` — not on
`{:parameterized, Ecto.Embedded, struct}`. Fixed to use the correct tag.

**`apply_nested` always populates `changes` for embed fields**

Nested changesets are now always placed in `changeset.changes` (not just when params
include the field). This ensures `inputs_for` always finds an `%Ecto.Changeset{}`
in `changes` rather than falling back to the plain `%{}` in `data`, which caused
`Ecto.Changeset.change/2` to raise `FunctionClauseError`.

**`force_change` instead of `put_change` for embed fields**

`Ecto.Changeset.put_change/3` silently skips when the new value equals the
existing data value (e.g. `put_change(cs, :tags, [])` when `cs.data.tags == []`).
This caused empty list embeds to disappear from `changes`. `force_change/3` is
now used for all embed fields.

**`maybe(schema)` fields handled correctly**

A spec wrapped in `maybe/1` is no longer auto-seeded or always put in `changes`.
When the field is absent from params, it is omitted — nil is a valid value for
`maybe`-wrapped fields and no sub-form should be rendered.

### Documentation

Added a full Phoenix LiveView worked example to the Ecto Integration section,
documenting five required patterns:

1. **Schemas as functions** — never `@module_attr` (anonymous functions are not escapable)
2. **`as:` on the form** — `<.form for={@form} as={:user}>` (required for schemaless changesets)
3. **`to_form/2` in assigns** — store `%Phoenix.HTML.Form{}`, not a raw changeset
4. **`_target`-based error filtering** — show errors only for the touched field during `phx-change`
5. **Params are cleaned automatically** — no application-level param stripping needed

---

## [0.4.0] — Unreleased

### Added

#### Schema extension — `extend/2` and `extend/3`

`extend/2` builds a new `%Schema{}` from an existing one by merging in additional
or overriding keys. No structs were added — the output is a plain `%Schema{}`.

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

Semantics:
- Extension keys that override a base key replace the spec and `required?` flag
  **in-place** — the key stays at its original position in the schema
- New extension keys are appended after all base keys
- `open?` is inherited from the base schema; override with `extend/3` `open:` opt
- Does not mutate the base — always returns a new `%Schema{}`
- `extend/2` can be chained — the result of `extend` can be extended again
- All coercions, transforms, defaults, and custom messages on the original spec
  are replaced when a key is overridden (the extension key's spec is used as-is)

#### Ecto nested embed support

`Gladius.Ecto.changeset/2-3` now builds proper nested `%Ecto.Changeset{}` values
for fields whose spec is (or wraps) a `%Gladius.Schema{}` or `list_of(schema(...))`,
and registers those fields with Ecto embedded types in `cs.types`. This makes
nested changeset fields compatible with Phoenix `inputs_for/4` in LiveView.

**Type declarations injected after cast:**

- `%Schema{}` field → `{:parameterized, Ecto.Embedded, %Ecto.Embedded{cardinality: :one, field: name}}`
- `list_of(schema)` field → `{:parameterized, Ecto.Embedded, %Ecto.Embedded{cardinality: :many, field: name}}`

Embed types are injected **after** `Ecto.Changeset.cast/4` (which uses `:map` for
safety) to avoid `Ecto.Type.cast_fun/1` raising on unknown parameterized types.

**List of embedded schemas:**

```elixir
schema(%{
  required(:name) => string(:filled?),
  required(:tags) => list_of(schema(%{required(:name) => string(:filled?)}))
})

cs = Gladius.Ecto.changeset(s, params)
cs.changes.tags  #=> [%Ecto.Changeset{}, ...]
cs.types[:tags]  #=> {:parameterized, Ecto.Embedded, %Ecto.Embedded{cardinality: :many}}
```

#### `Gladius.Ecto.traverse_errors/2`

New public function that recursively collects errors from Gladius-built nested
changesets. Use this instead of `Ecto.Changeset.traverse_errors/2` — Ecto's
built-in only recurses into fields whose type is a declared embed or association,
and does not find errors in Gladius nested changesets.

```elixir
Gladius.Ecto.traverse_errors(cs, fn {msg, _} -> msg end)
#=> %{name: ["can't be blank"], address: %{zip: ["must be exactly 5 characters"]}}
#   tags: [%{}, %{name: ["must be filled"]}]   # list form for many embeds
```

### Fixed

- `Gladius.Ecto` — string-keyed params inside nested maps and lists now atomize
  recursively. Previously `%{"address" => %{"zip" => "bad"}}` and
  `[%{"name" => "x"}]` kept string keys in nested positions, causing Gladius
  schemas (which use atom keys) to report all nested required fields as missing.

### Changed

- `Gladius.Ecto.changeset/2-3` — nested schema fields now produce `%Ecto.Changeset{}`
  values in `changes` instead of plain maps, and embed type entries in `types`.
  Existing code that accessed `cs.changes.nested_field` as a plain map will need
  to access it as a changeset: `cs.changes.nested_field.changes`.

---

## [0.3.0] — Unreleased

### Added

#### Custom error messages — `message:` option

Every spec builder and combinator now accepts a `message:` option that overrides
the generated error string for any failure. Accepts two forms:

- **String** — returned as-is, bypasses any configured translator.
- **Tuple `{domain, msgid, bindings}`** — dispatched through a translator if
  configured; falls back to `msgid` when no translator is set.

```elixir
string(:filled?, message: "can't be blank")
integer(gte?: 18, message: {"errors", "must be at least %{min}", [min: 18]})
coerce(integer(), from: :string, message: "must be a valid number")
transform(string(), &String.trim/1, message: "normalization failed")
maybe(string(:filled?), message: "must be a non-empty string or nil")
```

Supported on: all primitive builders (`string`, `integer`, `float`, `number`,
`boolean`, `atom`, `map`, `list`, `any`), `coerce/2`, `transform/2`, `maybe/1`,
`default/2`, `all_of/1`, `any_of/1`, `not_spec/1`, `schema/1`, `open_schema/1`,
and the `spec/1` macro.

#### i18n translator hook — `Gladius.Translator`

New `Gladius.Translator` behaviour for plugging in a custom message translator.
Configure via application env:

```elixir
config :gladius, translator: MyApp.GladiusTranslator
```

When configured, all built-in error messages pass through
`translator.translate(domain, msgid, bindings)`. Plain string `message:` overrides
bypass the translator. Designed to be compatible with Gettext, LLM-based
translation, or any custom backend.

#### Structured error metadata — `message_key` and `message_bindings`

`%Gladius.Error{}` gains two new fields populated by every built-in error:

- `message_key :: atom() | nil` — the predicate that failed (`:gte?`, `:filled?`,
  `:type?`, `:coerce`, `:transform`, `:validate`, etc.)
- `message_bindings :: keyword()` — dynamic values used in the message
  (e.g. `[min: 18]` for a `gte?` failure, `[format: ~r/@/]` for a format failure)

These fields are always populated regardless of whether `message:` is set,
allowing translators and custom renderers to work from structured data.

#### Partial schemas — `selection/2`

`selection/2` takes an existing `%Gladius.Schema{}` and a list of field names,
returning a new schema with only those fields — all made optional. The primary
use case is PATCH endpoints.

```elixir
patch = selection(user_schema, [:name, :email, :age, :role])

Gladius.conform(patch, %{})              #=> {:ok, %{}}
Gladius.conform(patch, %{name: "Mark"}) #=> {:ok, %{name: "Mark"}}
Gladius.conform(patch, %{age: -1})      #=> {:error, [...]}
```

- Selected fields absent → omitted from output, no error
- Selected fields present → validated by their original spec; all coercions,
  transforms, defaults, and custom messages apply
- Non-selected fields in input → rejected by closed schemas (prevents mass-assignment)
- `open?` is inherited from the source schema

#### Cross-field validation — `validate/2`

`validate/2` attaches validation rules that run only after the inner spec fully
passes. Multiple calls chain by appending rules to the same `%Gladius.Validate{}`
struct — they do not nest.

```elixir
schema(%{
  required(:start_date) => string(:filled?),
  required(:end_date)   => string(:filled?)
})
|> validate(fn %{start_date: s, end_date: e} ->
  if e >= s, do: :ok, else: {:error, :end_date, "must be on or after start date"}
end)
|> validate(&check_business_hours/1)
```

Rule return values: `:ok`, `{:error, field, message}`, `{:error, :base, message}`,
`{:error, [{field, message}]}`. Exceptions are caught and returned as
`%Error{predicate: :validate}`. All rules run; errors accumulate.

#### Ecto nested changeset support + `Gladius.Ecto.traverse_errors/2`

`Gladius.Ecto.changeset/2-3` now builds proper nested `%Ecto.Changeset{}`
structs for fields whose spec is (or wraps) a `%Gladius.Schema{}`. Nested
errors appear in the nested changeset rather than the parent's `errors` list,
making them compatible with Phoenix `inputs_for` and deep error inspection.

New `Gladius.Ecto.traverse_errors/2` recursively collects errors from nested
changesets. Use it instead of `Ecto.Changeset.traverse_errors/2` — Ecto's
built-in only recurses into declared embed/assoc typed fields.

```elixir
cs = Gladius.Ecto.changeset(user_schema, params)
Gladius.Ecto.traverse_errors(cs, fn {msg, _} -> msg end)
#=> %{name: ["can't be blank"], address: %{zip: ["must be exactly 5 characters"]}}
```

Also fixed: string-keyed nested params are now deep-atomized before conforming,
so Phoenix-style `%{"address" => %{"zip" => "bad"}}` params work correctly.

### Changed

- `%Gladius.Error{}` — two new fields: `message_key :: atom() | nil` and
  `message_bindings :: keyword()`. Existing fields unchanged; new fields default
  to `nil` and `[]` respectively, so existing pattern matches continue to work.
- `%Gladius.Spec{}`, `%Gladius.All{}`, `%Gladius.Any{}`, `%Gladius.Not{}`,
  `%Gladius.Maybe{}`, `%Gladius.Schema{}`, `%Gladius.Default{}`,
  `%Gladius.Transform{}` — new `message` field (defaults to `nil`). Existing
  struct literals without `message:` continue to work.
- `conformable()` type union extended with `Gladius.Validate`.
- `Gladius.Gen.gen/1` and `Gladius.Typespec.to_typespec/1` handle `%Validate{}`
  by delegating to the inner spec.
- `Gladius.Ecto.changeset/2-3` — nested schema fields produce nested changesets
  rather than plain map changes. `cs.changes.nested_field` is now an
  `%Ecto.Changeset{}` rather than a raw map for schema-typed fields.

---

## [0.2.0] — Unreleased

### Added

#### Default values — `default/2`

New combinator that injects a fallback when an optional schema key is absent.
The fallback is injected as-is — the inner spec only runs when the key is present.

```elixir
schema(%{
  required(:name)    => string(:filled?),
  optional(:role)    => default(atom(in?: [:admin, :user]), :user),
  optional(:retries) => default(integer(gte?: 0), 3)
})
```

- Absent key → fallback injected; inner spec not run
- Present key → inner spec validates the provided value normally
- Invalid provided value → error returned; fallback does not rescue it
- Required key → `default/2` has no effect on absence
- Composes with `ref/1` — a ref pointing to a `%Default{}` resolves correctly

#### Post-validation transforms — `transform/2`

New combinator that applies a function to the shaped value after validation
succeeds. Never runs on invalid data. Exceptions from the transform function
are caught and surfaced as `%Gladius.Error{predicate: :transform}`.

```elixir
schema(%{
  required(:name)  => transform(string(:filled?), &String.trim/1),
  required(:email) => transform(string(:filled?, format: ~r/@/), &String.downcase/1)
})

# Chainable via pipe — transform/2 is spec-first:
string(:filled?)
|> transform(&String.trim/1)
|> transform(&String.downcase/1)
```

- Runs after coercion and validation: `raw → coerce → validate → transform → {:ok, result}`
- Absent optional keys with `default(transform(...), val)` bypass the transform
- `gen/1` and `to_typespec/1` delegate to the inner spec

#### Struct validation

`conform/2` now accepts any Elixir struct as input. The struct is converted
to a plain map via `Map.from_struct/1` before dispatch. Output is a plain map.

```elixir
Gladius.conform(schema, %User{name: "Mark", email: "mark@x.com"})
#=> {:ok, %{name: "Mark", email: "mark@x.com"}}
```

`conform_struct/2` validates a struct and re-wraps the shaped output in the
original struct type on success.

```elixir
Gladius.conform_struct(schema, %User{name: "  Mark  ", age: "33"})
#=> {:ok, %User{name: "Mark", age: 33}}
```

`defschema` now accepts a `struct: true` option that defines both the
validator functions and a matching output struct in a single declaration.
The struct module is named `<CallerModule>.<PascalName>Schema`.

```elixir
defmodule MyApp.Schemas do
  import Gladius

  defschema :point, struct: true do
    schema(%{required(:x) => integer(), required(:y) => integer()})
  end
end

MyApp.Schemas.point(%{x: 3, y: 4})
#=> {:ok, %MyApp.Schemas.PointSchema{x: 3, y: 4}}
```

#### Ecto integration — `Gladius.Ecto`

New optional module `Gladius.Ecto` (guarded by
`Code.ensure_loaded?(Ecto.Changeset)`) that converts a Gladius schema into an
`Ecto.Changeset`. Requires `{:ecto, "~> 3.0"}` in the consuming application's
dependencies — Gladius does not pull it in transitively.

```elixir
# Schemaless (create workflows)
Gladius.Ecto.changeset(gladius_schema, params)

# Schema-aware (update workflows)
Gladius.Ecto.changeset(gladius_schema, params, %User{})
```

- String-keyed params (the Phoenix default) are normalised to atom keys
  before conforming — no manual atomisation step needed
- On `{:ok, shaped}` — changeset is valid; `changes` contains the fully
  shaped output with coercions, transforms, and defaults applied
- On `{:error, errors}` — changeset is invalid; each `%Gladius.Error{}` is
  mapped to `add_error/3` keyed on the last path segment
  (`%Error{path: [:address, :zip]}` → `add_error(cs, :zip, ...)`)
- Returns a plain `%Ecto.Changeset{}` — pipe Ecto validators after as normal

### Changed

- `conformable()` type union extended with `Gladius.Default` and
  `Gladius.Transform`
- `Gladius.Gen.gen/1` and `Gladius.Typespec.to_typespec/1` now handle
  `%Default{}` and `%Transform{}` by delegating to their inner spec

---

## [0.1.0] — unreleased

First public release.

### Spec algebra

- **Primitive builders** — `string/0-2`, `integer/0-2`, `float/0-2`,
  `number/0`, `boolean/0`, `atom/0-1`, `map/0`, `list/0-2`, `any/0`,
  `nil_spec/0`
- **Named constraints** — `filled?`, `gt?`, `gte?`, `lt?`, `lte?`,
  `min_length:`, `max_length:`, `size?:`, `format:`, `in?` — introspectable
  and generator-aware
- **Arbitrary predicates** — `spec/1` for cases named constraints can't cover
- **Combinators** — `all_of/1` (intersection), `any_of/1` (union),
  `not_spec/1` (complement), `maybe/1` (nullable), `list_of/1` (typed list),
  `cond_spec/2-3` (conditional branching)
- **Coercion** — `coerce/2` wraps any spec with a pre-processing step;
  runs before type-checking and constraints
- **Schemas** — `schema/1` (closed) and `open_schema/1`; errors accumulated
  across all keys in one pass, no short-circuiting

### Registry

- `defspec/2-3` — registers a named spec globally in ETS; accessible from
  any process via `ref/1`
- `defschema/2-3` — generates `name/1` and `name!/1` validator functions in
  the calling module
- `ref/1` — lazy registry reference; resolved at conform-time, enabling
  circular schemas
- Process-local overlay (`register_local/2`) for async-safe test isolation

### Coercion pipeline

- **Built-in source types** — `:string`, `:integer`, `:atom`, `:float`
- **Built-in pairs** — 11 source→target coercions: string→integer/float/
  boolean/atom/number, integer→float/string/boolean, atom→string,
  float→integer/string
- **User-extensible registry** — `Gladius.Coercions.register/2` backed by
  `:persistent_term`; user coercions take precedence over built-ins

### Generator inference

- `gen/1` — infers a `StreamData` generator from any spec
- Supports all primitives, combinators, and schemas
- Bounds-over-filters strategy for constrained numeric/string specs
  (avoids `FilterTooNarrowError`)
- Custom generators via `spec(pred, gen: my_generator)`

### Function signature checking

- `use Gladius.Signature` — opt-in per module
- `signature args: [...], ret: ..., fn: ...` — declares arg specs, return
  spec, and optional relationship constraint
- Validates and coerces all args before the impl runs; coerced values are
  forwarded (not the originals)
- Multi-clause functions: declare `signature` once before the first clause
- **Path errors** — all failing args reported in one raise; each error path
  prefixed with `{:arg, N}` so nested schema field failures render as
  `argument[0][:email]: must be filled`
- Zero overhead in `:prod` — signatures compile away entirely

### Typespec bridge

- `to_typespec/1` — converts any Gladius spec to quoted Elixir typespec AST
- `typespec_lossiness/1` — reports constraints that have no typespec
  equivalent (string format, negation, intersection, etc.)
- `type_ast/2` — generates `@type name :: type` declaration AST for macro
  injection
- `defspec :name, spec, type: true` — auto-generates `@type` with
  compile-time lossiness warnings
- `defschema :name, type: true do ... end` — same for schemas
- Integer constraint specialisation: `gte?: 0` → `non_neg_integer()`,
  `gt?: 0` → `pos_integer()`, `gte?: a, lte?: b` → `a..b`

---

[0.6.0]: https://github.com/Xs-and-10s/gladius/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Xs-and-10s/gladius/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/Xs-and-10s/gladius/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Xs-and-10s/gladius/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Xs-and-10s/gladius/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Xs-and-10s/gladius/releases/tag/v0.1.0
