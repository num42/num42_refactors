defmodule Num42.Refactors.EnginePriorityTest do
  use ExUnit.Case, async: true

  alias Num42.Refactors.Engine

  alias Num42.Refactors.Refactors.AliasOrder
  alias Num42.Refactors.Refactors.ExpandShortFormBindings
  alias Num42.Refactors.Refactors.InlineSingleExpressionDef
  alias Num42.Refactors.Refactors.MultiAliasExpand
  alias Num42.Refactors.Refactors.RejectIsNil
  alias Num42.Refactors.Refactors.SortFunctions

  describe "pipeline_modules/1 default ordering" do
    test "high-priority modules run before default ones" do
      mods = Engine.pipeline_modules()
      idx_expand = mods |> Enum.find_index(&(&1 == ExpandShortFormBindings))
      idx_alias = mods |> Enum.find_index(&(&1 == AliasOrder))

      assert idx_expand < idx_alias,
             "ExpandShortFormBindings (priority 250) should run before AliasOrder (default 100)"
    end

    test "low-priority modules run after default ones" do
      mods = Engine.pipeline_modules()
      idx_alias = mods |> Enum.find_index(&(&1 == AliasOrder))
      idx_inline = mods |> Enum.find_index(&(&1 == InlineSingleExpressionDef))
      idx_sort = mods |> Enum.find_index(&(&1 == SortFunctions))

      assert idx_alias < idx_inline,
             "InlineSingleExpressionDef (priority 50) should run after AliasOrder (default 100)"

      assert idx_inline < idx_sort,
             "SortFunctions (priority 30) should run after InlineSingleExpressionDef (priority 50)"
    end
  end

  describe "pipeline_modules/1 with config overrides" do
    test "configured_modules priority lifts a refactor to the top" do
      opts = [
        configured_modules: [
          {RejectIsNil, priority: 999}
        ]
      ]

      [first | _] = Engine.pipeline_modules(opts)
      assert first == RejectIsNil
    end

    test "configured_modules priority sinks a refactor to the bottom" do
      opts = [
        configured_modules: [
          {AliasOrder, priority: -10}
        ]
      ]

      assert List.last(Engine.pipeline_modules(opts)) == AliasOrder
    end

    test "ties stay alphabetical for determinism" do
      opts = [
        configured_modules: [
          {MultiAliasExpand, priority: 200},
          {AliasOrder, priority: 200}
        ]
      ]

      mods = Engine.pipeline_modules(opts)
      idx_alias_order = mods |> Enum.find_index(&(&1 == AliasOrder))
      idx_multi = mods |> Enum.find_index(&(&1 == MultiAliasExpand))

      assert idx_alias_order < idx_multi,
             "AliasOrder should precede MultiAliasExpand alphabetically within the same priority"
    end

    test "config priority places module ahead of default-priority modules" do
      opts = [
        configured_modules: [
          {RejectIsNil, priority: 500}
        ]
      ]

      mods = Engine.pipeline_modules(opts)
      idx_reject = mods |> Enum.find_index(&(&1 == RejectIsNil))
      idx_alias = mods |> Enum.find_index(&(&1 == AliasOrder))

      assert idx_reject < idx_alias,
             "RejectIsNil with config priority 500 should run before AliasOrder (default 100)"
    end
  end
end
