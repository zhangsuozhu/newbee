defmodule Newbee.Tools.Introspect do
  @moduledoc """
  Elixir module introspection: real exports, moduledoc, and BEAM info.
  Use it to learn a loaded module's API without reading source.

  ## Functions
  - `exports(module :: module()) :: [{atom(), arity()}]` — public function list (`__info__/module_info` filtered out).
  - `moduledoc(module :: module()) :: String.t() | nil` — the module's `@moduledoc` opener (via `Code.fetch_docs`).
  - `beam_info(module :: module()) :: %{module: module(), exports: [...], attributes: map()}` — BEAM chunk digest, `:attributes` via `:beam_lib.chunks`.

  ## Runnable example
      Newbee.Tools.Introspect.exports(Newbee.Tools.Fs)
      Newbee.Tools.Introspect.moduledoc(Newbee.Tools.Run)
      Newbee.Tools.Introspect.beam_info(Newbee.Diff)
  """

  @doc "Public function list of a module: [{name, arity}]."
  def exports(module) do
    if Code.ensure_loaded?(module) do
      module.__info__(:functions) |> Enum.reject(fn {n, _} -> n in [:__info__, :module_info] end)
    else
      []
    end
  end

  @doc "A module's @moduledoc (opener)."
  def moduledoc(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} when is_binary(doc) ->
        doc

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc "BEAM chunk digest: %{module, exports, attributes} (attributes subset pulled from Abstract Code)."
  def beam_info(module) do
    case :code.which(module) do
      path when is_list(path) or is_binary(path) ->
        chunk_path = if is_list(path), do: List.to_string(path), else: path

        case :beam_lib.chunks(String.to_charlist(chunk_path), [:attributes]) do
          {:ok, {_, [attributes: attrs]}} ->
            %{
              module: module,
              exports: exports(module),
              attributes: Map.new(attrs, fn {k, v} -> {k, v} end)
            }

          _ ->
            %{module: module, exports: exports(module), attributes: %{}}
        end

      _ ->
        %{module: module, exports: exports(module), attributes: %{}}
    end
  rescue
    _ -> %{module: module, exports: exports(module), attributes: %{}}
  end
end
