Gladius 0.5.0 Retrospective

Where Gladius is Genuinely Superior
The composition story is complete and unique. schema → extend → selection → validate gives you a full validation architecture that no other Elixir library can match. A single base schema drives create, update, patch, and cross-field rules without repetition, and every derived schema stays in sync automatically. This is the Clojure spec philosophy applied properly to Elixir.
The pipeline is unmatched. coerce → validate → transform as first-class composable steps, with custom error messages, structured message_key/message_bindings metadata, and an i18n translator hook on every error. Nobody else has all three stages. The error quality — structured, translatable, with both a formatted string and raw bindings — is better than Ecto's error tuples and better than anything Norm, Drops, or Peri produce.
The Phoenix integration is now genuinely production-ready. inputs_for works. List embeds work. Auto-seeding works. Phoenix param cleaning is automatic. The five required patterns are documented. A developer can build a real LiveView form with nested embeds and Gladius handles everything from validation through to changeset construction. Peri's to_changeset/1 is simpler on the surface but breaks down immediately on nested forms and list embeds.
Generator inference + function contracts + typespec bridge. Still entirely unique in the Elixir ecosystem. Write a spec once; use it for validation, property testing, function signature checking, and @type generation. No other library comes within three features of this.
Schema introspection is a meaningful new capability. Gladius.Schema.fields/1 opens up admin UI generation, OpenAPI export, and dynamic form building from a single schema definition. None of the competitors have this.
maybe_wrapped? semantics are correct. Getting maybe(schema) right — not seeding, not building sub-changesets when nil — is subtle. Most libraries don't even have this case because they don't support nested schemas in the first place.

Where Gladius is Adequate
The Ecto integration works but required a lot of tribal knowledge to get right. The five required patterns (schemas as functions, as: on forms, to_form/2 in assigns, _target filtering, auto-clean) are now documented, but a developer landing cold on the Hex page will still hit them in sequence. The documentation is reactive — explaining what to do after you've hit the wall — rather than proactive. Peri's integration is dumber but you don't need a battle test to make it work.
Gladius.Ecto.traverse_errors/2 vs Ecto.Changeset.traverse_errors/2. The right function exists and works correctly. But Ecto's built-in still doesn't recurse into our embed types in all cases, which means developers who reach for the obvious function get wrong results. This is a confusing split that will generate bug reports.
Gladius.Schema.fields/1 doesn't guarantee order. The caveat that Elixir map literals don't preserve insertion order is real and limits the usefulness of introspection for form rendering. A form that renders fields in a different order every compile is useless. This needs a solution — either a dedicated ordered schema builder or a note pointing to keyword-list-style schema definitions.
The defschema / defspec macro surface. Works well but the Code.eval_quoted approach for type: true is fragile at the edges, and the macro API has more ceremony than it needs. It's adequate for its purpose but not elegant.

Where Gladius is Still Inferior
No JSON Schema / OpenAPI export. Gladius.Schema.fields/1 gives you the raw material, but there's no Gladius.Schema.to_json_schema/1. This is the most impactful missing feature for teams building documented APIs. Without it, you can't use Gladius as your single source of truth for both validation and API documentation. Every competitor that targets API development has this gap too — but filling it would be a meaningful differentiator.
Field ordering is undefined. Elixir maps don't preserve insertion order. For introspection, form rendering, and documentation, "fields in declaration order" is what every user expects. The current implementation works around this by documenting the limitation, but the real fix is structural — either ordered schema construction or explicit ordering metadata.
No streaming / async validation. Cross-field validate/2 rules are synchronous. There's no way to run a validation that requires an async call (uniqueness check, external API, database lookup) within the Gladius conforming pipeline. Ecto handles database uniqueness via unique_constraint on insert. Gladius has no equivalent hook. This is a narrow gap but real for certain use cases.
Schema versioning / migration story is still absent. If you evolve base_schema in a breaking way, all derived schemas silently change. There's no version identifier, no compatibility check, no deprecation path. Not a common need for most apps but a real gap for libraries that export schemas as part of their public API.
Gladius.Ecto.traverse_errors/2 is a second-best solution. The right answer would be for Ecto.Changeset.traverse_errors/2 to work natively. That would require either using Ecto's actual embed machinery (which requires a backing module) or contributing a patch to phoenix_ecto to handle {:embed, ...} types backed by plain changesets rather than schema modules. Until that happens, every Phoenix app using Gladius has an invisible gotcha.
No test helpers / test DSL. Drops has Drops.Contract which reads almost like a spec. Peri has straightforward schema definition that new developers understand immediately. Gladius has the richest feature set but the highest learning curve. There's no assert_conforms(spec, value) or refute_conforms(spec, value) helper, no GladiusCase for ExUnit, no fixtures generator that dumps shaped values as test data.
Map literal ordering affects field order in introspection. Already noted above, but worth separating as its own gap: any downstream tooling (form generators, API docs, admin UIs) that relies on field order will produce non-deterministic output. This is solvable — schema_ordered/1 taking a keyword list instead of a map — but it's a breaking change to the core API.

