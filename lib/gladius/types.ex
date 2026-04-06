defmodule Gladius.Spec do
  @moduledoc """
  The leaf node of the spec algebra — a primitive spec.

  A spec is either:
  - **Typed**: has a `:type` (`:string`, `:integer`, etc.) plus optional named
    `:constraints` (`filled?: true`, `gt?: 18`, etc.). Named constraints are
    introspectable, enabling generator inference in Step 4.
  - **Predicated**: has an arbitrary `:predicate` function. Powerful but opaque
    to the generator — you'll need to supply `:generator` explicitly in Step 4.
  - **Both**: a typed spec that also narrows with an additional predicate.
    Built by `spec(is_integer() and &(&1 > 0))`.

  Fields `:coercion` and `:generator` are reserved for Steps 3 and 4 respectively.
  They are part of the struct now so the data model never needs to change shape.
  """

  @type type_name ::
          :string
          | :integer
          | :float
          | :number
          | :boolean
          | :atom
          | :map
          | :list
          | :tuple
          | :pid
          | :any
          | :nil

  @type t :: %__MODULE__{
          type: type_name() | nil,
          constraints: keyword(),
          predicate: (term() -> boolean()) | nil,
          # Reserved: Step 3
          coercion: (term() -> {:ok, term()} | {:error, term()}) | nil,
          # Reserved: Step 4
          generator: (-> term()) | nil,
          meta: map()
        }

  defstruct [
    :type,
    :predicate,
    :coercion,
    :generator,
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

  ## Example

      all_of([integer(), spec(&(&1 > 0)), spec(&(rem(&1, 2) == 0))])
      # positive even integer
  """

  @type t :: %__MODULE__{specs: [Gladius.conformable()]}
  defstruct [:specs]
end

# ---------------------------------------------------------------------------

defmodule Gladius.Any do
  @moduledoc """
  OR composition — **at least one** spec must conform (set-theoretic union).

  Tries each spec in order and returns the first successful result.
  If all fail, returns an error.

  ## Example

      any_of([integer(), string()])
      # accepts integers or strings
  """

  @type t :: %__MODULE__{specs: [Gladius.conformable()]}
  defstruct [:specs]
end

# ---------------------------------------------------------------------------

defmodule Gladius.Not do
  @moduledoc """
  Negation — the inner spec must **not** conform (set-theoretic complement).

  The value passes through unchanged on success (negation cannot shape data,
  it can only gate it).

  ## Example

      all_of([string(), not_spec(string(:filled?))])
      # a string that is NOT filled — i.e., an empty string
  """

  @type t :: %__MODULE__{spec: Gladius.conformable()}
  defstruct [:spec]
end

# ---------------------------------------------------------------------------

defmodule Gladius.Maybe do
  @moduledoc """
  Nullable wrapper — `nil` passes unconditionally; any other value is
  delegated to the inner spec.

  Semantically equivalent to `any_of([nil_spec(), inner_spec])` but more
  efficient and expressive.

  ## Example

      maybe(string(:filled?))
      # nil is ok; non-nil must be a non-empty string
  """

  @type t :: %__MODULE__{spec: Gladius.conformable()}
  defstruct [:spec]
end

# ---------------------------------------------------------------------------

defmodule Gladius.Ref do
  @moduledoc """
  A lazy reference to a named spec in the `Gladius.Registry`.

  Resolved at **conform-time**, not build-time. This is what enables circular
  schemas (e.g., a tree node whose children are also tree nodes) — you can
  reference a spec by name before it is registered.

  ## Example

      Gladius.def(:email, string(:filled?, format: ~r/@/))

      schema(%{
        required(:user_email) => ref(:email)
      })
  """

  @type t :: %__MODULE__{name: atom()}
  defstruct [:name]
end

# ---------------------------------------------------------------------------

defmodule Gladius.ListOf do
  @moduledoc """
  A homogeneous typed list — every element must conform to `element_spec`.

  Unlike `All`, errors are **accumulated across all elements** rather than
  short-circuiting. This gives the caller a complete picture of what's wrong
  with the entire list in one pass. Errors include a numeric index in the path
  (e.g., `[2, :name]` for the `:name` key of the third element).

  ## Example

      list_of(string(:filled?))
      # ["a", "b", "c"] -> ok
      # ["a", "",  "c"] -> error at path [1]: must be filled
  """

  @type t :: %__MODULE__{element_spec: Gladius.conformable()}
  defstruct [:element_spec]
end

# ---------------------------------------------------------------------------

defmodule Gladius.Cond do
  @moduledoc """
  Conditional branching — applies `if_spec` or `else_spec` based on a
  predicate function applied to the **whole value** at the current conform
  position.

  This is distinct from `any_of`: `Cond` makes a decision, then conforms
  exactly one branch. `Any` tries branches until one succeeds.

  `else_spec` defaults to `%Gladius.Spec{type: :any}` — a passthrough — if
  not supplied.

  ## Example

      # Shipping address is required for physical goods, irrelevant for digital
      cond_spec(
        fn order -> order.type == :physical end,
        ref(:address_schema),
        nil_spec()
      )

  Note: `cond_spec` in a schema works on the *sibling data*, not just the
  field value. Use it at the schema level, not nested inside a single field
  spec, when you need cross-field logic.
  """

  @type t :: %__MODULE__{
          predicate_fn: (term() -> boolean()),
          if_spec: Gladius.conformable(),
          else_spec: Gladius.conformable()
        }

  defstruct [:predicate_fn, :if_spec, :else_spec]
end

# ---------------------------------------------------------------------------

defmodule Gladius.SchemaKey do
  @moduledoc """
  Metadata for a single key in an `Gladius.Schema`.

  Not constructed directly — use `required/1` and `optional/1` as map keys
  inside `schema/1` or `open_schema/1`.
  """

  @type t :: %__MODULE__{
          name: atom(),
          required: boolean(),
          spec: Gladius.conformable()
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
  output. Useful for "at least these keys" contracts, or when wrapping
  external data that may evolve.

  Errors are accumulated across **all keys** in a single pass — no
  short-circuiting. The caller sees every problem at once.

  Construct via `schema/1` or `open_schema/1`, not directly.
  """

  @type t :: %__MODULE__{
          keys: [Gladius.SchemaKey.t()],
          open?: boolean()
        }

  defstruct keys: [], open?: false
end
