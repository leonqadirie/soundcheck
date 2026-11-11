Credo.Application.start(nil, nil)
# Tests that remove the cache table must not print the missing-plugin
# hint; the cache tests reset this flag to observe the hint.
Soundcheck.CacheHint.silence()
ExUnit.start()
