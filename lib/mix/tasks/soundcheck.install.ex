if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Soundcheck.Install do
    @shortdoc "Installs soundcheck and configures .credo.exs"

    @moduledoc """
    #{@shortdoc}

    Adds `soundcheck` as a `:dev`/`:test` dependency with `runtime: false`,
    registers the `Soundcheck` plugin in `.credo.exs` (creating the file if
    needed), and adds a `lint` Mix alias that compiles before running Credo,
    because soundcheck's semantic checks read compiled modules. An existing
    `lint` alias is left alone.

    ## Example

        mix igniter.install soundcheck
    """

    use Igniter.Mix.Task

    alias Igniter.Code.Common
    alias Igniter.Code.List
    alias Igniter.Code.Map
    alias Igniter.Project.TaskAliases

    @manual_install_warning """
    Could not add the Soundcheck plugin to .credo.exs automatically: its
    `configs:` value is not a literal list this installer can navigate.

    Add the plugin to your config manually:

        %{
          configs: [
            %{
              name: "default",
              plugins: [{Soundcheck, []}]
            }
          ]
        }
    """

    @notice """
    soundcheck enables a small set of high-confidence checks by default; the
    rest are opt-in. The checks table in the README lists every check and its
    parameters.

    Semantic checks read compiled modules, so run `mix lint` (compile, then
    `credo --strict`) rather than `mix credo` on its own. If your project
    already had a `lint` alias, make sure it compiles before running Credo.
    """

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :soundcheck,
        only: [:dev, :test],
        dep_opts: [runtime: false],
        example: "mix igniter.install soundcheck"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> Igniter.create_or_update_elixir_file(
        ".credo.exs",
        default_credo_config(),
        &update_credo_config/1
      )
      |> TaskAliases.add_alias(:lint, ["compile", "credo --strict"], if_exists: :ignore)
      |> Igniter.add_notice(@notice)
    end

    defp update_credo_config(zipper) do
      plugin_tuple = Sourceror.parse_string!("{Soundcheck, []}")
      plugin_list = Sourceror.parse_string!("[{Soundcheck, []}]")

      same_plugin? = fn existing, new ->
        Sourceror.to_string(Sourceror.Zipper.node(existing)) == Sourceror.to_string(new)
      end

      # Each step returns `:error` when the config is not a literal it can
      # navigate; degrade to a warning with manual instructions instead of
      # crashing the install.
      with {:ok, configs} <- Common.move_to_cursor(zipper, "%{configs: __cursor__()}"),
           {:ok, first_config} <- List.move_to_list_item(configs, fn _ -> true end),
           {:ok, updated} <-
             Map.put_in_map(first_config, [:plugins], plugin_list, fn plugins ->
               List.prepend_new_to_list(plugins, plugin_tuple, same_plugin?)
             end) do
        {:ok, updated}
      else
        _ -> {:warning, @manual_install_warning}
      end
    end

    defp default_credo_config do
      """
      %{
        configs: [
          %{
            name: "default",
            plugins: [{Soundcheck, []}]
          }
        ]
      }
      """
    end
  end
else
  defmodule Mix.Tasks.Soundcheck.Install do
    @shortdoc "Installs soundcheck and configures .credo.exs | Install `igniter` to use"

    @moduledoc """
    #{@shortdoc}

    This task requires the `igniter` package.
    """

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'soundcheck.install' requires igniter. Install igniter and try again.

      For more information, see: https://igniter.hexdocs.pm/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
