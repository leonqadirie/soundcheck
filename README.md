# soundcheck

soundcheck is a Credo plugin that catches Phoenix LiveView bugs living between files: a template emits an event no handler accepts, a hook pushes an event its LiveView ignores, a `start_async` result has nowhere to land. It links callbacks, HEEx templates, and JavaScript hooks into one model per run and checks the contracts between them.

> [!WARNING]
> This project is experimental and might break frequently.

The name comes from the check musicians run before going live.

soundcheck reports only what it can prove. When it cannot resolve something, such as `phx-click={@action}` or a hook registered by an npm package, it marks the finding unverifiable and shows it only in strict mode.

## Installation

With [Igniter](https://hexdocs.pm/igniter):

```shell
mix igniter.install soundcheck
```

The installer adds the dependency (`only: [:dev, :test], runtime: false`), registers the plugin in `.credo.exs`, and adds a `lint` alias.

Manually, add the dependency:

```elixir
def deps do
  [
    {:soundcheck, "~> 0.1", only: [:dev, :test], runtime: false}
  ]
end
```

and register the plugin in `.credo.exs`:

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

## Compile before running Credo

Semantic checks read compiled modules: handler clauses from each module's debug info, `on_mount` hooks, and the components each template renders. Run `mix compile` before `mix credo`, for example through an alias:

```elixir
defp aliases do
  [lint: ["compile", "credo --strict"]]
end
```

Without a compiled project, the Configuration check (SC000) reports why semantic checks skipped a module, and the other semantic checks stay silent. Syntactic checks work on uncompiled code.

## Checks

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

`mix credo explain <file>:<line>` shows each check's full explanation with before/after examples.

Enable every opt-in check:

```elixir
%{
  configs: [
    %{
      name: "default",
      plugins: [{Soundcheck, []}],
      checks: %{
        extra: [
          {Soundcheck.Check.Design.UnreadAssign, []},
          {Soundcheck.Check.Design.UnusedEventHandler, []},
          {Soundcheck.Check.Warning.OptionalAttrWithoutDefault, []},
          {Soundcheck.Check.Warning.PossiblyUnsetAssign, []},
          {Soundcheck.Check.Readability.AssignsDotAccess, []},
          {Soundcheck.Check.Refactor.BareAssignsInTemplate, []},
          {Soundcheck.Check.Refactor.TemplateBoundVariable, []},
          {Soundcheck.Check.Refactor.StreamCandidate, []},
          {Soundcheck.Check.Refactor.TemporaryAssignCandidate, []},
          {Soundcheck.Check.Refactor.ExpensiveCallInTemplate, []},
          {Soundcheck.Check.Refactor.ExpensiveMountWork, []},
          {Soundcheck.Check.Refactor.FormForChangeset, []},
          {Soundcheck.Check.Refactor.NavigateAcrossLiveSession, []},
          {Soundcheck.Check.Refactor.ChangeWithoutDebounce, []},
          {Soundcheck.Check.Design.ClickOnNonInteractiveElement, []},
          {Soundcheck.Check.Warning.BlockingCallInHandler, []},
          {Soundcheck.Check.Warning.FormFieldMismatch, []},
          {Soundcheck.Check.Warning.LiveRouteWithoutAuthHook, []},
          {Soundcheck.Check.Warning.UnhandledHookEvent, []},
          {Soundcheck.Check.Warning.UnhandledInfoMessage, []},
          {Soundcheck.Check.Warning.UnhandledServerPushEvent, []},
          {Soundcheck.Check.Warning.UnscopedLookupByClientParam, []}
        ]
      }
    }
  ]
}
```

## Full output: `mix soundcheck`

Credo shows each finding at one location. `mix soundcheck` shows every location a finding involves (template, handler, JavaScript), with line numbers for findings that live only in JavaScript, and writes SARIF with related locations for code scanning:

```shell
mix soundcheck                      # default checks, text output
mix soundcheck --all --strict       # every check, unverifiable findings too
mix soundcheck --only SC101,SC1002
mix soundcheck --format sarif --output soundcheck.sarif
```

```
SC101 warning: `phx-click="add-trak"` has no matching `handle_event/3` clause in `MyAppWeb.AlbumLive`.
   --> lib/my_app_web/live/album_live.ex:127:30
    |
127 |     <.button phx-click="add-trak">Add track</.button>
    |                        ^^^^^^^^
   = help: Did you mean "add-track"?
```

The task compiles first and exits with status 1 when it reports a finding that is not unverifiable. It reads `.credo.exs` like `mix credo` does: checks listed there run with their params, `{Check, false}` turns a check off, and the plugin's `js_paths` applies. Options: `--format text|json|sarif`, `--output FILE`, `--all`, `--only IDS`, `--strict`, `--path GLOB`, `--js-path DIR`, `--config-file FILE`, `--config-name NAME`, `--baseline FILE`, `--no-baseline`, `--write-baseline`, `--no-compile`.

## Suppressing findings

Fix the contract when you can. For a deliberate exception, add a `soundcheck:disable-*` comment with a reason. It works in Elixir, HEEx, and JavaScript, for `mix credo` and `mix soundcheck` alike:

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

`disable-next-line` covers the following line, `disable-line` its own line, and `disable-file` the whole file. Selectors are rule ids (`SC101`), family wildcards (`SC1xx`), or check names (`UnhandledEvent`), separated by commas or spaces. A comment covers a finding when it covers the finding's location or the line Credo reports it on. SC001 reports comments whose selectors match no rule and, with `strict: true`, comments without a reason.

## Adopting on an existing codebase

Record today's findings in a baseline, and soundcheck reports only new ones, in `mix credo` and `mix soundcheck` alike:

```shell
mix soundcheck --all --write-baseline   # writes .soundcheck_baseline.exs
```

Commit the file. Fingerprints use the rule, file, and message, not line numbers, so edits elsewhere in a file keep a finding recorded; changing the finding itself makes it new. Rewrite the baseline after fixing findings to shrink it. `mix soundcheck --no-baseline` shows everything.

## Configuration

Plugin parameters:

| Param | Default | Meaning |
|---|---|---|
| `js_paths` | `["assets/js"]` | Directories scanned for `.js`, `.ts`, and `.mjs` hook sources |

```elixir
plugins: [{Soundcheck, [js_paths: ["assets/js", "assets/vendor/hooks"]]}]
```

Every check takes:

| Param | Default | Meaning |
|---|---|---|
| `excluded_paths` | `[~r"/test/", "test"]` | Files to skip. A binary matches whole path segments (`"test"` skips `test/foo.ex`, not `contest/foo.ex`); a regex matches the full filename. |
| `strict` | `false` | Also report unverifiable findings. |

Check-specific parameters:

| Check | Param | Default | Meaning |
|---|---|---|---|
| `UnhandledEvent`, `UnusedEventHandler` | `ignore_events` | `[]` | Event names to skip: binaries (exact) or regexes |
| `PossiblyUnsetAssign` | `assume_set` | `[:current_user, :current_scope, :flash, :live_action, :page_title]` | Keys the team's conventions guarantee before the first render |
| `UnreadAssign` | `ignore_assigns` | `[:page_title]` | Keys never reported |
| `UndeclaredComponentAttr` | `implicit_assigns` | `[:inner_block, :rest, :__changed__, :__given__]` | Assign keys never reported |
| `UnguardedSubscribe`, `SubscribedWithoutHandleInfo` | `subscribe_functions` | `[~r/^Phoenix\.PubSub\.subscribe$/, ~r/\.subscribe$/]` | Subscribing functions, matched against `Module.function` with aliases expanded |
| `ExpensiveCallInTemplate` | `expensive_modules`, `expensive_functions` | `[~r/\.Repo$/, ~r/^Ecto\.Query$/, ~r/^(Req\|Finch\|HTTPoison\|Tesla)$/]`, `[{Enum, :sort}, ...]` | Calls that count as expensive in templates |
| `ExpensiveMountWork` | `expensive_modules` | `[~r/\.Repo$/, ~r/^(Req\|Finch\|HTTPoison\|Tesla)$/]` | Modules whose calls count as expensive in `mount/3` |
| `BlockingCallInHandler` | `blocking_functions`, `blocking_modules` | `[{Process, :sleep}, {:timer, :sleep}, {Task, :await}, ...]`, `[~r/^(Req\|Finch\|HTTPoison\|Tesla)$/]` | Calls that block a handler |
| `UnscopedLookupByClientParam` | `repo_modules`, `scope_assigns`, `authorizers`, `excluded_modules` | `[~r/\.Repo$/]`, `[:current_scope, :current_user]`, `[~r/authoriz/, ~r/permit/, ~r/can\?$/, ~r/allowed\?$/]`, `[~r/Admin/]` | Repos to watch; assigns and calls that count as scoping a clause; modules to skip |
| `LiveRouteWithoutAuthHook` | `auth_hooks`, `public_paths` | `:auto`, `[]` | Hook modules that authenticate (`:auto`: names containing `Auth`, once any route uses one); route paths that need none |
| `NavigateAcrossLiveSession` | `ignore_sessions` | `[]` | live_session names to skip as origin or target |
| `ChangeWithoutDebounce` | `input_types` | `["text", "search", "email", "textarea", "url", "tel"]` | Input types that count as text-like |
| `ClickOnNonInteractiveElement` | `non_interactive_tags` | `~w(div span li td tr img p section article)` | Tags that are not interactive by default |
| `UndefinedHook` | `external_hooks` | `[]` | Hook names registered by code soundcheck cannot follow; listing any closes an open registry |

Example:

```elixir
{Soundcheck.Check.Warning.UnhandledEvent, [ignore_events: [~r/^analytics-/], strict: true]}
```

## How findings appear in Credo

Credo reports each issue at one location, in an Elixir file unless the finding lives only in JavaScript. A finding inside a `~H` sigil points at the exact attribute. A finding inside a `.heex` file points at the owning module's `embed_templates` call (or `defmodule` for a colocated LiveView template), and its message starts with the template location. Hook findings point at the `phx-hook` attribute and name the JavaScript location in the message. A finding that lives only in JavaScript, such as an unused hook (SC1002), reports against the JavaScript file without a line number, and its message starts with `file:line:column`; `# credo:disable` comments cannot reach it, so use `// soundcheck:disable-next-line`. Each issue carries the full finding in `issue.meta[:soundcheck]`.

## Supported versions

Elixir 1.17 or later, Phoenix 1.7 and 1.8, LiveView 1.1 and 1.2, Credo 1.7.

## Design

`docs/architecture.md` in the repository describes the architecture, the planned rule catalog, and the decisions behind them.
