Gladius 0.3.0 — Retrospective

Where Gladius is Genuinely Superior
Composability is still unmatched. Specs are plain values. Every other library treats schemas as declarations; Gladius treats them as data. selection/2 is a direct example — you can't build that on top of Peri or Drops without reimplementing their internals.
The validation pipeline is the most complete. No other library in this space has coerce → validate → transform as first-class, composable, pipeable steps. Drops has coercion. Peri has validation. Nobody else has all three plus cross-field rules.
validate/2 is a meaningful differentiator. Peri has {:cond, pred, type_a, type_b} for conditional types, but not accumulated cross-field rules. Ecto has validate_change/3 but it runs in changeset pipeline context, not against shaped domain data. Gladius's approach is cleaner — rules receive the already-shaped output, so transforms and coercions have already run.
Generator inference + function contracts + typespec bridge. Still unique. Nobody else does all three.
selection/2 is better than Norm's selection/2. Norm's version requires you to know which keys are required vs optional ahead of time. Gladius flattens everything to optional automatically, which is exactly right for PATCH semantics.
Error quality jumped significantly. message_key + message_bindings on every %Error{} means Gladius errors are now structured data, not just strings. The i18n story is real even without an LLM translator.

Where Gladius is Still Inferior or Lacking
Schema extension is the most impactful remaining gap. Every real application has this pattern:
elixir# What users want to write but can't:
create_schema = schema(%{
  required(:name)  => string(:filled?),
  required(:email) => ref(:email),
  required(:age)   => integer(gte?: 0)
})

update_schema = extend(create_schema, %{
  optional(:role) => atom(in?: [:admin, :user])
})

patch_schema = selection(update_schema, [:name, :email, :age, :role])
Right now update_schema requires re-declaring all of create_schema's keys. This is not just ergonomic friction — it creates maintenance debt. A change to create_schema silently breaks update_schema. Peri doesn't have this either, but Ecto handles it implicitly through module inheritance and cast/4 field lists.
inputs_for LiveView compatibility is broken for nested schemas. This is the sharpest practical edge. Phoenix's inputs_for/4 helper in LiveView expects nested changesets to be stored under an Ecto embed or association type. Our %Ecto.Changeset{} in changes.address is correct data but wrong type declaration — it's stored as :map so Phoenix's form builder ignores it. The result: inputs_for silently produces nothing. This affects every developer who reaches for Gladius in a Phoenix app with nested forms.
No cast_embed semantics. Related to the above. Ecto's cast_embed/3 creates a linked changeset that the form builder understands. Our Gladius.Ecto.changeset/2 produces the right data structure but not the right Ecto metadata. The gap is Ecto.Embedded — a private Ecto struct that declares the embed relationship.
Missing required-field errors in Ecto changeset for nested schemas. If a required nested field is absent, Gladius produces %Error{path: [:address]} at the outer level. This gets routed to the parent changeset correctly. But if the nested map is present and missing inner required fields, those errors live in the nested changeset's errors list — not accessible to Phoenix form helpers that call Ecto.Changeset.traverse_errors/2.
No cast_assoc equivalent. For lists of embedded schemas (e.g. a user with many addresses), there's no list_of(schema(...)) → Ecto changeset path that produces a list of nested changesets.
message_key as atom isn't a stable Gettext key. :gte? is an Elixir atom. Gettext msgids are strings like "must be >= %{min}". The tuple form {domain, msgid, bindings} partially solves this, but there's no built-in catalogue — developers have to write the Gettext .po entries manually from scratch. Peri doesn't have i18n either, but Ecto's error format is well-documented and the Phoenix ecosystem has years of Gettext integration built around it.
Schema introspection is limited. You can't ask a schema "what fields do you have?" in a structured way without pattern-matching on %Schema{keys: keys}. There's no Gladius.Schema.fields/1 or similar. This matters for metaprogramming, admin UI generation, and documentation tooling.

Compared to Each Library Specifically
vs. Norm: Gladius wins on almost every axis now. Norm's one remaining advantage is that it's been production-tested for longer and the Clojure spec philosophy is more faithfully implemented (conformers, generators, instrumentation). Norm's maintenance situation remains unclear.
vs. Drops: Gladius wins on composability, generators, function contracts, and error quality. Drops still has a more principled type system foundation (dry-types influence) which gives it better type-level guarantees for complex type hierarchies — but most Elixir apps don't need that.
vs. Peri: This is now genuinely close for Phoenix apps. Peri has to_changeset/1 that works with Phoenix forms out of the box. Gladius has better composability, generators, typespec bridge, and cross-field validation. But Peri's LiveView form integration just works. For a developer building a standard Phoenix CRUD app, Peri is still easier to reach for on day one.
vs. Ecto.Changeset: Not really competing. Ecto.Changeset is infrastructure, not a library. The interesting question is whether Gladius.Ecto can get close enough to Ecto's form integration story that Phoenix developers use Gladius for validation logic and pipe the result into a thin Ecto changeset for Phoenix forms. That's the right framing — and 0.3.0 is close but not quite there because of the inputs_for gap.

How Close is Gladius to Go-To?
For boundary validation (HTTP params, message queues, config, API responses): Gladius is already the best option in the Elixir ecosystem. Nothing else combines coercion + validation + transforms + generators + function contracts in one composable library.
For Phoenix web app validation: 75% of the way there. The missing 25% is entirely in the Ecto integration — inputs_for support and schema extension. A developer writing a Phoenix app with flat forms and no nested embeds can use Gladius today. A developer with nested LiveView forms cannot.
For the library that Elixir developers reach for by default: Not yet, for one social reason beyond technical gaps — the ecosystem doesn't know it exists yet. Hex downloads, blog posts, and GitHub stars drive adoption. The library is technically ready to compete; the marketing work hasn't started.

The Two Gaps — Priority Assessment
Schema extension is higher impact. It's a DX gap that affects every non-trivial application regardless of whether they use Phoenix or LiveView. It also unblocks some of the Ecto work — extend + selection together give you a clean create/update/patch story.
inputs_for / Ecto embeds is higher Phoenix-adoption impact. It's the one thing preventing a Phoenix developer from recommending Gladius to a colleague without caveats.
My recommendation: do schema extension first (it's self-contained and enables better Ecto usage patterns), then tackle inputs_for. Want me to propose the interfaces before we start?
