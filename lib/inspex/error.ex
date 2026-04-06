defmodule Inspex.Error do
  @moduledoc """
  A single validation failure, with a dot-traversable path to the offending
  value.

  ## Fields

  - `:path` — list of atom keys and integer indices tracing from the root of
    the validated value to the failure site. Empty for root-level failures.
    Examples: `[]`, `[:user]`, `[:items, 2, :name]`.
  - `:predicate` — the name of the named constraint or check that failed, as
    an atom. `nil` for arbitrary-predicate specs.
  - `:value` — the actual value that failed (after any coercions in Step 3).
  - `:message` — a human-readable description of the failure.
  - `:meta` — open map for library-internal or user-supplied extra context
    (e.g., `%{expected_type: :integer, actual: :string}`).

  ## String representation

  Implements `String.Chars` so `to_string/1` and string interpolation work:

      iex> to_string(%Inspex.Error{path: [:user, :age], message: "must be >= 18"})
      ":user.:age: must be >= 18"

      iex> to_string(%Inspex.Error{path: [], message: "must be a map"})
      "must be a map"
  """

  @type t :: %__MODULE__{
          path: [atom() | non_neg_integer()],
          predicate: atom() | nil,
          value: term(),
          message: String.t(),
          meta: map()
        }

  defstruct [
    path: [],
    predicate: nil,
    value: nil,
    message: "",
    meta: %{}
  ]

  defimpl String.Chars do
    def to_string(%Inspex.Error{path: [], message: msg}), do: msg

    def to_string(%Inspex.Error{path: path, message: msg}) do
      formatted =
        path
        |> Enum.map(fn
          key when is_atom(key)    -> inspect(key)
          idx when is_integer(idx) -> "[#{idx}]"
          other                    -> inspect(other)
        end)
        |> Enum.join(".")

      "#{formatted}: #{msg}"
    end
  end
end

# ---------------------------------------------------------------------------

defmodule Inspex.ExplainResult do
  @moduledoc """
  The structured result of `Inspex.explain/2`.

  ## Fields

  - `:valid?` — `true` if the value conformed to the spec.
  - `:value` — the (possibly shaped/coerced) value on success, the original
    value on failure.
  - `:errors` — list of `Inspex.Error.t()`. Empty on success.
  - `:formatted` — a pre-rendered newline-delimited string of all error
    messages, ready to display. `"ok"` on success.

  ## Usage

      iex> result = Inspex.explain(schema, bad_data)
      iex> result.valid?
      false
      iex> IO.puts(result.formatted)
      :name: must be filled
      :email: key must be present
      :age[2]: must be >= 0
  """

  @type t :: %__MODULE__{
          valid?: boolean(),
          value: term(),
          errors: [Inspex.Error.t()],
          formatted: String.t()
        }

  defstruct [:valid?, :value, errors: [], formatted: ""]
end
