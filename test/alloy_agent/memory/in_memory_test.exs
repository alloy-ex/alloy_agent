defmodule AlloyAgent.Memory.InMemoryTest do
  use ExUnit.Case, async: true

  alias AlloyAgent.Memory.InMemory

  setup do
    {:ok, pid} = InMemory.start_link()
    {:ok, store: pid}
  end

  test "create + view round-trip", %{store: pid} do
    assert {:ok, "created /memories/foo.md"} = InMemory.create(pid, "/memories/foo.md", "hello")
    assert {:ok, "hello"} = InMemory.view(pid, "/memories/foo.md")
  end

  test "view on missing path errors", %{store: pid} do
    assert {:error, reason} = InMemory.view(pid, "/memories/missing.md")
    assert reason =~ "not found"
  end

  test "view on a directory-like prefix returns child listing", %{store: pid} do
    InMemory.create(pid, "/memories/notes/a.md", "a")
    InMemory.create(pid, "/memories/notes/b.md", "b")
    InMemory.create(pid, "/memories/other.md", "x")

    assert {:ok, listing} = InMemory.view(pid, "/memories/notes")
    assert listing =~ "/memories/notes/a.md"
    assert listing =~ "/memories/notes/b.md"
    refute listing =~ "/memories/other.md"
  end

  test "str_replace rewrites first occurrence", %{store: pid} do
    InMemory.create(pid, "/memories/f.md", "hello hello world")

    assert {:ok, _} = InMemory.str_replace(pid, "/memories/f.md", "hello", "bye")
    assert {:ok, "bye hello world"} = InMemory.view(pid, "/memories/f.md")
  end

  test "str_replace errors when old_str not found", %{store: pid} do
    InMemory.create(pid, "/memories/f.md", "hello")
    assert {:error, reason} = InMemory.str_replace(pid, "/memories/f.md", "nope", "x")
    assert reason =~ "not found"
  end

  test "insert at specific line", %{store: pid} do
    InMemory.create(pid, "/memories/list.md", "a\nb\nc")

    assert {:ok, _} = InMemory.insert(pid, "/memories/list.md", 2, "x")
    assert {:ok, "a\nb\nx\nc"} = InMemory.view(pid, "/memories/list.md")
  end

  test "insert at line 0 prepends", %{store: pid} do
    InMemory.create(pid, "/memories/list.md", "a\nb")
    assert {:ok, _} = InMemory.insert(pid, "/memories/list.md", 0, "x")
    assert {:ok, "x\na\nb"} = InMemory.view(pid, "/memories/list.md")
  end

  test "delete removes the path and any children", %{store: pid} do
    InMemory.create(pid, "/memories/dir/a.md", "a")
    InMemory.create(pid, "/memories/dir/b.md", "b")
    InMemory.create(pid, "/memories/outside.md", "keep")

    assert {:ok, _} = InMemory.delete(pid, "/memories/dir")
    assert {:error, _} = InMemory.view(pid, "/memories/dir/a.md")
    assert {:error, _} = InMemory.view(pid, "/memories/dir/b.md")
    assert {:ok, "keep"} = InMemory.view(pid, "/memories/outside.md")
  end

  test "rename moves a file", %{store: pid} do
    InMemory.create(pid, "/memories/old.md", "content")

    assert {:ok, _} = InMemory.rename(pid, "/memories/old.md", "/memories/new.md")
    assert {:error, _} = InMemory.view(pid, "/memories/old.md")
    assert {:ok, "content"} = InMemory.view(pid, "/memories/new.md")
  end
end
