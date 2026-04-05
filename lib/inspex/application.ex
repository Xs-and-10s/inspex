defmodule Inspex.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [Inspex.Registry]

    opts = [strategy: :one_for_one, name: Inspex.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
