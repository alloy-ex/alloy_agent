defmodule AlloyAgent.Memory.DiskTest do
  use ExUnit.Case, async: true

  alias AlloyAgent.Memory.Disk

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "alloy-agent-disk-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {module, store} = Disk.new(root: root, session_id: "s1")
    {:ok, store: store, module: module, root: root}
  end

  test "new/1 returns the {module, struct} tuple Alloy expects", %{
    module: module,
    store: store
  } do
    assert module == Disk
    assert %Disk{session_id: "s1"} = store
  end

  test "new/1 validates root and session_id" do
    assert_raise ArgumentError, fn -> Disk.new(root: "") end

    assert_raise ArgumentError, fn ->
      Disk.new(root: "/tmp/x", session_id: "has spaces")
    end

    assert_raise ArgumentError, fn ->
      Disk.new(root: "/tmp/x", session_id: "../escape")
    end
  end

  test "create + view round-trip", %{store: store} do
    assert {:ok, _} = Disk.create(store, "/memories/foo.md", "hello")
    assert {:ok, "hello"} = Disk.view(store, "/memories/foo.md")
  end

  test "view on directory lists entries", %{store: store} do
    Disk.create(store, "/memories/a.md", "a")
    Disk.create(store, "/memories/b.md", "b")

    assert {:ok, listing} = Disk.view(store, "/memories")
    assert listing =~ "/memories/a.md"
    assert listing =~ "/memories/b.md"
  end

  test "str_replace, insert, delete, rename", %{store: store} do
    Disk.create(store, "/memories/f.md", "one\ntwo\nthree")

    assert {:ok, _} = Disk.str_replace(store, "/memories/f.md", "two", "deux")
    assert {:ok, "one\ndeux\nthree"} = Disk.view(store, "/memories/f.md")

    assert {:ok, _} = Disk.insert(store, "/memories/f.md", 2, "inserted")
    assert {:ok, "one\ndeux\ninserted\nthree"} = Disk.view(store, "/memories/f.md")

    assert {:ok, _} = Disk.rename(store, "/memories/f.md", "/memories/renamed.md")
    assert {:error, _} = Disk.view(store, "/memories/f.md")
    assert {:ok, _} = Disk.view(store, "/memories/renamed.md")

    assert {:ok, _} = Disk.delete(store, "/memories/renamed.md")
    assert {:error, _} = Disk.view(store, "/memories/renamed.md")
  end

  test "paths from different sessions don't collide", %{root: root} do
    {Disk, s1} = Disk.new(root: root, session_id: "s1")
    {Disk, s2} = Disk.new(root: root, session_id: "s2")

    Disk.create(s1, "/memories/note.md", "session one")
    Disk.create(s2, "/memories/note.md", "session two")

    assert {:ok, "session one"} = Disk.view(s1, "/memories/note.md")
    assert {:ok, "session two"} = Disk.view(s2, "/memories/note.md")
  end

  test "rejects paths that don't start with /memories", %{store: store} do
    assert {:error, reason} = Disk.view(store, "/etc/passwd")
    assert reason =~ "must start with /memories"
  end

  test "every operation returns the path error itself, not wrapped in another", %{store: store} do
    expected = ~s(path must start with /memories: "/etc/passwd")

    assert {:error, ^expected} = Disk.create(store, "/etc/passwd", "x")
    assert {:error, ^expected} = Disk.str_replace(store, "/etc/passwd", "a", "b")
    assert {:error, ^expected} = Disk.insert(store, "/etc/passwd", 0, "x")
    assert {:error, ^expected} = Disk.delete(store, "/etc/passwd")
    assert {:error, ^expected} = Disk.rename(store, "/etc/passwd", "/memories/x.md")
    assert {:error, ^expected} = Disk.rename(store, "/memories/x.md", "/etc/passwd")
  end

  test "rejects paths that resolve outside the session root", %{store: store} do
    assert {:error, reason} = Disk.view(store, "/memories/../../outside.md")
    assert reason =~ "escapes session root"
  end

  test "missing paths report not found", %{store: store} do
    assert {:error, "path not found: /memories/nope.md"} = Disk.view(store, "/memories/nope.md")

    assert {:error, "path not found: /memories/nope.md"} =
             Disk.str_replace(store, "/memories/nope.md", "a", "b")

    assert {:error, "path not found: /memories/nope.md"} =
             Disk.insert(store, "/memories/nope.md", 0, "x")

    assert {:error, "path not found: /memories/nope.md"} =
             Disk.rename(store, "/memories/nope.md", "/memories/new.md")
  end

  test "str_replace reports a missing old_str and leaves the file alone", %{store: store} do
    Disk.create(store, "/memories/f.md", "hello")

    assert {:error, "old_str not found in /memories/f.md"} =
             Disk.str_replace(store, "/memories/f.md", "nope", "x")

    assert {:ok, "hello"} = Disk.view(store, "/memories/f.md")
  end

  test "file operations on a directory report the filesystem error", %{store: store} do
    Disk.create(store, "/memories/dir/a.md", "a")

    assert {:error, "failed to read /memories/dir: " <> _} =
             Disk.str_replace(store, "/memories/dir", "a", "b")

    assert {:error, "failed to read /memories/dir: " <> _} =
             Disk.insert(store, "/memories/dir", 0, "x")
  end

  test "a file standing where a directory is needed fails cleanly", %{store: store} do
    Disk.create(store, "/memories/a.md", "a")

    assert {:error, "failed to create /memories/a.md/b.md: " <> _} =
             Disk.create(store, "/memories/a.md/b.md", "b")

    Disk.create(store, "/memories/c.md", "c")

    assert {:error, "failed to rename: " <> _} =
             Disk.rename(store, "/memories/c.md", "/memories/a.md/c.md")
  end
end
