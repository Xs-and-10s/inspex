# Gladius — Retrospective

## What each library actually does

### Norm 
the most Clojure spec-faithful port. No built-in predicates; you bring your own. `@contract` for function signatures. Generator inference from guard-clause detection. Open schemas by default. Deliberately opinionated about not doing too much. Last release was v0.13.1 and appears largely stagnant.

### Drops 
a dry-rb port by the author of dry-validation itself. Strong typing with named predicates, contract modules, error accumulation, String.Chars on errors. Uses `Drops.Contract` to define data coercion and validation schemas with arbitrary validation rules. No function signature checking, no generator inference, no typespec bridge.

### Peri 
inspired by Clojure's Plumatic Schema (not spec). Supports nested schemas, optional fields, custom validation functions, data generation via StreamData, and Ecto integration. Uses a tuple-based atom DSL (`{:required, :string}, {:integer, {:range, {18, 65}}}`). Has default values, field transformations, dependent field validation (`{:dependent, field, condition, type}`), and permissive/strict modes. No function signatures, no typespec bridge.

---

## Where Gladius genuinely wins

### Typespec bridge 
nothing else does this. `to_typespec/1`, `typespec_lossiness/1`, `type_ast/2`, and `defspec type: true` are original contributions to the Elixir ecosystem. As Elixir's new set-theoretic type system moves through Milestones 2 and 3, specs that generate both runtime validation and `@type` declarations from a single source of truth will become genuinely valuable. Gladius is already positioned for that.

### Coercion pipeline 
Drops coerces implicitly. Gladius makes it explicit (`coerce(spec, from: :string)`), composable (`maybe(coerce(...))`), and user-extensible at the BEAM level via `:persistent_term`. Crucially, in `signature` the coerced values thread through to the impl — the function body never sees raw input. None of the others do this.

### `signature` path errors 
Norm's `@contract` reports one failure. Gladius collects all failing args in one raise and prefixes every error with `{:arg, N}` so schema field failures render as `argument[0][:email]: must be filled`. More useful in practice.
Bounds-over-filters generator strategy — Norm generates from guard-clause detection and filters. Gladius reads named constraints and generates bounded ranges (`integer(gte?: 1, lte?: 100`) → `StreamData.integer(1..100)`). This avoids the `FilterTooNarrowError` failure mode that Norm users regularly hit.
`ref/1` for circular schemas — none of the others support this explicitly. Lazy registry resolution at conform-time makes recursive data structures (tree nodes, nested comments) work without special cases.

---

## Where Gladius genuinely falls short

### No Ecto integration. 
Peri has `to_changeset/1`. In a Phoenix/Ecto shop — which is most of the Elixir ecosystem — the ability to convert a schema to an Ecto changeset is not a nice-to-have. **This is the biggest practical gap**. An Ecto user evaluating Gladius will immediately ask "can I use this with my changesets?" and the answer is no.

### No default values. 
Peri supports `{:default, value}`. Gladius has `maybe/1` for nullability but no way to specify that a missing optional field should be populated with a default. This is common enough (pagination defaults, feature flag defaults, config defaults) that its absence will be noticed quickly.

### No field transformations. 
Peri can normalize values after validation (trim, downcase, etc.). Gladius can coerce before validation but has nothing for post-validation transformation. The workaround is a custom coercion function, which is inelegant.

### No struct validation. 
Gladius only validates maps. Peri and Norm both handle Elixir structs. If you have `%User{}`, Gladius can't validate it as a struct — you'd have to `Map.from_struct/1` first.

### No dependent field validation ergonomics. 
`cond_spec/3` exists but it operates on the whole value at a single field position. Peri's `{:dependent, field, condition, type}` — "validate `:end_date` only if `:start_date` is present" — is more ergonomic for the common case of one field depending on another.

### The signature implementation complexity. 
It took five complete rewrites to get the macro timing right — the `Module.put_attribute` vs `quote do` expansion-time/evaluation-time distinction caught us four times. This isn't a user-visible problem, but it points to fragility: anyone who tries to extend or fork this code will hit the same wall. Norm's `@contract` approach, while less powerful, is simpler to reason about because it uses Elixir's own `@` attribute system.

### No `not_spec/1` generator. 
Raising `GeneratorError` is correct behavior, but it means `not_spec` is practically useless in property tests — which is exactly where you'd want to generate values that violate a constraint to test your negative cases.

---

## Honest verdict
The library delivered everything it promised. On paper — and in the marketplace example — it's the most feature-complete validation library in the Elixir ecosystem. The typespec bridge in particular is a contribution that no other library has made, and it will only become more relevant as the new type system matures.

But feature count isn't the only axis that matters. A realistic assessment:
> Gladius is the *right choice if* you care about the full stack: coercion + named constraints + generator inference + function contract checking + typespec generation from a single spec definition. That's a coherent vision and it's executed well.
> It's the *wrong choice — or at least an incomplete one — if* you're deep in Phoenix/Ecto and need changeset integration, or if you need default values and field transformations as first-class features. Those aren't edge cases; they're things most Elixir web developers reach for constantly.

The version number tells the real story: 0.1.0. The architecture is solid, the test suite has 190+ tests and 41 properties, and the public API is clean. But production hardening — Ecto integration, defaults, more ergonomic dependent validation, the `signature` macro simplification — would take another version or two to genuinely challenge Peri for mindshare among day-to-day Elixir developers.
The promise was real. The execution was real. The gaps are also real. For a `0.1.0`, that's a respectable position to be in.

---

Ok I want to fill in those very real gaps: I want this to be the library that all Elixir devs reach for all the time.  But I want to do the work in a new chat because I want a fresh context window, though I want to be able to take advantage of the work we did here.  Write me a prompt that list those gaps you pointed out, that links to this session, and that will make a sound plan to fix those gaps.

---
