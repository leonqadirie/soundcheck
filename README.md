# Soundcheck

[![Hex.pm](https://img.shields.io/hexpm/v/soundcheck.svg)](https://hex.pm/packages/soundcheck)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/soundcheck)
[![License: MIT](https://img.shields.io/badge/license-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)

Soundcheck is a [Credo](https://github.com/rrrene/credo) plugin for Phoenix LiveView. It finds bugs by checking how callbacks, HEEx templates, and JavaScript hooks work together: an event with no handler, an async task with no result callback, or an assign missing from the first render.

Some checks analyse source code directly. Others read compiled modules to resolve event handlers, components, routes, and mount hooks across files.

> [!WARNING]
> This project is experimental and might break frequently.

A set of high-confidence checks runs by default. All other checks are opt-in; the [checks table](#checks) lists which are enabled. When Soundcheck cannot resolve a dynamic value or external hook, it can report an **unverifiable** finding. These findings appear only when you enable Soundcheck's `strict` parameter or pass `mix soundcheck --strict`.

The name comes from the check musicians run before going live.

## Installation

Supported versions: Elixir 1.18 or later, Phoenix 1.7 and 1.8, LiveView 1.1 and 1.2, and Credo 1.7.

### With Igniter

If your project uses [Igniter](https://hexdocs.pm/igniter), run:

```shell
mix igniter.install soundcheck@0.2.0
```

The installer adds Soundcheck as a dependency with `only: [:dev, :test], runtime: false`, registers the plugin in `.credo.exs`, and adds a `lint` alias that compiles before running Credo. If you already have a `lint` alias, the installer leaves it as it is; make sure it runs `compile` before `credo`.

### Manual

Add Soundcheck to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:soundcheck, "~> 0.2.0", only: [:dev, :test], runtime: false}
  ]
end
```

Fetch the dependency:

```shell
mix deps.get
```

Then add the plugin to your existing `.credo.exs` configuration:

```elixir
%{
  configs: [
    %{
      name: "default",
      plugins: [{Soundcheck, []}]
    }
  ]
}
```

### Running with Credo

Compile your project before running Credo:

```shell
mix compile
mix credo
```

For a repeatable workflow, add a Mix alias:

```elixir
# mix.exs
defp aliases do
  [lint: ["compile", "credo --strict"]]
end
```

Then run `mix lint`. Credo's `--strict` option controls Credo's reporting; to include Soundcheck's unverifiable findings, set `strict: true` on the relevant checks in `.credo.exs`.

**Checks marked semantic require a compiled project.** They read handler clauses from module debug info, resolve `on_mount` hooks, and identify the components each template renders. If a module cannot be analysed, the Configuration check (SC000) reports the reason and the affected semantic checks stay silent. Checks marked syntactic work without compiling.

## Checks

- **Default:** `on` checks run automatically; `off` checks must be enabled in [Configuration](#configuration).
- **Tier:** syntactic checks read source code; semantic checks also read compiled modules.
- **Confidence:** how certain the check is about the pattern it detects.

| ID | Check | Category | Default | Tier | Confidence | What it catches |
|---|---|---|---|---|---|---|
| SC000 | `Soundcheck.Check.Consistency.Configuration` | consistency | on | semantic | high | LiveView not loaded, LiveView modules that cannot load or carry no debug info |
| SC001 | `Soundcheck.Check.Readability.InvalidSuppression` | readability | on | syntactic | high | `soundcheck:disable-*` comments naming no rule or an unknown one; with `strict`, comments without a reason |
| SC101 | `Soundcheck.Check.Warning.UnhandledEvent` | warning | on | semantic | high | Template events (`phx-*`, `JS.push`) with no `handle_event/3` clause in the receiving LiveView or LiveComponent |
| SC102 | `Soundcheck.Check.Design.UnusedEventHandler` | design | off | semantic | medium | `handle_event/3` clauses nothing in the project emits |
| SC103 | `Soundcheck.Check.Warning.UnhandledHookEvent` | warning | off | semantic | medium | `pushEvent`/`pushEventTo` calls in hooks that the receiving LiveView does not handle |
| SC104 | `Soundcheck.Check.Warning.UnhandledAsyncResult` | warning | on | semantic | high | `start_async/3` names with no matching `handle_async/3` clause |
| SC105 | `Soundcheck.Check.Warning.FormFieldMismatch` | warning | off | syntactic | medium | `handle_event/3` patterns that require a form field the form never sends |
| SC106 | `Soundcheck.Check.Warning.UnhandledServerPushEvent` | warning | off | syntactic | medium | `push_event/3` events no hook `handleEvent` or `phx:` window listener receives |
| SC107 | `Soundcheck.Check.Warning.UnhandledInfoMessage` | warning | off | semantic | high | Messages a LiveView sends itself, or a LiveComponent sends its parent LiveView, with no matching `handle_info/2` clause |
| SC108 | `Soundcheck.Check.Warning.EventPayloadMismatch` | warning | off | semantic | medium | `phx-click` events whose `phx-value-*` and `JS.push` values lack a key every matching `handle_event/3` clause requires |
| SC201 | `Soundcheck.Check.Warning.PossiblyUnsetAssign` | warning | off | semantic | medium | Template reads of assigns `mount/3` does not set on every path before the first render |
| SC202 | `Soundcheck.Check.Warning.AssignSetOnlyWhenConnected` | warning | on | semantic | high | Template reads of assigns `mount/3` sets only when connected, which crash the first, disconnected render |
| SC203 | `Soundcheck.Check.Warning.UndeclaredComponentAttr` | warning | on | syntactic | high | `@key` reads in function components that declare attrs but not `key` |
| SC204 | `Soundcheck.Check.Warning.OptionalAttrWithoutDefault` | warning | off | syntactic | medium | `@key` reads of optional attrs without a default, which raise when a caller omits them |
| SC205 | `Soundcheck.Check.Design.UnreadAssign` | design | off | syntactic | medium | Assign keys no template, layout, or callback reads |
| SC206 | `Soundcheck.Check.Warning.AsyncAssignFieldRead` | warning | on | syntactic | high | Template reads like `@org.name` of `assign_async` assigns, which hold an `AsyncResult` and raise on render |
| SC301 | `Soundcheck.Check.Refactor.BareAssignsInTemplate` | refactor | off | syntactic | high | The bare `assigns` in template expressions, which disables change tracking |
| SC302 | `Soundcheck.Check.Readability.AssignsDotAccess` | readability | off | syntactic | high | `assigns.key` where `@key` is idiomatic |
| SC303 | `Soundcheck.Check.Refactor.TemplateBoundVariable` | refactor | off | syntactic | medium | Variables bound in templates with `<% x = ... %>` and read later, which disables change tracking |
| SC304 | `Soundcheck.Check.Warning.StreamContainerWithoutPhxUpdate` | warning | on | syntactic | high | Stream loops whose parent element lacks `phx-update="stream"` |
| SC305 | `Soundcheck.Check.Warning.StreamChildWithoutId` | warning | on | syntactic | high | Children of stream containers without an `id={...}` from the stream |
| SC306 | `Soundcheck.Check.Warning.StreamConsumedOutsideFor` | warning | on | syntactic | high | `@streams.name` passed to `Enum`, `length/1`, and other enumerating functions |
| SC307 | `Soundcheck.Check.Refactor.StreamCandidate` | refactor | off | syntactic | low | List assigns grown one item at a time and rendered with `:for` |
| SC308 | `Soundcheck.Check.Refactor.TemporaryAssignCandidate` | refactor | off | syntactic | low | List assigns replaced whole, rendered once with `:for`, and never read in code |
| SC309 | `Soundcheck.Check.Refactor.ExpensiveCallInTemplate` | refactor | off | syntactic | medium | Database, HTTP, and sorting calls inside template expressions |
| SC310 | `Soundcheck.Check.Warning.UndefinedStream` | warning | off | syntactic | medium | `@streams.name` reads and `stream_insert`/`stream_delete` calls on stream names the module never defines |
| SC311 | `Soundcheck.Check.Warning.InvalidLiveComponent` | warning | on | semantic | high | `<.live_component>` calls without `id` or `module`, or whose `module` is not a LiveComponent, which raise on render |
| SC312 | `Soundcheck.Check.Warning.InvalidLiveRender` | warning | on | semantic | high | Nested `live_render(socket, ...)` calls without an `:id`, or of a module that is not a LiveView, which raise on render |
| SC313 | `Soundcheck.Check.Warning.LiteralLiveComponentIdInLoop` | warning | on | syntactic | high | `<.live_component>` with a literal `id` inside a `:for` loop, which raises once the loop renders two items |
| SC401 | `Soundcheck.Check.Warning.UnscopedLookupByClientParam` | warning | off | syntactic | medium | Repo and context lookups (`Blog.get_post!(id)`) by client-sent event or URL params in clauses that never consult the current user or scope |
| SC402 | `Soundcheck.Check.Warning.LiveRouteWithoutAuthHook` | warning | off | semantic | high | Live routes whose live_session and LiveView run no authentication `on_mount` hook that can halt the mount |
| SC501 | `Soundcheck.Check.Warning.UnguardedSubscribe` | warning | on | syntactic | high | PubSub subscriptions in `mount/3` outside `connected?(socket)` |
| SC502 | `Soundcheck.Check.Refactor.ExpensiveMountWork` | refactor | off | syntactic | medium | Database and HTTP calls in `mount/3` that run for both mounts |
| SC503 | `Soundcheck.Check.Warning.UndefinedMountHook` | warning | on | semantic | high | `on_mount` hooks whose module has no `on_mount/4` clause for the hook's argument, which crash every mount they guard |
| SC601 | `Soundcheck.Check.Warning.SubscribedWithoutHandleInfo` | warning | on | semantic | high | LiveViews that subscribe in `mount/3` but define no `handle_info/2` |
| SC602 | `Soundcheck.Check.Warning.BlockingCallInHandler` | warning | off | syntactic | medium | Sleeps, awaits, HTTP calls, and unbounded `receive` in event, info, and params handlers |
| SC603 | `Soundcheck.Check.Warning.CrashingMatchInCallback` | warning | off | syntactic | medium | `{:ok, _} = call()` matches in LiveView callbacks, which crash the process and lose unsaved state when the call fails |
| SC604 | `Soundcheck.Check.Warning.LiveViewCallbackInComponent` | warning | on | syntactic | high | LiveView-only callbacks (`handle_info/2`, `mount/3`, `handle_params/3`, ...) in a LiveComponent, which LiveView never calls |
| SC605 | `Soundcheck.Check.Warning.InvalidSendUpdate` | warning | on | semantic | high | `send_update` calls without an `:id`, or targeting a module that is not a LiveComponent, whose update raises or goes nowhere |
| SC701 | `Soundcheck.Check.Warning.PatchToForeignLiveView` | warning | on | semantic | high | `push_patch` to a route another LiveView renders, which raises |
| SC702 | `Soundcheck.Check.Refactor.NavigateAcrossLiveSession` | refactor | off | semantic | low | `push_navigate`, `<.link navigate>`, and `JS.navigate` into another live_session, which reloads the page |
| SC703 | `Soundcheck.Check.Warning.PatchWithoutHandleParams` | warning | on | semantic | high | `push_patch`, `<.link patch>`, and `JS.patch` back to a LiveView that defines no `handle_params/3`, which raises |
| SC801 | `Soundcheck.Check.Refactor.FormForChangeset` | refactor | off | syntactic | medium | Forms built from a changeset assign instead of `to_form/2` |
| SC802 | `Soundcheck.Check.Refactor.ChangeWithoutDebounce` | refactor | off | syntactic | medium | Text inputs in `phx-change` forms without `phx-debounce` |
| SC803 | `Soundcheck.Check.Warning.FormWithoutRecovery` | warning | off | syntactic | medium | `phx-submit` forms without an `id` or `phx-change`, whose input LiveView cannot restore after a reconnect |
| SC804 | `Soundcheck.Check.Warning.UndefinedUpload` | warning | off | syntactic | medium | `@uploads.name` reads and `consume_uploaded_entries` and other upload calls on names the module never allows |
| SC901 | `Soundcheck.Check.Design.ClickOnNonInteractiveElement` | design | off | syntactic | high | `phx-click` on non-interactive elements without role or keyboard support |
| SC1001 | `Soundcheck.Check.Warning.UndefinedHook` | warning | on | syntactic | high | `phx-hook` names `LiveSocket` does not register |
| SC1002 | `Soundcheck.Check.Design.UnusedHook` | design | off | syntactic | medium | Hooks registered with `LiveSocket` that no template uses; Credo reports these against the JavaScript file |
| SC1003 | `Soundcheck.Check.Warning.HookWithoutId` | warning | on | syntactic | high | HTML elements with `phx-hook` but no `id`, whose hook LiveView never mounts |

Use `mix credo explain <file>:<line>` for a check's full explanation and before/after examples.

## Running with `mix soundcheck`

The standalone task compiles your project and runs the same checks, with text, JSON, or SARIF output. It shows every location involved in a finding, including exact locations in HEEx and JavaScript files. SARIF output includes related locations for code scanning.

```shell
mix soundcheck                      # default checks, plus .credo.exs overrides
mix soundcheck --all --strict       # every check, including unverifiable findings
mix soundcheck --only SC101,SC1002   # selected checks
mix soundcheck --format sarif --output soundcheck.sarif
```

Example output:

```text
SC101 warning: `phx-click="add-trak"` has no matching `handle_event/3` clause in `MyAppWeb.AlbumLive`.
   --> lib/my_app_web/live/album_live.ex:127:30
    |
127 |     <.button phx-click="add-trak">Add track</.button>
    |                        ^^^^^^^^
   = help: Did you mean "add-track"?
```

The task reads check parameters, enabled and disabled checks, and the plugin's `js_paths` from `.credo.exs`. It reads Elixir sources from `--path`, not from Credo's `files` setting. `--all` and `--only` override check selection while retaining configured parameters. It exits with status 1 if it reports any finding that is not unverifiable.

### Command options

| Option | Meaning |
|---|---|
| `--all` | Run every check, including opt-in checks |
| `--only SC101,SC1002` | Run only the listed rule IDs |
| `--strict` | Include unverifiable findings |
| `--format text\|json\|sarif` | Output format; defaults to `text` |
| `--output FILE` | Write output to a file instead of standard output |
| `--path GLOB` | Elixir source glob; repeatable; defaults to `{lib,web}/**/*.ex` and `apps/*/{lib,web}/**/*.ex` |
| `--js-path DIR` | JavaScript source directory; repeatable; overrides configured `js_paths` |
| `--config-file FILE` | Credo configuration file; defaults to `.credo.exs` |
| `--config-name NAME` | Named Credo configuration; defaults to `default` |
| `--no-compile` | Use the existing build without recompiling |
| `--baseline FILE` | Use a specific baseline file |
| `--no-baseline` | Report findings even if they are in the baseline |
| `--write-baseline` | Record current findings in the baseline and exit with status 0 |

## Configuration

### Enabling and disabling checks

Add opt-in checks to `checks.extra` in `.credo.exs`. Use `false` to disable a check, or a keyword list to enable it with parameters:

```elixir
%{
  configs: [
    %{
      name: "default",
      plugins: [{Soundcheck, []}],
      checks: %{
        extra: [
          # Enable an opt-in check
          {Soundcheck.Check.Design.UnusedEventHandler, []},

          # Customise an enabled check
          {Soundcheck.Check.Warning.UnhandledEvent, [ignore_events: [~r/^analytics-/]]},

          # Disable a default check
          {Soundcheck.Check.Warning.UndefinedHook, false}
        ]
      }
    }
  ]
}
```

To enable every opt-in check in Credo, use the following `checks` section. Default checks need no additional entries. For a standalone run, use `mix soundcheck --all`.

```elixir
checks: %{
  extra: [
    {Soundcheck.Check.Design.ClickOnNonInteractiveElement, []},
    {Soundcheck.Check.Design.UnreadAssign, []},
    {Soundcheck.Check.Design.UnusedEventHandler, []},
    {Soundcheck.Check.Design.UnusedHook, []},
    {Soundcheck.Check.Readability.AssignsDotAccess, []},
    {Soundcheck.Check.Refactor.BareAssignsInTemplate, []},
    {Soundcheck.Check.Refactor.ChangeWithoutDebounce, []},
    {Soundcheck.Check.Refactor.ExpensiveCallInTemplate, []},
    {Soundcheck.Check.Refactor.ExpensiveMountWork, []},
    {Soundcheck.Check.Refactor.FormForChangeset, []},
    {Soundcheck.Check.Refactor.NavigateAcrossLiveSession, []},
    {Soundcheck.Check.Refactor.StreamCandidate, []},
    {Soundcheck.Check.Refactor.TemplateBoundVariable, []},
    {Soundcheck.Check.Refactor.TemporaryAssignCandidate, []},
    {Soundcheck.Check.Warning.BlockingCallInHandler, []},
    {Soundcheck.Check.Warning.CrashingMatchInCallback, []},
    {Soundcheck.Check.Warning.EventPayloadMismatch, []},
    {Soundcheck.Check.Warning.FormFieldMismatch, []},
    {Soundcheck.Check.Warning.FormWithoutRecovery, []},
    {Soundcheck.Check.Warning.LiveRouteWithoutAuthHook, []},
    {Soundcheck.Check.Warning.OptionalAttrWithoutDefault, []},
    {Soundcheck.Check.Warning.PossiblyUnsetAssign, []},
    {Soundcheck.Check.Warning.UndefinedStream, []},
    {Soundcheck.Check.Warning.UndefinedUpload, []},
    {Soundcheck.Check.Warning.UnhandledHookEvent, []},
    {Soundcheck.Check.Warning.UnhandledInfoMessage, []},
    {Soundcheck.Check.Warning.UnhandledServerPushEvent, []},
    {Soundcheck.Check.Warning.UnscopedLookupByClientParam, []}
  ]
}
```

### JavaScript sources

The plugin scans `assets/js` for `.js`, `.ts`, and `.mjs` hook sources by default. Set `js_paths` to scan other directories:

```elixir
plugins: [{Soundcheck, [js_paths: ["assets/js", "assets/vendor/hooks"]]}]
```

### Elixir sources

Two parameters decide which Elixir files soundcheck covers under Credo. Both default to the test directories, `[~r"/test/", "test"]`, and match paths the same way (see [Shared check parameters](#shared-check-parameters)).

| Parameter | Set on | Decides |
|---|---|---|
| `graph_excluded_paths` | the plugin | Which of the files Credo loaded soundcheck leaves out of its analysis. A file left out gets no findings and influences none. |
| `excluded_paths` | each check | Where that check does not report. The files still feed the analysis. |

A file gets a finding when it is in the analysis and outside the check's `excluded_paths`.

The plugin leaves test files out by default because the analysis crosses files: a LiveView in `test/support` that renders a component would otherwise receive that component's events, and soundcheck would report in `lib/` that the test LiveView does not handle them.

| Goal | Configuration |
|---|---|
| Analyze application code only | Nothing; this is the default |
| Analyze and report on LiveViews under `test/` | `graph_excluded_paths: []` on the plugin and `excluded_paths: []` on each check that should report there |
| Count test code as a place that renders components, without reporting in it | `graph_excluded_paths: []` on the plugin |
| Keep generated or vendored code out entirely | Add its path to the plugin's `graph_excluded_paths` |
| Silence a directory but keep it as context for other files | Add its path to the checks' `excluded_paths` |

Setting either parameter replaces its default, so repeat the test entries when you add a path:

```elixir
plugins: [{Soundcheck, [graph_excluded_paths: [~r"/test/", "test", "lib/my_app_web/generated"]]}]
```

Paths are relative to the directory Credo runs in. A project inside a directory named `test`, analyzed from above it, must override both parameters.

`mix soundcheck` uses neither parameter: it analyzes the globs `--path` names and reports every finding in them.

### Shared check parameters

Every check accepts:

| Parameter | Default | Meaning |
|---|---|---|
| `excluded_paths` | `[~r"/test/", "test"]` | Files the check does not report in; they still feed the analysis (see [Elixir sources](#elixir-sources)). Strings match whole path segments or full file paths; `"test"` skips `test/foo.ex`, but not `contest/foo.ex`. Regexes match the full filename. |
| `strict` | `false` | Include unverifiable findings. For SC001, also require a reason in suppression comments. |

### Check-specific parameters

Check names below omit the `Soundcheck.Check.<Category>.` prefix. Defaults containing `...` are abbreviated; use `mix credo explain <file>:<line>` for the full check explanation.

| Check | Param | Default | Meaning |
|---|---|---|---|
| `UnhandledEvent`, `UnusedEventHandler` | `ignore_events` | `[]` | Event names to skip: binaries (exact) or regexes |
| `EventPayloadMismatch` | `metadata_keys` | `[]` | Keys added to click payloads by `LiveSocket` metadata callbacks |
| `PossiblyUnsetAssign` | `assume_set` | `[:current_user, :current_scope, :flash, :live_action, :page_title]` | Keys the team's conventions guarantee before the first render |
| `UnreadAssign` | `ignore_assigns` | `[:page_title]` | Keys never reported |
| `UndeclaredComponentAttr` | `implicit_assigns` | `[:inner_block, :rest, :__changed__, :__given__]` | Assign keys never reported |
| `UnguardedSubscribe`, `SubscribedWithoutHandleInfo` | `subscribe_functions` | `[~r/^Phoenix\.PubSub\.subscribe$/, ~r/\.subscribe$/]` | Subscribing functions, matched against `Module.function` with aliases expanded |
| `ExpensiveCallInTemplate` | `expensive_modules`, `expensive_functions` | `[~r/\.Repo$/, ~r/^Ecto\.Query$/, ~r/^(Req\|Finch\|HTTPoison\|Tesla)$/]`, `[{Enum, :sort}, ...]` | Calls that count as expensive in templates |
| `ExpensiveMountWork` | `expensive_modules` | `[~r/\.Repo$/, ~r/^(Req\|Finch\|HTTPoison\|Tesla)$/]` | Modules whose calls count as expensive in `mount/3` |
| `BlockingCallInHandler` | `blocking_functions`, `blocking_modules` | `[{Process, :sleep}, {:timer, :sleep}, {Task, :await}, ...]`, `[~r/^(Req\|Finch\|HTTPoison\|Tesla)$/]` | Calls that block a handler |
| `UnscopedLookupByClientParam` | `repo_modules`, `scope_assigns`, `authorizers`, `excluded_modules` | `[~r/\.Repo$/]`, `[:current_scope, :current_user]`, `[~r/authoriz/, ~r/permit/, ~r/can\?$/, ~r/allowed\?$/]`, `[~r/Admin/]` | Repos to watch; assigns and calls that count as scoping a clause; modules to skip |
| `UnscopedLookupByClientParam` | `lookup_functions` | `[~r/\.get_\w+!?$/, ~r/\.fetch_\w+!?$/]` | Context lookup functions in project modules, matched against `Module.function` |
| `LiveRouteWithoutAuthHook` | `auth_hooks`, `public_paths` | `:auto`, `[]` | Hook modules that authenticate (`:auto`: names containing `Auth`, once any route uses one); route paths that need none |
| `NavigateAcrossLiveSession` | `ignore_sessions` | `[]` | live_session names to skip as origin or target |
| `ChangeWithoutDebounce` | `input_types` | `["text", "search", "email", "textarea", "url", "tel"]` | Input types that count as text-like |
| `ClickOnNonInteractiveElement` | `non_interactive_tags` | `~w(div span li td tr img p section article)` | Tags that are not interactive by default |
| `UndefinedHook` | `external_hooks` | `[]` | Hook names registered by code Soundcheck cannot follow; listing any closes an open registry |

For example, to include unverifiable event findings while ignoring analytics events:

```elixir
{Soundcheck.Check.Warning.UnhandledEvent, [ignore_events: [~r/^analytics-/], strict: true]}
```

## Suppressing findings

For an intentional exception, add a `soundcheck:disable-*` comment with a reason. Suppressions work in Elixir, HEEx, and JavaScript, with both `mix credo` and `mix soundcheck`.

```elixir
# soundcheck:disable-next-line SC107 -- sent by a test helper
```

```heex
<%!-- soundcheck:disable-next-line SC101 -- pushed by an external widget --%>
<div phx-click="external-event"></div>
```

```javascript
// soundcheck:disable-line UnusedHook -- mounted by the admin bundle
```

| Directive | Scope |
|---|---|
| `disable-next-line` | The following line |
| `disable-line` | The comment's own line |
| `disable-file` | The whole file |

Selectors can be rule IDs (`SC101`), family wildcards (`SC1xx`), or check names (`UnhandledEvent`). Separate multiple selectors with commas or spaces. A suppression applies when it covers the finding's location or the line Credo reports it on.

SC001 reports missing or unknown selectors. With `strict: true`, it also reports suppression comments without a reason.

## Adopting on an existing codebase

Use a baseline to record existing findings and report only new ones:

```shell
mix soundcheck --all --write-baseline
```

Commit the generated `.soundcheck_baseline.exs`. Both `mix credo` and `mix soundcheck` use it automatically.

Baseline fingerprints use the rule, file, and message, so moving a finding to another line does not make it new. Changing the finding itself does. Run the baseline command again after fixing findings to remove resolved entries. A run narrowed with `--only` or `--path` preserves entries outside its scope.

Use `mix soundcheck --no-baseline` to see all findings, or `--baseline FILE` to use a different baseline file.

## How findings appear in Credo

Credo reports each finding at one location:

| Finding location | Where Credo reports it |
|---|---|
| Inside a `~H` sigil | The exact attribute in the Elixir file |
| In a `.heex` file | The owning module's `embed_templates` call, or `defmodule` for a colocated LiveView template; the message includes the template location |
| A hook used by a template | The `phx-hook` attribute; the message includes the JavaScript location |
| Only in JavaScript, such as an unused hook (SC1002) | The JavaScript file, without a line number; the message starts with `file:line:column` |

For JavaScript-only findings, use `// soundcheck:disable-next-line` to suppress them; Elixir `# credo:disable` comments cannot reach them. Each Credo issue carries the full finding in `issue.meta[:soundcheck]`.

Use [`mix soundcheck`](#running-with-mix-soundcheck) when you need every related location or line-level JavaScript output.

## Design

See [docs/architecture.md](https://github.com/leonqadirie/soundcheck/blob/main/docs/architecture.md) for the architecture, planned rule catalog, and design decisions.

## License

MIT. See [LICENSE](LICENSE).
