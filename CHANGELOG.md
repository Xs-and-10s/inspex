# Changelog

All notable changes to Gladius are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Gladius adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/Xs-and-10s/gladius/releases/tag/v0.1.0
