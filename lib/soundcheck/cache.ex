defmodule Soundcheck.Cache do
  @moduledoc false
  # A run-scoped key-value cache backed by one named ETS table, owned by a
  # GenServer.
  #
  # Reads and writes go straight to ETS from the calling process. The
  # GenServer exists only to keep the table alive while Credo spawns and
  # ends a task per check and per file.
  #
  # `Soundcheck.init/1` clears the table at the start of every Credo run,
  # and `Soundcheck.Credo.ClearCacheTask` clears it again at the end, so
  # each `mix credo` invocation starts empty even in a long-lived VM.
  #
  # The table is absent when checks run without the plugin registered. Every
  # function then degrades instead of raising: reads behave as misses and
  # writes are no-ops, so checks still produce correct results, uncached.
  # Uncached, every check rebuilds the graph and rereads each compiled
  # module, which makes a Credo run about five to seven times slower on the
  # bench corpus. The first read or write against the missing table
  # therefore prints a hint to stderr, once per VM, that names the missing
  # plugin registration. `available?/0` and `clear/0` stay silent.
  #
  # The cache does not start itself on a miss: without the plugin nothing
  # empties it between runs, and a long-lived VM would keep serving the
  # previous run's graph.
  #
  # `put_shared/2` stores large values that many processes read in full,
  # such as the graph, in `:persistent_term` instead. Every ETS read copies
  # the value into the reader's heap; a persistent term read copies nothing.
  # Replacing or erasing a persistent term makes the VM scan every process,
  # so shared values suit write-once-per-run data only. The table records
  # each shared key, and `clear/0` erases them.

  use GenServer

  @table :soundcheck_cache

  @missing_table_hint "soundcheck plugin not registered: every check rebuilds the graph; " <>
                        "add {Soundcheck, []} to plugins in .credo.exs"
  @hint_emitted_key {__MODULE__, :missing_table_hint_emitted}

  @doc "Starts the cache owner. Fails with `{:already_started, pid}` when running."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns the value at `key`, or `default` on a miss or a missing table."
  @spec get(term(), term()) :: term()
  def get(key, default \\ nil) do
    if table_exists?() do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> value
        [] -> default
      end
    else
      warn_missing_table()
      default
    end
  end

  @doc "Stores `value` at `key`. A no-op when the table is missing."
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    if table_exists?(), do: :ets.insert(@table, {key, value}), else: warn_missing_table()
    :ok
  end

  @doc """
  Stores `value` at `key` as a persistent term, which processes read
  without copying. Write once per run: replacing a value makes the VM scan
  every process. A no-op when the table is missing.
  """
  @spec put_shared(term(), term()) :: :ok
  def put_shared(key, value) do
    if table_exists?() do
      :ets.insert(@table, {{__MODULE__, :shared, key}, true})
      :persistent_term.put({__MODULE__, :shared, key}, value)
    else
      warn_missing_table()
    end

    :ok
  end

  @doc "Returns the value `put_shared/2` stored at `key`, or `default`."
  @spec get_shared(term(), term()) :: term()
  def get_shared(key, default \\ nil),
    do: :persistent_term.get({__MODULE__, :shared, key}, default)

  @doc "Deletes every entry, shared ones included. A no-op when the table is missing."
  @spec clear() :: :ok
  def clear do
    if table_exists?() do
      for [key] <- :ets.match(@table, {{__MODULE__, :shared, :"$1"}, :_}),
          do: :persistent_term.erase({__MODULE__, :shared, key})

      :ets.delete_all_objects(@table)
    end

    :ok
  end

  @doc "Returns `true` when the cache table exists."
  @spec available?() :: boolean()
  def available?, do: table_exists?()

  defp table_exists?, do: :ets.whereis(@table) != :undefined

  # Credo starts its first wave of check tasks at once, so many processes
  # can find the flag unset before any of them sets it. Each one spawns a
  # helper that tries to register a claim name; registration is atomic, so
  # exactly one helper wins, sets the flag, and prints. The caller waits for
  # its helper, so the hint reaches stderr before the access returns. The
  # helper is a separate process because the caller may already hold a
  # registered name.
  defp warn_missing_table do
    if not hint_emitted?(), do: claim_and_emit_hint()
    :ok
  end

  defp claim_and_emit_hint do
    {pid, ref} =
      spawn_monitor(fn ->
        if claim_registered?() and not hint_emitted?() do
          :persistent_term.put(@hint_emitted_key, true)
          IO.puts(:stderr, @missing_table_hint)
        end
      end)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp claim_registered? do
    Process.register(self(), __MODULE__.MissingTableHintClaim)
    true
  rescue
    ArgumentError -> false
  end

  defp hint_emitted?, do: :persistent_term.get(@hint_emitted_key, false)

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    {:ok, nil}
  end
end
