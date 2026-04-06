defmodule Gladius.SignatureError do
  @moduledoc """
  Raised by `Gladius.Signature` when a function call violates its declared
  signature in `:dev` or `:test` environments.

  Never raised in `:prod` — signatures compile away to zero overhead.

  ## Fields

  - `:module`   — the module containing the violating function
  - `:function` — function name (atom)
  - `:arity`    — function arity (integer)
  - `:kind`     — `:args`, `:ret`, or `:fn`
  - `:errors`   — `[%Gladius.Error{}]` with prefixed paths:
      - args errors: path starts with `{:arg, index}` — e.g. `[{:arg, 0}, :email]`
      - ret errors:  path starts with `:ret`          — e.g. `[:ret, :name]`
      - fn errors:   path starts with `:fn`

  ## Error message format

  Errors from all failing arguments are collected in one raise, each identified
  by its `{:arg, N}` path prefix:

      MyApp.Users.register/2 argument error:
        argument[0][:email]: must be filled
        argument[1]: must be >= 18

  Nested schema field failures include the full path:

      argument[0][:address][:zip]: must be 5 characters
  """

  defexception [:module, :function, :arity, :kind, errors: []]

  @impl true
  def message(e) do
    "#{mfa(e)} #{kind_label(e.kind)}:\n  #{format_errors(e.errors)}"
  end

  defp mfa(%{module: m, function: f, arity: a}), do: "#{inspect(m)}.#{f}/#{a}"

  defp kind_label(:args), do: "argument error"
  defp kind_label(:ret),  do: "return value error"
  defp kind_label(:fn),   do: "relationship constraint error"

  defp format_errors(errors) do
    Enum.map_join(errors, "\n  ", &format_one/1)
  end

  defp format_one(%Gladius.Error{path: path, message: msg}) do
    "#{format_sig_path(path)}: #{msg}"
  end

  # Path head determines the context label.
  defp format_sig_path([{:arg, idx} | rest]), do: "argument[#{idx}]#{format_tail(rest)}"
  defp format_sig_path([:ret        | rest]), do: "return#{format_tail(rest)}"
  defp format_sig_path([:fn         | rest]), do: "fn#{format_tail(rest)}"
  defp format_sig_path([]),                   do: "(root)"

  # Remaining path segments rendered as bracket subscripts.
  defp format_tail([]),                          do: ""
  defp format_tail([h | t]) when is_atom(h),    do: "[#{inspect(h)}]#{format_tail(t)}"
  defp format_tail([h | t]) when is_integer(h), do: "[#{h}]#{format_tail(t)}"
  defp format_tail([h | t]),                    do: "[#{inspect(h)}]#{format_tail(t)}"
end
