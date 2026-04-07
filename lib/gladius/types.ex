defmodule Gladius.Spec do
  @moduledoc """
  The leaf node of the spec algebra — a primitive spec.

  A spec is either:
  - **Typed**: has a `:type` (`:string`, `:integer`, etc.) plus optional named
    `:constraints` (`filled?: true`, `gt?: 18`, etc.). Named constraints are
    introspectable, enabling generator inference.
  - **Predicated**: has an arbitrary `:predicate` function. Powerful but opaque
    to the generator — supply `:generator` explicitly.
  - **Both**: a typed spec that also narrows with an additional predicate.
    Built by `spec(is_integer() and &(&1 > 0))`.

  `:coercion` and `:generator` are reserved for coercion and generation.
  `:message` overrides the error message for any failure of this spec.
  """

  @type type_name ::
          :string | :integer | :float | :number | :boolean
          | :atom | :map | :list | :tuple | :pid | :any | :nil

  @type message :: nil | String.t() | {domain :: String.t() | nil, msgid :: String.t(), bindings :: keyword()}

  @type t :: %__MODULE__{
          type:        type_name() | nil,
          constraints: keyword(),
          predicate:   (term() -> boolean()) | nil,
          coercion:    (term() -> {:ok, term()} | {:error, term()}) | nil,
          generator:   (-> term()) | nil,
          message:     message(),
          meta:        map()
        }

  defstruct [
    :type,
    :predicate,
    :coercion,
    :generator,
    :message,
    constraints: [],
    meta: %{}
  ]
end

# ---------------------------------------------------------------------------

defmodule Gladius.All do
  @moduledoc """
  AND composition — **all** specs must conform (set-theoretic intersection).

  Conforms the value through specs in order. The shaped output of each
  successful conform is forwarded as input to the next spec, enabling a
  lightweight transformation pipeline. Short-circuits on first failure.
  """

  @type t :: %__MODULE__{specs: [Gladius.conformable()], message: Gladius.Spec.message()}
  defstruct [:specs, :message]
end

# ---------------------------------------------------------------------------

defmodule Gladius.Any do
  @moduledoc """
  OR composition — **at least one** spec must conform (set-theoretic union).

  Tries each spec in order and returns the first successful result.
  If all fail, returns an error.
  """

  @type t :: %__MODULE__{specs: [Gladius.conformable()], message: Gladius.Spec.message()}
  defstruct [:specs, :message]
end

# ---------------------------------------------------------------------------

defmodule Gladius.Not do
  @moduledoc """
  Negation — the inner spec must **not** conform (set-theoretic complement).

  The value passes through unchanged on success.
  """

  @type t :: %__MODULE__{spec: Gladius.conformable(), message: Gladius.Spec.message()}
  defstruct [:spec, :message]
end

# ---------------------------------------------------------------------------

defmodule Gladius.Maybe do
  @moduledoc """
  Nullable wrapper — `nil` passes unconditionally; any other value is
  delegated to the inner spec.
  """

  @type t :: %__MODULE__{spec: Gladius.conformable(), message: Gladius.Spec.message()}
  defstruct [:spec, :message]
end

# ---------------------------------------------------------------------------

defmodule Gladius.Ref do
  @moduledoc """
  A lazy reference to a named spec in the `Gladius.Registry`.

  Resolved at **conform-time**, not build-time. Enables circular schemas.
  """

  @type t :: %__MODULE__{name: atom()}
  defstruct [:name]
end

# ---------------------------------------------------------------------------

defmodule Gladius.ListOf do
  @moduledoc """
  A homogeneous typed list — every element must conform to `element_spec`.

  Errors are **accumulated across all elements** — no short-circuiting.
  """

  @type t :: %__MODULE__{element_spec: Gladius.conformable(), message: Gladius.Spec.message()}
  defstruct [:element_spec, :message]
end

# ---------------------------------------------------------------------------

defmodule Gladius.Cond do
  @moduledoc """
  Conditional branching — applies `if_spec` or `else_spec` based on a
  predicate function applied to the **whole value** at the current conform
  position.
  """

  @type t :: %__MODULE__{
          predicate_fn: (term() -> boolean()),
          if_spec:      Gladius.conformable(),
          else_spec:    Gladius.conformable(),
          message:      Gladius.Spec.message()
        }

  defstruct [:predicate_fn, :if_spec, :else_spec, :message]
end

# ---------------------------------------------------------------------------

