alias Number42.Refactors.Heex.{Tree, Scope}

targets = ["/Users/andreassolleder/dev/position-db", "/Users/andreassolleder/dev/hamm-therapy"]
sig = "~H" <> ~s(""")
nc = fn n -> Tree.walk(n, 0, fn _x, a -> a + 1 end) end

cands =
  Enum.flat_map(targets, fn t ->
    Path.wildcard(Path.join(t, "lib/**/*.ex"))
    |> Enum.filter(fn f -> File.regular?(f) and String.contains?(File.read!(f), sig) end)
    |> Enum.flat_map(fn f ->
      case Tree.from_source(File.read!(f)) do
        {:ok, sigils} ->
          Enum.flat_map(sigils, fn s ->
            Tree.walk(s.tree, [], fn n, a -> [n | a] end)
            |> Enum.filter(fn n ->
              match?({:element, _, _, _, _}, n) or match?({:eex_block, _, _, _}, n)
            end)
            |> Enum.filter(fn n -> nc.(n) >= 10 end)
            |> Enum.map(fn n -> {Path.basename(t), MapSet.size(Scope.free_nonassign_vars(n))} end)
          end)

        :error ->
          []
      end
    end)
  end)

cands
|> Enum.group_by(fn {cb, _} -> cb end)
|> Enum.each(fn {cb, cs} ->
  n = length(cs)
  safe = Enum.count(cs, fn {_, free} -> free == 0 end)

  IO.puts(
    "#{cb}: #{n} subtrees >=10n | #{safe} safe (no free var) = #{Float.round(100 * safe / n, 0)}%"
  )
end)
