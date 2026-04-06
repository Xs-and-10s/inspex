defmodule Gladius.UndefinedSpecError do
  @moduledoc "Raised when `ref/1` resolves against an unregistered spec name."
  defexception [:name]

  @impl true
  def message(%{name: name}) do
    """
    No spec registered under #{inspect(name)}.

    For global registration (production use):

        import Gladius
        Gladius.def(#{inspect(name)}, your_spec_here)

    For process-local registration (test use, async-safe):

        Gladius.Registry.register_local(#{inspect(name)}, your_spec_here)
    """
  end
end

defmodule Gladius.Registry do
  @moduledoc """
  Named spec registry — ETS-backed GenServer with a process-dictionary overlay.

  ## Architecture

      fetch!(name)
        1. Check process dictionary  → found: return spec
        2. Check ETS table           → found: return spec
        3. raise UndefinedSpecError

  ## Two registration paths

  **Global (ETS)** — `register/2` or the `Gladius.def/2` macro.
  Writes go through the GenServer (serialised), reads bypass it (concurrent).
  Visible to all processes. Use for application-level specs.

  **Local (process dict)** — `register_local/2`.
  Scoped to the calling process. Invisible to other processes, cleaned up when
  the process exits. Use in tests to keep `async: true`.

  ## Test isolation

      # In async: true tests — use local registration
      setup do
        Gladius.Registry.register_local(:email, Gladius.string(format: ~r/@/))
        on_exit(&Gladius.Registry.clear_local/0)
      end

      # For tests that exercise global registration specifically — use async: false
      # and clear in setup.

  ## ETS table properties

  The table is `:public` with `:read_concurrency` enabled. Reads (the hot path)
  never touch the GenServer process.
  """

  use GenServer

  @table :gladius_registry
  @pdict_prefix :__gladius_local__

  # ---------------------------------------------------------------------------
  # Client API — reads (bypass GenServer, hit ETS directly)
  # ---------------------------------------------------------------------------

  @doc """
  Returns the spec registered under `name`.

  Checks the process dictionary first (local override), then the global ETS
  table. Raises `Gladius.UndefinedSpecError` if not found in either.
  """
  @spec fetch!(atom()) :: term()
  def fetch!(name) when is_atom(name) do
    case Process.get({@pdict_prefix, name}) do
      nil  -> fetch_global!(name)
      spec -> spec
    end
  end

  @doc "Returns all globally registered specs as `%{name => spec}`."
  @spec all() :: %{atom() => term()}
  def all do
    @table |> :ets.tab2list() |> Map.new()
  end

  @doc "Returns `true` if a spec is registered under `name` (globally or locally)."
  @spec registered?(atom()) :: boolean()
  def registered?(name) when is_atom(name) do
    Process.get({@pdict_prefix, name}) != nil or
      match?([_], :ets.lookup(@table, name))
  end

  # ---------------------------------------------------------------------------
  # Client API — global writes (through GenServer)
  # ---------------------------------------------------------------------------

  @doc """
  Registers `spec` globally under `name`. Visible to all processes.
  Overwrites any previous global registration for the same name.

  For test-safe local registration, use `register_local/2`.
  """
  @spec register(atom(), term()) :: :ok
  def register(name, spec) when is_atom(name) do
    GenServer.call(__MODULE__, {:register, name, spec})
  end

  @doc "Removes the global registration for `name`."
  @spec unregister(atom()) :: :ok
  def unregister(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  @doc "Removes all global registrations. Use in `setup` for tests that touch the ETS table."
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # ---------------------------------------------------------------------------
  # Client API — local writes (process dictionary, no GenServer)
  # ---------------------------------------------------------------------------

  @doc """
  Registers `spec` locally under `name` in the calling process's dictionary.

  Local registrations shadow global ones and are cleaned up automatically when
  the process exits. **Preferred for tests** — keeps `async: true` safe.

      setup do
        Gladius.Registry.register_local(:role, Gladius.atom(in?: [:admin]))
        on_exit(&Gladius.Registry.clear_local/0)
      end
  """
  @spec register_local(atom(), term()) :: :ok
  def register_local(name, spec) when is_atom(name) do
    Process.put({@pdict_prefix, name}, spec)
    :ok
  end

  @doc "Removes the process-local registration for `name`."
  @spec unregister_local(atom()) :: :ok
  def unregister_local(name) when is_atom(name) do
    Process.delete({@pdict_prefix, name})
    :ok
  end

  @doc "Removes all process-local registrations from the calling process."
  @spec clear_local() :: :ok
  def clear_local do
    Process.get_keys()
    |> Enum.filter(&match?({@pdict_prefix, _}, &1))
    |> Enum.each(&Process.delete/1)
    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer lifecycle
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # :public so reads can go directly to ETS without a GenServer roundtrip
    # :named_table so any process can find it by name
    # read_concurrency: true — optimised for the expected read-heavy workload
    _table = :ets.new(@table, [:named_table, :public, {:read_concurrency, true}])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, name, spec}, _from, state) do
    :ets.insert(@table, {name, spec})
    {:reply, :ok, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    :ets.delete(@table, name)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp fetch_global!(name) do
    case :ets.lookup(@table, name) do
      [{^name, spec}] -> spec
      []              -> raise Gladius.UndefinedSpecError, name: name
    end
  end
end
