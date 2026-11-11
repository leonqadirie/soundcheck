defmodule Soundcheck.Credo.ClearCacheTask do
  @moduledoc false
  # Credo pipeline task appended to `:halt_execution` by `Soundcheck.init/1`.
  # It empties the run cache after every Credo run so graph memory does not
  # linger in long-lived VMs. `Soundcheck.init/1` also clears the cache at
  # the start of each run, in case a previous run crashed before this task.

  use Credo.Execution.Task

  @impl true
  def call(exec) do
    Soundcheck.Cache.clear()
    exec
  end
end
