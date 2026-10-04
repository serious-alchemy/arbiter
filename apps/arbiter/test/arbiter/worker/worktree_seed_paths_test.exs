defmodule Arbiter.Worker.WorktreeSeedPathsTest do
  @moduledoc """
  bd-2jerqw: `worker.repos.<repo>.seed_paths` — what `Worktree.seed_compiled_deps`
  copies into a fresh checkout is configurable, and every provisioning path
  honours it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.Worktree

  import GitFixture, only: [git!: 2]

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    GitFixture.forge_and_checkout(%{
      "README.md" => "readme\n",
      ".gitignore" => "/deps/\n/_build/\n"
    })
  end

  defp plant(repo, rel, contents \\ "x") do
    path = Path.join(repo, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp plant_default_tree(repo) do
    plant(repo, "deps/jason/mix.exs")
    plant(repo, "_build/test/lib/jason/ebin/jason.beam")
    plant(repo, "_build/dev/lib/jason/ebin/jason.beam")
    plant(repo, "_build/test/lib/myapp/ebin/myapp.beam")
    plant(repo, "priv/plts/core.plt")
  end

  defp bare_worktree(ctx, name) do
    path = Path.join(ctx.worktree_root, name)
    File.mkdir_p!(path)
    path
  end

  describe "seed_compiled_deps/3 with no seed_paths (today's behaviour)" do
    test "copies deps/* and _build/{test,dev}/lib/<name> only where deps/<name> exists", ctx do
      plant_default_tree(ctx.checkout)
      wt = bare_worktree(ctx, "default")

      assert :ok = Worktree.seed_compiled_deps(ctx.checkout, wt)

      assert File.exists?(Path.join(wt, "deps/jason/mix.exs"))
      assert File.exists?(Path.join(wt, "_build/test/lib/jason/ebin/jason.beam"))
      assert File.exists?(Path.join(wt, "_build/dev/lib/jason/ebin/jason.beam"))
      refute File.exists?(Path.join(wt, "_build/test/lib/myapp"))
      refute File.exists?(Path.join(wt, "priv/plts"))
    end

    test "nil is the same as the 2-arity call", ctx do
      plant_default_tree(ctx.checkout)
      wt = bare_worktree(ctx, "nil-default")

      assert :ok = Worktree.seed_compiled_deps(ctx.checkout, wt, nil)

      assert File.exists?(Path.join(wt, "deps/jason/mix.exs"))
      refute File.exists?(Path.join(wt, "_build/test/lib/myapp"))
    end
  end

  describe "seed_compiled_deps/3 with seed_paths" do
    test "copies exactly the listed paths, not the default set", ctx do
      plant_default_tree(ctx.checkout)
      wt = bare_worktree(ctx, "listed")

      assert :ok = Worktree.seed_compiled_deps(ctx.checkout, wt, ["_build/test/lib", "priv/plts"])

      # The whole listed dir, umbrella app included — the default filter is gone.
      assert File.exists?(Path.join(wt, "_build/test/lib/myapp/ebin/myapp.beam"))
      assert File.exists?(Path.join(wt, "_build/test/lib/jason/ebin/jason.beam"))
      assert File.exists?(Path.join(wt, "priv/plts/core.plt"))
      # Not listed, so not copied.
      refute File.exists?(Path.join(wt, "deps"))
      refute File.exists?(Path.join(wt, "_build/dev"))
    end

    test "skips a path missing from the source without error", ctx do
      plant(ctx.checkout, "priv/plts/core.plt")
      wt = bare_worktree(ctx, "missing")

      log =
        capture_log(fn ->
          assert :ok =
                   Worktree.seed_compiled_deps(ctx.checkout, wt, ["node_modules", "priv/plts"])
        end)

      refute File.exists?(Path.join(wt, "node_modules"))
      assert File.exists?(Path.join(wt, "priv/plts/core.plt"))
      refute log =~ "warning"
    end

    test "does not overwrite a path already present in the worktree", ctx do
      plant(ctx.checkout, "priv/plts/core.plt", "from source")
      wt = bare_worktree(ctx, "present")
      plant(wt, "priv/plts/core.plt", "already here")

      assert :ok = Worktree.seed_compiled_deps(ctx.checkout, wt, ["priv/plts"])

      assert File.read!(Path.join(wt, "priv/plts/core.plt")) == "already here"
    end

    test "copies a single file entry", ctx do
      plant(ctx.checkout, ".tool-versions", "elixir 1.19\n")
      wt = bare_worktree(ctx, "file")

      assert :ok = Worktree.seed_compiled_deps(ctx.checkout, wt, [".tool-versions"])

      assert File.read!(Path.join(wt, ".tool-versions")) == "elixir 1.19\n"
    end

    test "an empty list seeds nothing", ctx do
      plant_default_tree(ctx.checkout)
      wt = bare_worktree(ctx, "empty")

      assert :ok = Worktree.seed_compiled_deps(ctx.checkout, wt, [])

      assert File.ls!(wt) == []
    end

    test "never copies absolute, `..` or .git entries, and warns about each", ctx do
      plant(ctx.checkout, "priv/plts/core.plt")
      outside = plant(ctx.root, "outside/secret.txt")
      wt = bare_worktree(ctx, "unsafe")

      entries = [
        Path.dirname(outside),
        "../outside",
        "priv/../../outside",
        ".git",
        ".git/config",
        "./.git",
        "",
        "priv/plts"
      ]

      log =
        capture_log(fn ->
          assert :ok = Worktree.seed_compiled_deps(ctx.checkout, wt, entries)
        end)

      refute File.exists?(Path.join(wt, "outside"))
      refute File.exists?(Path.join(wt, ".git"))
      refute File.exists?(Path.join(wt, "priv/../outside"))
      assert File.exists?(Path.join(wt, "priv/plts/core.plt"))

      for entry <- Enum.reject(entries, &(&1 in ["", "priv/plts"])) do
        assert log =~ "seed_paths entry #{inspect(entry)}", "no warning for #{inspect(entry)}"
      end

      assert log =~ "seed_paths entry \"\""
    end

    test "a failed copy is logged and never raises", ctx do
      plant(ctx.checkout, "priv/plts/core.plt")
      # The destination parent is a regular file, so `cp` cannot create the entry.
      wt = bare_worktree(ctx, "blocked")
      File.write!(Path.join(wt, "priv"), "not a directory")

      log =
        capture_log(fn ->
          assert :ok = Worktree.seed_compiled_deps(ctx.checkout, wt, ["priv/plts"])
        end)

      assert log =~ "priv/plts"
    end

    test "a non-list value is ignored rather than crashing provisioning", ctx do
      wt = bare_worktree(ctx, "crash")

      assert :ok = Worktree.seed_compiled_deps(ctx.checkout, wt, :bogus)
    end
  end

  describe "create/4 honours seed_paths: (standard worktree path)" do
    test "linked worktree gets the configured list only", ctx do
      plant_default_tree(ctx.checkout)

      assert {:ok, wt} =
               Worktree.create(ctx.checkout, "feature/seed-linked", "main",
                 seed_paths: ["priv/plts"]
               )

      assert File.exists?(Path.join(wt, "priv/plts/core.plt"))
      refute File.exists?(Path.join(wt, "deps"))
    end

    test "no seed_paths: keeps the default set", ctx do
      plant_default_tree(ctx.checkout)

      assert {:ok, wt} = Worktree.create(ctx.checkout, "feature/seed-linked-default", "main")

      assert File.exists?(Path.join(wt, "deps/jason/mix.exs"))
      refute File.exists?(Path.join(wt, "priv/plts"))
    end

    test "attach/3 honours it", ctx do
      plant_default_tree(ctx.checkout)
      git!(ctx.checkout, ["branch", "feature/seed-attach", "main"])

      assert {:ok, wt} =
               Worktree.attach(ctx.checkout, "feature/seed-attach", seed_paths: ["priv/plts"])

      assert File.exists?(Path.join(wt, "priv/plts/core.plt"))
      refute File.exists?(Path.join(wt, "deps"))
    end

    test "create_detached/4 honours it, on a fresh add and a re-point", ctx do
      plant_default_tree(ctx.checkout)

      assert {:ok, wt} =
               Worktree.create_detached(ctx.checkout, "seed-detached", "main",
                 seed_paths: ["priv/plts"]
               )

      assert File.exists?(Path.join(wt, "priv/plts/core.plt"))
      refute File.exists?(Path.join(wt, "deps"))

      File.rm_rf!(Path.join(wt, "priv/plts"))

      assert {:ok, ^wt} =
               Worktree.create_detached(ctx.checkout, "seed-detached", "main",
                 seed_paths: ["priv/plts"]
               )

      assert File.exists?(Path.join(wt, "priv/plts/core.plt"))
    end
  end

  describe "private clone honours seed_paths (layout B)" do
    test "create/4 seeds the configured list only", ctx do
      plant_default_tree(ctx.checkout)

      assert {:ok, wt} =
               PrivateClone.create(ctx.checkout, "feature/seed-clone", "main", ["priv/plts"])

      assert PrivateClone.clone?(wt)
      assert File.exists?(Path.join(wt, "priv/plts/core.plt"))
      refute File.exists?(Path.join(wt, "deps"))
    end

    test "Worktree.create(layout: :private_clone, seed_paths:) reaches it", ctx do
      plant_default_tree(ctx.checkout)

      assert {:ok, wt} =
               Worktree.create(ctx.checkout, "feature/seed-clone-wt", "main",
                 layout: :private_clone,
                 seed_paths: ["priv/plts"]
               )

      assert File.exists?(Path.join(wt, "priv/plts/core.plt"))
      refute File.exists?(Path.join(wt, "deps"))
    end

    test "attach/4 seeds the configured list only", ctx do
      plant_default_tree(ctx.checkout)
      git!(ctx.checkout, ["branch", "feature/seed-clone-attach", "main"])

      assert {:ok, wt} =
               PrivateClone.attach(ctx.checkout, "feature/seed-clone-attach", "main", [
                 "priv/plts"
               ])

      assert File.exists?(Path.join(wt, "priv/plts/core.plt"))
      refute File.exists?(Path.join(wt, "deps"))
    end

    test "default (no list) is today's behaviour", ctx do
      plant_default_tree(ctx.checkout)

      assert {:ok, wt} = PrivateClone.create(ctx.checkout, "feature/seed-clone-default", "main")

      assert File.exists?(Path.join(wt, "deps/jason/mix.exs"))
      refute File.exists?(Path.join(wt, "priv/plts"))
    end
  end

  describe "commit gate: seeded paths the repo does not gitignore" do
    test "has_uncommitted?/1 ignores them, but still reports a real untracked file", ctx do
      plant(ctx.checkout, "priv/plts/core.plt")
      plant(ctx.checkout, "tmp/cache/blob.bin")

      assert {:ok, wt} =
               Worktree.create(ctx.checkout, "feature/seed-gate", "main",
                 seed_paths: ["priv/plts", "tmp/cache"]
               )

      assert File.exists?(Path.join(wt, "priv/plts/core.plt"))
      # Untracked as far as git is concerned (the fixture's .gitignore knows neither).
      assert git!(wt, ["status", "--porcelain"]) =~ "?? priv/"
      assert {:ok, false} = Worktree.has_uncommitted?(wt)

      plant(wt, "lib/real.ex", "defmodule Real do end\n")
      assert {:ok, true} = Worktree.has_uncommitted?(wt)
    end

    test "a file sitting next to a seeded path is not swallowed", ctx do
      plant(ctx.checkout, "priv/plts/core.plt")

      assert {:ok, wt} =
               Worktree.create(ctx.checkout, "feature/seed-gate-sibling", "main",
                 seed_paths: ["priv/plts"]
               )

      assert {:ok, false} = Worktree.has_uncommitted?(wt)

      plant(wt, "priv/plts_notes.md", "mine\n")
      assert {:ok, true} = Worktree.has_uncommitted?(wt)
    end

    test "a seeded path nested in an otherwise-untracked directory is still ignored", ctx do
      # `git status` collapses to `?? priv/` when nothing under priv/ is tracked.
      plant(ctx.checkout, "priv/plts/core.plt")

      assert {:ok, wt} =
               Worktree.create(ctx.checkout, "feature/seed-gate-collapsed", "main",
                 seed_paths: ["priv/plts"]
               )

      assert git!(wt, ["status", "--porcelain"]) =~ "?? priv/"
      assert {:ok, false} = Worktree.has_uncommitted?(wt)

      plant(wt, "priv/real.txt", "mine\n")
      assert {:ok, true} = Worktree.has_uncommitted?(wt)
    end

    test "the ignore is private to the seeded worktree (not the source repo)", ctx do
      plant(ctx.checkout, "priv/plts/core.plt")

      assert {:ok, wt} =
               Worktree.create(ctx.checkout, "feature/seed-gate-private", "main",
                 seed_paths: ["priv/plts"]
               )

      assert {:ok, wt2} = Worktree.create(ctx.checkout, "feature/seed-gate-other", "main")
      plant(wt2, "priv/plts/core.plt")

      assert {:ok, false} = Worktree.has_uncommitted?(wt)
      assert {:ok, true} = Worktree.has_uncommitted?(wt2)
    end

    test "leftover_work/2 (the reap check) disregards them too", ctx do
      plant(ctx.checkout, "priv/plts/core.plt")

      assert {:ok, wt} =
               Worktree.create(ctx.checkout, "feature/seed-leftover", "main",
                 seed_paths: ["priv/plts"]
               )

      assert {:ok, nil} = Worktree.leftover_work(wt)

      plant(wt, "lib/real.ex", "defmodule Real do end\n")
      assert {:ok, %{changes: ["?? lib/"]}} = Worktree.leftover_work(wt)
    end

    test "the private clone's gate ignores them too", ctx do
      plant(ctx.checkout, "priv/plts/core.plt")

      assert {:ok, wt} =
               PrivateClone.create(ctx.checkout, "feature/seed-gate-clone", "main", ["priv/plts"])

      assert {:ok, false} = Worktree.has_uncommitted?(wt)

      plant(wt, "lib/real.ex", "defmodule Real do end\n")
      assert {:ok, true} = Worktree.has_uncommitted?(wt)
    end

    test "unsafe entries never become ignore patterns", ctx do
      assert {:ok, wt} =
               Worktree.create(ctx.checkout, "feature/seed-gate-unsafe", "main",
                 seed_paths: ["..", "/", ".git"]
               )

      plant(wt, "lib/real.ex", "defmodule Real do end\n")
      assert {:ok, true} = Worktree.has_uncommitted?(wt)
    end

    test "an entry that was not actually copied never becomes an ignore pattern", ctx do
      # `docs` is tracked, so it already exists in the worktree and is skipped;
      # `scratch` is absent from the source. Neither may hide a real new file.
      GitFixture.commit!(ctx.checkout, %{"docs/a.md" => "a\n"}, "docs")
      git!(ctx.checkout, ["push", "-q", "origin", "main"])

      assert {:ok, wt} =
               Worktree.create(ctx.checkout, "feature/seed-gate-uncopied", "main",
                 seed_paths: ["docs", "scratch"]
               )

      plant(wt, "docs/new.md", "mine\n")
      assert {:ok, true} = Worktree.has_uncommitted?(wt)
      File.rm!(Path.join(wt, "docs/new.md"))

      plant(wt, "scratch/new.txt", "mine\n")
      assert {:ok, true} = Worktree.has_uncommitted?(wt)
    end
  end
end
