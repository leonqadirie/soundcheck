defmodule Soundcheck.Analysis.SuggestTest do
  use ExUnit.Case, async: true

  alias Soundcheck.Analysis.Suggest

  test "distance counts insertions, deletions, substitutions, and transpositions" do
    assert Suggest.distance("save", "save") == 0
    assert Suggest.distance("sav", "save") == 1
    assert Suggest.distance("svae", "save") == 1
    assert Suggest.distance("sove", "save") == 1
    assert Suggest.distance("", "abc") == 3
  end

  test "suggests the closest candidate within len/4 edits" do
    assert Suggest.closest("sav", ["save", "delete"]) == "save"
    assert Suggest.closest("incr", ["inc", "dec"]) == "inc"
    assert Suggest.closest("load-more", ["load-mroe", "load"]) == "load-mroe"
    assert Suggest.closest("xyz", ["save"]) == nil
  end

  test "never suggests the name itself" do
    assert Suggest.closest("save", ["save"]) == nil
  end
end
