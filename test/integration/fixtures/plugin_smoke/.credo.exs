# The fixture lives under the soundcheck repo's test/ directory, and Credo
# reports filenames relative to the current directory, so the plugin's
# default graph_excluded_paths and the checks' default excluded_paths (test
# directories) would skip every file here. The same holds for js_paths,
# which resolve against the current directory.
#
# The "plugin_defaults" config keeps the plugin's default
# graph_excluded_paths, so its graph holds none of the fixture's modules.
js_paths = ["test/integration/fixtures/plugin_smoke/assets/js"]

%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/"]},
      plugins: [{Soundcheck, [js_paths: js_paths, graph_excluded_paths: []]}],
      checks: %{
        extra: [
          {Soundcheck.Check.Warning.UndeclaredComponentAttr,
           [excluded_paths: [], priority: :higher]},
          # Credo hides low-priority issues without --strict.
          {Soundcheck.Check.Design.UnusedHook, [excluded_paths: [], priority: :high]}
        ]
      }
    },
    %{
      name: "plugin_defaults",
      files: %{included: ["lib/"]},
      plugins: [{Soundcheck, [js_paths: js_paths]}]
    }
  ]
}
