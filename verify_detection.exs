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

  cands = Enum.flat_map(files, fn f -> R.find_candidates(File.read!(f)) end)
  accepted = Enum.filter(cands, & &1.accepted)

  decline_reasons =
    cands
    |> Enum.reject(& &1.accepted)
    |> Enum.frequencies_by(fn c -> c.decline |> String.replace(~r/[\d.]+/, "N") end)
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.take(5)

  IO.puts("\n== #{Path.basename(t)} ==")
  IO.puts("  candidates (>=default gate): #{length(cands)}  accepted: #{length(accepted)}")
  IO.puts("  top decline reasons:")
  Enum.each(decline_reasons, fn {r, n} -> IO.puts("    #{n}x  #{r}") end)

  IO.puts("  sample accepted:")

  accepted
  |> Enum.sort_by(& &1.nodes, :desc)
  |> Enum.take(5)
  |> Enum.each(fn c ->
    IO.puts(
      "    <#{c.tag}> #{c.nodes}n/#{c.lines}L leak=#{c.leak} assigns=#{length(c.assigns)} (#{c.enclosing_fn})"
    )
  end)
end