defmodule Gladius.SchemaKey do
  @moduledoc """
  Metadata for a single key in a `Gladius.Schema`.

  Not constructed directly — use `required/1` and `optional/1` as map keys
  inside `schema/1` or `open_schema/1`.
  """

  @type t :: %__MODULE__{
          name:     atom(),
          required: boolean(),
          spec:     Gladius.conformable()
        }

  defstruct [:name, :spec, required: true]
end

# ---------------------------------------------------------------------------

defmodule Gladius.Schema do
  @moduledoc """
  A map spec — validates the shape, required keys, and typed values of a map.

  **Closed** (`open?: false`, the default): extra keys not declared in the
  schema are rejected with an `:unknown_key?` error.

  **Open** (`open?: true`): extra keys pass through unchanged in the shaped
  output.

  Errors accumulate across **all keys** in a single pass — no short-circuiting.

  Construct via `schema/1` or `open_schema/1`, not directly.
  """

  @type t :: %__MODULE__{
          keys:    [Gladius.SchemaKey.t()],
          open?:   boolean(),
          message: Gladius.Spec.message()
        }

  defstruct keys: [], open?: false, message: nil

    # ---------------------------------------------------------------------------
    # Introspection
    # ---------------------------------------------------------------------------

    @type field_descriptor :: %{name: atom(), required: boolean(), spec: term()}

    @doc """
    Returns field descriptors for a schema in declaration order.

    Each descriptor is `%{name: atom(), required: boolean(), spec: conformable()}`.
    Accepts any conformable wrapping a `%Gladius.Schema{}` — `validate/2`,
    `default/2`, `transform/2`, `maybe/1`, and `ref/1` are all unwrapped
    transparently. Raises `ArgumentError` if no schema is found.
    """
    @spec fields(term()) :: [field_descriptor()]
    def fields(conformable) do
      %__MODULE__{keys: keys} = unwrap!(conformable)
      Enum.map(keys, fn %Gladius.SchemaKey{name: n, spec: s, required: r} ->
        %{name: n, required: r, spec: s}
      end)
    end

    @doc "Returns only required field descriptors, in declaration order."
    @spec required_fields(term()) :: [field_descriptor()]
    def required_fields(c), do: c |> fields() |> Enum.filter(& &1.required)

    @doc "Returns only optional field descriptors, in declaration order."
    @spec optional_fields(term()) :: [field_descriptor()]
    def optional_fields(c), do: c |> fields() |> Enum.reject(& &1.required)

    @doc "Returns field names in declaration order."
    @spec field_names(term()) :: [atom()]
    def field_names(c), do: c |> fields() |> Enum.map(& &1.name)

    @doc "Returns `true` if the conformable resolves to a `%Gladius.Schema{}`."
    @spec schema?(term()) :: boolean()
    def schema?(c), do: match?(%__MODULE__{}, unwrap(c))

    @doc "Returns `true` if the schema is open (extra keys pass through)."
    @spec open?(term()) :: boolean()
    def open?(c) do
      case unwrap(c) do
        %__MODULE__{open?: v} -> v
        _                     -> false
      end
    end

    defp unwrap(%__MODULE__{} = s),          do: s
    defp unwrap(%Gladius.Default{spec: i}),  do: unwrap(i)
    defp unwrap(%Gladius.Transform{spec: i}), do: unwrap(i)
    defp unwrap(%Gladius.Maybe{spec: i}),    do: unwrap(i)
    defp unwrap(%Gladius.Validate{spec: i}), do: unwrap(i)
    defp unwrap(%Gladius.Ref{name: n}) do
      unwrap(Gladius.Registry.fetch!(n))
    rescue
      _ -> nil
    end
    defp unwrap(_), do: nil

    defp unwrap!(c) do
      case unwrap(c) do
        %__MODULE__{} = s -> s
        nil ->
          raise ArgumentError,
            "expected a %Gladius.Schema{} or a conformable wrapping one, got: #{inspect(c)}"
      end
    end

    @doc """
      Converts the schema (or any conformable wrapping a schema) to a JSON Schema
      (draft 2020-12) map.

      ## Options

        * `:title` - adds `"title"` to the root object
        * `:description` - adds `"description"` to the root object
        * `:schema_header` - include `"$schema"` URI (default: `true`)
      """
      @spec to_json_schema(term(), keyword()) :: map()
      def to_json_schema(conformable, opts \\ []) do
        Gladius.JsonSchema.convert(conformable, opts)
      end
  end
