defmodule Gladius do
  @moduledoc """
  `gladius` — a Clojure spec-inspired validation & parsing library for Elixir.

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

      import Gladius

      user = schema(%{
        required(:name)  => string(:filled?),
        required(:email) => string(:filled?, format: ~r/@/),
        required(:age)   => integer(gte?: 18),
        optional(:role)  => atom(in?: [:admin, :user, :guest])
      })

      Gladius.conform(user, %{name: "Mark", email: "mark@x.com", age: 33})
      #=> {:ok, %{name: "Mark", email: "mark@x.com", age: 33}}

      Gladius.conform(user, %{name: "", age: 15})
      #=> {:error, [
      #=>   %Gladius.Error{path: [:name],  message: "must be filled"},
      #=>   %Gladius.Error{path: [:email], message: "key :email must be present"},
      #=>   %Gladius.Error{path: [:age],   message: "must be >= 18"}
      #=> ]}

      Gladius.explain(user, %{name: "", age: 15})
      #=> %Gladius.ExplainResult{
      #=>   valid?: false,
      #=>   formatted: ":name: must be filled\\n:email: key :email must be present\\n:age: must be >= 18"
      #=>   ...
      #=> }
  """

  alias Gladius.{
    Spec, All, Any, Not, Maybe, Ref, ListOf, Cond, Schema, SchemaKey,
    Default, Transform, Validate, Error, ExplainResult, Constraints
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
          | Default.t()
          | Transform.t()
          | Validate.t()

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

      spec(is_integer() and &(&1 > 0))             # guard + capture (most ergonomic)
      spec(is_binary() and &(byte_size(&1) > 3))
      spec(&is_integer/1)                           # explicit capture
      spec(&(&1 > 0))
      spec(fn x -> rem(x, 2) == 0 end)             # anonymous function
      spec(is_integer() and &(&1 > 0) and &(rem(&1, 2) == 0))  # chained

  ## Supplying a generator

  Predicate specs are opaque to the generator — it cannot reverse an arbitrary
  function into a data source. Provide an explicit generator with the `:gen` option:

      even = spec(fn x -> rem(x, 2) == 0 end,
                  gen: StreamData.filter(StreamData.integer(), &(rem(&1, 2) == 0)))

      Gladius.gen(even)   # uses the explicit generator

  ## Prefer typed builders when possible

  `integer(gt?: 0)` is equivalent to `spec(is_integer() and &(&1 > 0))` for
  validation, but the typed form carries named constraint metadata so generators
  are inferred automatically without a `:gen` hint.
  """
  defmacro spec(expr, opts \\ []) do
    source  = Macro.to_string(expr)
    v       = Macro.var(:__gladius_v__, __MODULE__)
    bool_body = to_bool_expr(expr, v)
    gen_ast = opts[:gen]

    msg_ast = opts[:message]

    quote do
      %Gladius.Spec{
        predicate: fn unquote(v) -> unquote(bool_body) end,
        generator: unquote(gen_ast),
        message:   unquote(msg_ast),
        meta: %{source: unquote(source)}
      }
    end
  end

  # ===========================================================================
  # defspec — global spec registration (Clojure s/def equivalent)
  # ===========================================================================

  @doc """
  Registers a spec globally under `name` in the `Gladius.Registry`.

  The Clojure spec equivalent of `s/def`. Specs registered this way are
  accessible from any process via `ref/1`.

      import Gladius

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
  defmacro defspec(name, spec, opts \\ []) when is_atom(name) do
    type_code = defspec_type_code(name, spec, opts, __CALLER__)
    quote do
      Gladius.Registry.register(unquote(name), unquote(spec))
      unquote(type_code)
    end
  end

  defp defspec_type_code(name, spec_ast, opts, caller) do
    if Keyword.get(opts, :type, false) do
      try do
        {spec_struct, _bindings} = Code.eval_quoted(spec_ast, [], caller)

        for {_reason, msg} <- Gladius.Typespec.lossiness(spec_struct) do
          IO.warn("defspec #{inspect(name)} type: #{msg}", caller)
        end

        Gladius.Typespec.type_ast(name, spec_struct)
      rescue
        err ->
          IO.warn(
            "defspec #{inspect(name)}: could not evaluate spec at compile time; " <>
              "@type skipped. Cause: #{Exception.message(err)}",
            caller
          )
          quote do: :ok
      end
    else
      quote do: :ok
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
        import Gladius

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
      #=> raises Gladius.ConformError

  ## Generated functions

  - `name/1`  — returns `{:ok, shaped_value}` or `{:error, [%Gladius.Error{}]}`
  - `name!/1` — returns `shaped_value` or raises `Gladius.ConformError`
  """
  defmacro defschema(name, opts_or_block, block \\ nil) when is_atom(name) do
    {opts, schema_expr} =
      case {opts_or_block, block} do
        {[do: expr], nil}       -> {[], expr}
        {opts, [do: expr]}      -> {opts, expr}
      end

    bang        = :"#{name}!"
    type_code   = defschema_type_code(name, schema_expr, opts, __CALLER__)
    struct_mode = Keyword.get(opts, :struct, false)
    # When struct: true, the generated struct module is named <CallerModule>.<PascalName>Schema
    # e.g. defschema :point in MyApp.Schemas → MyApp.Schemas.PointSchema
    struct_mod  =
      if struct_mode do
        caller_mod = __CALLER__.module
        pascal     = name |> Atom.to_string() |> Macro.camelize()
        Module.concat(caller_mod, :"#{pascal}Schema")
      end

    if struct_mode do
      quote do
        # Define the output struct — fields are inferred at compile time by
        # evaluating the schema expression and extracting key names.
        defmodule unquote(struct_mod) do
          @moduledoc false
          schema_struct = unquote(schema_expr)
          fields = Enum.map(schema_struct.keys, & &1.name)
          defstruct fields
        end

        @doc "Validates `data` against the `#{unquote(name)}` schema. Returns `{:ok, %#{unquote(struct_mod)}{}}` or `{:error, errors}`."
        def unquote(name)(data) do
          case Gladius.conform(unquote(schema_expr), data) do
            {:ok, shaped} -> {:ok, struct(unquote(struct_mod), shaped)}
            err           -> err
          end
        end

        @doc "Like `#{unquote(name)}/1` but returns the struct or raises `Gladius.ConformError`."
        def unquote(bang)(data) do
          case unquote(name)(data) do
            {:ok, value}     -> value
            {:error, errors} -> raise Gladius.ConformError, name: unquote(name), errors: errors
          end
        end

        unquote(type_code)
      end
    else
      quote do
        @doc "Validates `data` against the `#{unquote(name)}` schema. Returns `{:ok, value}` or `{:error, errors}`."
        def unquote(name)(data) do
          Gladius.conform(unquote(schema_expr), data)
        end

        @doc "Like `#{unquote(name)}/1` but returns the shaped value or raises `Gladius.ConformError`."
        def unquote(bang)(data) do
          case unquote(name)(data) do
            {:ok, value}     -> value
            {:error, errors} -> raise Gladius.ConformError, name: unquote(name), errors: errors
          end
        end

        unquote(type_code)
      end
    end
  end

  defp defschema_type_code(name, schema_ast, opts, caller) do
    if Keyword.get(opts, :type, false) do
      try do
        {schema_struct, _} = Code.eval_quoted(schema_ast, [], caller)

        for {_reason, msg} <- Gladius.Typespec.lossiness(schema_struct) do
          IO.warn("defschema #{inspect(name)} type: #{msg}", caller)
        end

        Gladius.Typespec.type_ast(name, schema_struct)
      rescue
        err ->
          IO.warn(
            "defschema #{inspect(name)}: could not evaluate schema at compile time; " <>
              "@type skipped. Cause: #{Exception.message(err)}",
            caller
          )
          quote do: :ok
      end
    else
      quote do: :ok
    end
  end

  defp to_bool_expr({:and, _, [left, right]}, v) do
    l = to_bool_expr(left, v)
    r = to_bool_expr(right, v)
    quote do unquote(l) and unquote(r) end
  end

  defp to_bool_expr({guard_fn, meta, args}, v)
       when guard_fn in @guard_fns and args in [[], nil] do
    {guard_fn, meta, [v]}
  end

  defp to_bool_expr({:&, _, _} = capture, v) do
    quote do apply(unquote(capture), [unquote(v)]) end
  end

  defp to_bool_expr({:fn, _, _} = fn_literal, v) do
    quote do apply(unquote(fn_literal), [unquote(v)]) end
  end

  defp to_bool_expr(other, v) do
    quote do apply(unquote(other), [unquote(v)]) end
  end

  # ===========================================================================
  # Primitive type builders
  # ===========================================================================

  defp merge_constraints(shorthand, more) when is_atom(shorthand) and is_list(more) do
    [{shorthand, true} | more]
  end

  # Pulls :message out of a constraint keyword list so it doesn't reach
  # Gladius.Constraints.check/2, which would silently ignore it but leave
  # it polluting the constraints list in introspection.
  defp split_message(cs) when is_list(cs) do
    {cs[:message], Keyword.delete(cs, :message)}
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
  def string(c) when is_atom(c),        do: string([{c, true}])
  def string(cs) when is_list(cs) do
    {msg, constraints} = split_message(cs)
    %Spec{type: :string, constraints: constraints, message: msg}
  end
  def string(c, more) when is_atom(c),   do: string(merge_constraints(c, more))

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
  def integer(c) when is_atom(c),       do: integer([{c, true}])
  def integer(cs) when is_list(cs) do
    {msg, constraints} = split_message(cs)
    %Spec{type: :integer, constraints: constraints, message: msg}
  end
  def integer(c, more) when is_atom(c),  do: integer(merge_constraints(c, more))

  @doc "A float spec, with optional named constraints."
  @spec float(atom() | keyword()) :: Spec.t()
  @spec float(atom(), keyword()) :: Spec.t()
  def float(constraints \\ [])
  def float(c) when is_atom(c),         do: float([{c, true}])
  def float(cs) when is_list(cs) do
    {msg, constraints} = split_message(cs)
    %Spec{type: :float, constraints: constraints, message: msg}
  end
  def float(c, more) when is_atom(c),    do: float(merge_constraints(c, more))

  @doc "Accepts integers or floats, with optional named constraints."
  @spec number(keyword()) :: Spec.t()
  def number(cs \\ []) do
    {msg, constraints} = split_message(cs)
    %Spec{type: :number, constraints: constraints, message: msg}
  end

  @doc "A boolean spec. No meaningful constraints apply."
  @spec boolean() :: Spec.t()
  def boolean(opts \\ [])
  def boolean([]),                        do: %Spec{type: :boolean}
  def boolean(message: msg),              do: %Spec{type: :boolean, message: msg}

  @doc """
  An atom spec, with optional named constraints.

      atom()
      atom(in?: [:admin, :user])
  """
  @spec atom(keyword()) :: Spec.t()
  def atom(cs \\ []) do
    {msg, constraints} = split_message(cs)
    %Spec{type: :atom, constraints: constraints, message: msg}
  end

  @doc "Accepts any map. For shape validation, use `schema/1`."
  @spec map() :: Spec.t()
  def map(opts \\ [])
  def map([]),                            do: %Spec{type: :map}
  def map(message: msg),                  do: %Spec{type: :map, message: msg}

  @doc """
  Accepts any list. For typed lists (all elements checked), use `list_of/1`.

      list()
      list(:filled?)                    # non-empty list
      list(:filled?, min_length: 2)
  """
  @spec list(atom() | keyword()) :: Spec.t()
  @spec list(atom(), keyword()) :: Spec.t()
  def list(constraints \\ [])
  def list(c) when is_atom(c),          do: list([{c, true}])
  def list(cs) when is_list(cs) do
    {msg, constraints} = split_message(cs)
    %Spec{type: :list, constraints: constraints, message: msg}
  end
  def list(c, more) when is_atom(c),     do: list(merge_constraints(c, more))

  @doc "Accepts any value unconditionally. Useful as an `else` branch or placeholder."
  @spec any() :: Spec.t()
  def any(opts \\ [])
  def any([]),                            do: %Spec{type: :any}
  def any(message: msg),                  do: %Spec{type: :any, message: msg}

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
  @spec maybe(conformable(), [{:message, Spec.message()}]) :: Maybe.t()
  def maybe(inner_spec, opts \\ [])
  def maybe(inner_spec, []),              do: %Maybe{spec: inner_spec}
  def maybe(inner_spec, message: msg),   do: %Maybe{spec: inner_spec, message: msg}

  @doc """
  Lazy reference to a named spec in `Gladius.Registry`.
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

  @doc """
  Wraps a spec with a coercion — a transformation applied to the value
  **before** type-checking and constraints run.

  ## Forms

      # Custom coercion function — returns {:ok, coerced} or {:error, reason}
      coerce(integer(), fn
        v when is_binary(v) ->
          case Integer.parse(String.trim(v)) do
            {n, ""} -> {:ok, n}
            _       -> {:error, "not an integer string: \#{inspect(v)}"}
          end
        v when is_integer(v) -> {:ok, v}
        v -> {:error, "cannot coerce \#{inspect(v)} to integer"}
      end)

      # Built-in shorthand — coerce from a source type
      coerce(integer(), from: :string)   # "42"    → 42
      coerce(float(),   from: :string)   # "3.14"  → 3.14
      coerce(boolean(), from: :string)   # "true"  → true, "yes" → true, "1" → true
      coerce(atom(),    from: :string)   # "ok"    → :ok  (existing atoms only)

  ## Coercion runs before validation

  The pipeline is: `raw → coerce → type_check → constraints → {:ok, coerced}`.
  If coercion fails, an `%Gladius.Error{predicate: :coerce}` is returned and
  downstream checks are skipped.
  """
  @spec coerce(Spec.t(), (term() -> {:ok, term()} | {:error, term()})) :: Spec.t()
  @spec coerce(Spec.t(), [{:from, atom()}]) :: Spec.t()
  def coerce(%Spec{} = spec, coerce_fn) when is_function(coerce_fn, 1) do
    %{spec | coercion: coerce_fn}
  end

  def coerce(%Spec{type: target_type} = spec, opts) when is_list(opts) do
    source_type = Keyword.fetch!(opts, :from)
    message     = opts[:message]
    coerce_fn   = Gladius.Coercions.lookup(source_type, target_type)
    %{spec | coercion: coerce_fn, message: message || spec.message}
  end

  @doc """
  Wraps a spec with a post-validation transformation function.

  `fun/1` is called with the *shaped* value only after the inner spec
  succeeds. It is never called when validation fails.

  ## Examples

      # Normalize strings at the boundary
      transform(string(:filled?, format: ~r/@/), &String.downcase/1)
      transform(string(:filled?), &String.trim/1)

      # Enrich a schema output
      transform(
        schema(%{required(:name) => string(:filled?)}),
        fn m -> Map.put(m, :slug, String.downcase(m.name)) end
      )

      # Chain transforms with pipe
      string(:filled?)
      |> transform(&String.trim/1)
      |> transform(&String.downcase/1)

  ## Error handling

  If `fun` raises, the exception is caught and returned as
  `{:error, [%Gladius.Error{predicate: :transform, ...}]}`. The transform
  never crashes the caller.

  ## Ordering with coerce/2

  Coercion runs **before** validation; transform runs **after**:
  `raw → coerce → validate → transform → {:ok, result}`
  """
  @spec transform(conformable(), (term() -> term())) :: Transform.t()
  @spec transform(conformable(), (term() -> term()), [{:message, Spec.message()}]) :: Transform.t()
  def transform(spec, fun, opts \\ []) when is_function(fun, 1) do
    %Transform{spec: spec, fun: fun, message: opts[:message]}
  end

  @doc """
  Wraps a spec with a fallback value injected when an optional schema key
  is absent.

  The inner `spec` constrains **provided** values; `value` is the fallback
  used only when the key is missing from the input map. The default is
  injected as-is — it is not re-validated on every call.

  ## Example

      schema(%{
        required(:name)    => string(:filled?),
        optional(:role)    => default(one_of([:admin, :user, :guest]), :user),
        optional(:retries) => default(integer(gte?: 0), 3),
        optional(:tags)    => default(list_of(string(:filled?)), [])
      })

  ## Semantics

  - **Key absent** → `value` is injected directly, inner spec not run.
  - **Key present** → inner `spec` is run against the provided value normally.
    An invalid provided value returns an error; the default does not rescue it.
  - **Required key** → default has no effect on absence; required missing keys
    always produce a missing-key error.

  ## Composability

  `default/2` accepts any conformable as its inner spec, including schemas,
  list_of, maybe, and ref:

      optional(:coords) => default(schema(%{required(:x) => integer()}), %{x: 0})
      optional(:ref)    => default(maybe(string(:filled?)), nil)
  """
  @spec default(conformable(), term()) :: Default.t()
  @spec default(conformable(), term(), [{:message, Spec.message()}]) :: Default.t()
  def default(spec, value, opts \\ []) do
    %Default{spec: spec, value: value, message: opts[:message]}
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
  def schema(key_map) when is_map(key_map) or is_list(key_map),
    do: build_schema(key_map, false)

  @doc """
  Like `schema/1` but **open**: extra keys pass through unchanged in the
  shaped output.
  """
  @spec open_schema(map() | list()) :: Schema.t()
  def open_schema(key_map) when is_map(key_map) or is_list(key_map),
      do: build_schema(key_map, true)

  @doc """
  Returns a new schema containing only the named keys, all made optional.

  The primary use case is PATCH endpoints — validate whichever subset of
  fields the client chose to send, without requiring all fields to be present.

  ## Behaviour

  - Selected keys that are **absent** from input: omitted from output, no error.
  - Selected keys that are **present**: validated by their original spec.
  - Keys **not** in `field_names` are dropped from the schema entirely. For
    closed schemas they will produce an unknown-key error if present in input,
    preventing mass-assignment of unexpected fields.
  - `open?` is inherited from the source schema.

  ## Example

      user_schema = schema(%{
        required(:name)  => string(:filled?),
        required(:email) => string(:filled?, format: ~r/@/),
        required(:age)   => integer(gte?: 0),
        optional(:role)  => atom(in?: [:admin, :user])
      })

      patch = selection(user_schema, [:name, :email, :age, :role])

      Gladius.conform(patch, %{name: "Mark"})
      #=> {:ok, %{name: "Mark"}}          # only name provided — fine

      Gladius.conform(patch, %{})
      #=> {:ok, %{}}                       # nothing provided — fine

      Gladius.conform(patch, %{age: -1})
      #=> {:error, [%Error{path: [:age], ...}]}  # present but invalid — error

  """
  @spec selection(Schema.t(), [atom()]) :: Schema.t()
  def selection(%Schema{keys: keys, open?: open?}, field_names) when is_list(field_names) do
    selected =
      keys
      |> Enum.filter(&(&1.name in field_names))
      |> Enum.map(&%{&1 | required: false})

    %Schema{keys: selected, open?: open?}
  end

  @doc """
  Wraps any conformable with one or more cross-field validation rules that run
  **after** the inner spec fully passes.

  Rules are functions of arity 1 that receive the shaped output and return:

      :ok                                               # passes
      {:error, :field_name, "message"}                  # single named-field error
      {:error, :base, "message"}                        # root-level error
      {:error, [{:field_a, "msg"}, {:field_b, "msg"}]}  # multiple errors

  Multiple `validate/2` calls chain by appending rules to the same struct:

      schema(%{
        required(:start) => string(:filled?),
        required(:end)   => string(:filled?)
      })
      |> validate(fn %{start: s, end: e} ->
        if e >= s, do: :ok, else: {:error, :end, "must be after start"}
      end)
      |> validate(&check_business_hours/1)

  Rules only run when the inner spec fully succeeds. All rules run and all
  errors accumulate — there is no short-circuiting between rules.
  """
  @spec validate(conformable(), (term() -> Validate.rule_result())) :: Validate.t()
  def validate(%Validate{rules: existing} = v, fun) when is_function(fun, 1) do
    %{v | rules: existing ++ [fun]}
  end

  def validate(spec, fun) when is_function(fun, 1) do
    %Validate{spec: spec, rules: [fun]}
  end

  @doc """
  Extends an existing schema with additional or overriding keys.

  Extension keys take precedence over same-named base keys. Non-overridden
  base keys are preserved in their original order; new keys from the extension
  are appended after them.

  `open?` is inherited from the base schema unless explicitly overridden via
  the `open:` option in `extend/3`.

  ## Usage

      base = schema(%{
        required(:name)  => string(:filled?),
        required(:email) => string(:filled?, format: ~r/@/),
        required(:age)   => integer(gte?: 0)
      })

      # Add new fields
      extended = extend(base, %{optional(:role) => atom(in?: [:admin, :user])})

      # Override a field's spec
      stricter = extend(base, %{required(:age) => integer(gte?: 21)})

      # Change required → optional (or vice versa)
      lenient = extend(base, %{optional(:email) => string()})

  ## Create / update / patch pattern

      create = extend(base, %{required(:password) => string(min_length: 8)})
      update = extend(base, %{optional(:role) => atom(in?: [:admin, :user])})
      patch  = selection(update, [:name, :email, :age, :role])

  """
  @spec extend(Schema.t(), map()) :: Schema.t()
  @spec extend(Schema.t(), map(), [{:open?, boolean()}]) :: Schema.t()
  def extend(%Schema{keys: base_keys, open?: base_open?}, extension_map, opts \\ [])
      when is_map(extension_map) do
    open? = Keyword.get(opts, :open?, base_open?)

    # Parse extension map into SchemaKey structs (same logic as build_schema)
    extension_keys =
      Enum.map(extension_map, fn
        {{:required, name}, spec} -> %SchemaKey{name: name, spec: spec, required: true}
        {{:optional, name}, spec} -> %SchemaKey{name: name, spec: spec, required: false}
        {name, spec} when is_atom(name) -> %SchemaKey{name: name, spec: spec, required: true}
      end)

    extension_by_name = Map.new(extension_keys, &{&1.name, &1})

    # Base keys: override in place if present in extension, otherwise keep as-is
    merged_base =
      Enum.map(base_keys, fn base_key ->
        Map.get(extension_by_name, base_key.name, base_key)
      end)

    # New keys: those in extension not already in base (preserve extension order)
    base_names = MapSet.new(base_keys, & &1.name)
    new_keys   = Enum.reject(extension_keys, &MapSet.member?(base_names, &1.name))

    %Schema{keys: merged_base ++ new_keys, open?: open?}
  end

  @doc "Marks a schema map key as required. Returns a tagged tuple used by `schema/1`."
  @spec required(atom()) :: {:required, atom()}
  def required(name) when is_atom(name), do: {:required, name}

  @doc "Marks a schema map key as optional. Returns a tagged tuple used by `schema/1`."
  @spec optional(atom()) :: {:optional, atom()}
  def optional(name) when is_atom(name), do: {:optional, name}

  # build_schema/2 accepts either a map or a list of 2-tuples.
  # Maps: key order is NOT guaranteed (Elixir map literal ordering is undefined).
  # Lists: key order IS preserved — use a list when declaration order matters
  # (introspection, JSON Schema export, form rendering).
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
  # gen/1 — generator inference
  # ===========================================================================

  @doc """
  Returns a `StreamData` generator for `spec`.

  Typed specs with named constraints are inferred automatically. Predicate-only
  specs require an explicit `:gen` override on `spec/2`.
  """
  defdelegate gen(spec), to: Gladius.Gen

  # ===========================================================================
  # conform/2
  # ===========================================================================

  @doc """
  Validates `value` against `spec`. Returns `{:ok, shaped_value}` on success,
  or `{:error, [%Gladius.Error{}]}` with every failure — no short-circuiting.

  The shaped value may differ from the raw input when specs include coercions
  (`coerce/2`). The coerced value is what downstream constraints and the
  caller both receive.

  ## Examples

      iex> import Gladius
      iex> conform(string(:filled?), "hello")
      {:ok, "hello"}

      iex> conform(string(:filled?), "")
      {:error, [%Gladius.Error{predicate: :filled?, message: "must be filled"}]}

      iex> conform(coerce(integer(), from: :string), "42")
      {:ok, 42}

      iex> conform(schema(%{required(:age) => integer(gte?: 18)}), %{age: 15})
      {:error, [%Gladius.Error{path: [:age], message: "must be >= 18"}]}
  """
  @spec conform(conformable(), term()) :: conform_result()

  # --- Message override wrappers ----------------------------------------------
  #
  # When a conformable carries a non-nil :message, strip it, run the real
  # clause, then replace all error messages with the custom one.
  # These must be first so they fire before any other clause for their type.

  def conform(%Spec{message: msg} = spec, value) when not is_nil(msg) do
    conform(%{spec | message: nil}, value) |> override_message(msg)
  end

  def conform(%Transform{message: msg} = t, value) when not is_nil(msg) do
    conform(%{t | message: nil}, value) |> override_message(msg)
  end

  def conform(%Maybe{message: msg} = m, value) when not is_nil(msg) do
    conform(%{m | message: nil}, value) |> override_message(msg)
  end

  def conform(%Any{message: msg} = a, value) when not is_nil(msg) do
    conform(%{a | message: nil}, value) |> override_message(msg)
  end

  def conform(%Not{message: msg} = n, value) when not is_nil(msg) do
    conform(%{n | message: nil}, value) |> override_message(msg)
  end

  def conform(%Default{message: msg} = d, value) when not is_nil(msg) do
    conform(%{d | message: nil}, value) |> override_message(msg)
  end

  def conform(%Schema{message: msg} = s, value) when not is_nil(msg) do
    conform(%{s | message: nil}, value) |> override_message(msg)
  end

  # --- Struct input (transparent conversion) ----------------------------------
  #
  # Any Elixir struct is converted to a plain map before dispatch.
  # Output is always a plain map — use conform_struct/2 to re-wrap.
  def conform(spec, %{__struct__: _} = struct) do
    conform(spec, Map.from_struct(struct))
  end

  # --- Default (fallback for absent optional keys) ----------------------------
  #
  # When called directly (key is PRESENT in the parent schema), Default
  # delegates to its inner spec. The absent-key injection happens in the
  # Schema clause below — Default itself just acts as a transparent wrapper
  # when a value is actually being validated.
  def conform(%Default{spec: inner_spec}, value) do
    conform(inner_spec, value)
  end

  # --- Transform (post-validation) -------------------------------------------

  def conform(%Transform{spec: inner_spec, fun: fun}, value) do
    case conform(inner_spec, value) do
      {:error, _} = err ->
        err

      {:ok, shaped} ->
        try do
          {:ok, fun.(shaped)}
        rescue
          e ->
            reason   = Exception.message(e)
            bindings = [reason: reason]
            {:error, [%Error{
              predicate:        :transform,
              value:            shaped,
              message:          translate_default("transform failed: " <> reason, :transform, bindings),
              message_key:      :transform,
              message_bindings: bindings
            }]}
        end
    end
  end

  # --- Spec (leaf) -----------------------------------------------------------

  # Coercion pre-processing — must be first among all %Spec{} clauses.
  def conform(%Spec{coercion: coerce_fn} = spec, value) when not is_nil(coerce_fn) do
    case coerce_fn.(value) do
      {:ok, coerced}  ->
        conform(%{spec | coercion: nil}, coerced)

      {:error, reason} ->
        default_msg = to_string(reason)
        bindings    = [original: value]
        {:error, [%Error{
          predicate:        :coerce,
          value:            value,
          message:          translate_default(default_msg, :coerce, bindings),
          message_key:      :coerce,
          message_bindings: bindings,
          meta:             %{original: value}
        }]}
    end
  end

  # `any()` — unconditional pass
  def conform(%Spec{type: :any}, value), do: {:ok, value}

  # `nil_spec()`
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

  # Typed + predicated spec
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

  # Empty spec — passthrough
  def conform(%Spec{type: nil, predicate: nil}, value), do: {:ok, value}

  # --- All (AND) --------------------------------------------------------------

  def conform(%All{specs: []}, value), do: {:ok, value}

  def conform(%All{specs: specs}, value) do
    Enum.reduce_while(specs, {:ok, value}, fn spec, {:ok, acc} ->
      case conform(spec, acc) do
        {:ok, shaped} -> {:cont, {:ok, shaped}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # --- Any (OR) ---------------------------------------------------------------

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

  # --- Not --------------------------------------------------------------------

  def conform(%Not{spec: spec}, value) do
    case conform(spec, value) do
      {:ok, _} ->
        {:error, [%Error{value: value, message: "value must NOT conform to spec"}]}

      {:error, _} ->
        {:ok, value}
    end
  end

  # --- Maybe ------------------------------------------------------------------

  def conform(%Maybe{}, nil), do: {:ok, nil}
  def conform(%Maybe{spec: spec}, value), do: conform(spec, value)

  # --- Ref --------------------------------------------------------------------

  def conform(%Ref{name: name}, value) do
    spec = Gladius.Registry.fetch!(name)
    conform(spec, value)
  rescue
    e in Gladius.UndefinedSpecError ->
      {:error, [%Error{value: value, message: Exception.message(e)}]}
  end

  # --- ListOf -----------------------------------------------------------------

  def conform(%ListOf{}, value) when not is_list(value) do
    {:error, [type_error(:list, value, "must be a list")]}
  end

  def conform(%ListOf{element_spec: el_spec}, value) when is_list(value) do
    {shaped_rev, errors} =
      value
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {elem, idx}, {acc_shaped, acc_errs} ->
        case conform(el_spec, elem) do
          {:ok, shaped} ->
            {[shaped | acc_shaped], acc_errs}

          {:error, elem_errors} ->
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

  # --- Cond -------------------------------------------------------------------

  def conform(%Cond{predicate_fn: pred, if_spec: if_spec, else_spec: else_spec}, value) do
    if pred.(value),
      do: conform(if_spec, value),
      else: conform(else_spec, value)
  end

  # --- Schema -----------------------------------------------------------------

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
            keyed = prepend_path(field_errors, name)
            {acc_pairs, acc_errs ++ keyed}
        end
      end)

    # 4. Inject defaults for absent optional keys whose spec is %Default{}.
    # A %Ref{} may point to a %Default{}, so resolve one level of indirection.
    default_pairs =
      key_specs
      |> Enum.reject(& &1.required)
      |> Enum.reject(&Map.has_key?(value, &1.name))
      |> Enum.flat_map(fn %SchemaKey{name: name, spec: spec} ->
        resolved =
          case spec do
            %Ref{name: ref_name} ->
              try do
                Gladius.Registry.fetch!(ref_name)
              rescue
                Gladius.UndefinedSpecError -> spec
              end
            other ->
              other
          end

        case resolved do
          %Default{value: default_value} -> [{name, default_value}]
          _                              -> []
        end
      end)

    all_errors = missing_errors ++ unknown_errors ++ value_errors

    if all_errors == [] do
      shaped =
        if open? do
          Map.merge(value, Map.new(shaped_pairs ++ default_pairs))
        else
          Map.new(shaped_pairs ++ default_pairs)
        end

      {:ok, shaped}
    else
      {:error, all_errors}
    end
  end

  # --- Validate (cross-field rules) ------------------------------------------

  def conform(%Validate{spec: inner_spec, rules: rules}, value) do
    case conform(inner_spec, value) do
      {:error, _} = err ->
        # Inner spec failed — cross-field rules must not run on invalid data
        err

      {:ok, shaped} ->
        rule_errors =
          Enum.flat_map(rules, fn rule ->
            try do
              case rule.(shaped) do
                :ok ->
                  []

                {:error, field, message} when is_atom(field) ->
                  path = if field == :base, do: [], else: [field]
                  [%Error{path: path, message: message, predicate: :validate,
                          message_key: :validate, message_bindings: [field: field]}]

                {:error, pairs} when is_list(pairs) ->
                  Enum.map(pairs, fn {field, message} ->
                    path = if field == :base, do: [], else: [field]
                    %Error{path: path, message: message, predicate: :validate,
                           message_key: :validate, message_bindings: [field: field]}
                  end)
              end
            rescue
              e ->
                [%Error{
                  path:             [],
                  predicate:        :validate,
                  value:            shaped,
                  message:          "validate rule raised: " <> Exception.message(e),
                  message_key:      :validate,
                  message_bindings: [reason: Exception.message(e)]
                }]
            end
          end)

        if rule_errors == [] do
          {:ok, shaped}
        else
          {:error, rule_errors}
        end
    end
  end

  # ===========================================================================
  # valid?/2 and explain/2
  # ===========================================================================

  @doc """
  Returns `true` if `value` conforms to `spec`, `false` otherwise.

  ## Examples

      iex> import Gladius
      iex> valid?(integer(gte?: 0), 42)
      true
      iex> valid?(integer(gte?: 0), -1)
      false
  """
  @spec valid?(conformable(), term()) :: boolean()
  def valid?(spec, value), do: match?({:ok, _}, conform(spec, value))

  @doc """
  Like `conform/2` but accepts a struct as input and re-wraps the shaped
  output in the same struct type on success.

  Returns `{:error, [%Gladius.Error{}]}` if the input is not a struct.

  ## Example

      defmodule User do
        defstruct [:name, :email]
      end

      s = schema(%{
        required(:name)  => transform(string(:filled?), &String.trim/1),
        required(:email) => string(:filled?, format: ~r/@/)
      })

      Gladius.conform_struct(s, %User{name: "  Mark  ", email: "m@x.com"})
      #=> {:ok, %User{name: "Mark", email: "m@x.com"}}
  """
  @spec conform_struct(conformable(), struct()) :: {:ok, struct()} | {:error, [Error.t()]}
  def conform_struct(_spec, value) when not is_struct(value) do
    {:error, [%Error{value: value, message: "conform_struct/2 requires a struct, got: #{inspect(value)}"}]}
  end

  def conform_struct(spec, %{__struct__: mod} = struct) do
    case conform(spec, Map.from_struct(struct)) do
      {:ok, shaped_map} -> {:ok, struct(mod, shaped_map)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Returns a `%Gladius.ExplainResult{}` with structured errors and a
  pre-formatted string ready for display or logging.

  ## Example

      iex> import Gladius
      iex> result = explain(schema(%{required(:age) => integer(gte?: 18)}), %{age: 15})
      iex> result.valid?
      false
      iex> IO.puts(result.formatted)
      :age: must be >= 18
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
  # Typespec bridge
  # ===========================================================================

  @doc """
  Converts a Gladius spec to quoted Elixir typespec AST.

      iex> import Gladius
      iex> Macro.to_string(Gladius.to_typespec(integer(gte?: 0)))
      "non_neg_integer()"
  """
  defdelegate to_typespec(spec), to: Gladius.Typespec

  @doc """
  Returns lossiness notices for a spec — `[{reason, description}]`.
  Empty list means lossless.
  """
  defdelegate typespec_lossiness(spec), to: Gladius.Typespec, as: :lossiness

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

  defp type_error(type, value, default_message) do
    bindings = [expected: type, actual: type_of(value)]
    message  = translate_default(default_message, :type?, bindings)
    %Error{
      predicate:        :type?,
      value:            value,
      message:          message,
      message_key:      :type?,
      message_bindings: bindings,
      meta:             %{expected_type: type, actual_type: type_of(value)}
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

  # ---------------------------------------------------------------------------
  # Message override helpers
  # ---------------------------------------------------------------------------

  # Replaces the :message field on all errors in an error result.
  # {:ok, _} passes through unchanged.
  defp override_message({:ok, _} = ok, _msg), do: ok
  defp override_message({:error, errors}, msg) do
    resolved = resolve_message(msg)
    {:error, Enum.map(errors, &%{&1 | message: resolved})}
  end

  # Resolves a message value to a final string:
  #   nil                       — should not be called (guard in callers)
  #   binary                    — returned as-is; assumed already localised
  #   {domain, msgid, bindings} — passed through translator if configured;
  #                               falls back to msgid when no translator set
  defp resolve_message(msg) when is_binary(msg), do: msg
  defp resolve_message({domain, msgid, bindings}) do
    case Application.get_env(:gladius, :translator) do
      nil -> msgid
      mod -> mod.translate(domain, msgid, bindings)
    end
  end

  # Used by built-in error constructors (type_error, coerce, transform).
  # Applies the translator when configured; returns default_message otherwise.
  defp translate_default(default_message, _key, bindings) do
    case Application.get_env(:gladius, :translator) do
      nil -> default_message
      mod -> mod.translate(nil, default_message, bindings)
    end
  end
end
