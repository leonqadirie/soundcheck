defmodule Soundcheck.CacheTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Soundcheck.Cache

  setup do
    Cache.clear()
    :ok
  end

  test "stores and reads values, including nil and false" do
    Cache.put(:a, 1)
    Cache.put(:b, nil)
    Cache.put(:c, false)

    assert Cache.get(:a) == 1
    assert Cache.get(:b, :default) == nil
    assert Cache.get(:c, :default) == false
    assert Cache.get(:missing, :default) == :default
  end

  test "clear/0 empties the table" do
    Cache.put(:a, 1)
    Cache.clear()
    assert Cache.get(:a) == nil
  end

  test "put_shared/2 stores a value clear/0 erases" do
    Cache.put_shared(:graph, %{big: :value})
    assert Cache.get_shared(:graph) == %{big: :value}

    Cache.clear()
    assert Cache.get_shared(:graph, :default) == :default
  end

  test "reads and writes from short-lived processes survive their exit" do
    Task.await(Task.async(fn -> Cache.put(:from_task, :ok) end))
    assert Cache.get(:from_task) == :ok
  end

  describe "without the cache table" do
    setup do
      :ok = Supervisor.terminate_child(Soundcheck.Supervisor, Soundcheck.Cache)
      Soundcheck.CacheHint.reset()

      on_exit(fn ->
        Soundcheck.CacheHint.silence()
        Supervisor.restart_child(Soundcheck.Supervisor, Soundcheck.Cache)
      end)
    end

    test "reads miss, writes no-op, and the first access prints the hint once" do
      stderr =
        capture_io(:stderr, fn ->
          assert Cache.get(:a, :default) == :default
          assert Cache.put(:a, 1) == :ok
          assert Cache.put_shared(:c, 3) == :ok
          assert Cache.get_shared(:c, :default) == :default
        end)

      assert stderr =~ "add {Soundcheck, []} to plugins in .credo.exs"
      assert [_before, _after] = String.split(stderr, "soundcheck plugin not registered")
    end

    test "concurrent first accesses print the hint once" do
      stderr =
        capture_io(:stderr, fn ->
          1..50
          |> Task.async_stream(fn _ -> Cache.get(:a) end, max_concurrency: 50)
          |> Stream.run()
        end)

      assert [_before, _after] = String.split(stderr, "soundcheck plugin not registered")
    end

    test "available?/0 and clear/0 stay silent" do
      assert capture_io(:stderr, fn ->
               refute Cache.available?()
               assert Cache.clear() == :ok
             end) == ""
    end
  end
end
