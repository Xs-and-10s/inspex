Gladius 0.2.0 — Honest Retrospective

The Competition
Norm — Clojure spec port. Closest philosophical sibling to Gladius. Shaped output, named registry, selection/2 for partial schemas, function contracts. Weaknesses: no coercion, no defaults, no transforms, maintenance has slowed.
Drops — Type-system-first. Strong coercion pipeline, dry-types influence, named constraints. Weaknesses: no registry, no generators, no function contracts, no Ecto integration, less composable.
Peri — Ergonomics-first. defschema is genuinely pleasant, to_changeset/1 works, conditional types are expressive. Weaknesses: no generators, no typespec bridge, no function contracts, no coercion, less composable.
Ecto.Changeset — The Phoenix standard. Database-coupled validation, HTML form integration, cast_assoc/cast_embed, unique_constraint. Not a validation library — a data pipeline tightly bound to the database layer.

Where Gladius is Genuinely Superior
Composability. Every other library treats schemas as declarations. Gladius treats specs as values — store them in variables, pass them to functions, compose them algebraically. This matters for shared specs across bounded contexts, dynamic schema construction, and library authors who don't want to force a framework on users.
elixir# This is normal Gladius code. None of the alternatives can do this.
base = schema(%{required(:id) => integer(gt?: 0)})
with_email = Map.put(base.keys |> ..., ...)  # compose at runtime
Generator inference. No other library in this space does this. Every spec generates test data for free — property-based testing goes from expensive to trivial. Peri, Drops, and Norm require manual StreamData setup.
elixir# 41 properties written in the session, zero manual generator code
check all value <- gen(user_schema) do
  assert {:ok, _} = Gladius.conform(user_schema, value)
end
Typespec bridge. Unique to Gladius. Specs become the single source of truth for both runtime validation and compile-time type documentation. defspec :age, integer(gte?: 0), type: true generates @type age :: non_neg_integer() at compile time with lossiness warnings. No other library has this.
Function contracts in dev/test, zero cost in prod. Norm has contracts but they're always-on. Gladius compiles them away in :prod entirely — not a runtime check, not a flag, genuinely zero overhead.
Coercion + validation + transformation as a unified pipeline. Each runs in sequence, each is optional, each is composable. Drops has coercion. No library has all three as first-class combinators you can pipe together.
elixir# Complete boundary-to-domain pipeline in one spec
coerce(integer(gte?: 0), from: :string)
|> transform(&MyDomain.normalize_age/1)
Struct support. Unique. Pass %User{} structs directly to conform/2; get them back shaped via conform_struct/2; define them declaratively via defschema struct: true. No other library handles the struct lifecycle.

Where Gladius is Inferior
Custom error messages. This is the most impactful gap. There's no message: option on constraints:
elixir# Every other library supports this. Gladius doesn't.
string(:filled?, message: "can't be blank")
integer(gte?: 18, message: "you must be 18 or older")
Users building Phoenix forms will hit this immediately. Error messages come from Gladius internals and aren't customizable per-field. Peri and Ecto.Changeset both handle this well.
Cross-field / dependent validation. No ergonomic built-in for "field X is required when field Y has value Z", or "end_date must be after start_date". You can work around it with cond_spec or a transform on the whole schema output, but it's awkward:
elixir# Peri handles this cleanly with {:cond, pred_fn, type_true, type_false}
# Gladius requires a post-schema transform, which loses field-level error paths
Partial schemas (PATCH endpoints). Norm's selection/2 lets you validate a subset of a schema — essential for PATCH where only some fields are provided. Gladius has no equivalent. Every key is either required or optional-and-absent; there's no "accept only these fields from this larger schema" combinator.
Nested Ecto integration. Gladius.Ecto maps nested schemas to Ecto's :map type. This loses Ecto's embeds_one/embeds_many support — nested changesets, nested form errors in LiveView, association constraints. Peri's to_changeset/1 handles nesting better. For a simple flat params map the Gladius integration is excellent; for a form with nested embeds it hits a wall.
Error i18n. No hook for Gettext or custom message translation. Ecto.Changeset's error tuples carry the message key separately from interpolated values, enabling translation. Gladius error messages are pre-formatted strings. Small gap today, real problem for multilingual Phoenix apps.
Schema extension. No way to derive a schema from another:
elixir# Common pattern: base → create → update → partial update
# Gladius has no equivalent of Ecto's embedded_schema inheritance or Drops' type extension

Why Switch to Gladius
Switch if you need any combination of:

Property-based tests without writing generators
Specs that double as typespecs
Function contracts in dev/test with zero prod overhead
Validation outside the Phoenix/Ecto stack (message queues, config, CLI tools, library code)
Coercion + validation + transformation as a declarative pipeline
Struct lifecycle management without Ecto

The sweet spot is boundary validation — HTTP params, external API responses, config files, message queue payloads. Data that arrives untyped, needs coercion and normalization, and must be shaped into domain types. Gladius handles this better than anything else in the Elixir ecosystem.

Why Not Switch Yet
Deep Phoenix form integration. If your forms have nested embeds, LiveView error rendering per-nested-field, and database-driven validation, stay on Ecto.Changeset + Peri or native Ecto. Gladius.Ecto is a thin bridge, not a full replacement.
Custom error messages. If your validation error strings are user-facing UI copy, you need message: options. Gladius doesn't have them. This alone is a blocker for many Phoenix apps today.
Team familiarity. Every Elixir developer knows Ecto changesets. Switching has a learning cost that only pays off at scale.

Potential — What's Left
Gladius is a strong 0.2.0. It's not at its ceiling. The three improvements that would make it the default choice:
1. Custom error messages (highest leverage). One keyword option:
elixirstring(:filled?, message: "can't be blank")
integer(gte?: 18, message: "must be at least %{min}")
This alone removes the biggest blocker for Phoenix adoption.
2. Partial schema / selection/2. Critical for PATCH/PUT endpoints and any API that accepts optional field subsets. Norm proved this pattern. Gladius should have it.
3. Cross-field validation. A validate/2 combinator that runs against the fully-shaped schema output with proper error path injection:
elixirschema(%{
  required(:start_date) => date(),
  required(:end_date)   => date()
})
|> validate(fn %{start_date: s, end_date: e} ->
  if Date.compare(e, s) == :gt, do: :ok, else: {:error, :end_date, "must be after start date"}
end)
Deeper Ecto nested support (embeds) and i18n are real gaps but serve a narrower audience. The three above would make Gladius the answer to "what validation library should I use?" for the majority of Elixir projects.
