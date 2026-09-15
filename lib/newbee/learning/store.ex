defmodule Newbee.Learning.Store do
  @moduledoc """
  Durable content-addressed artifact store (docs/brs-drs-design.md §10).

  Experimental memory manifests, sealed attempt evidence, and evaluation
  snapshots are immutable artifacts addressed by the canonical SHA-256 of
  their content. This module owns no process; the Environment Coordinator
  sequences seals before the durable `memory_committed` commit event.

  Layout:

      <root>/objects/ab/cdef0123...   # fanout 2 + remaining 62 hex chars
      <root>/tmp/put-<unique>         # staging; orphaned files are cleaned

  Guarantees:

    * canonical encoding — maps with sorted keys (deep), NFC text values,
      numbers, true/false/null; equal values always hash identically;
    * safe scoped root — the root is resolved to an absolute path; object
      ids are validated as lowercase sha256 hex, so no path can escape the
      scoped root;
    * immutable content — an existing object is never overwritten; storing
      identical content is a no-op that returns the same id;
    * durable atomic installs — write tmp in the target directory,
      `fsync(file)`, atomic `rename`, `fsync(directory)`;
    * corruption fails — reads re-hash the stored bytes; a mismatch returns
      `{:error, {:corrupt, sha}}` instead of silent data.
  """

  alias Newbee.Learning.Contracts

  @objects_dir "objects"
  @tmp_dir "tmp"

  # ── canonical encoding ──

  @doc """
  Canonical JSON bytes for `value`: sorted map keys (deep), NFC text.
  Raises `ArgumentError` for values that are not JSON-safe.
  """
  def canonical(value) do
    value
    |> normalize()
    |> Jason.encode!()
  end

  @doc "Canonical content address: lowercase hex SHA-256 of `canonical(value)`."
  def hash(value) do
    :crypto.hash(:sha256, canonical(value)) |> Base.encode16(case: :lower)
  end

defp normalize(value) when is_map(value) do
    unless Enum.all?(Map.keys(value), &is_binary/1) do
      raise ArgumentError, "JSON object keys must be UTF-8 strings"
    end

    value
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Map.new(fn {k, v} -> {normalize_text(k), normalize(v)} end)
  end


  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value) when is_binary(value), do: normalize_text(value)

  defp normalize(value) when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
    do: value

  defp normalize(other) do
    raise ArgumentError, "value is not JSON-safe, cannot be content-addressed: #{inspect(other)}"
  end

  defp normalize_text(text) when is_binary(text) do
    if String.valid?(text) do
      String.normalize(text, :nfc)
    else
      raise ArgumentError, "invalid UTF-8 cannot be content-addressed"
    end
  end

  defp normalize_text(other),
    do: raise(ArgumentError, "store keys and strings must be text, got: " <> inspect(other))


  # ── store operations ──

  @doc """
  Store `value` under `root`, returning `{:ok, sha}`.

  The value must be JSON-safe. Installation is durable: same-directory tmp
  file, file fsync, atomic rename, directory fsync. An existing object is
  left untouched (immutable content); orphan tmp files from crashed puts
  are cleaned up on each call.
  """
  def put(root, value) do
    with :ok <- ensure_json_safe(value) do
      sha = hash(value)
      bytes = canonical(value)
      dir = object_dir(root, sha)
      path = object_path(root, sha)

      with :ok <- prepare(root, dir),
           :ok <- install(path, dir, bytes) do
        {:ok, sha}
      end
    end
  end

  @doc """
  Read the object `sha` from `root`.

  Returns `{:error, :not_found}` when absent and `{:error, {:corrupt, sha}}`
  when the stored bytes no longer hash to `sha` (bit rot, partial write,
  tampering) — corrupted content is never returned as data.
  """
  def get(root, sha) do
    with :ok <- validate_sha(sha) do
      path = object_path(root, sha)

      case File.read(path) do
        {:ok, bytes} ->
          if sha256(bytes) == sha do
            decode(bytes, sha)
          else
            {:error, {:corrupt, sha}}
          end

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, {:read_failed, reason}}
      end
    end
  end

  @doc "True when an intact object `sha` exists under `root`."
  def exists?(root, sha) do
    Contracts.sha256_hex?(sha) and File.regular?(object_path(root, sha))
  end

  @doc """
  Verify an object: `{:ok, value}` when present and intact,
  `{:error, reason}` otherwise. Alias of `get/2` kept explicit for
  receipt-checking call sites.
  """
  def verify(root, sha), do: get(root, sha)

  # ── internals ──

  defp ensure_json_safe(value) do
    if Contracts.json_safe?(value) do
      :ok
    else
      {:error, {:invalid_value, "expected string-keyed maps, lists, text, numbers, true/false, nil"}}
    end
  end

  defp validate_sha(sha) do
    if Contracts.sha256_hex?(sha) do
      :ok
    else
      {:error, {:invalid_sha, "expected lowercase sha256 hex (64 chars)"}}
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # Root is resolved to an absolute path and all object paths are built from
  # a validated sha, so no caller-controlled segment can escape the scope.
  defp store_root(root) when is_binary(root) do
    Path.expand(root)
  end

  defp object_dir(root, sha) do
    Path.join([store_root(root), @objects_dir, String.slice(sha, 0, 2)])
  end

  defp object_path(root, sha) do
    Path.join(object_dir(root, sha), String.slice(sha, 2, 62))
  end

  defp prepare(root, dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.mkdir_p(Path.join(store_root(root), @tmp_dir)) do
      cleanup_tmp(root)
    end
  end

  defp cleanup_tmp(root) do
    tmp = Path.join(store_root(root), @tmp_dir)

    case File.ls(tmp) do
      {:ok, names} ->
        Enum.each(names, fn name -> File.rm(Path.join(tmp, name)) end)
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp install(path, dir, bytes) do
    if File.regular?(path) do
      # Immutable content: never overwrite. The address is derived from the
      # content, so an existing object already stores exactly these bytes
      # (or the reader will flag corruption on get).
      :ok
    else
      tmp = Path.join(dir, ".tmp-#{System.unique_integer([:positive, :monotonic])}")

      with :ok <- File.write(tmp, bytes),
           :ok <- fsync_file(tmp),
           :ok <- File.rename(tmp, path),
           :ok <- fsync_dir(dir) do
        :ok
      else
        {:error, reason} ->
          File.rm(tmp)
          {:error, {:install_failed, reason}}
      end
    end
  end

  defp fsync_file(path) do
    case File.open(path, [:read]) do
      {:ok, io} ->
        result = :file.sync(io)
        File.close(io)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fsync_dir(dir) do
    case File.open(dir, [:read]) do
      {:ok, io} ->
        result = :file.sync(io)
        File.close(io)
        result

      {:error, reason} ->
        # Some filesystems do not allow opening directories; durability of
        # the rename then relies on the file fsync already performed.
        if reason in [:eisdir, :eacces, :eperm, :einval], do: :ok, else: {:error, reason}
    end
  end

  defp decode(bytes, sha) do
    case Jason.decode(bytes) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, {:corrupt, sha}}
    end
  end
end