defmodule Soundcheck.CacheHint do
  @moduledoc false
  # Controls whether `Soundcheck.Cache` prints its missing-plugin hint, for
  # tests that remove the cache table. The cache keeps a printed-once flag
  # in a persistent term; this module writes the same term. The cache tests
  # fail when the two keys drift apart, because the hint stops printing.

  @key {Soundcheck.Cache, :missing_table_hint_emitted}

  @doc "Marks the hint as printed, which silences it."
  def silence, do: :persistent_term.put(@key, true)

  @doc "Forgets that the hint was printed, so the next access prints it again."
  def reset do
    :persistent_term.erase(@key)
    :ok
  end
end
