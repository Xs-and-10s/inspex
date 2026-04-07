Gladius 0.4.0 — Retrospective

Where Gladius is Genuinely Superior
The composition story is now complete. extend/2 + selection/2 + validate/2 together give you a validation architecture no other Elixir library can match. A single base schema drives create, update, patch, and cross-field rules without repetition. Norm has selection but no extension. Peri has cross-field conditions but no composable derivation. Drops has neither.
The pipeline is unique. coerce → validate → transform as first-class, composable, pipeable steps — with custom error messages, i18n hooks, and structured metadata on every error — is a better boundary-validation story than anything else in the ecosystem. Drops has coercion. Nobody else has all three stages plus the error quality.
The Ecto integration is now genuinely Phoenix-friendly. inputs_for works on nested schemas. list_of(schema) produces many-cardinality embeds. Gladius.Ecto.traverse_errors/2 handles deep error collection. A Phoenix developer building a LiveView form with nested embeds can use Gladius end-to-end. Peri's to_changeset/1 is simpler but doesn't handle nested forms.
Generator inference + function contracts + typespec bridge. Still unique in the ecosystem. No other Elixir validation library produces StreamData generators automatically, validates function signatures in dev/test with zero prod overhead, and emits @type annotations from the same spec definition.
Error quality is class-leading. message_key, message_bindings, custom message overrides, i18n translator hook, structured %Error{} — richer than Norm, Drops, Peri, and comparable to what Ecto provides (Ecto's error tuples carry opts, Gladius carries both opts-equivalent and a pre-formatted string).

Where Gladius is Adequate
The Ecto integration works but has rough edges. The Gladius.Ecto.traverse_errors/2 / Ecto.Changeset.traverse_errors/2 split is confusing. A developer landing on Hex will naturally reach for Ecto's version, get wrong results, and not know why. The correct behaviour requires knowing Gladius's custom function exists. This is documentation debt more than a code gap, but it creates friction.
inputs_for works, but requires testing in a real Phoenix app. The embed type injection approach (apply_embed_types after cast) works correctly in tests, but hasn't been validated against a real Phoenix LiveView form with server-side state management, phx-change events, and multiple form submissions. The theory is sound; the integration surface is wide.
defschema and defspec are macro-heavy. They work well but the compile-time Code.eval_quoted approach for type: true is fragile when specs reference runtime variables. Dialyzer and the new Elixir set-theoretic type system may eventually make the typespec bridge less necessary, but for now it's a value-add that comes with sharp edges.

Where Gladius is Still Inferior
No schema introspection API. You can't ask a schema "what fields do you have?" without pattern-matching on %Schema{keys: keys} yourself. This matters for:

Admin UI generation (what fields to render)
OpenAPI/JSON Schema export (what shape does this endpoint accept)
Documentation tooling
Dynamic form building

Ecto has __schema__/1 for this. Gladius has nothing. A Gladius.Schema.fields/1 returning [{name, required?, spec}] and a Gladius.Schema.to_json_schema/1 would unlock significant downstream use cases.
No OpenAPI / JSON Schema export. Related to the above but worth calling out separately. The typespec bridge emits Elixir AST — useful for @type annotations but not for API documentation. to_json_schema/1 that walks the spec tree and emits a JSON Schema map would make Gladius the single source of truth for both validation and API docs. This is a meaningful gap for teams building documented APIs.
Gladius.Ecto.traverse_errors/2 vs Ecto.Changeset.traverse_errors/2 confusion. Until Ecto's built-in recursion is triggered by our embed types (or we find another path), users have to know to use ours. This is the most likely source of "Gladius doesn't work properly" bug reports.
No async/streaming validation. Not a common need, but worth noting: there's no way to validate a field by making an async call (e.g. checking email uniqueness without touching the database layer). Ecto handles this via unsafe_validate_unique and database constraints on Repo.insert. Gladius has no equivalent — cross-field validate/2 rules are synchronous.
Still no schema migration story. If you evolve base_schema in a breaking way (remove a field, change a constraint), all derived schemas (extend, selection) silently change too. There's no versioning, no compatibility checking, no warning when a downstream schema becomes invalid. Norm doesn't have this either, but Ecto schema modules are versioned implicitly by the module system.
gen.ex warning (redefining @doc attribute at line 44) has been there since session one. It's cosmetic but appears on every mix test run and signals an unfixed internal bug.

vs. the Competition Specifically
vs. Norm: Gladius wins decisively. Norm's maintenance situation is a real concern. Any team evaluating Norm should strongly consider Gladius instead.
vs. Drops: Gladius wins on composability, generators, and the full feature set. Drops still has a more principled type-system foundation but that advantage is narrow in practice.
vs. Peri: The gap has closed significantly. For a Phoenix LiveView app with nested forms, Gladius is now competitive — inputs_for works, nested errors surface correctly. Peri's one remaining advantage is simplicity: defschema + to_changeset/1 is genuinely easier to explain to a new Elixir developer in five minutes. Gladius has more surface area to learn.
vs. Ecto.Changeset directly: Not a real competition. Ecto is infrastructure. The right framing is: Gladius validates and shapes data, Ecto.Changeset integrates with the database layer. They compose. Gladius makes the Ecto part smaller by handling everything before Repo.insert.

How Close to "Just Marketing"?
For boundary validation (the strongest use case): Already there. Gladius is the best option in the Elixir ecosystem for validating data at application boundaries — HTTP params, message queues, config files, external API responses. Nothing else comes close on the full feature set. Marketing is the only gap here.
For Phoenix web apps with flat forms: 85% there. The remaining 15% is the traverse_errors confusion and the lack of production battle-testing in real Phoenix apps.
For Phoenix web apps with nested LiveView forms: 75% there. inputs_for works in theory. Real production use will surface edge cases (error rendering, form resets, live uploads alongside nested embeds) that tests don't catch.
For "the default Elixir validation library": 70% there, for two reasons that are entirely non-technical:

Nobody knows it exists. Zero blog posts, zero conference talks, zero "I switched from X to Gladius" posts.
The README, while thorough, is dense. A developer landing on the Hex page for the first time needs a 60-second answer to "why should I use this instead of what I already know?" The README gives a 10-minute answer.

The honest answer: the library is technically ready to compete for the default choice. The gap is awareness and a shorter on-ramp for newcomers. A focused blog post — "Building Phoenix forms with Gladius" showing the full create/update/patch/LiveView pattern end-to-end — would do more for adoption than any additional feature.

Recommended next steps, in order

1. Fix the gen.ex @doc warning — one line, should have been fixed sessions ago
2. Gladius.Schema.fields/1 — small, high-leverage for introspection
3. Battle-test the Ecto integration — build a real Phoenix LiveView form, find the edge cases
4. Write the "Gladius + Phoenix" blog post — most impactful thing for adoption
5. JSON Schema / OpenAPI export — unlocks API documentation use case
