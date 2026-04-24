defmodule AlloyAgent.Memory.Disk do
  @moduledoc """
  Filesystem-backed `Alloy.Memory` store. Each agent's memory tree
  lives under `<root>/<session_id>/memories/...`, where `session_id`
  namespaces one agent's memory from another's and prevents cross-agent
  leakage when multiple processes share the same root.

  Memory survives process restarts. To delete an agent's memory,
  remove the corresponding session directory.

  ## Usage

      store = AlloyAgent.Memory.Disk.new(
        root: "/var/agent/memories",
        session_id: "acct-42"
      )

      {:ok, pid} = AlloyAgent.start_link(
        provider: {Alloy.Provider.Anthropic, ...},
        memory: store
      )

  ## Safety

  Every path is validated twice: first by `Alloy.Memory.validate_path/1`
  (which enforces the `/memories/...` root and rejects `..` traversal)
  before a call reaches this store, and again here to confirm the
  resolved filesystem path stays under the session root. This guards
  against any path-validation bugs in the upstream router.
  """

  @behaviour Alloy.Memory

  @enforce_keys [:root, :session_id]
  defstruct [:root, :session_id]

  @type t :: %__MODULE__{root: String.t(), session_id: String.t()}

  @doc """
  Build a new store handle. Returns the `{module, store_term}` tuple
  ready to pass as the `:memory` option.

  ## Options

    - `:root` (required) — base directory under which session memory
      trees live.
    - `:session_id` (optional) — namespace within `root`. Defaults to
      `"default"`. Supply a per-agent value if multiple agents share
      a root directory.
  """
  @spec new(keyword()) :: {module(), t()}
  def new(opts) do
    root = Keyword.fetch!(opts, :root)
    session_id = Keyword.get(opts, :session_id, "default")

    unless is_binary(root) and root != "" do
      raise ArgumentError,
            "AlloyAgent.Memory.Disk requires a non-empty :root, got: #{inspect(root)}"
    end

    unless is_binary(session_id) and session_id =~ ~r/^[A-Za-z0-9_\-\.]+$/ do
      raise ArgumentError,
            ":session_id must be alphanumeric with _, -, . only — got: #{inspect(session_id)}"
    end

    {__MODULE__, %__MODULE__{root: root, session_id: session_id}}
  end

  @impl true
  def view(%__MODULE__{} = store, path) do
    with {:ok, fs} <- to_fs_path(store, path) do
      cond do
        File.dir?(fs) -> list_directory(fs, path)
        File.regular?(fs) -> read_file(fs, path)
        true -> {:error, "path not found: #{path}"}
      end
    end
  end

  defp list_directory(fs, path) do
    case File.ls(fs) do
      {:ok, entries} ->
        listing =
          entries
          |> Enum.sort()
          |> Enum.map_join("\n", &Path.join(path, &1))

        {:ok, listing}

      {:error, reason} ->
        {:error, "failed to list #{path}: #{inspect(reason)}"}
    end
  end

  defp read_file(fs, path) do
    case File.read(fs) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "failed to read #{path}: #{inspect(reason)}"}
    end
  end

  @impl true
  def create(%__MODULE__{} = store, path, file_text) do
    with {:ok, fs} <- to_fs_path(store, path),
         :ok <- File.mkdir_p(Path.dirname(fs)),
         :ok <- File.write(fs, file_text) do
      {:ok, "created #{path}"}
    else
      {:error, reason} -> {:error, "failed to create #{path}: #{inspect(reason)}"}
    end
  end

  @impl true
  def str_replace(%__MODULE__{} = store, path, old_str, new_str) do
    with {:ok, fs} <- to_fs_path(store, path),
         {:ok, contents} <- File.read(fs) do
      apply_str_replace(fs, path, contents, old_str, new_str)
    else
      {:error, :enoent} -> {:error, "path not found: #{path}"}
      {:error, reason} -> {:error, "failed to read #{path}: #{inspect(reason)}"}
    end
  end

  defp apply_str_replace(fs, path, contents, old_str, new_str) do
    if String.contains?(contents, old_str) do
      updated = String.replace(contents, old_str, new_str, global: false)

      case File.write(fs, updated) do
        :ok -> {:ok, "replaced in #{path}"}
        {:error, reason} -> {:error, "failed to write #{path}: #{inspect(reason)}"}
      end
    else
      {:error, "old_str not found in #{path}"}
    end
  end

  @impl true
  def insert(%__MODULE__{} = store, path, insert_line, text) do
    with {:ok, fs} <- to_fs_path(store, path),
         {:ok, contents} <- File.read(fs) do
      lines = String.split(contents, "\n")
      {before_lines, after_lines} = Enum.split(lines, insert_line)
      updated = Enum.join(before_lines ++ [text] ++ after_lines, "\n")

      case File.write(fs, updated) do
        :ok -> {:ok, "inserted at line #{insert_line} of #{path}"}
        {:error, reason} -> {:error, "failed to write #{path}: #{inspect(reason)}"}
      end
    else
      {:error, :enoent} -> {:error, "path not found: #{path}"}
      {:error, reason} -> {:error, "failed to read #{path}: #{inspect(reason)}"}
    end
  end

  @impl true
  def delete(%__MODULE__{} = store, path) do
    with {:ok, fs} <- to_fs_path(store, path) do
      case File.rm_rf(fs) do
        {:ok, _} -> {:ok, "deleted #{path}"}
        {:error, reason, _} -> {:error, "failed to delete #{path}: #{inspect(reason)}"}
      end
    end
  end

  @impl true
  def rename(%__MODULE__{} = store, old_path, new_path) do
    with {:ok, old_fs} <- to_fs_path(store, old_path),
         {:ok, new_fs} <- to_fs_path(store, new_path),
         :ok <- File.mkdir_p(Path.dirname(new_fs)),
         :ok <- File.rename(old_fs, new_fs) do
      {:ok, "renamed #{old_path} -> #{new_path}"}
    else
      {:error, :enoent} -> {:error, "path not found: #{old_path}"}
      {:error, reason} -> {:error, "failed to rename: #{inspect(reason)}"}
    end
  end

  # Resolve a validated `/memories/...` path to an absolute filesystem
  # path rooted at `<store.root>/<session_id>`. Returns an error if the
  # resolved path would escape the session root (defense in depth —
  # Alloy.Memory.validate_path/1 should have already rejected any
  # traversal attempts upstream).
  defp to_fs_path(%__MODULE__{root: root, session_id: session_id}, "/memories" <> rest) do
    base = Path.join([root, session_id, "memories"])
    target = Path.expand(base <> rest, base)

    if String.starts_with?(target, Path.expand(base) <> "/") or target == Path.expand(base) do
      {:ok, target}
    else
      {:error, "resolved path escapes session root: #{inspect(target)}"}
    end
  end

  defp to_fs_path(_store, path) do
    {:error, "path must start with /memories: #{inspect(path)}"}
  end
end
