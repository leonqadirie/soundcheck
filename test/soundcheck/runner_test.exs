defmodule Soundcheck.RunnerTest do
  use ExUnit.Case, async: true

  alias Soundcheck.Runner

  test "run/1 rejects unknown options" do
    assert_raise ArgumentError, ~r/unknown keys \[:path\]/, fn ->
      Runner.run(path: ["lib/**/*.ex"])
    end
  end
end
