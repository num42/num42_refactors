# Credo configuration – run with: mix credo --strict
# See https://hexdocs.pm/credo/config_file.html
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "mix.exs"],
        excluded: [~r/_build/, ~r/deps/]
      },
      override_checks: [
        {Credo.Check.Refactor.Nesting, max_nesting: 3}
      ],
      strict: true,
      color: true
    }
  ]
}
