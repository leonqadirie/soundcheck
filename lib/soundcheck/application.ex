defmodule Soundcheck.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [Soundcheck.Cache, Soundcheck.Once]
    Supervisor.start_link(children, strategy: :one_for_one, name: Soundcheck.Supervisor)
  end
end
