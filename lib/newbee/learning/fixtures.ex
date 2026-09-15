defmodule Newbee.Learning.Fixtures do
  @moduledoc """
  Curated offline Elixir fixture suite for the BRS/DRS v2 learning
  experiment (docs/brs-drs-design.md §4, §9).

  Every fixture is a small, self-contained Elixir error-recovery or tool-use
  task with fixed inputs, fixed initial files, and a deterministic trusted
  oracle. Oracles are curated offline (never model-generated) and consist of
  exit-code plus stdout substring expectations, so a verdict is reproducible
  and cannot be influenced by the actor.

  Splits:

    * `:development` — practice targets the learner may see and retry.
    * `:heldout` — evaluation-only variants around the same skills; held-out
      fixtures are never eligible for practice.

  `list/1` and `get/1` return public task descriptors only. The private
  oracle (`check/3` expectations) is never included in public descriptors;
  leakage is enforced by tests that embed canary strings in oracles and
  assert they do not appear in any public JSON.

  `check/3` evaluates a captured sandbox result (concrete artifact:
  `%{"exit_code" => integer, "stdout" => binary, "stderr" => binary}`) and
  never executes code itself; sandboxed execution is owned by
  `Newbee.Learning.Sandbox` (separate component).
  """

  alias Newbee.Learning.Evaluation

  @splits [:development, :heldout]

  # ------------------------------------------------------------ fixture data

  @fixtures [
    %{
      "id" => "dev_syntax_missing_do",
      "split" => :development,
      "version" => 1,
      "title" => "Fix a missing do keyword",
      "kind" => "elixir_error_recovery",
      "tags" => ["syntax", "def"],
      "task" => %{
        "prompt" => """
        The file `solution.ex` fails to compile with a syntax error.
        Fix the module so that running `elixir solution.ex` prints exactly
        `DEV_SYNTAX_OK` on its own line and exits with status 0.
        """,
        "initial_files" => %{
          "solution.ex" => """
          defmodule Greeter
            def greet(name)
              "hello " <> name
            end
          end

          IO.puts(Greeter.greet("dev"))
          IO.puts("DEV_SYNTAX_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["DEV_SYNTAX_OK", "hello dev"],
        "stdout_not_contains" => ["(SyntaxError)"]
      }
    },
    %{
      "id" => "dev_undefined_function",
      "split" => :development,
      "version" => 1,
      "title" => "Call a function that exists",
      "kind" => "elixir_error_recovery",
      "tags" => ["undefined_function", "module"],
      "task" => %{
        "prompt" => """
        Running `elixir solution.ex` raises UndefinedFunctionError.
        Repair the script so it prints `DEV_UNDEF_OK` on its own line and
        exits with status 0. You may change either the call site or the
        module, but keep the public behaviour: greeting "world".
        """,
        "initial_files" => %{
          "solution.ex" => """
          defmodule Hello do
            def hello(name), do: "hello " <> name
          end

          IO.puts(Hello.greet("world"))
          IO.puts("DEV_UNDEF_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["DEV_UNDEF_OK", "hello world"],
        "stdout_not_contains" => ["(UndefinedFunctionError)"]
      }
    },
    %{
      "id" => "dev_badmatch_list",
      "split" => :development,
      "version" => 1,
      "title" => "Fix a MatchError on list destructuring",
      "kind" => "elixir_error_recovery",
      "tags" => ["badmatch", "pattern_match"],
      "task" => %{
        "prompt" => """
        Running `elixir solution.ex` crashes with a MatchError because the
        list has three elements but the pattern expects two. Fix the
        destructuring (keep all three values used) so the script prints
        `DEV_MATCH_OK` and exits with status 0.
        """,
        "initial_files" => %{
          "solution.ex" => """
          [a, b] = [1, 2, 3]
          IO.puts("sum=" <> Integer.to_string(a + b))
          IO.puts("DEV_MATCH_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["DEV_MATCH_OK", "sum=6"],
        "stdout_not_contains" => ["(MatchError)"]
      }
    },
    %{
      "id" => "dev_string_to_integer",
      "split" => :development,
      "version" => 1,
      "title" => "Parse an integer safely",
      "kind" => "elixir_error_recovery",
      "tags" => ["parse", "argument_error"],
      "task" => %{
        "prompt" => """
        `String.to_integer/1` raises ArgumentError on the input "12x3".
        Change the script to use a safe parse so it prints `value=12` for the
        leading digits (use Integer.parse/1) and then `DEV_PARSE_OK`, exiting
        with status 0.
        """,
        "initial_files" => %{
          "solution.ex" => """
          value = String.to_integer("12x3")
          IO.puts("value=" <> Integer.to_string(value))
          IO.puts("DEV_PARSE_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["DEV_PARSE_OK", "value=12"],
        "stdout_not_contains" => ["(ArgumentError)"]
      }
    },
    %{
      "id" => "held_case_clause_add_clause",
      "split" => :heldout,
      "version" => 1,
      "title" => "Add the missing case clause",
      "kind" => "elixir_error_recovery",
      "tags" => ["case_clause", "control_flow"],
      "task" => %{
        "prompt" => """
        Running `elixir solution.ex` crashes with CaseClauseError on the
        input :unknown. Add a catch-all clause so the script prints
        `handled=other` and then `HELD_CASE_OK`, exiting with status 0.
        """,
        "initial_files" => %{
          "solution.ex" => """
          input = :unknown

          handled =
            case input do
              :ok -> "ok"
              :error -> "error"
            end

          IO.puts("handled=" <> handled)
          IO.puts("HELD_CASE_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["HELD_CASE_OK", "handled=other"],
        "stdout_not_contains" => ["(CaseClauseError)"]
      }
    },
    %{
      "id" => "held_empty_enum_head",
      "split" => :heldout,
      "version" => 1,
      "title" => "Handle the empty list before Enum.max/1",
      "kind" => "elixir_error_recovery",
      "tags" => ["enum", "empty_error", "guard"],
      "task" => %{
        "prompt" => """
        `Enum.max/1` raises Enum.EmptyError when the readings list is empty.
        Make the script robust: when the list is empty print `max=none`,
        otherwise `max=<n>`. With the fixed input [] it must print
        `max=none` and `HELD_EMPTY_OK`, exiting with status 0.
        """,
        "initial_files" => %{
          "solution.ex" => """
          readings = []
          IO.puts("max=" <> Integer.to_string(Enum.max(readings)))
          IO.puts("HELD_EMPTY_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["HELD_EMPTY_OK", "max=none"],
        "stdout_not_contains" => ["(Enum.EmptyError)"]
      }
    },
    %{
      "id" => "held_arity_mismatch",
      "split" => :heldout,
      "version" => 1,
      "title" => "Fix the arity mismatch",
      "kind" => "elixir_error_recovery",
      "tags" => ["arity", "undefined_function"],
      "task" => %{
        "prompt" => """
        The script calls `Calc.add/3` but only `Calc.add/2` is defined, so
        it raises UndefinedFunctionError. Fix the script (either add the
        3-arity clause summing all three numbers, or change the call) so it
        prints `total=6` and `HELD_ARITY_OK`, exiting with status 0.
        """,
        "initial_files" => %{
          "solution.ex" => """
          defmodule Calc do
            def add(a, b), do: a + b
          end

          IO.puts("total=" <> Integer.to_string(Calc.add(1, 2, 3)))
          IO.puts("HELD_ARITY_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["HELD_ARITY_OK", "total=6"],
        "stdout_not_contains" => ["(UndefinedFunctionError)"]
      }
    },
    %{
      "id" => "held_badarith_string_concat",
      "split" => :heldout,
      "version" => 1,
      "title" => "Convert before arithmetic",
      "kind" => "elixir_error_recovery",
      "tags" => ["badarith", "types"],
      "task" => %{
        "prompt" => """
        The script adds a string to an integer and crashes with
        ArithmeticError. Convert the string "40" to an integer before adding
        so it prints `total=42` and `HELD_ARITH_OK`, exiting with status 0.
        """,
        "initial_files" => %{
          "solution.ex" => """
          left = "40"
          right = 2
          IO.puts("total=" <> Integer.to_string(left + right))
          IO.puts("HELD_ARITH_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["HELD_ARITH_OK", "total=42"],
        "stdout_not_contains" => ["(ArithmeticError)", "(BadArityError)"]
      }
    },
    %{
      "id" => "held_missing_map_key",
      "split" => :heldout,
      "version" => 1,
      "title" => "Fetch a map key safely",
      "kind" => "elixir_error_recovery",
      "tags" => ["key_error", "map"],
      "task" => %{
        "prompt" => """
        Accessing `config.timeout` raises KeyError because the key is
        `:timeout_ms`. Fix the access so the script prints `timeout=250`
        and `HELD_KEY_OK`, exiting with status 0.
        """,
        "initial_files" => %{
          "solution.ex" => """
          config = %{retries: 3, timeout_ms: 250}
          IO.puts("timeout=" <> Integer.to_string(config.timeout))
          IO.puts("HELD_KEY_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["HELD_KEY_OK", "timeout=250"],
        "stdout_not_contains" => ["(KeyError)"]
      }
    },
    %{
      "id" => "held_recursion_base_case",
      "split" => :heldout,
      "version" => 1,
      "title" => "Add the missing recursion base case",
      "kind" => "elixir_error_recovery",
      "tags" => ["recursion", "function_clause"],
      "task" => %{
        "prompt" => """
        `Count.down/1` recurses below zero and crashes with a
        FunctionClauseError. Add a base case so the countdown stops at 0 and
        the script prints `done` and `HELD_REC_OK`, exiting with status 0.
        """,
        "initial_files" => %{
          "solution.ex" => """
          defmodule Count do
            def down(n) when n > 0 do
              IO.puts(Integer.to_string(n))
              down(n - 1)
            end
          end

          Count.down(3)
          IO.puts("HELD_REC_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["HELD_REC_OK", "done"],
        "stdout_not_contains" => ["(FunctionClauseError)"]
      }
    },
    %{
      "id" => "held_file_read_missing",
      "split" => :heldout,
      "version" => 1,
      "title" => "Handle a missing file",
      "kind" => "tool_use",
      "tags" => ["file", "match", "error_tuple"],
      "task" => %{
        "prompt" => """
        The script matches `{:ok, body}` on File.read/1 of a file that does
        not exist and crashes with MatchError. Handle the error tuple: print
        `missing=input.txt` when the file is absent, then `HELD_FILE_OK`,
        exiting with status 0. Do not create input.txt.
        """,
        "initial_files" => %{
          "solution.ex" => """
          {:ok, body} = File.read("input.txt")
          IO.puts(body)
          IO.puts("HELD_FILE_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["HELD_FILE_OK", "missing=input.txt"],
        "stdout_not_contains" => ["(MatchError)", "(File.Error)"]
      }
    },
    %{
      "id" => "held_raise_rescue",
      "split" => :heldout,
      "version" => 1,
      "title" => "Rescue a raised error",
      "kind" => "elixir_error_recovery",
      "tags" => ["raise", "rescue"],
      "task" => %{
        "prompt" => """
        The script raises RuntimeError "boom" and exits non-zero. Wrap the
        risky call in try/rescue so it prints `caught=boom` and
        `HELD_RESCUE_OK`, exiting with status 0.
        """,
        "initial_files" => %{
          "solution.ex" => """
          defmodule Risky do
            def run!, do: raise("boom")
          end

          Risky.run!()
          IO.puts("HELD_RESCUE_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["HELD_RESCUE_OK", "caught=boom"],
        "stdout_not_contains" => ["** (RuntimeError)"]
      }
    },
    %{
      "id" => "held_protocol_string",
      "split" => :heldout,
      "version" => 1,
      "title" => "Convert a tuple before interpolating",
      "kind" => "elixir_error_recovery",
      "tags" => ["protocol", "string_chars"],
      "task" => %{
        "prompt" => """
        Interpolating the tuple {:ok, 7} into a string raises a
        Protocol.UndefinedError for String.Chars. Convert the tuple with
        inspect/1 (or destructure it) so the script prints
        `result={:ok, 7}` and `HELD_PROTO_OK`, exiting with status 0.
        """,
        "initial_files" => %{
          "solution.ex" => """
          result = {:ok, 7}
          IO.puts("result=\#{result}")
          IO.puts("HELD_PROTO_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["HELD_PROTO_OK", "result={:ok, 7}"],
        "stdout_not_contains" => ["(Protocol.UndefinedError)"]
      }
    },
    %{
      "id" => "held_badmap_update",
      "split" => :heldout,
      "version" => 1,
      "title" => "Update a key that exists",
      "kind" => "elixir_error_recovery",
      "tags" => ["map_update", "key_error"],
      "task" => %{
        "prompt" => """
        `%{state | count: 1}` raises KeyError because the map key is
        `:counter`, not `:count`. Fix the update so the script prints
        `counter=1` and `HELD_MAP_OK`, exiting with status 0.
        """,
        "initial_files" => %{
          "solution.ex" => """
          state = %{counter: 0}
          state = %{state | count: 1}
          IO.puts("counter=" <> Integer.to_string(state.counter))
          IO.puts("HELD_MAP_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["HELD_MAP_OK", "counter=1"],
        "stdout_not_contains" => ["(KeyError)"]
      }
    },
    %{
      "id" => "held_split_parse_csv",
      "split" => :heldout,
      "version" => 1,
      "title" => "Parse a CSV line defensively",
      "kind" => "tool_use",
      "tags" => ["string", "parse", "pattern_match"],
      "task" => %{
        "prompt" => """
        The CSV line "alpha,beta" is split with String.split/2 and the
        script matches exactly three fields, crashing with MatchError.
        Handle lines with any number of fields: print `fields=2` for the
        fixed input and `HELD_CSV_OK`, exiting with status 0.
        """,
        "initial_files" => %{
          "solution.ex" => """
          line = "alpha,beta"
          [a, b, c] = String.split(line, ",")
          IO.puts(a <> b <> c)
          IO.puts("HELD_CSV_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["HELD_CSV_OK", "fields=2"],
        "stdout_not_contains" => ["(MatchError)"]
      }
    },
    %{
      "id" => "held_enum_at_nil",
      "split" => :heldout,
      "version" => 1,
      "title" => "Handle a missing list index",
      "kind" => "elixir_error_recovery",
      "tags" => ["enum", "nil", "protocol"],
      "task" => %{
        "prompt" => """
        `Enum.at(list, 5)` returns nil and the script calls String.upcase/1
        on it, raising Protocol.UndefinedError. Handle the missing index:
        print `item=missing` when the index is absent, then `HELD_INDEX_OK`,
        exiting with status 0.
        """,
        "initial_files" => %{
          "solution.ex" => """
          list = ["a", "b"]
          item = Enum.at(list, 5)
          IO.puts("item=" <> String.upcase(item))
          IO.puts("HELD_INDEX_OK")
          """
        }
      },
      "expect" => %{
        "exit_code" => 0,
        "stdout_contains" => ["HELD_INDEX_OK", "item=missing"],
        "stdout_not_contains" => ["(Protocol.UndefinedError)"]
      }
    }
  ]

  @by_id Map.new(@fixtures, &{&1["id"], &1})

  # ------------------------------------------------------------------- API

  @doc "All split identifiers."
  @spec splits() :: [atom()]
  def splits, do: @splits

  @doc """
  List public descriptors, optionally filtered by split
  (`:development`, `:heldout`, `:all`; string forms accepted).
  """
  @spec list(atom() | binary()) :: [map()]
  def list(split \\ :all)

  def list(split) when split in [:all, "all"] do
    Enum.map(@fixtures, &public_descriptor/1)
  end

  def list(split) when split in [:development, :heldout] do
    @fixtures
    |> Enum.filter(&(&1["split"] == split))
    |> Enum.map(&public_descriptor/1)
  end

  def list(split) when is_binary(split) do
    case safe_split(split) do
      {:ok, atom} -> list(atom)
      :error -> []
    end
  end

  def list(_other), do: []

  @doc """
  Fetch one public descriptor by id. Never includes the private oracle.
  Returns `{:error, :unknown_fixture}` for unknown ids.
  """
  @spec get(binary()) :: {:ok, map()} | {:error, :unknown_fixture}
  def get(id) when is_binary(id) do
    case Map.fetch(@by_id, id) do
      {:ok, fixture} -> {:ok, public_descriptor(fixture)}
      :error -> {:error, :unknown_fixture}
    end
  end

  def get(_other), do: {:error, :unknown_fixture}

  @doc """
  Run the deterministic trusted oracle for `id` against a captured sandbox
  result (`%{"exit_code" => integer, "stdout" => binary, ...}`).

  Returns `{:ok, verdict}` with per-check detail, or `{:error, reason}`.
  The verdict never embeds oracle substrings, so evidence cannot leak the
  private expectations. This function never executes code itself.
  """
  @spec check(binary(), map()) :: {:ok, map()} | {:error, term()}
  def check(id, sandbox_result) when is_binary(id) and is_map(sandbox_result) do
    with {:ok, fixture} <- fetch_fixture(id),
         {:ok, exit_code, stdout} <- result_fields(sandbox_result) do
      expect = fixture["expect"]

      checks =
        [
          %{
            "check" => "exit_code",
            "expected" => expect["exit_code"],
            "actual" => exit_code,
            "pass" => exit_code == expect["exit_code"]
          }
        ] ++
          Enum.map(expect["stdout_contains"], fn needle ->
            %{
              "check" => "stdout_contains",
              "index" => :erlang.phash2(needle),
              "pass" => String.contains?(stdout, needle)
            }
          end) ++
          Enum.map(expect["stdout_not_contains"], fn needle ->
            %{
              "check" => "stdout_not_contains",
              "index" => :erlang.phash2(needle),
              "pass" => not String.contains?(stdout, needle)
            }
          end)

      verdict = if Enum.all?(checks, & &1["pass"]), do: "pass", else: "fail"

      {:ok,
       %{
         "fixture_id" => id,
         "fixture_version" => fixture["version"],
         "verdict" => verdict,
         "checks" => checks
       }}
    end
  end

  def check(id, _other) when is_binary(id), do: {:error, :invalid_sandbox_result}
  def check(_id, _result), do: {:error, :invalid_fixture_id}

  @doc """
  Content hash of the entire curated suite (public tasks and private
  oracles), computed with the canonical Evaluation hash. Pin this in
  evaluation protocols as the fixture cohort version.
  """
  @spec version() :: binary()
  def version, do: Evaluation.hash(@fixtures)

  @doc "Number of fixtures per split."
  @spec counts() :: map()
  def counts do
    %{
      "development" => Enum.count(@fixtures, &(&1["split"] == :development)),
      "heldout" => Enum.count(@fixtures, &(&1["split"] == :heldout))
    }
  end

  # --------------------------------------------------------------- internal

  defp safe_split("development"), do: {:ok, :development}
  defp safe_split("heldout"), do: {:ok, :heldout}
  defp safe_split(_), do: :error

  defp fetch_fixture(id) do
    case Map.fetch(@by_id, id) do
      {:ok, fixture} -> {:ok, fixture}
      :error -> {:error, :unknown_fixture}
    end
  end

  defp result_fields(result) do
    exit_code = Map.get(result, "exit_code")
    stdout = Map.get(result, "stdout")

    cond do
      not is_integer(exit_code) -> {:error, :invalid_sandbox_result}
      not is_binary(stdout) -> {:error, :invalid_sandbox_result}
      true -> {:ok, exit_code, stdout}
    end
  end

  # Public descriptor: task statement, fixed inputs and initial files only.
  # Oracle expectations and any other private fields are excluded here.
  defp public_descriptor(fixture) do
    %{
      "id" => fixture["id"],
      "split" => Atom.to_string(fixture["split"]),
      "version" => fixture["version"],
      "title" => fixture["title"],
      "kind" => fixture["kind"],
      "tags" => fixture["tags"],
      "task" => fixture["task"]
    }
  end
end