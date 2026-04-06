defmodule Gladius.Validate do
  @moduledoc """
  Wraps any Gladius conformable with one or more cross-field validation rules.

  Rules run **only when the inner spec fully passes** — they never see
  partially-valid data. All rules run on success and all errors accumulate;
  the first failing rule does not short-circuit the rest.

  ## Construction

  Use `Gladius.validate/2`. Multiple calls chain by appending rules to the
  same struct rather than nesting, keeping the conform tree flat:

      schema(%{
        required(:start_date) => string(:filled?),
        required(:end_date)   => string(:filled?)
      })
      |> validate(fn %{start_date: s, end_date: e} ->
        if e > s, do: :ok, else: {:error, :end_date, "must be after start date"}
      end)
      |> validate(fn %{start_date: s} ->
        if s >= "2020-01-01", do: :ok, else: {:error, :start_date, "too far in the past"}
      end)

  ## Rule return values

      :ok                                               # passes
      {:error, :field_name, "message"}                  # single named-field error
      {:error, :base, "message"}                        # root-level error (no field)
      {:error, [{:field_a, "msg"}, {:field_b, "msg"}]}  # multiple errors

  Errors become `%Gladius.Error{predicate: :validate, path: [field]}`.
  Using `:base` as the field produces `path: []`.

  ## Semantics

  - Inner spec fails → `{:error, errors}` passed through; rules not called.
  - Inner spec passes → all rules called on the shaped output.
  - Rule raises → exception is caught and surfaced as
    `%Gladius.Error{predicate: :validate, message: "validate rule raised: ..."}`.
  """

  @enforce_keys [:spec, :rules]
  defstruct [:spec, :rules]

  @type rule_result ::
          :ok
          | {:error, atom(), String.t()}
          | {:error, [{atom(), String.t()}]}

  @type t :: %__MODULE__{
          spec:  Gladius.conformable(),
          rules: [(term() -> rule_result())]
        }
end
