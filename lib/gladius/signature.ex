defmodule Gladius.Signature do
  @moduledoc """
  Runtime function signature validation, inspired by Clojure's `s/fdef`.

  Validates argument and return specs in `:dev` and `:test`. In `:prod`,
  signatures compile away entirely — zero overhead.

  ## Setup

      defmodule MyApp.Users do
        use Gladius.Signature

        signature args: [string(:filled?), integer(gte?: 18)],
                  ret:  boolean()
        def register(email, age) do
          # ...
        end
      end

  Note: `signature` is a **macro**, not a module attribute — write it without
  `@`. You do not need `import Gladius` in the module; the generated code
  imports it internally.

  ## Options

  - `:args` — list of specs, one per argument.
  - `:ret`  — spec for the return value.
  - `:fn`   — spec applied to `{coerced_args_list, return_value}`.

  ## Multi-clause functions

  Declare `signature` before the **first** clause only:

      signature args: [integer()], ret: integer()
      def fact(0), do: 1
      def fact(n) when n > 0, do: n * fact(n - 1)

  ## Prod behaviour

  In `:prod`, `signature/1` and the `def` override are both no-ops.
  """

  defmacro __using__(_opts) do
    quote do
      import Kernel, except: [def: 2]
      import Gladius.Signature, only: [def: 2, signature: 1]
    end
  end

  # ---------------------------------------------------------------------------
  # signature/1
  #
  # Calls Module.put_attribute DIRECTLY in the macro body — not in quote do.
  # This runs at macro expansion time, the same phase as the get_attribute in
  # the def override below. That's what makes the pending handoff work.
  # ---------------------------------------------------------------------------

  defmacro signature(opts) do
    if Mix.env() in [:dev, :test] do
      Module.put_attribute(__CALLER__.module, :__gladius_pending_sig__, opts)
    end
    :ok
  end

  # ---------------------------------------------------------------------------
  # def override
  #
  # All Module.put/get_attribute calls are in the macro body (not in quote),
  # so they all run at expansion time — consistent with signature/1 above.
  #
  # :__gladius_signed__ is managed as a plain list manually rather than using
  # accumulate: true.  The accumulate: true registration lives in quote do
  # (evaluation time), so it may not have fired by the time the first def
  # expansion tries to put a value — leaving the attribute non-accumulating
  # and put_attribute stores the bare tuple instead of appending to a list.
  # Manual list management avoids that timing hazard entirely.
  # ---------------------------------------------------------------------------

  defmacro def(call, expr) do
    module = __CALLER__.module

    if Mix.env() in [:dev, :test] do
      pending = Module.get_attribute(module, :__gladius_pending_sig__)
      signed  = Module.get_attribute(module, :__gladius_signed__) || []
      {name, arity} = extract_name_arity(call)
      already_signed = Enum.any?(signed, &match?({^name, ^arity}, &1))

      cond do
        pending != nil ->
          Module.put_attribute(module, :__gladius_signed__, [{name, arity} | signed])
          Module.put_attribute(module, :__gladius_pending_sig__, nil)
          impl_call = rename_call(call, impl_name(name, arity))
          wrapper   = generate_wrapper(name, arity, pending)
          quote do
            Kernel.defp(unquote(impl_call), unquote(expr))
            unquote(wrapper)
          end

        already_signed ->
          impl_call = rename_call(call, impl_name(name, arity))
          quote do: Kernel.defp(unquote(impl_call), unquote(expr))

        true ->
          quote do: Kernel.def(unquote(call), unquote(expr))
      end
    else
      quote do: Kernel.def(unquote(call), unquote(expr))
    end
  end

  # ---------------------------------------------------------------------------
  # generate_wrapper/3
  #
  # opts_ast: the raw opts AST stored by signature/1.
  # `unquote(opts_ast)` in the wrapper body splices it as code — spec builders
  # are called at each invocation of the public function (runtime).
  # `import Gladius` puts string/1, integer/1 etc. in scope for those calls.
  #
  # Kernel.def is used (not bare def) so the module's own import does not
  # re-intercept the wrapper and rename it to defp.
  # ---------------------------------------------------------------------------

  defp generate_wrapper(name, arity, opts_ast) do
    impl    = impl_name(name, arity)
    splat   = for i <- 0..(max(arity - 1, 0)), arity > 0, do: Macro.var(:"ia#{i}__", nil)
    coerced = for i <- 0..(max(arity - 1, 0)), arity > 0, do: Macro.var(:"ca#{i}__", nil)

    quote do
      Kernel.def unquote(name)(unquote_splicing(splat)) do
        import Gladius, warn: false
        __sig__      = unquote(opts_ast)
        __raw_args__ = unquote(splat)

        __args__ =
          case Keyword.get(__sig__, :args) do
            nil       -> __raw_args__
            args_spec ->
              Gladius.Signature.__coerce_and_check_args__(
                __raw_args__, args_spec, __MODULE__, unquote(name), unquote(arity)
              )
          end

        unquote(coerced) = __args__
        __result__ = unquote(impl)(unquote_splicing(coerced))

        case Keyword.get(__sig__, :ret) do
          nil      -> :ok
          ret_spec ->
            Gladius.Signature.__check_ret__(
              __result__, ret_spec, __MODULE__, unquote(name), unquote(arity)
            )
        end

        case Keyword.get(__sig__, :fn) do
          nil     -> :ok
          fn_spec ->
            Gladius.Signature.__check_fn__(
              __args__, __result__, fn_spec, __MODULE__, unquote(name), unquote(arity)
            )
        end

        __result__
      end
    end
  end

  defp impl_name(name, arity), do: :"__gladius_impl_#{name}_#{arity}__"

  defp extract_name_arity({:when, _, [{name, _, args} | _]}),
    do: {name, length(args || [])}
  defp extract_name_arity({name, _, args}),
    do: {name, length(args || [])}

  defp rename_call({:when, meta, [{_n, m2, args}, guard]}, new_name),
    do: {:when, meta, [{new_name, m2, args}, guard]}
  defp rename_call({_name, meta, args}, new_name),
    do: {new_name, meta, args}

  # ---------------------------------------------------------------------------
  # Runtime checks
  # ---------------------------------------------------------------------------

  @doc false
  # Validates and coerces all args against their specs. Returns coerced arg list.
  #
  # Key improvements over naive per-arg early-raise:
  # 1. All arg failures are collected — not just the first one.
  # 2. Each error path is prefixed with {:arg, idx} so the caller knows which
  #    argument failed AND which nested field within it.
  # 3. Coercion results from passing args are still threaded to the impl correctly.
  def __coerce_and_check_args__(args, args_specs, module, function, arity)
      when is_list(args_specs) do
    results =
      args
      |> Enum.zip(args_specs)
      |> Enum.with_index()
      |> Enum.map(fn {{arg, spec}, idx} ->
        case Gladius.conform(spec, arg) do
          {:ok, coerced}   -> {:ok, coerced}
          {:error, errors} -> {:error, prefix_paths(errors, {:arg, idx})}
        end
      end)

    all_errors = Enum.flat_map(results, fn
      {:ok, _}     -> []
      {:error, es} -> es
    end)

    if all_errors == [] do
      Enum.map(results, fn {:ok, v} -> v end)
    else
      raise Gladius.SignatureError,
        module: module, function: function, arity: arity,
        kind: :args, errors: all_errors
    end
  end

  @doc false
  def __check_ret__(result, ret_spec, module, function, arity) do
    case Gladius.conform(ret_spec, result) do
      {:ok, _}         -> :ok
      {:error, errors} ->
        raise Gladius.SignatureError,
          module: module, function: function, arity: arity,
          kind: :ret, errors: prefix_paths(errors, :ret)
    end
  end

  @doc false
  def __check_fn__(args, result, fn_spec, module, function, arity) do
    case Gladius.conform(fn_spec, {args, result}) do
      {:ok, _}         -> :ok
      {:error, errors} ->
        raise Gladius.SignatureError,
          module: module, function: function, arity: arity,
          kind: :fn, errors: prefix_paths(errors, :fn)
    end
  end

  defp prefix_paths(errors, prefix) do
    Enum.map(errors, fn err -> %{err | path: [prefix | err.path]} end)
  end
end
