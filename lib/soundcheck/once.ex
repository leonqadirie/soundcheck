defmodule Soundcheck.Once do
  @moduledoc false
  # Computes a value at most once per key per run, however many processes
  # ask for it at the same time.
  #
  # Credo runs one task per check and, inside it, one task per file, so the
  # first wave of a run asks for the same graph or rule result from many
  # processes at once. `run/2` serves a stored result straight from
  # `Soundcheck.Cache`. On a miss, it asks this GenServer for the key: the
  # first caller gets the claim, computes the value in its own process, and
  # stores it; later callers for the same key wait until the claim is
  # released, then read the stored value. Computations for different keys
  # run concurrently.
  #
  # The computation runs in the caller, so the server never holds the
  # function or its result, and a failure raises where it happened, with
  # its own stacktrace. A failed computation stores nothing: the callers
  # that waited for it retry, one at a time, and so does the next call.
  #
  # `run_shared/2` does the same for large values that many processes read
  # in full, such as the graph: it keeps the value in a persistent term
  # (`Soundcheck.Cache.put_shared/2`), so later reads do not copy it.
  #
  # When the server or the cache table is not running (checks used without
  # the plugin), `run/2` and `run_shared/2` compute in the calling process
  # without storing anything.

  use GenServer

  alias Soundcheck.Cache

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the result of `fun` for `key`, computing it at most once per run.

  `fun` must be a pure function of `key`: the result is shared across all
  callers.
  """
  @spec run(term(), (-> value)) :: value when value: term()
  def run(key, fun) when is_function(fun, 0) do
    cache_key = {__MODULE__, key}

    case Cache.get(cache_key, :miss) do
      {:ok, value} -> value
      :miss -> if shared?(), do: claim(cache_key, fun), else: fun.()
    end
  end

  @doc """
  Like `run/2`, but stores the result as a persistent term, so callers
  read it without copying. Use it for large values computed once per run.
  """
  @spec run_shared(term(), (-> value)) :: value when value: term()
  def run_shared(key, fun) when is_function(fun, 0) do
    if shared?() do
      # The computation's own result is `:ok`, so the cache table never
      # holds a copy of the value.
      run({:shared, key}, fn -> Cache.put_shared(key, fun.()) end)
      Cache.get_shared(key)
    else
      fun.()
    end
  end

  defp shared?, do: Cache.available?() and Process.whereis(__MODULE__) != nil

  defp claim(cache_key, fun) do
    case GenServer.call(__MODULE__, {:claim, cache_key}, :infinity) do
      :compute ->
        compute(cache_key, fun)

      :released ->
        # The claimant stored a value, or failed and stored none; in that
        # case this caller asks for the claim itself.
        case Cache.get(cache_key, :miss) do
          {:ok, value} -> value
          :miss -> claim(cache_key, fun)
        end
    end
  end

  defp compute(cache_key, fun) do
    value = fun.()
    Cache.put(cache_key, {:ok, value})
    value
  after
    GenServer.cast(__MODULE__, {:release, cache_key})
  end

  # ── GenServer callbacks ──
  #
  # State: %{claims: %{cache_key => %{ref, waiters}}, keys: %{ref => cache_key}}
  #
  # The server monitors each claimant, so a claimant that dies before it
  # releases its key (a Credo task killed at its timeout) still frees the
  # waiters. `keys` maps the monitor ref back to the key, so a `:DOWN`
  # message finds the claim without scanning `claims`.

  @impl true
  def init(_opts), do: {:ok, %{claims: %{}, keys: %{}}}

  @impl true
  def handle_call({:claim, cache_key}, {pid, _tag} = from, state) do
    case state.claims do
      %{^cache_key => claim} ->
        {:noreply, put_in(state.claims[cache_key], %{claim | waiters: [from | claim.waiters]})}

      %{} ->
        if Cache.get(cache_key, :miss) == :miss do
          ref = Process.monitor(pid)

          {:reply, :compute,
           %{
             claims: Map.put(state.claims, cache_key, %{ref: ref, waiters: []}),
             keys: Map.put(state.keys, ref, cache_key)
           }}
        else
          # The claimant stored the value and released the key between the
          # caller's cache read and this call.
          {:reply, :released, state}
        end
    end
  end

  @impl true
  def handle_cast({:release, cache_key}, state) do
    case state.claims do
      %{^cache_key => %{ref: ref}} ->
        Process.demonitor(ref, [:flush])
        {:noreply, release(state, cache_key, ref)}

      %{} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case state.keys do
      %{^ref => cache_key} -> {:noreply, release(state, cache_key, ref)}
      %{} -> {:noreply, state}
    end
  end

  defp release(state, cache_key, ref) do
    {%{waiters: waiters}, claims} = Map.pop!(state.claims, cache_key)
    Enum.each(waiters, &GenServer.reply(&1, :released))
    %{claims: claims, keys: Map.delete(state.keys, ref)}
  end
end
