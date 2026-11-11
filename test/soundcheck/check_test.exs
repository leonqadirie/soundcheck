defmodule Soundcheck.CheckTest do
  use Soundcheck.CheckCase, async: false

  alias Soundcheck.Graph

  # Reports each analysis to the process in its `notify` param. Its regex
  # default reproduces the defaults that compare unequal across
  # `param_defaults/0` calls on OTP 28+.
  defmodule CountingCheck do
    use Soundcheck.Check,
      id: "SC9999",
      base_priority: :normal,
      category: :warning,
      confidence: :high,
      tier: :syntactic,
      default: false,
      summary: "Counts its analyses",
      param_defaults: [patterns: [~r/Repo$/]],
      explanations: [check: "Counts its analyses."]

    @impl Soundcheck.Rule
    def analyze(_graph, params) do
      send(params[:notify], :analyzed)
      []
    end
  end

  test "run_on_all_source_files/3 analyzes the project once, however many files Credo hands it" do
    sources = [
      {"lib/a.ex", "defmodule A do\nend\n"},
      {"lib/b.ex", "defmodule B do\nend\n"}
    ]

    Graph.prepare(inputs(sources), js_paths: [])
    source_files = for {file, source} <- sources, do: Credo.SourceFile.parse(source, file)

    assert :ok =
             CountingCheck.run_on_all_source_files(Credo.Execution.build(), source_files,
               notify: self()
             )

    assert_received :analyzed
    refute_received :analyzed
  end

  test "use Soundcheck.Check names missing rule options at compile time" do
    message = "use Soundcheck.Check is missing required options: [:default, :summary]"

    assert_raise ArgumentError, message, fn ->
      Code.compile_quoted(
        quote do
          defmodule MissingRuleOptions do
            use Soundcheck.Check,
              id: "SC9998",
              base_priority: :normal,
              category: :warning,
              confidence: :high,
              tier: :syntactic,
              explanations: [check: "Never compiles."]
          end
        end
      )
    end
  end
end
