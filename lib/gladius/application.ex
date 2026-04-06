defmodule Gladius.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [Gladius.Registry]

    opts = [strategy: :one_for_one, name: Gladius.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
