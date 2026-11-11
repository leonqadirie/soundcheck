# Rules for working with soundcheck

## Understanding soundcheck

soundcheck is a Credo plugin for Phoenix LiveView projects. It checks the contracts between LiveView callbacks, HEEx templates, and JavaScript hooks: events emitted versus events handled, hooks referenced versus hooks registered, `start_async` names versus `handle_async` clauses, and declared component attrs versus assigns read.

Syntactic checks read source and work on uncompiled code. Semantic checks read compiled modules (debug info, `__live__/0`, rendered components).

## Setup

Register the plugin in `.credo.exs`:

    %{
      configs: [
        %{
          name: "default",
          plugins: [{Soundcheck, []}]
        }
      ]
    }

Projects using Igniter can run `mix igniter.install soundcheck`, which adds the dependency, registers the plugin, and adds a `lint` alias.

## Compile before running

Semantic checks need a compiled project. Run `mix compile` before `mix credo`, for example:

    lint: ["compile", "credo --strict"]

On an uncompiled project, SC000 (`Soundcheck.Check.Consistency.Configuration`) reports which modules could not be analyzed. Fix that first; other semantic checks stay silent until then.

## Enabling checks

Only high-confidence checks run by default. Don't guess check names: the checks table in the README (`deps/soundcheck/README.md` inside a consuming project) lists every check, its default, and its parameters, plus a block that enables all opt-in checks.

## Reading a finding

Messages end with the rule id, such as `(SC101)`. A finding inside a `.heex` file is reported at the owning module's `embed_templates` call, and its message starts with the template path, line, and column; edit the template, not the module. Hook findings name the JavaScript file and line in the message.

## Fixing findings

Fix the contract, not the symptom:

- SC101/SC103 (unhandled event): rename the event to what the handler expects (the message suggests the closest handled name), or add the missing `handle_event/3` clause to the module the message names. Do not add a catch-all `handle_event/3` to silence it.
- SC104 (unhandled async result): add a `handle_async/3` clause for that name.
- SC107 (unhandled info message): add a `handle_info/2` clause for that message.
- SC203 (undeclared component attr): add the `attr` declaration, or assign the key in the component body before rendering.
- SC1001 (unknown hook): fix the hook name, or register the hook with `LiveSocket`. If the hook comes from code soundcheck cannot follow (an npm package), list it in the check's `external_hooks` param.

## Suppressing

Prefer fixing. When a finding is a deliberate exception, add a `soundcheck:disable-*` comment with a reason; it works in Elixir, HEEx, and JavaScript:

    # soundcheck:disable-next-line SC107 -- sent by a test helper
    <%!-- soundcheck:disable-next-line SC101 -- pushed by an external widget --%>

Use `disable-next-line` or `disable-line` with the specific rule id, not `disable-file` or family wildcards, unless the whole file is an exception. Findings marked unverifiable appear only with the check's `strict: true` param; they are not errors to suppress.
