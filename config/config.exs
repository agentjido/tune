import Config

if config_env() == :dev do
  example_link = &"https://github.com/agentjido/tune/tree/v#{&1}/examples"

  config :git_hooks,
    auto_install: false,
    hooks: [
      commit_msg: [
        tasks: [{:cmd, "mix git_ops.check_message", include_hook_args: true}]
      ]
    ]

  config :git_ops,
    mix_project: Tune.MixProject,
    repository_url: "https://github.com/agentjido/tune",
    release_strategy: :pull_request,
    version_source: :tags,
    version_tag_prefix: "v",
    managed_files: [
      {"mix.exs", :mix},
      {"README.md", example_link, example_link},
      {"guides/compatibility.md", example_link, example_link}
    ],
    types: [docs: [header: "Documentation"], style: [hidden?: true]]
end
