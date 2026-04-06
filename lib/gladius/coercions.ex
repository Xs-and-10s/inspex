defmodule Gladius.Coercions do
  @moduledoc """
  Built-in coercion functions for use with `Gladius.coerce/2`.

  All coercions are **idempotent** — if the value is already the target type
  they return `{:ok, value}` unchanged, so you never need to special-case
  values that arrived pre-coerced.

  ## Built-in coercions

  | `from:`     | Target    | Notes                                    |
  |-------------|-----------|------------------------------------------|
  | `:string`   | `integer` | trims whitespace, strict integer parse   |
  | `:string`   | `float`   | passes integers through as floats        |
  | `:string`   | `boolean` | true/yes/1/on, false/no/0/off            |
  | `:string`   | `atom`    | `String.to_existing_atom/1` — safe       |
  | `:string`   | `number`  | same as string → float                   |
  | `:integer`  | `float`   | `42 → 42.0`                              |
  | `:integer`  | `string`  | `42 → "42"`                              |
  | `:integer`  | `boolean` | `0 → false`, `1 → true` (db booleans)   |
  | `:atom`     | `string`  | `Atom.to_string/1`                       |
  | `:float`    | `integer` | **truncates** toward zero: `3.7 → 3`     |
  | `:float`    | `string`  | `"Float.to_string(v)"`                                 |

  ## User-extensible registry

  Register application-specific coercions at startup:

      # In your Application.start/2 or a module's @on_load:
      Gladius.Coercions.register({:decimal, :float}, fn
        %Decimal{} = d -> {:ok, Decimal.to_float(d)}
        v when is_float(v) -> {:ok, v}
        v -> {:error, "cannot coerce \#{inspect(v)} to float"}
      end)

  Then use it anywhere in your app:

      coerce(float(gt?: 0.0), from: :decimal)

  User-registered coercions take **precedence over built-ins** for the same
  `{source, target}` pair, so you can override default behaviour.

  Registrations persist for the lifetime of the BEAM node. They are stored in
  `:persistent_term`, so reads are extremely fast (no ETS lookup, no lock) but
  writes trigger a global GC pass. Register at startup, not in hot paths.

  See `register/2` and `registered/0`.
  """

  @pt_key {__MODULE__, :user_registry}

  # ===========================================================================
  # String → other types  (HTTP params, form data, CSV, query strings)
  # ===========================================================================

  @doc "Coerces a string to an integer. Passes integers through unchanged."
  @spec string_to_integer(term()) :: {:ok, integer()} | {:error, String.t()}
  def string_to_integer(v) when is_integer(v), do: {:ok, v}

  def string_to_integer(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} -> {:ok, n}
      _       -> {:error, "cannot coerce #{inspect(v)} to integer"}
    end
  end

  def string_to_integer(v), do: {:error, "cannot coerce #{inspect(v)} to integer"}

  @doc "Coerces a string to a float. Passes floats and integers through unchanged."
  @spec string_to_float(term()) :: {:ok, float()} | {:error, String.t()}
  def string_to_float(v) when is_float(v),   do: {:ok, v}
  def string_to_float(v) when is_integer(v), do: {:ok, v * 1.0}

  def string_to_float(v) when is_binary(v) do
    case Float.parse(String.trim(v)) do
      {f, ""} -> {:ok, f}
      _       -> {:error, "cannot coerce #{inspect(v)} to float"}
    end
  end

  def string_to_float(v), do: {:error, "cannot coerce #{inspect(v)} to float"}

  @doc """
  Coerces a string to a boolean. Passes booleans through unchanged.

  Truthy: `"true"`, `"1"`, `"yes"`, `"on"` (case-insensitive)
  Falsy:  `"false"`, `"0"`, `"no"`, `"off"` (case-insensitive)
  """
  @spec string_to_boolean(term()) :: {:ok, boolean()} | {:error, String.t()}
  def string_to_boolean(v) when is_boolean(v), do: {:ok, v}

  def string_to_boolean(v) when is_binary(v) do
    case String.downcase(String.trim(v)) do
      t when t in ~w(true 1 yes on)  -> {:ok, true}
      f when f in ~w(false 0 no off) -> {:ok, false}
      _ ->
        {:error,
         "cannot coerce #{inspect(v)} to boolean — " <>
           "expected true/false/yes/no/1/0/on/off"}
    end
  end

  def string_to_boolean(v), do: {:error, "cannot coerce #{inspect(v)} to boolean"}

  @doc """
  Coerces a string to an existing atom. Passes atoms through unchanged.

  Uses `String.to_existing_atom/1` — safe against atom table exhaustion.
  For enum fields, prefer `atom(in?: [...])` which guarantees the atoms are
  always already loaded.
  """
  @spec string_to_atom(term()) :: {:ok, atom()} | {:error, String.t()}
  def string_to_atom(v) when is_atom(v), do: {:ok, v}

  def string_to_atom(v) when is_binary(v) do
    {:ok, String.to_existing_atom(v)}
  rescue
    ArgumentError -> {:error, "#{inspect(v)} is not an existing atom"}
  end

  def string_to_atom(v), do: {:error, "cannot coerce #{inspect(v)} to atom"}

  # ===========================================================================
  # Integer → other types  (database integers, Ecto changesets)
  # ===========================================================================

  @doc "Coerces an integer to a float. Passes floats through unchanged."
  @spec integer_to_float(term()) :: {:ok, float()} | {:error, String.t()}
  def integer_to_float(v) when is_float(v),   do: {:ok, v}
  def integer_to_float(v) when is_integer(v), do: {:ok, v * 1.0}
  def integer_to_float(v), do: {:error, "cannot coerce #{inspect(v)} to float"}

  @doc "Coerces an integer to its decimal string representation. Passes strings through unchanged."
  @spec integer_to_string(term()) :: {:ok, String.t()} | {:error, String.t()}
  def integer_to_string(v) when is_binary(v),  do: {:ok, v}
  def integer_to_string(v) when is_integer(v), do: {:ok, Integer.to_string(v)}
  def integer_to_string(v), do: {:error, "cannot coerce #{inspect(v)} to string"}

  @doc """
  Coerces a database-style integer boolean to `true`/`false`.
  Passes booleans through unchanged. Only `0` and `1` are accepted.
  """
  @spec integer_to_boolean(term()) :: {:ok, boolean()} | {:error, String.t()}
  def integer_to_boolean(v) when is_boolean(v), do: {:ok, v}
  def integer_to_boolean(0), do: {:ok, false}
  def integer_to_boolean(1), do: {:ok, true}

  def integer_to_boolean(v) do
    {:error, "cannot coerce #{inspect(v)} to boolean — expected 0 or 1"}
  end

  # ===========================================================================
  # Atom → other types
  # ===========================================================================

  @doc "Coerces an atom to its string name via `Atom.to_string/1`. Passes strings through unchanged."
  @spec atom_to_string(term()) :: {:ok, String.t()} | {:error, String.t()}
  def atom_to_string(v) when is_binary(v), do: {:ok, v}
  def atom_to_string(nil), do: {:error, "cannot coerce nil to string"}
  def atom_to_string(v) when is_atom(v),   do: {:ok, Atom.to_string(v)}
  def atom_to_string(v), do: {:error, "cannot coerce #{inspect(v)} to string"}

  # ===========================================================================
  # Float → other types
  # ===========================================================================

  @doc """
  Coerces a float to an integer by **truncating** toward zero.
  Passes integers through unchanged.

  `3.7 → 3`, `-3.7 → -3`. Use a custom function if you need rounding.
  """
  @spec float_to_integer(term()) :: {:ok, integer()} | {:error, String.t()}
  def float_to_integer(v) when is_integer(v), do: {:ok, v}
  def float_to_integer(v) when is_float(v),   do: {:ok, trunc(v)}
  def float_to_integer(v), do: {:error, "cannot coerce #{inspect(v)} to integer"}

  @doc "Coerces a float to its string representation. Passes strings through unchanged."
  @spec float_to_string(term()) :: {:ok, String.t()} | {:error, String.t()}
  def float_to_string(v) when is_binary(v), do: {:ok, v}
  def float_to_string(v) when is_float(v),  do: {:ok, "#{v}"}
  def float_to_string(v), do: {:error, "cannot coerce #{inspect(v)} to string"}

  # ===========================================================================
  # User-extensible registry
  # ===========================================================================

  @doc """
  Registers a user-defined coercion for the given `{source_type, target_type}` pair.

  User-registered coercions are checked before built-ins, so you can override
  default behaviour for any pair.

  Should be called once at application startup (e.g. in `Application.start/2`)
  because `:persistent_term` writes trigger a global GC pass.

      Gladius.Coercions.register({:decimal, :float}, fn
        %Decimal{} = d -> {:ok, Decimal.to_float(d)}
        v when is_float(v) -> {:ok, v}
        v -> {:error, "cannot coerce \#{inspect(v)} to float"}
      end)
  """
  @spec register({atom(), atom()}, (term() -> {:ok, term()} | {:error, String.t()})) :: :ok
  def register({source, target}, fun)
      when is_atom(source) and is_atom(target) and is_function(fun, 1) do
    current = :persistent_term.get(@pt_key, %{})
    :persistent_term.put(@pt_key, Map.put(current, {source, target}, fun))
    :ok
  end

  @doc """
  Returns all user-registered coercions as a map of `{source, target} => fun`.

  Useful for introspection and testing.
  """
  @spec registered() :: %{{atom(), atom()} => function()}
  def registered, do: :persistent_term.get(@pt_key, %{})

  # ===========================================================================
  # Lookup
  # ===========================================================================

  @doc """
  Returns the coercion function for `{source_type, target_type}`.

  User-registered coercions take precedence over built-ins.
  Raises `ArgumentError` if no coercion exists for the pair — this is a
  programming error, not a data error, so it surfaces at build time (when
  `coerce(spec, from: source)` is called) rather than at validation time.
  """
  @spec lookup(atom(), atom()) :: (term() -> {:ok, term()} | {:error, String.t()})
  def lookup(source, target) do
    user = :persistent_term.get(@pt_key, %{})

    case Map.get(user, {source, target}) do
      nil -> builtin(source, target)
      fun -> fun
    end
  end

  # Built-in dispatch — kept private so the public API is just lookup/2.
  defp builtin(:string,  :integer), do: &string_to_integer/1
  defp builtin(:string,  :float),   do: &string_to_float/1
  defp builtin(:string,  :boolean), do: &string_to_boolean/1
  defp builtin(:string,  :atom),    do: &string_to_atom/1
  defp builtin(:string,  :number),  do: &string_to_float/1
  defp builtin(:integer, :float),   do: &integer_to_float/1
  defp builtin(:integer, :string),  do: &integer_to_string/1
  defp builtin(:integer, :boolean), do: &integer_to_boolean/1
  defp builtin(:atom,    :string),  do: &atom_to_string/1
  defp builtin(:float,   :integer), do: &float_to_integer/1
  defp builtin(:float,   :string),  do: &float_to_string/1

  defp builtin(source, target) do
    user_pairs =
      registered()
      |> Map.keys()
      |> Enum.map_join("\n    ", fn {s, t} -> "from: #{inspect(s)} → #{inspect(t)}" end)

    user_section =
      if user_pairs == "",
        do: "",
        else: "\n\n  User-registered:\n    #{user_pairs}"

    raise ArgumentError, """
    No coercion from #{inspect(source)} to #{inspect(target)}.

    Built-in coercions (from: source):
      :string  → :integer, :float, :number, :boolean, :atom
      :integer → :float, :string, :boolean
      :atom    → :string
      :float   → :integer, :string
    #{user_section}
    Register a custom coercion:

        Gladius.Coercions.register({#{inspect(source)}, #{inspect(target)}}, fn value ->
          # return {:ok, coerced} or {:error, "reason"}
        end)
    """
  end
end
