defmodule Newbee.Colony.TeamTemplate do
  @moduledoc """
  团队模板（纯数据模式）：角色分工 + 沟通机制 + 运营闭环的可复用定义。

  - 模板由 main 角色提案、人审批后入库（Colony.Team），本模块只做规范化与校验，不碰 Store。
  - 运营机制 = 有序阶段流水线；每个阶段一个负责角色，`gate: "review"` 的阶段产出成果后
    等待验收，打回则回到 `rework_to` 阶段重做，形成有界闭环迭代。
  - `max_rounds` 是回退轮次上限；达到上限后停下等人决策，绝不无限循环。
  - 模板是全局可复用资产（不绑定蜂群）；引用模板才产生蜂群、成员与工作。
  """

  @max_roles 8
  @max_stages 12
  @max_rounds_cap 5
  @max_text 4_000
  @gates ~w(review auto)

  @doc "合法 gate 列表（review=需验收，auto=完成即推进）。"
  def gates, do: @gates

  @doc "回退轮次硬上限（防无限迭代）。"
  def max_rounds_cap, do: @max_rounds_cap

  @doc """
  规范化并校验模板定义。attrs: name, description?, roles[], stages[], max_rounds?。
  成功返回 {:ok, template_map}（不含 id/version 等记录字段）；失败 {:error, code, message}。
  """
  def normalize(attrs) when is_map(attrs) do
    with {:ok, name} <- text(attrs["name"], "name", 120),
         {:ok, description} <- optional_text(attrs["description"], "description"),
         {:ok, roles} <- normalize_roles(attrs["roles"]),
         {:ok, stages} <- normalize_stages(attrs["stages"], roles),
         {:ok, rounds} <- normalize_rounds(attrs["max_rounds"]) do
      {:ok,
       %{
         "name" => name,
         "description" => description,
         "roles" => roles,
         "stages" => stages,
         "max_rounds" => rounds
       }}
    end
  end

  def normalize(_), do: {:error, "bad_request", "模板必须是对象"}

  @doc "按 key 找角色；不存在返回 nil。"
  def role(template, key) when is_map(template),
    do: Enum.find(template["roles"] || [], &(&1["key"] == key))

  @doc "第一个阶段的负责角色 key（项目启动时的总协调人）。"
  def lead_key(template) when is_map(template) do
    case template["stages"] do
      [first | _] -> first["role"]
      _ -> nil
    end
  end

  @doc "阶段列表里 key 的下标；不存在返回 nil。"
  def stage_index(template, key) when is_map(template) and is_binary(key),
    do: Enum.find_index(template["stages"] || [], &(&1["key"] == key))

  def stage_index(_, _), do: nil

  @doc """
  模板的人读摘要（注入执行上下文/提案上下文用）。只包含分工与流程事实，
  不含权限指令；调用方把它当资料注入。
  """
  def summary(template) when is_map(template) do
    roles =
      Enum.map_join(template["roles"] || [], "\n", fn r ->
        "- #{r["name"]}(#{r["key"]}): #{r["duty"]}"
      end)

    stages =
      Enum.map_join(template["stages"] || [], " → ", fn s ->
        gate = if s["gate"] == "review", do: "验收", else: "自动"
        "#{s["name"]}@#{s["role"]}[#{gate}]"
      end)

    "团队：#{template["name"]}\n#{template["description"]}\n角色分工：\n#{roles}\n运营流程：#{stages}\n回退轮次上限：#{template["max_rounds"]}"
  end

  @doc "内置「产研团队」模板定义（可直接 normalize/入库）。"
  def product_team do
    %{
      "name" => "产研团队",
      "description" => "产品经理调研并设计产品，UI交互设计师设计用户操作，架构师定技术方案，研发实现，测试验证；验收打回自动回到对应环节，循环迭代产品。",
      "roles" => [
        %{
          "key" => "pm",
          "name" => "产品经理",
          "duty" => "调研用户与竞品，定义目标、范围、优先级与验收标准，撰写PRD；每轮迭代先复盘上轮验收与测试反馈，再修订需求。",
          "capabilities" => ["research", "review", "communicate"]
        },
        %{
          "key" => "ui",
          "name" => "UI交互设计师",
          "duty" => "依据PRD设计信息架构、页面流程与交互细节，产出交互说明与界面规范（文字/原型文件），保证操作路径可用、一致。",
          "capabilities" => ["research", "edit", "communicate"]
        },
        %{
          "key" => "arch",
          "name" => "架构师",
          "duty" => "依据PRD与交互设计制定技术方案：模块边界、数据模型、接口契约、风险与验证方法；控制复杂度，不做过度设计。",
          "capabilities" => ["research", "edit", "shell"]
        },
        %{
          "key" => "dev",
          "name" => "研发工程师",
          "duty" => "按技术方案与交互规范实现功能，编写并运行测试，交付代码变更、验证结果与未覆盖范围；只在授权目录内修改。",
          "capabilities" => ["edit", "shell", "research"]
        },
        %{
          "key" => "qa",
          "name" => "测试工程师",
          "duty" => "依据PRD验收标准与交互规范设计用例并实际执行，输出缺陷清单（复现步骤/期望/实际）与测试报告；结论必须有执行证据。",
          "capabilities" => ["shell", "research", "review"]
        }
      ],
      "stages" => [
        %{
          "key" => "research",
          "name" => "产品调研设计",
          "role" => "pm",
          "goal" => "产出PRD：目标用户、场景、功能范围、优先级、每条需求的验收标准；迭代轮先总结上轮反馈再修订。",
          "gate" => "review",
          "rework_to" => "research"
        },
        %{
          "key" => "design",
          "name" => "UI交互设计",
          "role" => "ui",
          "goal" => "产出页面流程、关键界面与交互说明，覆盖PRD的全部核心场景；标注状态、空态与错误处理。",
          "gate" => "review",
          "rework_to" => "design"
        },
        %{
          "key" => "arch",
          "name" => "技术方案",
          "role" => "arch",
          "goal" => "产出模块划分、数据与接口契约、实现顺序、风险与验证方法；与PRD和交互设计一一对应。",
          "gate" => "review",
          "rework_to" => "design"
        },
        %{
          "key" => "develop",
          "name" => "研发实现",
          "role" => "dev",
          "goal" => "实现本轮PRD范围内的功能并通过自测；交付变更说明、运行/测试证据与已知限制。",
          "gate" => "auto",
          "rework_to" => "develop"
        },
        %{
          "key" => "test",
          "name" => "测试验证",
          "role" => "qa",
          "goal" => "执行验收用例与回归测试，输出测试报告与缺陷清单；发现阻断缺陷时明确打回理由。",
          "gate" => "review",
          "rework_to" => "develop"
        }
      ],
      "max_rounds" => 3
    }
  end

  # ── 规范化 ──

  defp normalize_roles(roles) when is_list(roles) and roles != [] do
    if length(roles) > @max_roles do
      {:error, "bad_request", "角色最多 #{@max_roles} 个"}
    else
      roles
      |> Enum.reduce_while({:ok, []}, fn role, {:ok, acc} ->
        case normalize_role(role) do
          {:ok, r} -> {:cont, {:ok, acc ++ [r]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, list} ->
          keys = Enum.map(list, & &1["key"])

          if length(Enum.uniq(keys)) != length(keys),
            do: {:error, "bad_request", "角色 key 重复"},
            else: {:ok, list}

        error ->
          error
      end
    end
  end

  defp normalize_roles(_), do: {:error, "bad_request", "至少需要 1 个角色"}

  defp normalize_role(role) when is_map(role) do
    with {:ok, key} <- role_key(role["key"]),
         {:ok, name} <- text(role["name"], "roles.name", 60),
         {:ok, duty} <- text(role["duty"], "roles.duty", @max_text) do
      {:ok,
       %{
         "key" => key,
         "name" => name,
         "duty" => duty,
         "capabilities" => capabilities(role["capabilities"])
       }}
    end
  end

  defp normalize_role(_), do: {:error, "bad_request", "角色必须是对象"}

  defp role_key(key) when is_binary(key) do
    if Regex.match?(~r/^[a-z][a-z0-9_]{0,23}$/, key),
      do: {:ok, key},
      else: {:error, "bad_request", "角色 key 只能用小写字母/数字/下划线（如 pm、dev）"}
  end

  defp role_key(_), do: {:error, "bad_request", "角色缺少 key"}

  defp capabilities(list) when is_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(8)
    |> case do
      [] -> ["research", "communicate"]
      caps -> caps
    end
  end

  defp capabilities(_), do: ["research", "communicate"]

  defp normalize_stages(stages, roles) when is_list(stages) and stages != [] do
    if length(stages) > @max_stages do
      {:error, "bad_request", "阶段最多 #{@max_stages} 个"}
    else
      role_keys = MapSet.new(roles, & &1["key"])

      stages
      |> Enum.reduce_while({:ok, []}, fn stage, {:ok, acc} ->
        case normalize_stage(stage, role_keys) do
          {:ok, s} -> {:cont, {:ok, acc ++ [s]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, list} -> validate_stage_refs(list)
        error -> error
      end
    end
  end

  defp normalize_stages(_, _), do: {:error, "bad_request", "至少需要 1 个运营阶段"}

  defp normalize_stage(stage, role_keys) when is_map(stage) do
    with {:ok, key} <- role_key(stage["key"]),
         {:ok, name} <- text(stage["name"], "stages.name", 60),
         {:ok, goal} <- text(stage["goal"], "stages.goal", @max_text),
         {:ok, role} <- stage_role(stage["role"], role_keys),
         {:ok, gate} <- stage_gate(stage["gate"]) do
      rework = if is_binary(stage["rework_to"]) and stage["rework_to"] != "", do: stage["rework_to"], else: key
      {:ok, %{"key" => key, "name" => name, "role" => role, "goal" => goal, "gate" => gate, "rework_to" => rework}}
    end
  end

  defp normalize_stage(_, _), do: {:error, "bad_request", "阶段必须是对象"}

  defp stage_role(key, role_keys) when is_binary(key) do
    if MapSet.member?(role_keys, key),
      do: {:ok, key},
      else: {:error, "bad_request", "阶段负责角色 #{key} 不存在"}
  end

  defp stage_role(_, _), do: {:error, "bad_request", "阶段缺少负责角色 role"}

  defp stage_gate(nil), do: {:ok, "review"}
  defp stage_gate(gate) when gate in @gates, do: {:ok, gate}
  defp stage_gate(_), do: {:error, "bad_request", "gate 只能是 review 或 auto"}

  defp validate_stage_refs(stages) do
    keys = Enum.map(stages, & &1["key"])

    cond do
      length(Enum.uniq(keys)) != length(keys) ->
        {:error, "bad_request", "阶段 key 重复"}

      bad = Enum.find(stages, &(&1["rework_to"] not in keys)) ->
        {:error, "bad_request", "阶段 #{bad["key"]} 的 rework_to 指向不存在的阶段"}

      true ->
        {:ok, stages}
    end
  end

  defp normalize_rounds(nil), do: {:ok, 2}

  defp normalize_rounds(value) when is_integer(value) and value >= 1 and value <= @max_rounds_cap,
    do: {:ok, value}

  defp normalize_rounds(_), do: {:error, "bad_request", "max_rounds 必须是 1..#{@max_rounds_cap} 的整数"}

  defp text(value, field, max) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, "bad_request", "缺少 #{field}"}
      String.length(trimmed) > max -> {:error, "bad_request", "#{field} 超过 #{max} 字"}
      true -> {:ok, trimmed}
    end
  end

  defp text(_, field, _), do: {:error, "bad_request", "缺少 #{field}"}

  defp optional_text(nil, _), do: {:ok, ""}

  defp optional_text(value, field) when is_binary(value) do
    if String.length(value) > @max_text,
      do: {:error, "bad_request", "#{field} 超过 #{@max_text} 字"},
      else: {:ok, String.trim(value)}
  end

  defp optional_text(_, field), do: {:error, "bad_request", "#{field} 必须是文本"}
end
