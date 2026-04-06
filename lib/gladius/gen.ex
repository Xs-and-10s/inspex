defmodule Gladius.Gen do
  @moduledoc """
  Generator inference for `gladius` specs.

  Converts a spec into a `StreamData` generator. Used via `Gladius.gen/1`.

  ## Inference rules

  | Spec form                  | Strategy                                         |
  |----------------------------|--------------------------------------------------|
  | `integer(gte?: 0, lte?: 9)`| `StreamData.integer(0..9)`                       |
  | `string(:filled?)`         | `StreamData.string(:printable, min_length: 1)`   |
  | `boolean()`                | `StreamData.boolean()`                           |
  | `atom(in?: [:a, :b])`      | `StreamData.member_of([:a, :b])`                 |
  | `maybe(inner)`             | `one_of([constant(nil), gen(inner)])`            |
  | `any_of([s1, s2])`         | `one_of([gen(s1), gen(s2)])`                     |
  | `all_of([s1, s2, ...])`    | `gen(s1)` filtered by `valid?` against s2…sN     |
  | `list_of(elem_spec)`       | `StreamData.list_of(gen(elem_spec))`             |
  | `schema(%{...})`           | `StreamData.fixed_map` of each key's generator   |
  | `ref(:name)`               | resolves from registry, then infers              |
  | `spec(pred, gen: g)`       | uses the explicit `g` override                   |
  | `spec(pred)`               | raises `Gladius.GeneratorError`                   |
  | `not_spec(_)`              | raises `Gladius.GeneratorError`                   |
  | `cond_spec(...)`           | raises `Gladius.GeneratorError`                   |

  ## Constraints → bounds

  Named constraints on typed specs are translated to generator bounds rather
  than filters where possible. `integer(gte?: 1, lte?: 100)` produces
  `StreamData.integer(1..100)`, not `StreamData.filter(integer(), &(&1 in 1..100))`.
  This avoids filter-rejection loops and keeps shrinking useful.

  Constraints that cannot be directly modelled as bounds (`format: regex`,
  `filled?` on strings beyond `min_length`) fall back to `StreamData.filter/3`
  with a generous `max_tries` cap.
  """

  alias Gladius.{Spec, All, Any, Not, Maybe, Ref, ListOf, Cond, Schema, SchemaKey}

  # ---------------------------------------------------------------------------
  # Public entry point
  # ---------------------------------------------------------------------------

  @doc """
  Returns a `StreamData` generator for `spec`.

  Raises `Gladius.GeneratorError` for specs whose generators cannot be inferred
  (predicate-only specs, `not_spec/1`, `cond_spec/3`).

  ## Property-based testing usage

      use ExUnitProperties
      import Gladius, except: [integer: 0, integer: 1, integer: 2,
                               float: 0, float: 1, float: 2,
                               string: 0, string: 1, string: 2,
                               boolean: 0, atom: 0, atom: 1,
                               list: 0, list: 1, list: 2, list_of: 1]

      property "generated values always conform" do
        spec = schema(%{
          required(:name) => string(:filled?),
          required(:age)  => integer(gte?: 18, lte?: 120)
        })
        check all value <- Gladius.gen(spec) do
          assert Gladius.valid?(spec, value)
        end
      end
  """
  @spec gen(Gladius.conformable()) :: term()
  @doc false
  def gen(%Spec{generator: g}) when not is_nil(g), do: g

  def gen(%Spec{type: :any}),     do: StreamData.one_of([
    StreamData.integer(),
    StreamData.string(:printable),
    StreamData.boolean(),
    StreamData.constant(nil),
    StreamData.atom(:alphanumeric)
  ])

  def gen(%Spec{type: :null}),    do: StreamData.constant(nil)
  def gen(%Spec{type: :boolean}), do: StreamData.boolean()

  def gen(%Spec{type: :integer, constraints: cs}), do: integer_gen(cs)
  def gen(%Spec{type: :float,   constraints: cs}), do: float_gen(cs)
  def gen(%Spec{type: :number,  constraints: cs}), do: number_gen(cs)
  def gen(%Spec{type: :string,  constraints: cs}), do: string_gen(cs)
  def gen(%Spec{type: :atom,    constraints: cs}), do: atom_gen(cs)

  def gen(%Spec{type: :map}) do
    StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.term(), max_length: 5)
  end

  def gen(%Spec{type: :list}) do
    StreamData.list_of(StreamData.term(), max_length: 10)
  end

  # Predicate-only spec — cannot infer
  def gen(%Spec{type: nil, predicate: pred, meta: meta}) when not is_nil(pred) do
    source = Map.get(meta, :source, "anonymous predicate")
    raise Gladius.GeneratorError, spec: source
  end

  # Empty spec — treat as any()
  def gen(%Spec{type: nil, predicate: nil}), do: gen(%Spec{type: :any})

  # --- Combinators -----------------------------------------------------------

  # All (AND) — generate from the first spec, filter by the rest.
  # The first spec sets the type domain; subsequent specs narrow it.
  # Prefer putting the most selective typed spec first for efficiency.
  def gen(%All{specs: []}) do
    StreamData.term()
  end

  def gen(%All{specs: [head | tail]}) do
    # Optimisation: collect typed %Spec{} constraints from the tail that share
    # the same type as the head, and merge them into the base generator.
    # This avoids pathological filter rejection rates like:
    #   all_of([integer(gte?: 1), integer(lte?: 100)])
    # which without merging would generate up to 1,000,000 and filter to 1..100.
    {mergeable, rest} =
      case head do
        %Gladius.Spec{type: type, predicate: nil} when not is_nil(type) ->
          Enum.split_with(tail, fn
            %Gladius.Spec{type: ^type, predicate: nil} -> true
            _ -> false
          end)
        _ -> {[], tail}
      end

    merged_head =
      Enum.reduce(mergeable, head, fn %Gladius.Spec{constraints: cs}, acc ->
        %{acc | constraints: acc.constraints ++ cs}
      end)

    base = gen(merged_head)

    if rest == [] do
      base
    else
      StreamData.filter(base, fn v ->
        Enum.all?(rest, &Gladius.valid?(&1, v))
      end, 100)
    end
  end

  # Any (OR) — weighted uniform choice over each spec's generator.
  def gen(%Any{specs: []}) do
    raise Gladius.GeneratorError, spec: "any_of([])"
  end

  def gen(%Any{specs: specs}) do
    specs |> Enum.map(&gen/1) |> StreamData.one_of()
  end

  # Not — cannot infer without a base type to generate from.
  def gen(%Not{}) do
    raise Gladius.GeneratorError,
      spec: "not_spec/1 — no base type to generate from. " <>
            "Wrap in all_of([typed_spec, not_spec(...)]) to give the generator a domain."
  end

  # Maybe — nil or the inner spec's generator, with equal weight.
  def gen(%Maybe{spec: inner}) do
    StreamData.one_of([StreamData.constant(nil), gen(inner)])
  end

  # Ref — resolve from registry at gen-time, then infer.
  def gen(%Ref{name: name}) do
    spec = Gladius.Registry.fetch!(name)
    gen(spec)
  end

  # ListOf — list of generated elements, bounded to avoid huge test data.
  def gen(%ListOf{element_spec: el_spec}) do
    StreamData.list_of(gen(el_spec), max_length: 20)
  end

  # Cond — cannot infer; the predicate splits based on runtime data.
  def gen(%Cond{}) do
    raise Gladius.GeneratorError,
      spec: "cond_spec/3 — branching depends on runtime values. " <>
            "Use any_of([if_spec_gen, else_spec_gen]) as an approximation, " <>
            "or provide an explicit generator."
  end

  # Schema — fixed_map for required keys; optional keys are coin-flipped in.
  def gen(%Schema{keys: key_specs}) do
    {required, optional} = Enum.split_with(key_specs, & &1.required)

    required_gen =
      required
      |> Enum.map(fn %SchemaKey{name: name, spec: spec} -> {name, gen(spec)} end)
      |> Map.new()
      |> StreamData.fixed_map()

    if optional == [] do
      required_gen
    else
      # Each optional key: include with 50% probability
      optional_slot_gens =
        Enum.map(optional, fn %SchemaKey{name: name, spec: spec} ->
          StreamData.one_of([
            StreamData.constant(:omit),
            StreamData.map(gen(spec), fn v -> {:include, name, v} end)
          ])
        end)

      StreamData.bind(required_gen, fn base ->
        optional_slot_gens
        |> StreamData.fixed_list()
        |> StreamData.map(fn slots ->
          Enum.reduce(slots, base, fn
            :omit,              acc -> acc
            {:include, k, v},   acc -> Map.put(acc, k, v)
          end)
        end)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Type-specific generators
  # ---------------------------------------------------------------------------

  defp integer_gen(constraints) do
    lower = integer_lower(constraints)
    upper = integer_upper(constraints)
    # Ensure lower <= upper (user could write gt?: 100, lte?: 10 — nonsensical
    # but shouldn't crash the generator; StreamData will just generate nothing)
    StreamData.integer(lower..upper)
  end

  defp float_gen(constraints) do
    min = Keyword.get(constraints, :gte?) || Keyword.get(constraints, :gt?) || -1.0e6
    max = Keyword.get(constraints, :lte?) || Keyword.get(constraints, :lt?) || 1.0e6
    StreamData.float(min: min * 1.0, max: max * 1.0)
  end

  defp number_gen(constraints) do
    StreamData.one_of([integer_gen(constraints), float_gen(constraints)])
  end

  defp string_gen(constraints) do
    filled?    = Keyword.get(constraints, :filled?, false)
    exact_size = Keyword.get(constraints, :size?)
    min_len    = Keyword.get(constraints, :min_length) || (if filled?, do: 1, else: 0)
    max_len    = Keyword.get(constraints, :max_length) || 100

    {min_len, max_len} =
      if exact_size, do: {exact_size, exact_size}, else: {min_len, max_len}

    # :ascii ensures byte_size(v) == String.length(v), keeping the generator
    # consistent with the byte_size-based min_length/max_length/size? constraints.
    # Users who need Unicode strings should supply an explicit :gen override.
    base = StreamData.string(:ascii, min_length: min_len, max_length: max_len)

    case Keyword.get(constraints, :format) do
      nil   -> base
      regex ->
        # Can't reverse a regex — filter instead. Third arg is an integer
        # (max_consecutive_failures), not a keyword list.
        StreamData.filter(base, &Regex.match?(regex, &1), 1_000)
    end
  end

  defp atom_gen(constraints) do
    case Keyword.get(constraints, :in?) do
      nil    -> StreamData.atom(:alphanumeric)
      values -> StreamData.member_of(values)
    end
  end

  defp integer_lower(cs) do
    cond do
      n = Keyword.get(cs, :gte?) -> n
      n = Keyword.get(cs, :gt?)  -> n + 1
      true -> -1_000_000
    end
  end

  defp integer_upper(cs) do
    cond do
      n = Keyword.get(cs, :lte?) -> n
      n = Keyword.get(cs, :lt?)  -> n - 1
      true -> 1_000_000
    end
  end
end
