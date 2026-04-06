defmodule Gladius.GeneratorError do
  @moduledoc """
  Raised by `Gladius.gen/1` when a generator cannot be inferred from a spec.

  This happens for:
  - Predicate-only specs (`spec(fn x -> ... end)`) — the predicate is opaque
  - `not_spec/1` — no base type to generate from
  - `cond_spec/3` — branching logic depends on runtime data

  ## Fixing it

  Supply an explicit generator via the `:gen` option on `spec/2`:

      spec(fn x -> rem(x, 2) == 0 end,
           gen: StreamData.integer() |> StreamData.filter(&(rem(&1, 2) == 0)))

  Or use a typed builder whose constraints ARE introspectable:

      # This generator is inferred automatically:
      all_of([integer(), spec(&(rem(&1, 2) == 0), gen: StreamData.filter(StreamData.integer(), &(rem(&1,2)==0)))])
  """

  defexception [:spec]

  @impl true
  def message(%{spec: spec}) do
    """
    Cannot infer a generator for: #{inspect(spec)}

    Predicate specs are opaque to the generator — it cannot reverse an
    arbitrary function into a data source.

    Provide an explicit generator with the :gen option:

        spec(your_predicate, gen: your_stream_data_generator)

    Typed builders (string/1, integer/1, etc.) with named constraints are
    inferred automatically and do not require a :gen option.
    """
  end
end
