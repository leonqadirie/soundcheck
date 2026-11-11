defmodule Soundcheck.NameFilterTest do
  use ExUnit.Case, async: true

  import Soundcheck.NameFilter

  test "exact entries match by equality" do
    assert matches_any?(:save, [:save])
    assert matches_any?("save", ["save"])
    refute matches_any?("save", [:save])
    refute matches_any?(:save, ["save"])
  end

  test "regex entries match binaries and stringified atoms and modules" do
    assert matches_any?("row-delete", [~r/^row-/])
    assert matches_any?(:tick, [~r/^ti/])
    assert matches_any?(MyAppWeb.Admin.UserLive, [~r/Admin/])
    refute matches_any?(MyAppWeb.UserLive, [~r/Admin/])
  end

  test "regex entries never match other terms" do
    refute matches_any?({:tag, 1}, [~r/tag/])
    refute matches_any?(1, [~r/1/])
  end

  test "an empty entry list matches nothing" do
    refute matches_any?(:save, [])
  end
end
