defmodule Newbee.Environment.BindingCodec do
  @moduledoc """
  Binding Continuity 的编解码器（DESIGN §4.4 step 2/3/4）⭐。

  - **codec 白名单 + 大小预算**：只允许明确可序列化的类型
    （nil/bool/number/binary/atom/list/tuple/map/白名单 struct/AST），
    **逐项编解码，不反序列化任意 term**（不用 binary_to_term 解任意数据）；
  - **ArtifactRef 直通**：原本就是 ArtifactRef 的值以内容寻址句柄迁移；
  - **普通大值**：超单值预算不静默换句柄（那会改变变量类型）——
    encode 返回 `{:error, {:over_budget, name, bytes}}`，由 Generation
    取消切换并提示 worker 先显式 artifactize；
  - **tombstone**：PID/Port/Reference/Fun/ETS tid/外部资源句柄 ——
    名字保留，访问时报明确错误（见 `Newbee.Environment.BindingCodec.Tombstone`）；
  - **粒度隔离**：单个值恢复失败只 tombstone 该值，不拖垮整体。
  """

  alias Newbee.ArtifactRef

  @default_value_budget 64_000
  @default_total_budget 1_000_000
  @max_encode_depth 128
  @max_encode_steps 50_000

  # 允许恢复的 struct（模块必须已存在——String.to_existing_atom，不造原子）
  @struct_whitelist [DateTime, Date, Time, NaiveDateTime, Range, Regex, MapSet, Version, ArtifactRef]

  defstruct name: nil, kind: :inline, value: nil, reason: nil, type: nil, bytes: 0

  defmodule Tombstone do
    @moduledoc """
    绑定墓碑（§4.4 step 3）：名字保留、访问时报明确错误。
    带有可选 `recipe`（recompute_recipe）提示——仅当 runtime 记录了
    可靠 provenance 且重放无副作用时存在（§16 待细化）。
    """
    @enforce_keys [:name, :type, :reason]
    defstruct [:name, :type, :reason, :recipe]

    def message(%__MODULE__{} = t) do
      base = "binding #{t.name} 已墓碑化（#{t.type}：#{t.reason}）"

      case t.recipe do
        nil -> base <> "。请重算该值。"
        recipe -> base <> "。可重算：#{recipe}"
      end
    end
  end

  # ── encode ──

  @doc """
  编码 binding（keyword list）为快照条目。
  返回 {:ok, snapshot} | {:error, {:over_budget, name, bytes}}。
  snapshot = %{entries: [%{name, kind, value|reason}], summary: %{...}}
  """
  def encode(binding, opts \\ []) when is_list(binding) do
    value_budget = Keyword.get(opts, :value_budget, @default_value_budget)
    total_budget = Keyword.get(opts, :total_budget, @default_total_budget)

    {entries, {total, tombstones}} =
      Enum.map_reduce(binding, {0, 0}, fn {name, value}, {total, tombs} ->
        entry = encode_value(to_string(name), value, value_budget)

        case entry do
          {:over_budget, bytes} ->
            throw({:over_budget, name, bytes})

          %{kind: :tombstone} ->
            {entry, {total, tombs + 1}}

          %{bytes: bytes} ->
            if total + bytes > total_budget,
              do: throw({:over_budget, name, total + bytes}),
              else: {entry, {total + bytes, tombs}}
        end
      end)

    {:ok,
     %{
       entries: entries,
       summary: %{count: length(entries), tombstones: tombstones, bytes: total}
     }}
  catch
    {:over_budget, name, bytes} -> {:error, {:over_budget, name, bytes}}
  end

  defp encode_value(name, value, budget) do
    with :ok <- preflight_encode(value, budget) do
      case encode_term(value) do
        {:ok, encoded} ->
          bytes = encoded |> Jason.encode!() |> byte_size()

          if bytes > budget do
            {:over_budget, bytes}
          else
            %{name: name, kind: :inline, value: encoded, bytes: bytes}
          end

        {:artifact, ref_map} ->
          %{name: name, kind: :artifact, value: ref_map, bytes: 0}

        {:tombstone, type, reason} ->
          %{name: name, kind: :tombstone, type: type, reason: reason, bytes: 0}
      end
    end
  end

  defp preflight_encode(value, budget) do
    preflight_encode([{:term, value, 0}], budget, 0, 0)
  end

  defp preflight_encode(_stack, budget, binary_bytes, _steps) when binary_bytes > budget,
    do: {:over_budget, binary_bytes}

  defp preflight_encode(_stack, budget, _binary_bytes, steps)
       when steps >= @max_encode_steps,
       do: {:over_budget, budget + 1}

  defp preflight_encode([], _budget, _binary_bytes, _steps), do: :ok

  defp preflight_encode([{:tuple, tuple, index, depth} | rest], budget, bytes, steps) do
    if index == tuple_size(tuple) do
      preflight_encode(rest, budget, bytes, steps + 1)
    else
      preflight_encode(
        [{:term, elem(tuple, index), depth + 1}, {:tuple, tuple, index + 1, depth} | rest],
        budget,
        bytes,
        steps + 1
      )
    end
  end

  defp preflight_encode([{:map, iterator, depth} | rest], budget, bytes, steps) do
    case :maps.next(iterator) do
      :none ->
        preflight_encode(rest, budget, bytes, steps + 1)

      {key, value, next} ->
        preflight_encode(
          [{:term, key, depth + 1}, {:term, value, depth + 1}, {:map, next, depth} | rest],
          budget,
          bytes,
          steps + 1
        )
    end
  end

  defp preflight_encode([{:term, _value, depth} | _rest], budget, _bytes, _steps)
       when depth > @max_encode_depth,
       do: {:over_budget, budget + 1}

  defp preflight_encode([{:term, value, depth} | rest], budget, bytes, steps) do
    case value do
      [] ->
        preflight_encode(rest, budget, bytes, steps + 1)

      [head | tail] ->
        preflight_encode(
          [{:term, head, depth + 1}, {:term, tail, depth} | rest],
          budget,
          bytes,
          steps + 1
        )

      %ArtifactRef{} ->
        preflight_encode(rest, budget, bytes, steps + 1)

      %Regex{} = regex ->
        preflight_encode(rest, budget, bytes + byte_size(Regex.source(regex)), steps + 1)

      %Range{} ->
        preflight_encode(rest, budget, bytes, steps + 1)

      %MapSet{} = set ->
        set_map = set |> Map.from_struct() |> Map.fetch!(:map)
        preflight_encode([{:term, set_map, depth + 1} | rest], budget, bytes, steps + 1)

      %_{} = struct ->
        if struct.__struct__ in @struct_whitelist do
          preflight_encode(
            [{:term, Map.from_struct(struct), depth + 1} | rest],
            budget,
            bytes,
            steps + 1
          )
        else
          preflight_encode(rest, budget, bytes, steps + 1)
        end

      value when is_tuple(value) ->
        preflight_encode([{:tuple, value, 0, depth} | rest], budget, bytes, steps + 1)

      value when is_map(value) ->
        preflight_encode([{:map, :maps.iterator(value), depth} | rest], budget, bytes, steps + 1)

      value when is_binary(value) ->
        preflight_encode(rest, budget, bytes + byte_size(value), steps + 1)

      _other ->
        preflight_encode(rest, budget, bytes, steps + 1)
    end
  end

  # ── 白名单类型逐项编解码 ──

  defp encode_term(nil), do: {:ok, %{"$t" => "nil"}}
  defp encode_term(v) when is_boolean(v), do: {:ok, %{"$t" => "bool", "v" => v}}
  defp encode_term(v) when is_integer(v), do: {:ok, %{"$t" => "int", "v" => v}}
  defp encode_term(v) when is_float(v), do: {:ok, %{"$t" => "float", "v" => v}}

  defp encode_term(v) when is_binary(v) do
    if String.valid?(v) do
      {:ok, %{"$t" => "bin", "v" => v}}
    else
      {:ok, %{"$t" => "bin64", "v" => Base.encode64(v)}}
    end
  end

  defp encode_term(v) when is_atom(v), do: {:ok, %{"$t" => "atom", "v" => to_string(v)}}

  defp encode_term(%ArtifactRef{} = ref) do
    {:artifact,
     %{
       "id" => ref.id,
       "path" => ref.path,
       "bytes" => ref.bytes,
       "sha256" => ref.sha256,
       "media_type" => ref.media_type
     }}
  end

  defp encode_term(%Regex{} = r), do: {:ok, %{"$t" => "regex", "source" => Regex.source(r), "opts" => Regex.opts(r)}}

  defp encode_term(%Range{} = r) do
    {:ok, %{"$t" => "range", "first" => r.first, "last" => r.last, "step" => r.step}}
  end

  defp encode_term(%MapSet{} = s) do
    with {:ok, list} <- encode_term(MapSet.to_list(s)) do
      {:ok, %{"$t" => "mapset", "items" => list["v"]}}
    end
  end

  defp encode_term(%_{} = struct) do
    mod = struct.__struct__

    if mod in @struct_whitelist do
      fields =
        struct
        |> Map.from_struct()
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      case encode_term(fields) do
        {:ok, encoded} ->
          {:ok, %{"$t" => "struct", "mod" => inspect(mod), "fields" => encoded["v"]}}

        other ->
          other
      end
    else
      {:tombstone, "struct:" <> inspect(mod), "struct 不在 codec 白名单"}
    end
  end

  defp encode_term(v) when is_list(v) do
    encoded = Enum.map(v, &encode_term/1)

    if Enum.all?(encoded, &match?({:ok, _}, &1)) do
      {:ok, %{"$t" => "list", "v" => Enum.map(encoded, fn {:ok, e} -> e end)}}
    else
      {:tombstone, "list", "含不可编码元素"}
    end
  end

  defp encode_term(v) when is_tuple(v) do
    encoded = v |> Tuple.to_list() |> Enum.map(&encode_term/1)

    if Enum.all?(encoded, &match?({:ok, _}, &1)) do
      {:ok, %{"$t" => "tuple", "v" => Enum.map(encoded, fn {:ok, e} -> e end)}}
    else
      {:tombstone, "tuple", "含不可编码元素"}
    end
  end

  defp encode_term(v) when is_map(v) do
    encoded =
      Enum.map(v, fn {k, val} ->
        with {:ok, ek} <- encode_map_key(k), {:ok, ev} <- encode_term(val) do
          {:ok, {ek, ev}}
        end
      end)

    if Enum.all?(encoded, &match?({:ok, _}, &1)) do
      {:ok, %{"$t" => "map", "v" => Enum.map(encoded, fn {:ok, {k, val}} -> [k, val] end)}}
    else
      {:tombstone, "map", "含不可编码键或值"}
    end
  end

  defp encode_term(v) when is_pid(v), do: {:tombstone, "pid", "进程句柄跨 generation 失效"}
  defp encode_term(v) when is_port(v), do: {:tombstone, "port", "端口句柄跨 generation 失效"}
  defp encode_term(v) when is_reference(v), do: {:tombstone, "reference", "引用跨 generation 失效"}

  defp encode_term(v) when is_function(v) do
    {:tombstone, "function", "闭包不可迁移（任意匿名函数无法可靠恢复源码）"}
  end

  defp encode_map_key(k) when is_atom(k), do: {:ok, %{"$t" => "atom", "v" => to_string(k)}}
  defp encode_map_key(k) when is_binary(k), do: {:ok, %{"$t" => "bin", "v" => k}}
  defp encode_map_key(k) when is_integer(k), do: {:ok, %{"$t" => "int", "v" => k}}
  defp encode_map_key(_), do: :error

  # ── decode ──

  @doc """
  恢复快照为 binding（keyword list）。按 binding 粒度隔离失败：
  单个值解码失败只 tombstone 该值（§4.4 step 4）。tombstone 项恢复为
  Tombstone 结构体——访问方读到它能报明确错误。
  返回 {binding, migration_summary}。
  """
  def decode(%{entries: entries}) when is_list(entries) do
    {binding, failed, tombstones} =
      Enum.reduce(entries, {[], 0, 0}, fn entry, {acc, failed, tombs} ->
        name = String.to_atom(entry.name)

        case entry.kind do
          :inline ->
            case decode_term(entry.value) do
              {:ok, value} -> {[{name, value} | acc], failed, tombs}
              {:error, _} -> {[{name, tombstone(name, entry, "decode failed")} | acc], failed + 1, tombs}
            end

          :artifact ->
            case decode_artifact(entry.value) do
              {:ok, ref} -> {[{name, ref} | acc], failed, tombs}
              {:error, _} -> {[{name, tombstone(name, entry, "artifact corrupt")} | acc], failed + 1, tombs}
            end

          :tombstone ->
            {[
               {name,
                %Tombstone{name: entry.name, type: entry.type || "unknown", reason: entry.reason || "unmigratable"}}
               | acc
             ], failed, tombs + 1}
        end
      end)

    summary = %{restored: length(binding) - failed - tombstones, tombstones: tombstones, failed: failed}
    {Enum.reverse(binding), summary}
  end

  defp tombstone(name, entry, reason) do
    %Tombstone{name: entry.name || to_string(name), type: entry.type || "unknown", reason: reason}
  end

  defp decode_artifact(map) when is_map(map) do
    ref = %ArtifactRef{
      id: map["id"],
      path: map["path"],
      bytes: map["bytes"],
      sha256: map["sha256"],
      media_type: map["media_type"]
    }

    # 迁移即验证句柄（内容寻址校验）；文件缺失 → 恢复失败 → tombstone
    if File.exists?(ref.path), do: {:ok, ref}, else: {:error, :missing}
  end

  defp decode_term(%{"$t" => "nil"}), do: {:ok, nil}
  defp decode_term(%{"$t" => "bool", "v" => v}) when is_boolean(v), do: {:ok, v}
  defp decode_term(%{"$t" => "int", "v" => v}) when is_integer(v), do: {:ok, v}
  defp decode_term(%{"$t" => "float", "v" => v}) when is_number(v), do: {:ok, v / 1}
  defp decode_term(%{"$t" => "bin", "v" => v}) when is_binary(v), do: {:ok, v}

  defp decode_term(%{"$t" => "bin64", "v" => v}) when is_binary(v) do
    case Base.decode64(v) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :bad_base64}
    end
  end

  defp decode_term(%{"$t" => "atom", "v" => v}) when is_binary(v) do
    {:ok, String.to_existing_atom(v)}
  rescue
    ArgumentError -> {:error, :unknown_atom}
  end

  defp decode_term(%{"$t" => "regex", "source" => src, "opts" => opts}) do
    case Regex.compile(src, opts || "") do
      {:ok, r} -> {:ok, r}
      {:error, _} -> {:error, :bad_regex}
    end
  end

  defp decode_term(%{"$t" => "range", "first" => f, "last" => l} = m) do
    {:ok, Range.new(f, l, Map.get(m, "step", 1))}
  end

  defp decode_term(%{"$t" => "mapset", "items" => items}) when is_list(items) do
    with {:ok, list} <- decode_term(%{"$t" => "list", "v" => items}) do
      {:ok, MapSet.new(list)}
    end
  end

  defp decode_term(%{"$t" => "struct", "mod" => mod_str, "fields" => fields}) do
    with {:ok, mod} <- existing_module(mod_str),
         true <- mod in @struct_whitelist,
         {:ok, field_map} <- decode_term(%{"$t" => "map", "v" => fields}) do
      {:ok, struct(mod, field_map)}
    else
      _ -> {:error, :bad_struct}
    end
  end

  defp decode_term(%{"$t" => "list", "v" => items}) when is_list(items) do
    decoded = Enum.map(items, &decode_term/1)

    if Enum.all?(decoded, &match?({:ok, _}, &1)) do
      {:ok, Enum.map(decoded, fn {:ok, v} -> v end)}
    else
      {:error, :bad_element}
    end
  end

  defp decode_term(%{"$t" => "tuple", "v" => items}) when is_list(items) do
    case decode_term(%{"$t" => "list", "v" => items}) do
      {:ok, list} -> {:ok, List.to_tuple(list)}
      err -> err
    end
  end

  defp decode_term(%{"$t" => "map", "v" => pairs}) when is_list(pairs) do
    decoded =
      Enum.map(pairs, fn
        [k, v] ->
          with {:ok, dk} <- decode_map_key(k), {:ok, dv} <- decode_term(v) do
            {:ok, {dk, dv}}
          end

        _ ->
          :error
      end)

    if Enum.all?(decoded, &match?({:ok, _}, &1)) do
      {:ok, Map.new(decoded, fn {:ok, kv} -> kv end)}
    else
      {:error, :bad_pair}
    end
  end

  defp decode_term(_), do: {:error, :unknown_type}

  defp decode_map_key(%{"$t" => "atom", "v" => v}), do: decode_term(%{"$t" => "atom", "v" => v})
  defp decode_map_key(%{"$t" => "bin", "v" => v}), do: {:ok, v}
  defp decode_map_key(%{"$t" => "int", "v" => v}), do: {:ok, v}
  defp decode_map_key(_), do: {:error, :bad_key}

  defp existing_module("Elixir." <> _ = name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, :unknown_module}
  end

  defp existing_module(_), do: {:error, :not_a_module}

  def struct_whitelist, do: @struct_whitelist
  def default_value_budget, do: @default_value_budget
  def default_total_budget, do: @default_total_budget
end
