alias Number42.Refactors.Ex.ExtractHeexComponentBySeam, as: R

files = [
  "/Users/andreassolleder/dev/position-db/lib/position_db_web/components/content_section.ex",
  "/Users/andreassolleder/dev/position-db/lib/position_db_web/live/configurator_live/masses_live.ex",
  "/Users/andreassolleder/dev/position-db/lib/position_db_web/live/item_live/import.ex",
  "/Users/andreassolleder/dev/position-db/lib/position_db_web/live/brand_item_live/edit.ex"
]

for f <- files do
  src = File.read!(f)
  out = R.transform(src, enabled: true)
  changed = out != src
  parses = match?({:ok, _}, Code.string_to_quoted(out))

  new_comps =
    length(Regex.scan(~r/defp (\w+)\(assigns\)/, out)) -
      length(Regex.scan(~r/defp (\w+)\(assigns\)/, src))

  IO.puts("#{Path.basename(f)}: changed=#{changed} parses=#{parses} new_components=#{new_comps}")

  if changed and not parses do
    IO.puts("  !! PARSE FAILURE — first 1500 chars of diff region:")
    {:error, e} = Code.string_to_quoted(out)
    IO.inspect(e)
  end
end
