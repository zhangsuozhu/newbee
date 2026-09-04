defmodule Newbee.ArchiveTest do
  @moduledoc """
  Newbee.Archive 契约测试：无损压缩 / 分层装配 / 崩溃安全 / history:// 拉取。

  覆盖 DESIGN §4.6 的四条承诺：
  1. 压缩改视图不动日志（transcript 字节不变）；
  2. pull over push（history:// 全链路）；
  3. 确定性压缩优先（LLM 失败时事实账本兜底）；
  4. 崩溃安全（坏账本尾行 / 段文件损坏优雅降级）。
  """
  use ExUnit.Case, async: false
  alias Newbee.{Archive, Session}

  setup do
    id = "arch_#{:erlang.unique_integer([:positive])}"
    s = Session.open(id)
    on_exit(fn -> cleanup(id) end)
    {:ok, session: s, id: id}
  end

  defp cleanup(id) do
    Newbee.Session.delete(id)
  end

  defp feed(s, msgs) do
    Enum.each(msgs, &Session.append(s, &1))
  end

  defp conv(n) do
    # n 轮（user + assistant tool_call + tool 结果）——transcript 语义：不含 system 基底
    Enum.flat_map(1..n, fn i ->
      [
        %{"role" => "user", "content" => "请求 #{i}：修改 lib/demo.ex 第 #{i} 处"},
        %{
          "role" => "assistant",
          "content" => "处理 #{i}",
          "tool_calls" => [
            %{
              "id" => "c#{i}",
              "type" => "function",
              "function" => %{
                "name" => "run_elixir",
                "arguments" => Jason.encode!(%{title: "写文件", code: "Newbee.Tools.Fs.write(\"lib/demo.ex\", \"v#{i}\")"})
              }
            }
          ]
        },
        %{"role" => "tool", "tool_call_id" => "c#{i}", "content" => "✓ ok\n:ok"}
      ]
    end)
  end

  test "压缩后 transcript 逐字节不变（日志永不被压缩销毁）", %{session: s} do
    feed(s, conv(10))
    before = File.read!(s.transcript)

    {:ok, %{archived: n}} = Archive.compact(s, retain: 4)
    assert n > 0

    assert File.read!(s.transcript) == before
    assert Archive.archived?(s)
  end

  test "视图 = 汇总消息 + 近期原文；切点后消息完整（system 基底由 Loop 前置，不进档）", %{session: s} do
    msgs = conv(10)
    feed(s, msgs)

    {:ok, %{view: view}} = Archive.compact(s, retain: 4)

    # 视图 = [汇总消息 | 最近 4 条原文]；意图脊柱里归档区间的用户消息逐字可见
    summary = hd(view)
    assert summary["role"] == "system"
    assert summary["content"] =~ "请求 1：修改 lib/demo.ex"
    assert length(view) == 1 + 4
    assert List.last(view) == List.last(Session.messages(s))
  end

  test "二次压缩不做摘要的摘要：新段 digest 独立、旧段不再重算", %{session: s} do
    feed(s, conv(8))
    {:ok, %{segment: seg1}} = Archive.compact(s, retain: 4, client: fake_client("第一段摘要"))

    feed(s, conv(4))
    {:ok, %{segment: seg2}} = Archive.compact(s, retain: 4, client: fake_client("第二段摘要"))

    assert seg1 != seg2
    digests = Archive.digests(s)
    assert digests[seg1] == "第一段摘要"
    assert digests[seg2] == "第二段摘要"

    view = Archive.view(s)
    summary = hd(view)["content"]
    # 两段 digest 并存（新→旧），而不是互相覆盖或重蒸
    assert summary =~ "第二段摘要"
    assert summary =~ "第一段摘要"
    # 用户意图脊柱跨两段都在
    assert summary =~ "请求 1：修改"
  end

  test "LLM 失败：确定性事实账本仍然完整（无『历史已截断』灾难）", %{session: s} do
    feed(s, conv(6))

    # client 为 nil → digest 完全跳过；视图只剩确定性装配
    {:ok, %{segment: seg}} = Archive.compact(s, retain: 4)

    assert Archive.digests(s) == %{}
    view = Archive.view(s)
    summary = hd(view)["content"]
    assert summary =~ "请求 1" and summary =~ seg
    # 段的事实账本（history://s/seg）照常可读
    {:ok, text} = Archive.read_history(s, "s/#{seg}")
    assert text =~ "lib/demo.ex"
    assert text =~ "用户意图"
  end

  test "确定性事实提取：用户意图逐字、文件、✗→✓ 错误对、剔除注入提醒", _ctx do
    msgs = [
      %{"role" => "system", "content" => "BASE"},
      %{"role" => "user", "content" => "帮我修复 parser 崩溃"},
      %{"role" => "user", "content" => "[进度监控] 检测到进度停滞"},
      %{"role" => "user", "content" => "（自主目标模式启动）目标：x"},
      %{
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "1",
            "type" => "function",
            "function" => %{
              "name" => "run_elixir",
              "arguments" => Jason.encode!(%{code: "Newbee.Tools.Edit.patch(\"src/a.ex\", :old, :new)"})
            }
          }
        ]
      },
      %{"role" => "tool", "tool_call_id" => "1", "content" => "✗ error\n** (KeyError) key :old not found"},
      %{
        "role" => "assistant",
        "tool_calls" => [
          %{
            "id" => "2",
            "type" => "function",
            "function" => %{
              "name" => "run_elixir",
              "arguments" => Jason.encode!(%{code: "Newbee.Tools.Fs.write(\"src/a.ex\", \"fixed\")"})
            }
          }
        ]
      },
      %{"role" => "tool", "tool_call_id" => "2", "content" => "✓ ok\n:wrote"}
    ]

    facts = Archive.extract_facts(msgs)

    assert facts["user_intents"] == ["帮我修复 parser 崩溃"]
    assert "src/a.ex" in facts["files"]
    # 错误签名 + 后续 ✓ 视为已解决
    assert facts["errors"] == ["** (KeyError) key :old not found → 已解决"]
    assert facts["results"] == [":wrote"]
  end

  test "history:// 全链路：索引 / 段摘要 / 原文 / 检索 / 文件清单", %{session: s, id: id} do
    feed(s, conv(6))
    {:ok, %{segment: seg}} = Archive.compact(s, retain: 4)

    Session.set_current(id)
    on_exit(fn -> Session.set_current(nil) end)

    {:ok, idx} = Newbee.read("history://")
    assert idx =~ seg and idx =~ "档案"

    {:ok, seg_text} = Newbee.read("history://s/#{seg}")
    assert seg_text =~ "lib/demo.ex" and seg_text =~ "raw"

    {:ok, raw} = Newbee.read("history://s/#{seg}/raw")
    assert raw =~ "请求 1" and raw =~ "✓ ok"

    {:ok, hits} = Newbee.read("history://q/demo.ex")
    assert hits =~ seg

    {:ok, files} = Newbee.read("history://files")
    assert files =~ "lib/demo.ex"
  after
    Session.set_current(nil)
  end

  test "崩溃安全：账本尾行损坏 → 视图退回原始消息（半条压缩 = 没发生过）", %{session: s} do
    feed(s, conv(8))
    {:ok, _} = Archive.compact(s, retain: 4)
    corrupted_view_len = length(Archive.view(s))

    ledger = Path.join(s.dir, "compactions.jsonl")
    File.write!(ledger, File.read!(ledger) <> ~s({"id": 99, "topic": "compacted", "data": {), [:append])

    # 坏尾行被丢弃：视图回到最后一次有效压缩
    assert length(Archive.view(s)) == corrupted_view_len
  end

  test "崩溃安全：段文件被外力篡改 → sha 校验拒绝读取", %{session: s} do
    feed(s, conv(6))
    {:ok, %{segment: seg}} = Archive.compact(s, retain: 4)

    path = Path.join([s.dir, "archive", seg <> ".jsonl"])
    File.write!(path, String.replace(File.read!(path), "请求 1", "被篡改 1"))

    assert {:error, :checksum_mismatch} = Archive.segment_messages(s, seg)
  end

  test "账本失校验（transcript 漂移）→ 视图优雅降级为原始消息", %{session: s} do
    feed(s, conv(8))
    {:ok, _} = Archive.compact(s, retain: 4)

    # 模拟外力改写 transcript 开头（旧版本覆写式压缩的遗留）
    lines = s.transcript |> File.read!() |> String.split("\n", trim: true)
    body = lines |> Enum.drop(2) |> Enum.map_join("\n", & &1)
    File.write!(s.transcript, body <> "\n")

    assert Archive.view(s) == Session.messages(s)
  end

  test "旧会话（无账本）视图 = 原始消息，逐字节兼容", %{session: s} do
    msgs = conv(5)
    feed(s, msgs)
    assert Archive.view(s) == Session.messages(s)
    assert {:ok, text} = Archive.read_history(s, "")
    assert text =~ "尚无归档段"
  end

  test "current_cut：无档案 nil；压缩后返回切点与段清单（WebUI 分隔条数据源）", %{session: s} do
    assert Archive.current_cut(s) == nil
    feed(s, conv(8))
    {:ok, %{cut: cut}} = Archive.compact(s, retain: 4)
    assert %{cut: ^cut, segments: [seg | _]} = Archive.current_cut(s)
    assert seg.id == "seg-0001" and seg.messages > 0
  end

  test "digest 事件可补写：先失败后成功，幂等不重复", %{session: s} do
    feed(s, conv(6))
    {:ok, %{segment: seg}} = Archive.compact(s, retain: 4)

    # 第一次：LLM 报错 → 不写 digest 事件
    assert {:error, _} = Archive.digest_segment(s, seg, fake_client({:error, :boom}))
    assert Archive.digests(s) == %{}

    # 第二次：成功 → 事件落账本，视图立即用上
    :ok = Archive.digest_segment(s, seg, fake_client("补写的摘要"))
    assert Archive.digests(s)[seg] == "补写的摘要"
    assert hd(Archive.view(s))["content"] =~ "补写的摘要"
  end

  test "token 预算滑窗：超预算段折叠为首行 + history:// 指针", %{session: s} do
    feed(s, conv(6))
    long = String.duplicate("这是一段很长的摘要。", 400)
    {:ok, %{segment: seg1}} = Archive.compact(s, retain: 4, client: fake_client(long))

    feed(s, conv(6))
    {:ok, %{segment: _seg2}} = Archive.compact(s, retain: 4, client: fake_client("短摘要"))

    summary = s |> Archive.view() |> hd() |> Map.get("content")
    # 新段（短）完整保留；旧段（长）折叠并带可拉取指针
    assert summary =~ "短摘要"
    assert summary =~ seg1
    assert summary =~ "history://s/#{seg1}"
  end

  test "noop：保留条数 ≥ 消息数时不产生段", %{session: s} do
    feed(s, conv(3))
    assert :noop = Archive.compact(s, retain: 64)
    refute Archive.archived?(s)
  end

  test "档案召回：用户输入词元命中归档段 → 返回指针行；弱命中静默", %{session: s} do
    msgs =
      conv(4) ++
        [
          %{"role" => "user", "content" => "parser 在处理 utf8 输入时崩溃了，帮我修 parser"},
          %{"role" => "tool", "tool_call_id" => "p1", "content" => "✓ ok\nparser fixed"}
        ] ++ conv(2)

    feed(s, msgs)
    # 归档区间覆盖 parser 消息（最近 4 条原文保留）
    {:ok, _} = Archive.compact(s, retain: 4)

    # 强命中：parser + utf8（latin 词元）都在归档段里
    hits = Archive.recall(s, "回到 utf8 parser 崩溃的问题，现在 parser 又出错了")
    assert length(hits) >= 1
    assert Enum.all?(hits, &String.starts_with?(&1, "[seg-"))

    # 弱命中（词元不足 2 个）/ 停用词：静默
    assert Archive.recall(s, "the and with") == []
    # 短文本（词元提取后不足阈值）
    assert Archive.recall(s, "继续") == []
  end

  test "命中路径：摘要请求 == envelope 消息逐字回放 + 尾部指令", %{session: s} do
    feed(s, conv(6))
    env_msgs = [%{"role" => "system", "content" => "BASE-SYS"}] ++ List.flatten(conv(6))
    digest_client = capture_client(self())
    :ok = Newbee.RequestEnvelope.record(s, digest_client, env_msgs)
    env = Newbee.RequestEnvelope.load(s)

    {:ok, %{segment: seg}} =
      Archive.compact(s, retain: 4, client: digest_client, envelope: env)

    assert_received {:digest_request, request}
    assert request == env_msgs ++ [List.last(request)]
    assert List.last(request)["role"] == "user"
    assert List.last(request)["content"] =~ "压缩引擎"
    assert List.last(request)["content"] =~ "不要调用工具"
    assert_received {:digest_tools, tools}
    assert tools == Jason.decode!(Jason.encode!(Newbee.Codec.tools()))
    # A26 修复：摘要请求与路由请求参数对齐——不写 temperature（stream_chat 也不写）
    assert_received {:digest_has_temperature, false}
    assert Archive.digests(s)[seg] =~ "回放摘要"
  end

  test "无 envelope → 抽取路径（单 user 消息）", %{session: s} do
    feed(s, conv(6))
    {:ok, %{segment: _seg}} = Archive.compact(s, retain: 4, client: capture_client(self()))
    assert_received {:digest_request, request}
    assert length(request) == 1
    assert hd(request)["role"] == "user"
    assert hd(request)["content"] =~ "结构化抽取"
  end

  test "envelope route 失配 → 抽取路径", %{session: s} do
    feed(s, conv(6))

    env = %{
      "version" => 1,
      "base_url" => "http://localhost",
      "model" => "other-model",
      "tools" => [],
      "messages" => [%{"role" => "user", "content" => "x"}],
      "message_count" => 1,
      "sha256" => "x"
    }

    {:ok, %{segment: _seg}} = Archive.compact(s, retain: 4, client: capture_client(self()), envelope: env)
    assert_received {:digest_request, request}
    assert length(request) == 1
  end

  test "二次压缩回放含旧摘要的 envelope（旧摘要前缀）", %{session: s} do
    feed(s, conv(6))

    env1_msgs = [%{"role" => "system", "content" => "BASE"}] ++ List.flatten(conv(6))
    digest_client1 = capture_client(self())
    :ok = Newbee.RequestEnvelope.record(s, digest_client1, env1_msgs)
    env1 = Newbee.RequestEnvelope.load(s)

    {:ok, _} = Archive.compact(s, retain: 4, client: digest_client1, envelope: env1)
    assert_received {:digest_request, _first}

    feed(s, conv(4))
    summary_view = Archive.view(s)
    summary_msg = hd(summary_view)
    assert summary_msg["role"] == "system"
    assert summary_msg["content"] =~ "回放摘要"

    env2_msgs = [%{"role" => "system", "content" => "BASE"}] ++ summary_view
    digest_client2 = capture_client(self())
    :ok = Newbee.RequestEnvelope.record(s, digest_client2, env2_msgs)
    env2 = Newbee.RequestEnvelope.load(s)

    {:ok, _} = Archive.compact(s, retain: 4, client: digest_client2, envelope: env2)
    assert_received {:digest_request, second}
    assert Enum.drop(second, -1) == env2_msgs
  end

  test "无 base 时退回确定性抽取路径（兼容旧行为）", %{session: s} do
    feed(s, conv(6))
    {:ok, %{segment: seg}} = Archive.compact(s, retain: 4, client: fake_client("旧路径摘要"))
    # 函数注入路径不产生 HTTP 请求，直接写 digest
    assert Archive.digests(s)[seg] == "旧路径摘要"
  end

  # ── fakes ──
  # 真 client 形状的 fake：Req.Test plug 截获请求体发回测试进程，返回最小
  # OpenAI 兼容响应。验证 digest 请求形状（前缀缓存友好路径）不经真实网络。
  defp capture_client(test_pid) do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      send(test_pid, {:digest_request, req["messages"]})
      send(test_pid, {:digest_tools, req["tools"]})
      send(test_pid, {:digest_has_temperature, Map.has_key?(req, "temperature")})

      Req.Test.json(conn, %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => "回放摘要：任务与改动要点"}}
        ],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}
      })
    end

    Newbee.LLM.Client.new(
      model: "test/digest-model",
      api_key: "test",
      base_url: "http://localhost",
      req_options: [plug: plug, retry: false]
    )
  end

  defp fake_client(text) when is_binary(text), do: fn _extract, _seg -> {:ok, text} end
  defp fake_client(other), do: fn _extract, _seg -> other end

  test "检索覆盖 tool_calls 参数（assistant 空正文不丢索引）", %{session: s} do
    Newbee.Session.append(s, %{"role" => "user", "content" => "start"})

    Newbee.Session.append(s, %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{
          "id" => "c1",
          "type" => "function",
          "function" => %{"name" => "run_elixir", "arguments" => "special_tool_marker_987()"}
        }
      ]
    })

    Newbee.Session.append(s, %{"role" => "tool", "tool_call_id" => "c1", "content" => "ok"})
    Newbee.Session.append(s, %{"role" => "user", "content" => "end"})
    {:ok, %{segment: seg}} = Archive.compact(s, retain: 1)
    {:ok, hits} = Archive.read_history(s, "q/special_tool_marker_987")
    assert hits =~ seg
  end

  test "召回只返回段指针，不推原文载荷", %{session: s} do
    secret = "secret_marker_abc_xyz"
    Newbee.Session.append(s, %{"role" => "user", "content" => "parser crash " <> secret})
    Newbee.Session.append(s, %{"role" => "assistant", "content" => "got"})
    Newbee.Session.append(s, %{"role" => "tool", "content" => "result " <> secret})
    Newbee.Session.append(s, %{"role" => "user", "content" => "tail one"})
    Newbee.Session.append(s, %{"role" => "user", "content" => "tail two"})
    {:ok, %{segment: seg}} = Archive.compact(s, retain: 1)
    hits = Archive.recall(s, "parser " <> secret <> " crash")
    assert length(hits) >= 1
    assert Enum.all?(hits, fn h -> String.starts_with?(h, "[") end)
    refute Enum.any?(hits, fn h -> String.contains?(h, secret) end)
    assert Enum.any?(hits, fn h -> String.contains?(h, seg) end)
  end

  test "envelope 篡改后 load 拒绝（防毒化 digest）", %{session: s} do
    client = Newbee.LLM.Client.new(model: "m", base_url: "http://localhost", api_key: "t")
    :ok = Newbee.RequestEnvelope.record(s, client, [%{"role" => "user", "content" => "ORIGINAL"}])
    path = Newbee.RequestEnvelope.path(s)
    body = File.read!(path) |> Jason.decode!()
    tampered = put_in(body, ["messages", Access.at(0), "content"], "TAMPERED")
    File.write!(path, Jason.encode!(tampered))
    assert Newbee.RequestEnvelope.load(s) == nil
  end

  test "delete 清除全局 current 残留", %{id: id} do
    Newbee.Session.set_current(id)
    assert Newbee.Session.current_id() == id
    :ok = Newbee.Session.delete(id)
    assert Newbee.Session.current_id() == nil
  end
end
