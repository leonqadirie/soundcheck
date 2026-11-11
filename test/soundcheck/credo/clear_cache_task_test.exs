defmodule Soundcheck.Credo.ClearCacheTaskTest do
  use ExUnit.Case, async: false

  alias Soundcheck.Cache
  alias Soundcheck.Credo.ClearCacheTask

  setup do
    Cache.clear()
    :ok
  end

  test "clears the cache and returns the exec unchanged" do
    Cache.put(:a, 1)
    exec = %Credo.Execution{}

    assert ^exec = ClearCacheTask.call(exec)
    assert Cache.get(:a) == nil
  end
end
