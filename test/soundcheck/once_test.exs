defmodule Soundcheck.OnceTest do
  use ExUnit.Case, async: false

  alias Soundcheck.{Cache, Once}

  setup do
    Cache.clear()
    :ok
  end

  test "computes a key once across concurrent callers" do
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      Process.sleep(50)
      :value
    end

    results =
      1..50
      |> Task.async_stream(fn _ -> Once.run(:shared, fun) end, max_concurrency: 50)
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.uniq(results) == [:value]
    assert :counters.get(counter, 1) == 1
  end

  test "serves later calls from the cache" do
    assert Once.run(:k, fn -> 1 end) == 1
    assert Once.run(:k, fn -> raise "must not run" end) == 1
  end

  test "computes different keys concurrently" do
    slow =
      Task.async(fn ->
        Once.run(:slow, fn ->
          receive do
            :release -> :slow
          end
        end)
      end)

    # The fast key finishes while the slow key's computation still blocks.
    assert Once.run(:fast, fn -> :fast end) == :fast

    wait_for_claim(:slow)
    send(slow.pid, :release)
    assert Task.await(slow) == :slow
  end

  test "raises a failure in the caller that computed and does not store it" do
    assert_raise RuntimeError, "boom", fn -> Once.run(:fails, fn -> raise "boom" end) end
    assert Once.run(:fails, fn -> :recovered end) == :recovered
  end

  test "computes in the calling process" do
    assert Once.run(:caller, fn -> self() end) == self()
  end

  test "a waiter computes the key itself after the claimant fails" do
    claimant =
      Task.async(fn ->
        try do
          Once.run(:retried, fn ->
            receive do
              :fail -> raise "boom"
            end
          end)
        rescue
          error in RuntimeError -> {:raised, error.message}
        end
      end)

    wait_for_claim(:retried)
    waiter = Task.async(fn -> Once.run(:retried, fn -> :recovered end) end)
    wait_for_waiter(:retried)

    send(claimant.pid, :fail)

    assert Task.await(claimant) == {:raised, "boom"}
    assert Task.await(waiter) == :recovered
  end

  test "a claimant that dies releases its waiters" do
    {claimant_pid, ref} =
      spawn_monitor(fn -> Once.run(:killed, fn -> Process.sleep(:infinity) end) end)

    wait_for_claim(:killed)

    waiter = Task.async(fn -> Once.run(:killed, fn -> :recovered end) end)
    wait_for_waiter(:killed)

    Process.exit(claimant_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^claimant_pid, :killed}

    assert Task.await(waiter) == :recovered
  end

  test "run_shared/2 computes once and serves the value from a persistent term" do
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      Process.sleep(50)
      %{graph: :value}
    end

    results =
      1..50
      |> Task.async_stream(fn _ -> Once.run_shared(:graph, fun) end, max_concurrency: 50)
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.uniq(results) == [%{graph: :value}]
    assert :counters.get(counter, 1) == 1
    assert Cache.get_shared(:graph) == %{graph: :value}
  end

  test "run_shared/2 recomputes after the cache clears" do
    assert Once.run_shared(:graph, fn -> 1 end) == 1
    Cache.clear()
    assert Once.run_shared(:graph, fn -> 2 end) == 2
  end

  test "computes uncached when the cache table is missing" do
    :ok = Supervisor.terminate_child(Soundcheck.Supervisor, Soundcheck.Cache)
    on_exit(fn -> Supervisor.restart_child(Soundcheck.Supervisor, Soundcheck.Cache) end)

    counter = :counters.new(1, [])
    fun = fn -> :counters.add(counter, 1, 1) end

    Once.run(:uncached, fun)
    Once.run(:uncached, fun)
    Once.run_shared(:uncached_shared, fun)

    assert :counters.get(counter, 1) == 3
    assert Cache.get_shared(:uncached_shared, :missing) == :missing
  end

  defp wait_for_claim(key), do: wait_for(key, &is_map/1)

  defp wait_for_waiter(key), do: wait_for(key, &match?(%{waiters: [_waiter]}, &1))

  # Polls the Once server until its claim on `key` satisfies `ready?`.
  defp wait_for(key, ready?, attempts \\ 50) do
    claim = Map.get(:sys.get_state(Once).claims, {Once, key})

    cond do
      ready?.(claim) ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        wait_for(key, ready?, attempts - 1)
    end
  end
end
