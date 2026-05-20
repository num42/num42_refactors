defmodule Mix.Tasks.Refactor.Shared do
  @moduledoc false

  # extracted from: Mix.Tasks.Refactor, Mix.Tasks.Refactor.HeexClones
  def expand_inputs_shared(patterns),
    do:
      patterns
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.uniq()
      |> Enum.filter(&File.regular?/1)
end
