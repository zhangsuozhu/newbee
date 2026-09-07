# Regression: CSS single source --nb-*, no legacy aliases.
defmodule Newbee.Web.CssSingleSourceTest do
  use ExUnit.Case, async: false
  @legacy ~r/var\(--(bg2?|fg2?|accent|border)\)/
  test "app.js has no legacy refs" do
    {:ok, js} = File.read("priv/web/app.js")
    assert Regex.scan(@legacy, js) == []
  end

  test "style.css has no legacy refs and single root" do
    {:ok, css} = File.read("priv/web/style.css")
    assert Regex.scan(@legacy, css) == []
    assert length(Regex.scan(~r/:root\s*\{/, css)) == 1
  end

  test "all var refs defined" do
    {:ok, css} = File.read("priv/web/style.css")
    {:ok, js} = File.read("priv/web/app.js")
    defs = Regex.scan(~r/--([a-zA-Z0-9-]+)\s*:/, css) |> Enum.map(fn [_, n] -> n end) |> MapSet.new()

    refs =
      (Regex.scan(~r/var\(--([a-zA-Z0-9-]+)\)/, css) ++ Regex.scan(~r/var\(--([a-zA-Z0-9-]+)\)/, js))
      |> Enum.map(fn [_, n] -> n end)
      |> MapSet.new()

    assert MapSet.to_list(MapSet.difference(refs, defs)) == []
  end
end
