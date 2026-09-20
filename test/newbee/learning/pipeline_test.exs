defmodule Newbee.Learning.PipelineTest do
  use ExUnit.Case, async: false
  alias Newbee.Learning.Pipeline

  @solutions %{
    "held_case_clause_add_clause" => ~S'''
    defmodule Adder do
      def add(a, a), do: :same
      def add(a, b), do: a + b
    end
    IO.puts(Adder.add(1, 2))
    IO.puts("HELD_CASE_OK")
    ''',
    "held_empty_enum_head" => ~S'''
    defmodule SafeHead do
      def head([]), do: nil
      def head(list), do: hd(list)
    end
    IO.inspect(SafeHead.head([1, 2]))
    IO.puts("HELD_EMPTY_OK")
    ''',
    "dev_syntax_missing_do" => ~S'''
    defmodule Greeter do
      def greet(name) do
        "hello " <> name
      end
    end
    IO.puts(Greeter.greet("dev"))
    IO.puts("DEV_SYNTAX_OK")
    ''',
    "dev_undefined_function" => ~S'''
    defmodule Hello do
      def hello(name), do: "hello " <> name
    end
    IO.puts(Hello.hello("world"))
    IO.puts("DEV_UNDEF_OK")
    ''',
    "dev_badmatch_list" => ~S'''
    [a, b, c] = [1, 2, 3]
    IO.puts("sum=" <> Integer.to_string(a + b + c))
    IO.puts("DEV_MATCH_OK")
    ''',
    "dev_string_to_integer" => ~S'''
    case Integer.parse("42abc") do
      {n, _rest} -> IO.puts("parsed=" <> Integer.to_string(n))
      :error -> IO.puts("parsed=0")
    end
    IO.puts("DEV_PARSE_OK")
    '''
  }

  test "stub model passes reproduction and practice, evaluation runs both arms" do
    # Actor input must carry fixture_id: Pipeline injects it into the public task map.
    model_fun = fn messages, _opts ->
      body = hd(Enum.reverse(messages))["content"]
      decoded = Jason.decode!(body)
      id = decoded["task"]["fixture_id"]
      code = Map.fetch!(@solutions, id)
      {:ok, Jason.encode!(%{"code" => code}), %{"total_tokens" => 100}}
    end

    root = Path.join(System.tmp_dir!(), "nbrs-pipeline-" <> Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    dev = list_dev()
    held = list_held() |> Enum.take(2)

    {:ok, result} =
      Pipeline.run(
        experiment_id: "e2e",
        root: root,
        model_fun: model_fun,
        fixtures: dev,
        heldout: held,
        trials: 1,
        max_practices: 1
      )

    assert result["reproduction"] == "pass"
    assert length(result["practices"]) == 1
    report = result["report"]
    assert report["conclusion"] in ["improved", "regressed", "no_clear_gain"]
    assert report["promotion"] == "manual_review_required"
    assert report["coverage"]["planned_pairs"] == length(held)
  end

  defp list_dev, do: Newbee.Learning.Fixtures.list(:development)
  defp list_held, do: Newbee.Learning.Fixtures.list(:heldout)
end
