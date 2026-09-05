defmodule Newbee.DEE.BoundedIO do
  @moduledoc false

  def start_link(limit) when is_integer(limit) and limit > 0 do
    owner = self()

    {:ok,
     spawn_link(fn ->
       ref = Process.monitor(owner)
       loop(%{owner_ref: ref, chunks: [], bytes: 0, dropped: 0, limit: limit})
     end)}
  end

  def contents(pid, timeout \\ 1_000) when is_pid(pid) do
    ref = make_ref()
    send(pid, {:bounded_io_contents, self(), ref})

    receive do
      {:bounded_io_contents, ^ref, data, dropped} ->
        suffix =
          if dropped > 0,
            do: <<10>> <> "[output truncated; dropped " <> Integer.to_string(dropped) <> " bytes]",
            else: ""

        data <> suffix
    after
      timeout -> "[output capture unavailable]"
    end
  end

  def stop(pid) when is_pid(pid), do: send(pid, :bounded_io_stop)

  defp loop(state) do
    receive do
      {:io_request, from, reply_as, request} ->
        {reply, next} = handle_request(request, state)
        send(from, {:io_reply, reply_as, reply})
        loop(next)

      {:bounded_io_contents, from, ref} ->
        data = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()
        send(from, {:bounded_io_contents, ref, data, state.dropped})
        loop(state)

      {:DOWN, ref, :process, _pid, _reason} when ref == state.owner_ref ->
        :ok

      :bounded_io_stop ->
        :ok

      _other ->
        loop(state)
    end
  end

  defp handle_request({:requests, requests}, state) do
    Enum.reduce_while(requests, {:ok, state}, fn request, {:ok, acc} ->
      case handle_request(request, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {error, next} -> {:halt, {error, next}}
      end
    end)
  end

  defp handle_request({:put_chars, encoding, chars}, state), do: put_chars(chars, encoding, state)
  defp handle_request({:put_chars, chars}, state), do: put_chars(chars, :unicode, state)

  defp handle_request({:put_chars, encoding, module, function, args}, state) do
    try do
      put_chars(apply(module, function, args), encoding, state)
    rescue
      _ -> {{:error, :put_chars}, state}
    end
  end

  defp handle_request(:getopts, state), do: {[binary: true, encoding: :unicode], state}
  defp handle_request({:get_geometry, _}, state), do: {{:error, :enotsup}, state}
  defp handle_request(_other, state), do: {{:error, :request}, state}

  defp put_chars(chars, encoding, state) do
    try do
      binary =
        case encoding do
          :latin1 -> :unicode.characters_to_binary(chars, :latin1, :utf8)
          _ -> :unicode.characters_to_binary(chars)
        end

      remaining = max(state.limit - state.bytes, 0)
      chunk = valid_prefix(binary, min(byte_size(binary), remaining))
      kept = byte_size(chunk)
      chunks = if chunk == "", do: state.chunks, else: [chunk | state.chunks]
      {:ok, %{state | chunks: chunks, bytes: state.bytes + kept, dropped: state.dropped + byte_size(binary) - kept}}
    rescue
      _ -> {{:error, :put_chars}, state}
    end
  end

  defp valid_prefix(_binary, 0), do: ""

  defp valid_prefix(binary, size) do
    prefix = binary_part(binary, 0, size)
    if String.valid?(prefix), do: prefix, else: valid_prefix(binary, size - 1)
  end
end
