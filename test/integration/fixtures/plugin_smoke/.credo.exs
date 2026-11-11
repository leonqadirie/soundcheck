# The fixture lives under the soundcheck repo's test/ directory, and Credo
# reports filenames relative to the current directory, so the checks' default
# excluded_paths (test directories) would skip every file here. The same holds
# for js_paths, which resolve against the current directory.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/"]},
      plugins: [{Soundcheck, [js_paths: ["test/integration/fixtures/plugin_smoke/assets/js"]]}],
      checks: %{
        extra: [
          {Soundcheck.Check.Warning.UndeclaredComponentAttr,
           [excluded_paths: [], priority: :higher]},
          # Credo hides low-priority issues without --strict.
          {Soundcheck.Check.Design.UnusedHook, [excluded_paths: [], priority: :high]}
        ]
      }
    }
  ]
}
