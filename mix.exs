defmodule Num42.Refactors.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/num42/num42_refactors"

  def project do
    [
      app: :num42_refactors,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      description: description(),
      source_url: @source_url,
      name: "Num42.Refactors"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp description do
    "AST-based refactor engine for Elixir — pluggable, idempotent, semantics-preserving rewrites driven by Sourceror."
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:sourceror, "~> 1.7"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["num42"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end
end
