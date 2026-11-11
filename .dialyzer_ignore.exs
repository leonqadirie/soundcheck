# Each entry names the reason it exists; `list_unused_filters: true` reports
# entries that no longer match a warning, so stale ones surface in `mix lint`.
[
  # Elixir 1.20 on OTP 29: Dialyzer reports MapSet opacity mismatches on
  # correct code that threads a MapSet through a recursive private function.
  # A minimal module doing only `walk(items, MapSet.new())` with
  # `MapSet.member?/2` and `MapSet.put/2` reproduces both warnings.
  {"lib/soundcheck/analysis/events.ex", :call_without_opaque},
  {"lib/soundcheck/analysis/events.ex", :call_with_opaque},
  {"lib/soundcheck/js/extractor.ex", :call_without_opaque},
  {"lib/soundcheck/js/extractor.ex", :call_with_opaque},
  {"lib/soundcheck/runner.ex", :call_without_opaque}
]
