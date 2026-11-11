# Generates the synthetic LiveView corpus the benchmarks analyze.
#
# The script runs in a plain `elixir` VM rather than as a Mix task: Mix
# compiles the whole project, corpus included, before it runs a task, so a
# stale corpus would compile in full, and a broken one would block its own
# regeneration. Run `mix compile` afterwards to compile the new corpus.
Code.require_file("lib/bench.ex", __DIR__)
Code.require_file("lib/bench/corpus.ex", __DIR__)

fingerprint = Bench.Corpus.generate()
IO.puts("corpus written to #{Bench.corpus_dir()} (fingerprint #{fingerprint})")
