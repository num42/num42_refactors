alias Number42.Refactors.Heex.{Tree, ComponentNaming}
alias Number42.Refactors.Ex.ExtractHeexComponentBySeam, as: R

targets = [
  "/Users/andreassolleder/dev/position-db",
  "/Users/andreassolleder/dev/hamm-therapy",
  "/Users/andreassolleder/dev/sharing-backend-phoenix"
]

sig = "~H" <> ~s(""")

for t <- targets do
  files =
    Path.wildcard(Path.join(t, "lib/**/*.ex"))
    |> Enum.filter(fn f -> File.regular?(f) and String.contains?(File.read!(f), sig) end)

  # every accepted candidate node, named
  names =
    Enum.flat_map(files, fn f ->
      src = File.read!(f)

      case Tree.from_source(src) do
        {:ok, sigils} ->
          accepted = R.find_candidates(src) |> Enum.filter(& &1.accepted)

          # re-walk to map accepted candidates back to nodes for naming
          Enum.flat_map(sigils, fn sigil ->
            Tree.walk(sigil.tree, [], fn n, acc -> [n | acc] end)
            |> Enum.filter(fn n ->
              match?({:element, _, _, _, _}, n) or match?({:eex_block, _, _, _}, n)
            end)
            |> Enum.filter(fn n ->
              tag =
                case n do
                  {:element, t, _, _, _} -> t
                  _ -> "eex_block"
                end

              Enum.any?(accepted, fn c -> c.tag == tag end)
            end)
            |> Enum.map(fn n -> ComponentNaming.derive(n, []) end)
          end)

        :error ->
          []
      end
    end)

  fallback = Enum.count(names, &(&1 == :component))
  total = length(names)

  IO.puts(
    "#{Path.basename(t)}: #{total} named | #{total - fallback} from a real source (#{Float.round(100 * (total - fallback) / max(total, 1), 0)}%), #{fallback} generic fallback"
  )

  names
  |> Enum.frequencies()
  |> Enum.sort_by(fn {_, c} -> -c end)
  |> Enum.take(8)
  |> Enum.each(fn {name, c} -> IO.puts("    #{c}x  <.#{name}>") end)
end
