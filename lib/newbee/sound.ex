defmodule Newbee.Sound do
  @moduledoc "回合结束提示音：按状态播放不同声音（done/ask/error/interrupted/info）。"
  @type kind :: :done | :ask | :error | :interrupted | :info
  @kinds [:done, :ask, :error, :interrupted, :info]
  @doc "支持的声音种类。"
  @spec kinds() :: [kind()]
  def kinds, do: @kinds
  @doc "归一化任意回合结果为声音种类。"
  @spec normalize(atom() | binary() | tuple() | any()) :: kind()
  def normalize(:done), do: :done
  def normalize(:goal_done), do: :done
  def normalize(:ask), do: :ask
  def normalize(:permission_ask), do: :ask
  def normalize(:goal_ask), do: :ask
  def normalize(:error), do: :error
  def normalize(:goal_cancelled), do: :error
  def normalize(:goal_limit), do: :error
  def normalize(:interrupted), do: :interrupted
  def normalize(:info), do: :info
  def normalize(:text), do: :info
  def normalize(:text_end), do: :info
  def normalize(:turn_end), do: :info
  def normalize("done"), do: :done
  def normalize("ask"), do: :ask
  def normalize("error"), do: :error
  def normalize("interrupted"), do: :interrupted
  def normalize({:turn_end, kind, _ms}) when is_atom(kind), do: normalize(kind)
  def normalize({:turn_end, kind}) when is_atom(kind), do: normalize(kind)
  def normalize({kind, _, _}) when is_atom(kind), do: normalize(kind)
  def normalize({kind, _, _, _}) when is_atom(kind), do: normalize(kind)
  def normalize({kind, _}) when is_atom(kind), do: normalize(kind)
  def normalize(kind) when is_atom(kind), do: :info
  def normalize(_), do: :info
  @doc "声音是否开启（默认开启）。环境变量 NEWBEE_SOUND 可覆盖。"
  @spec enabled?() :: boolean()
  def enabled? do
    case System.get_env("NEWBEE_SOUND") do
      nil -> app_enabled?()
      "" -> app_enabled?()
      v -> parse_env(v, app_enabled?())
    end
  end

  @doc "异步播放一种声音，永不阻塞、永不抛异常。"
  @spec play(atom() | binary() | tuple() | any()) :: :ok
  def play(kind) do
    normalized = normalize(kind)

    if enabled?() do
      spawn(fn -> play_sync(normalized) end)
      :ok
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc false
  @spec bell_pattern(kind()) :: [non_neg_integer()]
  def bell_pattern(:done), do: [0, 200]
  def bell_pattern(:ask), do: [0]
  def bell_pattern(:error), do: [0, 120, 120]
  def bell_pattern(:interrupted), do: [0, 350]
  def bell_pattern(:info), do: [0]
  def bell_pattern(_), do: [0]
  @doc false
  @spec canberra_id(kind()) :: String.t()
  def canberra_id(:done), do: "complete"
  def canberra_id(:ask), do: "dialog-information"
  def canberra_id(:error), do: "dialog-error"
  def canberra_id(:interrupted), do: "dialog-warning"
  def canberra_id(:info), do: "bell"
  def canberra_id(_), do: "bell"
  @doc false
  @spec freedesktop_file(kind()) :: String.t()
  def freedesktop_file(kind), do: canberra_id(kind) <> ".oga"
  @doc false
  @spec macos_file(kind()) :: String.t()
  def macos_file(:done), do: "Hero.aiff"
  def macos_file(:ask), do: "Ping.aiff"
  def macos_file(:error), do: "Sosumi.aiff"
  def macos_file(:interrupted), do: "Tink.aiff"
  def macos_file(:info), do: "Pop.aiff"
  def macos_file(_), do: "Pop.aiff"

  defp app_enabled? do
    case Application.get_env(:newbee, :sound_enabled) do
      false -> false
      nil -> true
      true -> true
      _ -> true
    end
  end

  defp parse_env(v, default) do
    case v |> String.trim() |> String.downcase() do
      "0" -> false
      "false" -> false
      "off" -> false
      "no" -> false
      "disable" -> false
      "disabled" -> false
      "1" -> true
      "true" -> true
      "on" -> true
      "yes" -> true
      "enable" -> true
      "enabled" -> true
      _ -> default
    end
  end

  defp play_sync(kind) do
    played =
      case :os.type() do
        {:unix, :darwin} -> play_macos(kind) || play_bell(kind)
        {:unix, _} -> play_linux(kind) || play_bell(kind)
        {:win32, _} -> play_bell(kind)
        _ -> play_bell(kind)
      end

    played
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp play_linux(kind) do
    cond do
      executable?("canberra-gtk-play") ->
        run("canberra-gtk-play -i " <> canberra_id(kind) <> " >/dev/null 2>&1 &")

      executable?("paplay") and freedesktop_present?(kind) ->
        run("paplay /usr/share/sounds/freedesktop/stereo/" <> freedesktop_file(kind) <> " >/dev/null 2>&1 &")

      true ->
        nil
    end
  end

  defp play_macos(kind) do
    path = "/System/Library/Sounds/" <> macos_file(kind)

    cond do
      executable?("afplay") and File.exists?(path) ->
        run("afplay " <> path <> " >/dev/null 2>&1 &")

      true ->
        nil
    end
  end

  defp play_bell(kind) do
    pattern = bell_pattern(kind)
    bel = <<7>>

    spawn(fn ->
      Enum.reduce(pattern, true, fn wait, first ->
        unless first, do: Process.sleep(wait)
        write_bel(bel)
        false
      end)
    end)

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp write_bel(bel) do
    case File.open("/dev/tty", [:write]) do
      {:ok, io} ->
        IO.write(io, bel)
        File.close(io)

      _ ->
        try do
          IO.write(:stdio, bel)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp executable?(name), do: System.find_executable(name) != nil

  defp freedesktop_present?(kind) do
    File.exists?("/usr/share/sounds/freedesktop/stereo/" <> freedesktop_file(kind))
  end

  defp run(cmd) do
    try do
      _ = :os.cmd(String.to_charlist(cmd))
      :ok
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end
end
