# soundcheck benchmarks

A local benchee suite for A/B-testing soundcheck's performance across commits. CI does not run it.

`bench/` is a standalone Mix project that plays the host app. It compiles a generated LiveView corpus and loads soundcheck as a path dependency, so soundcheck parses the corpus and introspects its compiled modules inside the corpus's VM, as it does in production.

## A/B workflow

```sh
git switch main
task bench -- --save main        # base results land in tmp/bench/main/
git switch my-branch
task bench -- --compare main     # prints each job next to its main result
```

Narrow a run with `--only GROUP` and `--size SIZE` (both repeatable); pass the same filters to the save and the compare runs. `task bench:checks` runs only the per-check group.

| Group | Measures |
|---|---|
| `e2e` | `Soundcheck.Runner.run/1` with every check: `runner cold` clears the cache before each run, `runner warm` keeps BEAM introspection memoized |
| `stages` | Input parsing, module indexing, graph building, HEEx parsing, and JS extraction over preloaded sources |
| `checks` | Each check's `analyze/2` over a prebuilt graph, cache cleared before each run (default size: `medium`) |
| `credo` | A full in-process Credo run, without `--strict`, with every soundcheck check enabled and no Credo built-in checks. Credo skips checks with a `:low` base priority outside `--strict`, so the run leaves out the Design, Readability, and Refactor checks at that priority |

Corpus sizes: `small` (20 LiveViews), `medium` (100), `large` (400).

### Before this suite exists on the base commit

`SOUNDCHECK_PATH` points the bench project at another checkout, so the current harness can benchmark a commit that predates it:

```sh
git worktree add tmp/bench-base main
SOUNDCHECK_PATH=../tmp/bench-base task bench -- --save main
task bench -- --compare main
```

The same trick keeps the harness fixed while only soundcheck varies, which helps when the bench code itself changed between the two commits.

## The corpus

`task bench:gen` runs `bench/gen.exs`, which writes the corpus into `bench/corpus/` (gitignored) and reruns only when the generator changes. The generator seeds `:rand` per size, so every machine gets the same files. `corpus/FINGERPRINT` holds a sha256 over them.

`--save` writes each group's results to `tmp/bench/TAG/GROUP.benchee` and its metadata (fingerprint, scheduler count, OTP and Elixir versions, soundcheck revision) to `GROUP.meta.exs`, after removing the group's previous files. `--compare` refuses to run when a requested group's saved results come from a different corpus or lack metadata, because the two runs would measure different inputs; re-save the base after changing the generator. It warns when the machine setup differs. The revision counts as dirty only when soundcheck's `lib/`, `mix.exs`, or `mix.lock` changed.

About 5% of the corpus sites carry each kind of contract violation (unhandled events, unknown hooks, stream children without ids, form field mismatches, and more), so the checks report findings and exercise their diagnostic paths. A violation that lives in a feature, such as a stream child without an id, turns that feature on, and the first LiveViews and component modules each carry one kind, so even the small corpus covers every kind.

The generator runs as a plain `elixir` script rather than a Mix task: Mix compiles the whole project, corpus included, before running a task, so a stale corpus would compile in full first and a broken one would block its own regeneration.

## Reading results

- Run on AC power with other applications closed, and compare medians. Treat differences within about 3% as noise.
- "Cold" means a cold soundcheck cache only. The corpus modules stay loaded and the OS page cache stays warm, so the suite does not measure a first run's cost.
- `Graph.build/2` indexes modules with `Task.async_stream`, so `graph build`, `e2e`, and `credo` timings depend on the core count. The same parallelism hides the spawned tasks' memory and reductions: benchee counts only the calling process. The `credo` job runs Credo in a separate process, which it kills afterwards to stop the servers each run leaves behind, so its memory and reduction counts cover none of the work.
- A commit that adds a check changes `e2e`, which runs every check the commit ships, and `credo`, unless the check has a `:low` base priority; in the `checks` group the new check appears without a saved counterpart.
- Saved `.benchee` files load only into the benchee version that wrote them; `bench/mix.lock` pins it.
