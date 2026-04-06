defmodule Gladius.Typespec do
  @moduledoc """
  Converts `gladius` specs to Elixir typespec AST.

  ## Fidelity

  The mapping is *lossless* for most specs and *lossy* for a small set of
  constructs that have no typespec equivalent:

  | Construct              | Elixir typespec           | Notes                          |
  |------------------------|---------------------------|--------------------------------|
  | `string(:filled?)`     | `String.t()`              | constraints not expressible    |
  | `all_of/1`             | first typed spec's type   | intersection not in typespecs  |
  | `not_spec/1`           | `term()`                  | negation not in typespecs      |
  | `cond_spec/3`          | `T_if \\| T_else`         | predicate is lost              |
  | `coerce/2`             | target type only           | input type not represented     |

  Call `lossiness/1` to enumerate what was elided for any given spec.

  ## Usage

      # Ad-hoc conversion
      Gladius.to_typespec(integer(gte?: 0))
      #=> {non_neg_integer, [], []}    (quoted AST for non_neg_integer())

      Macro.to_string(Gladius.to_typespec(maybe(string())))
      #=> "String.t() | nil"

      # Generate a @type declaration AST (for use inside macros)
      Gladius.Typespec.type_ast(:user_id, integer(gte?: 1))
      # Produces AST equivalent to: @type user_id :: pos_integer()
  """

  alias Gladius.{Spec, All, Any, Not, Maybe, Ref, ListOf, Cond, Schema, SchemaKey}

  # ===========================================================================
  # to_typespec/1
  # ===========================================================================

  @doc """
  Converts an gladius spec to quoted Elixir typespec AST.

  Always returns a valid quoted form. Lossy constructs fall back to `term()`.
  Use `lossiness/1` to inspect what was elided.

  ## Examples

      iex> import Gladius
      iex> Macro.to_string(Gladius.to_typespec(string()))
      "String.t()"

      iex> Macro.to_string(Gladius.to_typespec(integer(gte?: 0, lte?: 100)))
      "0..100"

      iex> Macro.to_string(Gladius.to_typespec(maybe(string(:filled?))))
      "String.t() | nil"

      iex> Macro.to_string(Gladius.to_typespec(atom(in?: [:admin, :user])))
      ":admin | :user"
  """
  @spec to_typespec(Gladius.conformable()) :: Macro.t()

  # ---------------------------------------------------------------------------
  # Coerce wrapper — use the inner spec's typespec.
  # The coercion changes what *input* the function accepts, but the spec
  # itself still validates the target type.  We use the target type and note
  # the lossiness via lossiness/1.
  # ---------------------------------------------------------------------------
  def to_typespec(%Spec{coercion: fn_} = spec) when not is_nil(fn_) do
    to_typespec(%{spec | coercion: nil})
  end

  # ---------------------------------------------------------------------------
  # Primitives
  # ---------------------------------------------------------------------------
  def to_typespec(%Spec{type: :string}),  do: quote(do: String.t())
  def to_typespec(%Spec{type: :float}),   do: quote(do: float())
  def to_typespec(%Spec{type: :number}),  do: quote(do: number())
  def to_typespec(%Spec{type: :boolean}), do: quote(do: boolean())
  def to_typespec(%Spec{type: :map}),     do: quote(do: map())
  def to_typespec(%Spec{type: :list}),    do: quote(do: list())
  def to_typespec(%Spec{type: :any}),     do: quote(do: any())
  def to_typespec(%Spec{type: :null}),    do: nil   # nil literal in typespec

  # Atom — check for `in?` to emit a union of atom literals.
  def to_typespec(%Spec{type: :atom, constraints: cs}) do
    case Keyword.get(cs, :in?) do
      nil    -> quote(do: atom())
      values -> union(values)
    end
  end

  # Integer — specialise common constraint patterns.
  def to_typespec(%Spec{type: :integer, constraints: cs}) do
    integer_ts(cs)
  end

  # Predicate-only spec (no type) — no typespec equivalent.
  def to_typespec(%Spec{type: nil}) do
    quote(do: term())
  end

  # ---------------------------------------------------------------------------
  # Combinators
  # ---------------------------------------------------------------------------

  # all_of — set-theoretic intersection, not expressible in typespecs.
  # Strategy: use the first spec with a concrete (non-:any) type.
  # Falls back to term() if all specs are predicate-only or :any.
  def to_typespec(%All{specs: specs}) do
    typed =
      Enum.find(specs, fn
        %Spec{type: t} when t not in [nil, :any] -> true
        _ -> false
      end)

    if typed, do: to_typespec(typed), else: quote(do: term())
  end

  # any_of — union of all branch typespecs.
  def to_typespec(%Any{specs: specs}) do
    specs |> Enum.map(&to_typespec/1) |> union()
  end

  # not_spec — negation is not expressible; term() is the safe fallback.
  def to_typespec(%Not{}), do: quote(do: term())

  # maybe — inner type | nil.
  def to_typespec(%Maybe{spec: spec}) do
    inner = to_typespec(spec)
    quote(do: unquote(inner) | nil)
  end

  # ref — emit a named type reference: ref(:email) → email().
  # This is valid in a @type context if the caller has defined @type email.
  def to_typespec(%Ref{name: name}), do: {name, [], []}

  # list_of — [element_type].
  def to_typespec(%ListOf{element_spec: spec}) do
    [to_typespec(spec)]
  end

  # cond_spec — predicate is lost; union of both branches.
  def to_typespec(%Cond{if_spec: if_s, else_spec: else_s}) do
    t1 = to_typespec(if_s)
    t2 = to_typespec(else_s)
    quote(do: unquote(t1) | unquote(t2))
  end

  # ---------------------------------------------------------------------------
  # Schema
  # ---------------------------------------------------------------------------

  # Closed schema → %{required(:k) => T, optional(:k) => T}.
  # Open schema adds optional(atom()) => any() to represent unknown keys.
  def to_typespec(%Schema{keys: keys, open?: open?}) do
    pairs = Enum.map(keys, &schema_key_pair/1)

    all_pairs =
      if open? do
        pairs ++ [{{:optional, [], [{:atom, [], []}]}, {:any, [], []}}]
      else
        pairs
      end

    {:%{}, [], all_pairs}
  end

  # ===========================================================================
  # lossiness/1
  # ===========================================================================

  @doc """
  Returns a list of lossiness notices for a spec.

  Each notice is `{reason :: atom(), description :: String.t()}`.
  An empty list means the typespec is a lossless representation.

  ## Examples

      iex> Gladius.typespec_lossiness(Gladius.string(:filled?))
      [{:constraint_not_expressible, "filled?: true has no typespec equivalent"}]

      iex> Gladius.typespec_lossiness(Gladius.integer(gte?: 0, lte?: 100))
      []

      iex> Gladius.typespec_lossiness(Gladius.not_spec(Gladius.integer()))
      [{:negation_not_expressible, "not_spec has no typespec equivalent; term() used"}]
  """
  @spec lossiness(Gladius.conformable()) :: [{atom(), String.t()}]
  def lossiness(spec), do: collect_lossiness(spec) |> Enum.uniq()

  # ===========================================================================
  # type_ast/2
  # ===========================================================================

  @doc """
  Generates the AST for a `@type name :: type` declaration.

  The returned AST can be injected into a module via `unquote` inside a
  `quote do` block, or passed to `Module.eval_quoted/2`.

  ## Example

      # Inside a macro:
      quote do
        unquote(Gladius.Typespec.type_ast(:user_id, Gladius.integer(gte?: 1)))
      end
      # Equivalent to: @type user_id :: pos_integer()

      # Or at runtime:
      Module.eval_quoted(MyModule, Gladius.Typespec.type_ast(:email, email_spec))
  """
  @spec type_ast(atom(), Gladius.conformable()) :: Macro.t()
  def type_ast(name, spec) when is_atom(name) do
    ts = to_typespec(spec)
    {:@, [], [{:type, [], [{:":::", [], [{name, [], []}, ts]}]}]}
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  # Integer constraint → specialised typespec.
  # Priority: in? → literal union; gte?/gt? alone → named types;
  # gte?+lte? → range; everything else → integer().
  defp integer_ts(cs) do
    in_vals  = Keyword.get(cs, :in?)
    gte      = Keyword.get(cs, :gte?)
    gt       = Keyword.get(cs, :gt?)
    lte      = Keyword.get(cs, :lte?)

    cond do
      in_vals            -> union(in_vals)
      gte == 0 && !lte   -> quote(do: non_neg_integer())
      gt  == 0 && !lte   -> quote(do: pos_integer())
      gte != nil && lte != nil -> quote(do: unquote(gte)..unquote(lte))
      true               -> quote(do: integer())
    end
  end

  # Schema key pair: {required(:name) => T} or {optional(:name) => T}.
  defp schema_key_pair(%SchemaKey{name: name, spec: spec, required: req}) do
    wrapper = if req, do: :required, else: :optional
    {{wrapper, [], [name]}, to_typespec(spec)}
  end

  # Build a union type from a list of AST nodes or plain values (atoms/integers).
  # Single element → no union wrapper needed.
  defp union([]),       do: quote(do: term())
  defp union([single]), do: single
  defp union([h | t]),  do: {:|, [], [h, union(t)]}

  # ---------------------------------------------------------------------------
  # Lossiness collection — walks the spec tree
  # ---------------------------------------------------------------------------

  defp collect_lossiness(%Spec{coercion: fn_} = spec) when not is_nil(fn_) do
    inner = %{spec | coercion: nil}
    [{:coercion_not_expressible,
      "input type before coercion is not represented; only the target type appears"}
     | collect_lossiness(inner)]
  end

  defp collect_lossiness(%Spec{type: :string, constraints: cs}) do
    cs
    |> Enum.flat_map(fn {k, v} ->
      if v not in [nil, false] and k in [:filled?, :format, :min_length, :max_length, :size?] do
        [{:constraint_not_expressible,
          "#{inspect(k)}: #{inspect(v)} has no typespec equivalent"}]
      else
        []
      end
    end)
  end

  defp collect_lossiness(%All{specs: specs}) do
    inner = Enum.flat_map(specs, &collect_lossiness/1)
    [{:intersection_not_expressible,
      "all_of is set-theoretic intersection; only the first typed spec's type is used"}
     | inner]
  end

  defp collect_lossiness(%Not{spec: spec}) do
    [{:negation_not_expressible,
      "not_spec has no typespec equivalent; term() used"}
     | collect_lossiness(spec)]
  end

  defp collect_lossiness(%Cond{if_spec: if_s, else_spec: else_s}) do
    inner = collect_lossiness(if_s) ++ collect_lossiness(else_s)
    [{:predicate_not_expressible,
      "cond_spec predicate is lost; a union of both branches is used"}
     | inner]
  end

  defp collect_lossiness(%Maybe{spec: s}),            do: collect_lossiness(s)
  defp collect_lossiness(%Any{specs: specs}),         do: Enum.flat_map(specs, &collect_lossiness/1)
  defp collect_lossiness(%ListOf{element_spec: s}),   do: collect_lossiness(s)
  defp collect_lossiness(%Ref{}),                     do: []
  defp collect_lossiness(%Spec{}),                    do: []
  defp collect_lossiness(%Schema{keys: keys}) do
    Enum.flat_map(keys, fn %SchemaKey{spec: s} -> collect_lossiness(s) end)
  end
end
