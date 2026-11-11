defmodule Soundcheck.Check do
  @moduledoc false
  # Base for soundcheck's Credo checks.
  #
  # `use Soundcheck.Check` takes the `use Credo.Check` options plus the rule
  # options below, implements `Soundcheck.Rule` except `analyze/2`, and
  # generates the Credo `run/2`.
  #
  #   * `:confidence` and `:tier` (required) - see `Soundcheck.Rule`.
  #   * `:default` (required) - whether the check runs by default.
  #   * `:summary` (required) - one line on what the check catches, for the
  #     README's check table.
  #   * `:tier_note` - replaces the generated tier sentence when part of the
  #     check works without compiling.
  #   * `:needs` - the graph links `analyze/2` reads, from
  #     `Soundcheck.Graph.links/0` (default `[]`).
  #
  # The macro appends the confidence and tier sentence to the `:check`
  # explanation and documents the `excluded_paths` and `strict` params
  # unless the check documents them itself.
  #
  # Credo calls `run_on_all_source_files/3` once per check and run. The
  # generated version analyzes the whole project there, instead of once per
  # source file through `run/2`, and appends each diagnostic as a Credo
  # issue on its anchor file.
  #
  # A diagnostic without an anchor lives only in JavaScript, a file Credo
  # never parses. It becomes an issue whose filename is the JavaScript file.
  # It carries no line number, because Credo's verbose output reads the line
  # from the parsed source file and there is none; the message leads with
  # `file:line:column` instead.
  #
  # Every check takes an `excluded_paths` param (default: test directories)
  # and a `strict` param (default `false`); unverifiable diagnostics appear
  # only in strict mode.

  alias Credo.Execution.ExecutionIssues
  alias Credo.IssueMeta
  alias Credo.SourceFile
  alias Soundcheck.Baseline
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Once
  alias Soundcheck.PathFilter
  alias Soundcheck.Rule
  alias Soundcheck.Suppression

  @required_rule_options [:confidence, :tier, :default, :summary]
  @rule_options @required_rule_options ++ [:tier_note, :needs]

  @param_docs [
    excluded_paths: "Paths to skip (atoms, binaries as path segments, or regexes).",
    strict: "Unused."
  ]

  @tier_notes [
    syntactic: "syntactic (works without compiling)",
    semantic: "semantic (run `mix compile` before `mix credo`)"
  ]

  defmacro __using__(opts) do
    {rule_opts, credo_opts} = Keyword.split(opts, @rule_options)
    rule_opts = validate_rule_options!(rule_opts)

    # Both sides are keyword-list ASTs; the check's own defaults win.
    defaults =
      quote do: [excluded_paths: Soundcheck.PathFilter.default_excluded_paths(), strict: false]

    credo_opts =
      credo_opts
      |> Keyword.update(:param_defaults, defaults, &Keyword.merge(defaults, &1))
      |> Keyword.update!(:explanations, &explanations(&1, rule_opts))

    quote do
      @behaviour Soundcheck.Rule

      use Credo.Check, unquote(credo_opts)

      @impl Soundcheck.Rule
      def confidence, do: unquote(rule_opts[:confidence])

      @impl Soundcheck.Rule
      def tier, do: unquote(rule_opts[:tier])

      @impl Soundcheck.Rule
      def default?, do: unquote(rule_opts[:default])

      @impl Soundcheck.Rule
      def summary, do: unquote(rule_opts[:summary])

      @impl Soundcheck.Rule
      def needs, do: unquote(rule_opts[:needs])

      @impl Credo.Check
      def run(%SourceFile{} = source_file, params),
        do: Soundcheck.Check.run_on_file(__MODULE__, source_file, params)

      @impl Credo.Check
      def run_on_all_source_files(exec, source_files, params),
        do: Soundcheck.Check.run_on_all(__MODULE__, exec, source_files, params)
    end
  end

  # Raises at the check's compile time, naming the missing options or the
  # unknown links, instead of a `KeyError` from inside the generated code.
  defp validate_rule_options!(rule_opts) do
    case @required_rule_options -- Keyword.keys(rule_opts) do
      [] ->
        rule_opts
        |> Keyword.validate!([tier_note: nil, needs: []] ++ @required_rule_options)
        |> tap(&validate_needs!(&1[:needs]))

      missing ->
        raise ArgumentError,
              "use Soundcheck.Check is missing required options: #{inspect(missing)}"
    end
  end

  defp validate_needs!(needs) do
    case needs -- Graph.links() do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, "use Soundcheck.Check got unknown needs: #{inspect(unknown)}"
    end
  end

  # `explanations` is the keyword list AST from the check's `use` call; the
  # `:check` text may be a sigil, so the footer joins it at runtime.
  defp explanations(explanations, rule_opts) do
    tier = rule_opts[:tier_note] || @tier_notes[rule_opts[:tier]]
    footer = "\nConfidence: #{rule_opts[:confidence]}. Tier: #{tier}.\n"

    explanations
    |> Keyword.update!(:check, &quote(do: unquote(&1) <> unquote(footer)))
    |> Keyword.update(:params, @param_docs, &Keyword.merge(@param_docs, &1))
  end

  @doc """
  The generated `run_on_all_source_files/3`: analyzes the project and
  appends the check's issues to the run. A diagnostic becomes an issue
  when its anchor file is among `source_files`, which Credo has already
  narrowed to the files this check covers. Anchorless diagnostics are
  filed under their JavaScript file, and need at least one source file.
  """
  # Appends through `Credo.Execution.ExecutionIssues.append/2` [private:
  # the call Credo's generated `run_on_source_file/3` makes].
  @spec run_on_all(module(), Credo.Execution.t(), [SourceFile.t()], keyword()) :: :ok
  def run_on_all(_check, _exec, [], _params), do: :ok

  def run_on_all(check, exec, [first | _] = source_files, params) do
    resolved = resolve_params(check, params)
    by_bucket = Enum.group_by(diagnostics(check, resolved), &bucket/1)

    anchored =
      for source_file <- source_files,
          issue <- file_issues(check, source_file, by_bucket, resolved),
          do: issue

    ExecutionIssues.append(exec, anchored ++ unanchored_issues(check, first, by_bucket, resolved))
  end

  @doc """
  The generated `run/2`: analyzes the project and returns the check's
  issues anchored in `source_file`. Credo itself calls
  `run_on_all_source_files/3`; `run/2` serves callers that hold one file.
  """
  @spec run_on_file(module(), SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run_on_file(check, %SourceFile{} = source_file, params) do
    resolved = resolve_params(check, params)
    by_bucket = Enum.group_by(diagnostics(check, resolved), &bucket/1)
    file_issues(check, source_file, by_bucket, resolved)
  end

  # Credo keeps filenames relative to the current directory; the graph may
  # hold absolute ones. Buckets use expanded paths so both meet.
  defp file_issues(check, %SourceFile{filename: filename} = source_file, by_bucket, params) do
    if PathFilter.excluded?(filename, Keyword.fetch!(params, :excluded_paths)) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      by_bucket
      |> Map.get(Path.expand(filename), [])
      |> Enum.map(&to_issue(&1, issue_meta, check))
    end
  end

  # An issue needs an `IssueMeta`, which needs a parsed source file; any
  # file of the run serves, because the issue's filename is replaced.
  defp unanchored_issues(check, source_file, by_bucket, params) do
    issue_meta = IssueMeta.for(source_file, params)

    for diagnostic <- Map.get(by_bucket, :unanchored, []),
        file = Path.relative_to_cwd(diagnostic.primary.file),
        not PathFilter.excluded?(file, Keyword.fetch!(params, :excluded_paths)),
        do: %{to_issue(diagnostic, issue_meta, check) | filename: file}
  end

  defp diagnostics(check, params) do
    check
    |> Rule.run(Graph.Current.get(check.needs()), params)
    |> Rule.drop_silenced(baseline(), &directives/1)
  end

  # Credo runs every check in the same run, and many report findings in the
  # same files, so each file's suppression directives parse once per run.
  defp directives(file),
    do: Once.run({__MODULE__, :directives, file}, fn -> Suppression.file_directives(file) end)

  defp bucket(%Diagnostic{anchor: nil}), do: :unanchored
  defp bucket(%Diagnostic{anchor: anchor}), do: Path.expand(anchor.file)

  # Every check reads the same baseline file, so it loads once per run.
  defp baseline, do: Once.run({__MODULE__, :baseline}, &Baseline.load/0)

  # Fills in the check's defaults and keeps every other param, such as
  # Credo's own `priority` and `exit_status`, which `format_issue/3` reads.
  defp resolve_params(check, params), do: Keyword.merge(check.param_defaults(), params)

  @doc """
  Projects a diagnostic onto a single-location Credo issue at its anchor.
  When the defect sits elsewhere (a `.heex` file), the message leads with
  that location. A diagnostic without an anchor becomes an issue without a
  line number, and its message leads with the primary location.
  """
  @spec to_issue(Diagnostic.t(), IssueMeta.t(), module()) :: Credo.Issue.t()
  def to_issue(%Diagnostic{} = diagnostic, issue_meta, check) do
    {line, column} = if diagnostic.anchor, do: diagnostic.anchor.start, else: {nil, nil}

    location =
      if diagnostic.anchor && diagnostic.primary.file == diagnostic.anchor.file,
        do: "",
        else: "#{format_position(diagnostic.primary)}: "

    suggestion = if diagnostic.suggestion, do: " #{diagnostic.suggestion}", else: ""

    issue_meta
    |> Credo.Check.format_issue(
      [
        message: "#{location}#{diagnostic.message}#{suggestion} (#{diagnostic.id})",
        line_no: line,
        column: column,
        trigger: Credo.Issue.no_trigger()
      ],
      check
    )
    # `no_trigger` keeps `format_issue/3` from deriving a column, but Credo's
    # verbose, JSON, and SARIF output call `to_string/1` on the trigger of
    # any issue with a column and raise on the sentinel tuple. A nil trigger
    # is the `%Credo.Issue{}` default, and every formatter handles it.
    |> Map.merge(%{trigger: nil, meta: [soundcheck: diagnostic]})
  end

  defp format_position(%{file: file, start: {line, column}}), do: "#{file}:#{line}:#{column}"
end