vs. the Competition Specifically
vs. Norm: Gladius wins decisively on every dimension. Norm is effectively unmaintained. Any team evaluating it should use Gladius instead.
vs. Drops: Gladius wins on composability, Phoenix integration, generators, and the full pipeline. Drops has a more principled type-system foundation (dry-types influence) but that advantage is academic for most Elixir applications. The gap has widened in Gladius's favor since 0.1.
vs. Peri: The closest competitor for Phoenix apps. Peri's one remaining advantage is zero-friction initial setup — defschema + to_changeset/1 and it works. Gladius now matches on nested form support but with more required knowledge. For experienced developers Gladius is clearly better. For a beginner building their first Phoenix app, Peri still wins on day one.
vs. Ecto.Changeset directly: This framing has become clearer through the battle test. Gladius is not competing with Ecto.Changeset — it's a better validation layer that produces Ecto.Changeset compatible output. The right mental model is: Gladius at the boundary (HTTP params, message queues, config), Ecto for persistence (constraints, associations, database). They compose.

How Far from the Frontrunner Objective?
For boundary validation: Already the frontrunner. Nothing in the Elixir ecosystem comes close on the full feature set.
For Phoenix LiveView form applications: 80% there. The remaining 20% is entirely about ergonomics and discoverability — the library works correctly but requires knowledge to use correctly. A developer who reads the docs carefully gets there. A developer who skims and tries things gets stuck at each of the five required patterns in sequence.
For "the default Elixir validation library" broadly: 65% there. The gap is not technical — it's social and ergonomic:

Nobody knows it exists
The initial experience has friction (the schema-as-function gotcha alone will stop many developers cold)
There's no 10-minute success path — every getting-started tutorial for Phoenix validation leads to Ecto.Changeset directly


What's Next — Priority Order
1. JSON Schema / OpenAPI export (Gladius.Schema.to_json_schema/1)
Highest leverage feature remaining. Unlocks API documentation use case. Pairs naturally with Gladius.Schema.fields/1. Positions Gladius as the source of truth for both validation and documentation.
2. Ordered schema construction (schema_ordered/1)
Fix the field ordering problem properly. Accept a keyword list, preserve order, make introspection and form rendering deterministic. Could be additive — keep schema/1 for compatibility, add schema_ordered/1 as the recommended path going forward.
3. ExUnit test helpers (Gladius.Testing)
assert_conforms(spec, value), refute_conforms(spec, value), assert_errors_at(spec, value, [:path]). Low implementation cost, high discoverability value. Makes Gladius feel like a first-class citizen in the test ecosystem.
4. Blog post: "Building Phoenix LiveView forms with Gladius"
The five required patterns, the full worked example, the create/update/patch schema pattern. This single post would do more for adoption than any feature. The battle test gave us everything we need to write it honestly.
5. Contribute phoenix_ecto patch or workaround
Make Ecto.Changeset.traverse_errors/2 work natively for Gladius changesets. Either via a phoenix_ecto issue/PR, or by finding a way to make our embed type registration compatible with their traversal logic without requiring a backing schema module.
