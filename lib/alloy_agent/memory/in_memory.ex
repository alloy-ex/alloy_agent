defmodule AlloyAgent.Memory.InMemory do
  @moduledoc """
  Process-local `Alloy.Memory` store backed by an `Agent` holding a
  simple `%{path => content}` map.

  Memory survives only for the lifetime of the store process — call
  `start_link/0`, pass the returned pid as the store term, and any
  memory the agent writes is gone when the process exits.

  For persistence across restarts, use `AlloyAgent.Memory.Disk` or
  implement your own store.

  ## Usage

      {:ok, store_pid} = AlloyAgent.Memory.InMemory.start_link()

      {:ok, pid} = AlloyAgent.start_link(
        provider: {Alloy.Provider.Anthropic, ...},
        memory: {AlloyAgent.Memory.InMemory, store_pid}
      )
  """

  @behaviour Alloy.Memory

  use Agent

  @doc """
  Start an empty in-memory store and return its pid. Pass the pid as
  the store term in `{AlloyAgent.Memory.InMemory, pid}`.
  """
  @spec start_link() :: {:ok, pid()}
  def start_link, do: Agent.start_link(fn -> %{} end)

  @doc """
  Return the full `%{path => content}` map. Test and debug helper.
  """
  @spec contents(pid()) :: map()
  def contents(pid), do: Agent.get(pid, & &1)

  @impl true
  def view(pid, path) do
    case Agent.get(pid, &Map.fetch(&1, path)) do
      {:ok, contents} ->
        {:ok, contents}

      :error ->
        children = list_children(pid, path)

        if children == [] do
          {:error, "path not found: #{path}"}
        else
          {:ok, Enum.join(children, "\n")}
        end
    end
  end

  @impl true
  def create(pid, path, file_text) do
    Agent.update(pid, &Map.put(&1, path, file_text))
    {:ok, "created #{path}"}
  end

  @impl true
  def str_replace(pid, path, old_str, new_str) do
    Agent.get_and_update(pid, fn state ->
      case Map.fetch(state, path) do
        {:ok, contents} -> do_str_replace(state, path, contents, old_str, new_str)
        :error -> {{:error, "path not found: #{path}"}, state}
      end
    end)
  end

  defp do_str_replace(state, path, contents, old_str, new_str) do
    if String.contains?(contents, old_str) do
      updated = String.replace(contents, old_str, new_str, global: false)
      {{:ok, "replaced in #{path}"}, Map.put(state, path, updated)}
    else
      {{:error, "old_str not found in #{path}"}, state}
    end
  end

  @impl true
  def insert(pid, path, insert_line, text) do
    Agent.get_and_update(pid, fn state ->
      case Map.fetch(state, path) do
        {:ok, contents} ->
          lines = String.split(contents, "\n")
          {before_lines, after_lines} = Enum.split(lines, insert_line)
          updated = Enum.join(before_lines ++ [text] ++ after_lines, "\n")
          {{:ok, "inserted at line #{insert_line} of #{path}"}, Map.put(state, path, updated)}

        :error ->
          {{:error, "path not found: #{path}"}, state}
      end
    end)
  end

  @impl true
  def delete(pid, path) do
    Agent.update(pid, fn state ->
      Enum.reject(state, fn {k, _} -> k == path or String.starts_with?(k, path <> "/") end)
      |> Map.new()
    end)

    {:ok, "deleted #{path}"}
  end

  @impl true
  def rename(pid, old_path, new_path) do
    Agent.get_and_update(pid, fn state ->
      case Map.fetch(state, old_path) do
        {:ok, contents} ->
          new_state = state |> Map.delete(old_path) |> Map.put(new_path, contents)
          {{:ok, "renamed #{old_path} -> #{new_path}"}, new_state}

        :error ->
          {{:error, "path not found: #{old_path}"}, state}
      end
    end)
  end

  defp list_children(pid, path) do
    prefix = if String.ends_with?(path, "/"), do: path, else: path <> "/"

    pid
    |> contents()
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, prefix))
  end
end
