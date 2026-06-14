defmodule Number42.Refactors.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/num42/num42_refactors"

  def project do
    [
      app: :number42_refactors,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      dialyzer: dialyzer(),
      description: description(),
      source_url: @source_url,
      homepage_url: @source_url,
      name: "Number42.Refactors"
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:mix, :eex, :dialyzer],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp description do
    "AST-based refactor engine for Elixir — pluggable, idempotent rewrites driven by Sourceror."
  end

  # The model-generation Mix task lives under dev/ and is compiled only in
  # :dev — it depends on tokenizers/safetensors/nx, which are dev-only and
  # absent in :test/:prod. The library proper (lib/) never touches them.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:sourceror, "~> 1.7"},
      # Static-embedding model generation only — see priv/semantic. The
      # refactors load frozen JSON vector tables at runtime; these deps
      # are needed solely to regenerate those tables from the source model.
      {:tokenizers, "~> 0.5", only: :dev, runtime: false},
      {:safetensors, "~> 0.1", only: :dev, runtime: false},
      {:nx, "~> 0.9", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["num42"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Docs" => "https://hexdocs.pm/number42_refactors"
      },
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "LICENSE",
        "guides/architecture.md",
        "guides/configuration.md",
        "guides/authoring-a-refactor.md",
        "guides/ci-usage.md",
        "guides/comparison.md",
        "guides/troubleshooting.md",
        "guides/safety-and-limitations.md",
        "guides/performance.md",
        "guides/refactor-catalog.md",
        "CONTRIBUTING.md",
        "CODE_OF_CONDUCT.md"
      ],
      groups_for_extras: [
        Guides: Path.wildcard("guides/*.md")
      ],
      nest_modules_by_prefix: [
        Number42.Refactors.Ex,
        Number42.Refactors.Heex
      ],
      groups_for_modules: [
        Core: [
          Number42.Refactors.Engine,
          Number42.Refactors.Refactor,
          Number42.Refactors.AstHelpers,
          Number42.Refactors.AstDiff
        ],
        "Mix Tasks": [
          Mix.Tasks.Refactor,
          Mix.Tasks.Refactor.HeexClones
        ],
        "HEEx Internals": [
          Number42.Refactors.Heex.Clones,
          Number42.Refactors.Heex.Fingerprint,
          Number42.Refactors.Heex.Normalizer,
          Number42.Refactors.Heex.Tree
        ],
        "Refactors – Style & Ordering": [
          Number42.Refactors.Ex.AliasOrder,
          Number42.Refactors.Ex.AliasUsage,
          Number42.Refactors.Ex.ImportAfterAlias,
          Number42.Refactors.Ex.LiftDirectives,
          Number42.Refactors.Ex.MultiAliasExpand,
          Number42.Refactors.Ex.RemoveBlankBetweenAttrAndDef,
          Number42.Refactors.Ex.SortFunctions,
          Number42.Refactors.Ex.SortKeywords,
          Number42.Refactors.Ex.MergeAssignKeywords
        ],
        "Refactors – Enum / Map / Stream": [
          Number42.Refactors.Ex.EnumCapture,
          Number42.Refactors.Ex.EnumFindToKeyfind,
          Number42.Refactors.Ex.EnumIntoToMapNew,
          Number42.Refactors.Ex.EnumIntoToMapSet,
          Number42.Refactors.Ex.EnumMapIntoToMapNew,
          Number42.Refactors.Ex.EnumReduceToSum,
          Number42.Refactors.Ex.EnumReverseConcat,
          Number42.Refactors.Ex.FilterCountToCount,
          Number42.Refactors.Ex.FlatMapToFilter,
          Number42.Refactors.Ex.MapNewLambdaToForComprehension,
          Number42.Refactors.Ex.MapNewToPipe,
          Number42.Refactors.Ex.MapSumToSumBy,
          Number42.Refactors.Ex.MemberToInOperator,
          Number42.Refactors.Ex.MergePipelineIntoComprehension,
          Number42.Refactors.Ex.ReduceAsMap,
          Number42.Refactors.Ex.ReduceMapPut,
          Number42.Refactors.Ex.RejectIsNil,
          Number42.Refactors.Ex.SortReverseToDesc,
          Number42.Refactors.Ex.UseMapJoin
        ],
        "Refactors – Pattern Matching & Control Flow": [
          Number42.Refactors.Ex.CaseTrueFalse,
          Number42.Refactors.Ex.CollapseNestedCaseToWith,
          Number42.Refactors.Ex.IfLiftToClauses,
          Number42.Refactors.Ex.RedundantBooleanIf,
          Number42.Refactors.Ex.RemoveTrivialElseClause,
          Number42.Refactors.Ex.WithSingleClauseToCase,
          Number42.Refactors.Ex.WithWithoutElse
        ],
        "Refactors – Pipes & Sigils": [
          Number42.Refactors.Ex.ExtractSocketToPipe,
          Number42.Refactors.Ex.ExtractToPipeline,
          Number42.Refactors.Ex.LiftPinnedEctoExpr,
          Number42.Refactors.Ex.LiftWithIntoPipeline,
          Number42.Refactors.Ex.ManualTapToTap,
          Number42.Refactors.Ex.PipeReassign
        ],
        "Refactors – Length / String / List": [
          Number42.Refactors.Ex.GraphemesLength,
          Number42.Refactors.Ex.LengthInGuard,
          Number42.Refactors.Ex.LengthZeroToEmpty,
          Number42.Refactors.Ex.ListLastOfReverse,
          Number42.Refactors.Ex.SortForTopK
        ],
        "Refactors – Definition Hygiene": [
          Number42.Refactors.Ex.DelegateExactDuplicates,
          Number42.Refactors.Ex.ExpandShortFormBindings,
          Number42.Refactors.Ex.ExpandShortFormFunctions,
          Number42.Refactors.Ex.ExpandShortFormParams,
          Number42.Refactors.Ex.IdentityPassthrough,
          Number42.Refactors.Ex.InlineSingleExpressionDef,
          Number42.Refactors.Ex.LiftUntypedParamToStructPattern,
          Number42.Refactors.Ex.ResolveImplTrue,
          Number42.Refactors.Ex.UnusedVariable
        ],
        "Refactors – Cross-File Extraction": [
          Number42.Refactors.Ex.ExtractBehaviourFromAdapterFamily,
          Number42.Refactors.Ex.ExtractCaseToHelper,
          Number42.Refactors.Ex.ExtractInlineBlock,
          Number42.Refactors.Ex.ExtractIntraModuleClone,
          Number42.Refactors.Ex.ExtractLambdaBlock,
          Number42.Refactors.Ex.ExtractNestedBlock,
          Number42.Refactors.Ex.ExtractParametricClone,
          Number42.Refactors.Ex.ExtractProtocolFromStructFamily,
          Number42.Refactors.Ex.ExtractRenamedClone,
          Number42.Refactors.Ex.ExtractSharedModule
        ],
        "Refactors – HEEx": [
          Number42.Refactors.Ex.ExtractHeexExactClone,
          Number42.Refactors.Ex.ExtractHeexFor
        ],
        "Refactors – Type & API Safety": [
          Number42.Refactors.Ex.MapGetUnsafePass,
          Number42.Refactors.Ex.TryRescueWithSafeAlternative,
          Number42.Refactors.Ex.UtcNowTruncate
        ]
      ]
    ]
  end
end
