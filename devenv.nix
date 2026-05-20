{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:

{
  # https://devenv.sh/packages/
  packages = [
    pkgs.beam.packages.erlang_28.elixir-ls
    pkgs.beam.packages.erlang_28.elixir_1_19
    pkgs.git
  ];

  # https://devenv.sh/languages/
  languages.elixir = {
    enable = true;
    package = pkgs.beam.packages.erlang_28.elixir_1_19;
  };

  # https://devenv.sh/scripts/
  scripts.mix-install.exec = ''
    mix deps.get
  '';

  scripts.precommit.exec = ''
    mix format --check-formatted
    mix compile --warnings-as-errors
    mix test
  '';

  enterShell = ''
    elixir --version
    mix-install
  '';

  # Task names must use a colon namespace (e.g. app:foo); bare names like "mix_install" are invalid.
  tasks = {
    "app:mix_install" = {
      exec = ''
        mix local.hex --force
        mix local.rebar --force
        mix deps.get
      '';
    };

    "app:mix_format" = {
      exec = ''
        mix format
      '';
      execIfModified = [
        "mix.exs"
        "mix.lock"
        "lib"
        "test"
      ];
    };
  };

  # https://devenv.sh/tests/
  enterTest = ''
    echo "Running tests"
    git --version | grep --color=auto "${pkgs.git.version}"

    mix test --warnings-as-errors --cover
  '';

  # https://devenv.sh/git-hooks/
  git-hooks.hooks.mix-precommit = {
    enable = true;
    name = "Mix precommit";
    # Use 'devenv run' so the command runs inside the dev env (mix on PATH)
    # and exit code is propagated (devenv shell is known to swallow exit codes)
    entry = "devenv shell precommit";
    language = "system";
    pass_filenames = false;
  };

  # See full reference at https://devenv.sh/reference/options/
}
