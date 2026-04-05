defmodule Inspex do
  @moduledoc """
  `inspex` — a Clojure spec-inspired validation & parsing library for Elixir.

  ## Design

  - **Parse, don't validate**: `conform/2` returns a *shaped* value on
    success, not just `true`. Coercions (Step 3) slot naturally into this.
  - **Specs are values**: a spec is a struct, not a module. Store it in a
    variable, pass it to a function, compose it with other specs.
  - **Named constraints are introspectable**: `string(:filled?)` carries
    metadata the generator (Step 4) can use. Arbitrary predicates via
    `spec/1` are opaque — you supply the generator yourself.
  - **Complete error reporting**: `Schema` and `ListOf` accumulate errors
    across all keys/elements in one pass. No need for multiple round-trips.

  ## Quick start

      import Inspex

      user = schema(%{
        required(:name)  => string(:filled?),
        required(:email) => string(:filled?, format: ~r/@/),
        required(:age)   => integer(gte?: 18),
        optional(:role)  => atom(in?: [:admin, :user, :guest])
      })

      Inspex.conform(user, %{name: "Mark", email: "mark@x.com", age: 33})
      #=> {:ok, %{name: "Mark", email: "mark@x.com", age: 33}}

      Inspex.conform(user, %{name: "", age: 15})
      #=> {:error, [
      #=>   %Inspex.Error{path: [:name],  message: "must be filled"},
      #=>   %Inspex.Error{path: [:email], message: "key :email must be present"},
      #=>   %Inspex.Error{path: [:age],   message: "must be >= 18"}
      #=> ]}

      Inspex.explain(user, %{name: "", age: 15})
      #=> %Inspex.ExplainResult{
      #=>   valid?: false,
      #=>   formatted: ":name: must be filled\\n:email: key :email must be present\\n:age: must be >= 18"
      #=>   ...
      #=> }
  """

  alias Inspex.{
    Spec, All, Any, Not, Maybe, Ref, ListOf, Cond, Schema, SchemaKey,
    Error, ExplainResult, Constraints
  }

  # ---------------------------------------------------------------------------
  # Type alias — anything the conform interpreter can dispatch on
  # ---------------------------------------------------------------------------

  @type conformable ::
          Spec.t()
          | All.t()
          | Any.t()
          | Not.t()
          | Maybe.t()
          | Ref.t()
          | ListOf.t()
          | Cond.t()
          | Schema.t()

  @type conform_result :: {:ok, term()} | {:error, [Error.t()]}

  # ===========================================================================
  # spec/1 macro
  # ===========================================================================

  # Guard functions recognized for zero-arg shorthand in `spec/1`.
  # `spec(is_integer() and &(&1 > 0))` — the `is_integer()` part gets rewritten
  # to `fn __v__ -> is_integer(__v__) end` automatically.
  @guard_fns ~w(
    is_atom is_binary is_bitstring is_boolean is_exception is_float
    is_function is_integer is_list is_map is_map_key is_nil is_number
    is_pid is_port is_reference is_struct is_tuple
  )a

  @doc """
  Builds a predicate spec from an arbitrary boolean expression.

  ## Supported forms

      # Norm-style guard + predicate composition (most ergonomic):
      spec(is_integer() and &(&1 > 0))
      spec(is_binary() and &(byte_size(&1) > 3))

      # Explicit function capture:
      spec(&is_integer/1)
      spec(&(&1 > 0))

      # Anonymous function:
      spec(fn x -> is_integer(x) and rem(x, 2) == 0 end)

      # `and`-chaining of any of the above:
      spec(is_integer() and &(&1 > 0) and &(rem(&1, 2) == 0))

  ## On generators (Step 4)

  Predicate specs are opaque to the generator — it cannot infer what data
  would satisfy an arbitrary function. In Step 4, supply a generator explicitly:

      spec(fn x -> rem(x, 2) == 0 end, gen: StreamData.integer() |> StreamData.filter(&(rem(&1,2)==0)))

  For now, the `:gen` option is accepted but ignored.

  ## Prefer typed builders when possible

  `integer(gt?: 0)` is equivalent to `spec(is_integer() and &(&1 > 0))` for
  conforming, but the typed form carries named constraint metadata that the
  generator can use without a manual hint.
  """
  defmacro spec(expr, _opts \\ []) do
    source = Macro.to_string(expr)
    # We rewrite the spec expression into a boolean body using a known var,
    # then wrap it once in `fn __v__ -> body end`.
    # This avoids nested lambdas and keeps the compiled function clean.
    v = Macro.var(:__inspex_v__, __MODULE__)
    bool_body = to_bool_expr(expr, v)

    quote do
      %Inspex.Spec{
        predicate: fn unquote(v) -> unquote(bool_body) end,
        meta: %{source: unquote(source)}
      }
    end
  end

  # ===========================================================================
  # Inspex.def/2 — global spec registration (Clojure s/def equivalent)
  # ===========================================================================

  @doc """
  Registers a spec globally under `name` in the `Inspex.Registry`.

  The Clojure spec equivalent of `s/def`. Specs registered this way are
  accessible from any process via `ref/1`.

      import Inspex

      defspec :email,  string(:filled?, format: ~r/@/)
      defspec :age,    integer(gte?: 0, lte?: 150)
      defspec :role,   atom(in?: [:admin, :user, :guest])

      user = schema(%{
        required(:email) => ref(:email),
        required(:age)   => ref(:age),
        optional(:role)  => ref(:role)
      })

  ## When to use `defspec` vs `defschema`

  - `defspec` is for **leaf specs** — primitives and combinators you want to
    name and reuse across schemas.
  - `defschema` is for **composite schemas** — generates callable functions in
    the current module and is the ergonomic entry point for validation.
  """
  defmacro defspec(name, spec) when is_atom(name) do
    quote do
      Inspex.Registry.register(unquote(name), unquote(spec))
    end
  end

  # ===========================================================================
  # defschema — generates a named validator function (Peri-style ergonomics)
  # ===========================================================================

  @doc """
  Defines a named schema and generates `name/1` and `name!/1` validator
  functions in the calling module.

  ## Usage

      defmodule MyApp.Schemas do
        import Inspex

        defschema :user do
          schema(%{
            required(:name)  => string(:filled?),
            required(:email) => ref(:email),
            required(:age)   => integer(gte?: 18),
            optional(:role)  => atom(in?: [:admin, :user])
          })
        end
      end

      MyApp.Schemas.user(%{name: "Mark", email: "m@x.com", age: 33})
      #=> {:ok, %{name: "Mark", email: "m@x.com", age: 33}}

      MyApp.Schemas.user!(%{name: "", age: 15})
      #=> raises Inspex.ConformError

  ## Generated functions

  - `name/1`  — returns `{:ok, shaped_value}` or `{:error, [%Inspex.Error{}]}`
  - `name!/1` — returns `shaped_value` or raises `Inspex.ConformError`

  ## Registering a defschema globally

  `defschema` does not automatically register the schema in the `Inspex.Registry`.
  If you want to reference it via `ref/1`, call `Inspex.def/2` separately:

      defschema :address do
        schema(%{required(:street) => string(:filled?), required(:zip) => string(size?: 5)})
      end

      # Now ref(:address) works from other schemas
      Inspex.def(:address, address(%{}))   # ← call your own function to get the schema struct

  A cleaner approach: define the schema expression once as a module function:

      def address_schema do
        schema(%{required(:street) => string(:filled?), required(:zip) => string(size?: 5)})
      end

      defschema :address, do: address_schema()
      # Then: Inspex.def(:address, address_schema())
  """
  defmacro defschema(name, do: schema_expr) when is_atom(name) do
    bang = :"#{name}!"

    quote do
      @doc "Validates `data` against the `#{unquote(name)}` schema. Returns `{:ok, value}` or `{:error, errors}`."
      def unquote(name)(data) do
        Inspex.conform(unquote(schema_expr), data)
      end

      @doc "Like `#{unquote(name)}/1` but returns the shaped value or raises `Inspex.ConformError`."
      def unquote(bang)(data) do
        case unquote(name)(data) do
          {:ok, value}     -> value
          {:error, errors} -> raise Inspex.ConformError, name: unquote(name), errors: errors
        end
      end
    end
  end

  # `expr and expr` — recursively inline both sides
  defp to_bool_expr({:and, _, [left, right]}, v) do
    l = to_bool_expr(left, v)
    r = to_bool_expr(right, v)
    quote do unquote(l) and unquote(r) end
  end

  # `is_integer()` (zero-arg guard call) — rewrite to `is_integer(v)`
  defp to_bool_expr({guard_fn, meta, args}, v)
       when guard_fn in @guard_fns and args in [[], nil] do
    {guard_fn, meta, [v]}
  end

  # `&is_integer/1` or `&(&1 > 0)` — use apply/2 rather than capture.()
  # to avoid Elixir's nested-capture restriction when two & expressions
  # appear in the same `and` chain.
  defp to_bool_expr({:&, _, _} = capture, v) do
    quote do apply(unquote(capture), [unquote(v)]) end
  end

  # `fn x -> ... end` — same apply/2 treatment for consistency
  defp to_bool_expr({:fn, _, _} = fn_literal, v) do
    quote do apply(unquote(fn_literal), [unquote(v)]) end
  end

  # Anything else: treat as a value that responds to apply/2
  # (e.g. a local variable holding a function reference)
  defp to_bool_expr(other, v) do
    quote do apply(unquote(other), [unquote(v)]) end
  end

  # ===========================================================================
  # Primitive type builders
  # ===========================================================================

  # Shared helper: normalise `(atom, keyword)` into a flat constraint list.
  # Enables the ergonomic `string(:filled?, format: ~r/@/, min_length: 3)` form
  # in addition to the existing `string(:filled?)` and `string(filled?: true, ...)` forms.
  defp merge_constraints(shorthand, more) when is_atom(shorthand) and is_list(more) do
    [{shorthand, true} | more]
  end

  @doc """
  A string spec, with optional named constraints.

  Accepts three call forms:

      string()                                  # any string
      string(:filled?)                          # single shorthand atom
      string(:filled?, format: ~r/@/)           # shorthand + extra constraints
      string(filled?: true, format: ~r/@/)      # full keyword list
  """
  @spec string(atom() | keyword()) :: Spec.t()
  @spec string(atom(), keyword()) :: Spec.t()
  def string(constraints \\ [])
  def string(c) when is_atom(c),                 do: string([{c, true}])
  def string(cs) when is_list(cs),               do: %Spec{type: :string, constraints: cs}
  def string(c, more) when is_atom(c),           do: string(merge_constraints(c, more))

  @doc """
  An integer spec, with optional named constraints.

      integer()
      integer(:filled?)
      integer(gt?: 0, lte?: 100)
      integer(:filled?, gt?: 0)
  """
  @spec integer(atom() | keyword()) :: Spec.t()
  @spec integer(atom(), keyword()) :: Spec.t()
  def integer(constraints \\ [])
  def integer(c) when is_atom(c),                do: integer([{c, true}])
  def integer(cs) when is_list(cs),              do: %Spec{type: :integer, constraints: cs}
  def integer(c, more) when is_atom(c),          do: integer(merge_constraints(c, more))

  @doc "A float spec, with optional named constraints."
  @spec float(atom() | keyword()) :: Spec.t()
  @spec float(atom(), keyword()) :: Spec.t()
  def float(constraints \\ [])
  def float(c) when is_atom(c),                  do: float([{c, true}])
  def float(cs) when is_list(cs),                do: %Spec{type: :float, constraints: cs}
  def float(c, more) when is_atom(c),            do: float(merge_constraints(c, more))

  @doc "Accepts integers or floats, with optional named constraints."
  @spec number(keyword()) :: Spec.t()
  def number(constraints \\ []),                 do: %Spec{type: :number, constraints: constraints}

  @doc "A boolean spec. No meaningful constraints apply."
  @spec boolean() :: Spec.t()
  def boolean,                                   do: %Spec{type: :boolean}

  @doc """
  An atom spec, with optional named constraints.

      atom()
      atom(in?: [:admin, :user])
  """
  @spec atom(keyword()) :: Spec.t()
  def atom(constraints \\ []),                   do: %Spec{type: :atom, constraints: constraints}

  @doc "Accepts any map. For shape validation, use `schema/1`."
  @spec map() :: Spec.t()
  def map,                                       do: %Spec{type: :map}

  @doc """
  Accepts any list. For typed lists (all elements checked), use `list_of/1`.

      list()
      list(:filled?)                    # non-empty list
      list(:filled?, min_length: 2)
  """
  @spec list(atom() | keyword()) :: Spec.t()
  @spec list(atom(), keyword()) :: Spec.t()
  def list(constraints \\ [])
  def list(c) when is_atom(c),                   do: list([{c, true}])
  def list(cs) when is_list(cs),                 do: %Spec{type: :list, constraints: cs}
  def list(c, more) when is_atom(c),             do: list(merge_constraints(c, more))

  @doc "Accepts any value unconditionally. Useful as an `else` branch or placeholder."
  @spec any() :: Spec.t()
  def any,                                       do: %Spec{type: :any}

  @doc "Accepts only `nil`."
  @spec nil_spec() :: Spec.t()
  def nil_spec,                                  do: %Spec{type: :null}

  # ===========================================================================
  # Combinator builders
  # ===========================================================================

  @doc """
  AND — all specs must conform (set-theoretic intersection).
  Conforms the value through specs in order; the output of each becomes
  the input of the next (lightweight pipeline). Short-circuits on first failure.
  """
  @spec all_of([conformable()]) :: All.t()
  def all_of(specs) when is_list(specs), do: %All{specs: specs}

  @doc """
  OR — at least one spec must conform (set-theoretic union).
  Tries specs in order and returns the first successful result.
  """
  @spec any_of([conformable()]) :: Any.t()
  def any_of(specs) when is_list(specs), do: %Any{specs: specs}

  @doc """
  NOT — the spec must not conform (set-theoretic complement).
  The value passes through unchanged on success.
  """
  @spec not_spec(conformable()) :: Not.t()
  def not_spec(spec), do: %Not{spec: spec}

  @doc """
  Nullable wrapper. `nil` passes unconditionally; non-nil values are checked
  against `inner_spec`.
  """
  @spec maybe(conformable()) :: Maybe.t()
  def maybe(inner_spec), do: %Maybe{spec: inner_spec}

  @doc """
  Lazy reference to a named spec in `Inspex.Registry`.
  Resolved at conform-time — enables circular schemas.
  """
  @spec ref(atom()) :: Ref.t()
  def ref(name) when is_atom(name), do: %Ref{name: name}

  @doc """
  Every element of a list must conform to `element_spec`.
  Accumulates errors from all elements — does not short-circuit.
  """
  @spec list_of(conformable()) :: ListOf.t()
  def list_of(element_spec), do: %ListOf{element_spec: element_spec}

  @doc """
  Conditional spec. Applies `if_spec` when `predicate_fn.(value)` is truthy,
  `else_spec` otherwise. Defaults to passthrough (`any()`) if `else_spec`
  is omitted.
  """
  @spec cond_spec((term() -> boolean()), conformable(), conformable()) :: Cond.t()
  def cond_spec(predicate_fn, if_spec, else_spec \\ nil) when is_function(predicate_fn, 1) do
    %Cond{predicate_fn: predicate_fn, if_spec: if_spec, else_spec: else_spec || any()}
  end

  # ===========================================================================
  # Schema builders
  # ===========================================================================

  @doc """
  Builds a **closed** map spec from a map of `required(key)` / `optional(key)`
  => spec pairs.

      schema(%{
        required(:name)  => string(:filled?),
        required(:email) => string(format: ~r/@/),
        optional(:age)   => integer(gte?: 0)
      })

  Closed: keys not declared in the schema are rejected.
  For open schemas (extra keys allowed), use `open_schema/1`.

  Bare atoms as keys are treated as `required`:

      schema(%{name: string(), age: integer()})
      # same as: required(:name) => ..., required(:age) => ...
  """
  @spec schema(map()) :: Schema.t()
  def schema(key_map) when is_map(key_map), do: build_schema(key_map, false)

  @doc """
  Like `schema/1` but **open**: extra keys pass through unchanged in the
  shaped output.
  """
  @spec open_schema(map()) :: Schema.t()
  def open_schema(key_map) when is_map(key_map), do: build_schema(key_map, true)

  @doc "Marks a schema map key as required. Returns a tagged tuple used by `schema/1`."
  @spec required(atom()) :: {:required, atom()}
  def required(name) when is_atom(name), do: {:required, name}

  @doc "Marks a schema map key as optional. Returns a tagged tuple used by `schema/1`."
  @spec optional(atom()) :: {:optional, atom()}
  def optional(name) when is_atom(name), do: {:optional, name}

  defp build_schema(key_map, open?) do
    keys =
      Enum.map(key_map, fn
        {{:required, name}, spec} -> %SchemaKey{name: name, spec: spec, required: true}
        {{:optional, name}, spec} -> %SchemaKey{name: name, spec: spec, required: false}
        {name, spec} when is_atom(name) -> %SchemaKey{name: name, spec: spec, required: true}
      end)

    %Schema{keys: keys, open?: open?}
  end

  # ===========================================================================
  # The conform interpreter — a recursive, pattern-matched tree walk
  # ===========================================================================

  @doc """
  Validates `value` against `spec`.

  Returns `{:ok, shaped_value}` on success, or `{:error, [%Inspex.Error{}]}`
  with a complete list of all failures.

  The shaped value may differ from the input once coercions (Step 3) are
  introduced. For now it is always the original value unchanged.
  """
  @spec conform(conformable(), term()) :: conform_result()

  # --- Spec (leaf) -----------------------------------------------------------

  # `any()` — unconditional pass
  def conform(%Spec{type: :any}, value), do: {:ok, value}

  # `nil_spec()` — only nil passes. Uses :null (not :nil) because in Elixir
  # nil == :nil, which would collide with the unset zero-value of the type field.
  def conform(%Spec{type: :null}, nil),   do: {:ok, nil}
  def conform(%Spec{type: :null}, value), do: {:error, [type_error(:null, value, "must be nil")]}

  # Typed spec — check type, then named constraints
  def conform(%Spec{type: type, constraints: cs, predicate: nil}, value)
      when not is_nil(type) do
    with :ok <- check_type(type, value),
         [] <- Constraints.check(value, cs) do
      {:ok, value}
    else
      {:error, err} -> {:error, [err]}
      errors when is_list(errors) -> {:error, errors}
    end
  end

  # Predicate-only spec (type: nil, predicate: fn)
  def conform(%Spec{type: nil, predicate: pred, meta: meta}, value)
      when is_function(pred, 1) do
    if pred.(value) do
      {:ok, value}
    else
      source = Map.get(meta, :source, "anonymous predicate")
      {:error, [%Error{value: value, message: "failed spec: #{source}"}]}
    end
  end

  # Typed + predicated spec (e.g. `spec(is_integer() and &(&1 > 0))`)
  def conform(%Spec{type: type, predicate: pred, constraints: cs}, value)
      when not is_nil(type) and not is_nil(pred) do
    with :ok <- check_type(type, value),
         true <- pred.(value) || :predicate_failed,
         [] <- Constraints.check(value, cs) do
      {:ok, value}
    else
      {:error, err} -> {:error, [err]}
      :predicate_failed ->
        {:error, [%Error{value: value, predicate: :predicate, message: "failed predicate"}]}
      errors when is_list(errors) -> {:error, errors}
    end
  end

  # Empty spec (no type, no predicate) — passthrough, same as any()
  def conform(%Spec{type: nil, predicate: nil}, value), do: {:ok, value}

  # --- All (AND / intersection) -----------------------------------------------

  # Vacuous truth: all_of([]) always passes
  def conform(%All{specs: []}, value), do: {:ok, value}

  def conform(%All{specs: specs}, value) do
    Enum.reduce_while(specs, {:ok, value}, fn spec, {:ok, acc} ->
      case conform(spec, acc) do
        {:ok, shaped} -> {:cont, {:ok, shaped}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # --- Any (OR / union) -------------------------------------------------------

  # Vacuous failure: any_of([]) never passes
  def conform(%Any{specs: []}, value) do
    {:error, [%Error{value: value, message: "any_of([]) — empty union never conforms"}]}
  end

  def conform(%Any{specs: specs}, value) do
    Enum.find_value(specs, fn spec ->
      case conform(spec, value) do
        {:ok, _} = ok -> ok
        {:error, _} -> nil
      end
    end) ||
      {:error,
       [%Error{value: value, message: "value did not conform to any spec in any_of"}]}
  end

  # --- Not (negation) ---------------------------------------------------------

  def conform(%Not{spec: spec}, value) do
    case conform(spec, value) do
      {:ok, _} ->
        {:error, [%Error{value: value, message: "value must NOT conform to spec"}]}

      {:error, _} ->
        # Negation succeeded — pass through the original value unchanged.
        # (Negation cannot shape data, only gate it.)
        {:ok, value}
    end
  end

  # --- Maybe (nullable) -------------------------------------------------------

  def conform(%Maybe{}, nil), do: {:ok, nil}
  def conform(%Maybe{spec: spec}, value), do: conform(spec, value)

  # --- Ref (lazy registry resolution) ----------------------------------------

  def conform(%Ref{name: name}, value) do
    spec = Inspex.Registry.fetch!(name)
    conform(spec, value)
  rescue
    e in Inspex.UndefinedSpecError ->
      {:error, [%Error{value: value, message: Exception.message(e)}]}
  end

  # --- ListOf (typed list) ----------------------------------------------------

  def conform(%ListOf{}, value) when not is_list(value) do
    {:error, [type_error(:list, value, "must be a list")]}
  end

  def conform(%ListOf{element_spec: el_spec}, value) when is_list(value) do
    # Accumulate errors from ALL elements — do not short-circuit.
    {shaped_rev, errors} =
      value
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {elem, idx}, {acc_shaped, acc_errs} ->
        case conform(el_spec, elem) do
          {:ok, shaped} ->
            {[shaped | acc_shaped], acc_errs}

          {:error, elem_errors} ->
            # Prepend the element index to each error's path
            indexed = prepend_path(elem_errors, idx)
            {[elem | acc_shaped], acc_errs ++ indexed}
        end
      end)

    if errors == [] do
      {:ok, Enum.reverse(shaped_rev)}
    else
      {:error, errors}
    end
  end

  # --- Cond (conditional branching) -------------------------------------------

  def conform(%Cond{predicate_fn: pred, if_spec: if_spec, else_spec: else_spec}, value) do
    if pred.(value),
      do: conform(if_spec, value),
      else: conform(else_spec, value)
  end

  # --- Schema (map validation) ------------------------------------------------

  def conform(%Schema{}, value) when not is_map(value) do
    {:error, [type_error(:map, value, "must be a map")]}
  end

  def conform(%Schema{keys: key_specs, open?: open?}, value) when is_map(value) do
    declared_names = MapSet.new(key_specs, & &1.name)

    # 1. Missing required key errors
    missing_errors =
      key_specs
      |> Enum.filter(& &1.required)
      |> Enum.reject(&Map.has_key?(value, &1.name))
      |> Enum.map(fn %SchemaKey{name: name} ->
        %Error{
          path: [name],
          predicate: :has_key?,
          value: nil,
          message: "key #{inspect(name)} must be present"
        }
      end)

    # 2. Unknown key errors (closed schemas only)
    unknown_errors =
      if open? do
        []
      else
        value
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(declared_names, &1))
        |> Enum.map(fn key ->
          %Error{
            path: [key],
            predicate: :unknown_key?,
            value: Map.get(value, key),
            message: "unknown key #{inspect(key)}"
          }
        end)
      end

    # 3. Conform each present key — accumulate ALL errors
    {shaped_pairs, value_errors} =
      key_specs
      |> Enum.filter(&Map.has_key?(value, &1.name))
      |> Enum.reduce({[], []}, fn %SchemaKey{name: name, spec: spec}, {acc_pairs, acc_errs} ->
        raw = Map.get(value, name)

        case conform(spec, raw) do
          {:ok, shaped} ->
            {[{name, shaped} | acc_pairs], acc_errs}

          {:error, field_errors} ->
            # Prepend the field name to each error's path
            keyed = prepend_path(field_errors, name)
            {acc_pairs, acc_errs ++ keyed}
        end
      end)

    all_errors = missing_errors ++ unknown_errors ++ value_errors

    if all_errors == [] do
      shaped =
        if open? do
          # Open schemas: merge shaped values onto the original map to
          # preserve unknown keys in the output
          Map.merge(value, Map.new(shaped_pairs))
        else
          Map.new(shaped_pairs)
        end

      {:ok, shaped}
    else
      {:error, all_errors}
    end
  end

  # ===========================================================================
  # valid?/2 and explain/2
  # ===========================================================================

  @doc """
  Returns `true` if `value` conforms to `spec`, `false` otherwise.

  Does not produce error details — use `explain/2` for diagnostics.
  """
  @spec valid?(conformable(), term()) :: boolean()
  def valid?(spec, value), do: match?({:ok, _}, conform(spec, value))

  @doc """
  Returns a `%Inspex.ExplainResult{}` with structured errors and a
  pre-formatted string for display.

  For just the `{:ok, val} | {:error, errors}` tuple, use `conform/2`.
  """
  @spec explain(conformable(), term()) :: ExplainResult.t()
  def explain(spec, value) do
    case conform(spec, value) do
      {:ok, shaped} ->
        %ExplainResult{valid?: true, value: shaped, errors: [], formatted: "ok"}

      {:error, errors} ->
        formatted =
          errors
          |> Enum.map(&to_string/1)
          |> Enum.join("\n")

        %ExplainResult{valid?: false, value: value, errors: errors, formatted: formatted}
    end
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  @spec check_type(atom(), term()) :: :ok | {:error, Error.t()}
  defp check_type(:string,  v) when is_binary(v),           do: :ok
  defp check_type(:integer, v) when is_integer(v),          do: :ok
  defp check_type(:float,   v) when is_float(v),            do: :ok
  defp check_type(:number,  v) when is_number(v),           do: :ok
  defp check_type(:boolean, v) when is_boolean(v),          do: :ok
  defp check_type(:atom,    v) when is_atom(v),             do: :ok
  defp check_type(:map,     v) when is_map(v),              do: :ok
  defp check_type(:list,    v) when is_list(v),             do: :ok
  defp check_type(:tuple,   v) when is_tuple(v),            do: :ok
  defp check_type(:pid,     v) when is_pid(v),              do: :ok
  defp check_type(type, value) do
    {:error, type_error(type, value, "must be a #{type}, got: #{inspect(type_of(value))}")}
  end

  defp type_error(type, value, message) do
    %Error{
      predicate: :type?,
      value: value,
      message: message,
      meta: %{expected_type: type, actual_type: type_of(value)}
    }
  end

  defp prepend_path(errors, key) do
    Enum.map(errors, fn err -> %{err | path: [key | err.path]} end)
  end

  defp type_of(v) when is_integer(v),  do: :integer
  defp type_of(v) when is_binary(v),   do: :string
  defp type_of(v) when is_float(v),    do: :float
  defp type_of(v) when is_boolean(v),  do: :boolean
  defp type_of(v) when is_atom(v),     do: :atom
  defp type_of(v) when is_list(v),     do: :list
  defp type_of(v) when is_map(v),      do: :map
  defp type_of(v) when is_tuple(v),    do: :tuple
  defp type_of(v) when is_pid(v),      do: :pid
  defp type_of(nil),                   do: :nil
  defp type_of(_),                     do: :unknown
end
