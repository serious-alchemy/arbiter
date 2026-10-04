defmodule Arbiter.VersionTest do
  use ExUnit.Case, async: true

  describe "Arbiter.Version" do
    test "app_version/0 returns a string" do
      assert is_binary(Arbiter.Version.app_version())
    end

    test "git_sha/0 returns a string" do
      assert is_binary(Arbiter.Version.git_sha())
    end

    test "built_at/0 returns a string" do
      assert is_binary(Arbiter.Version.built_at())
    end

    test "git_sha reflects current HEAD, not stale compile-time value" do
      {expected_sha, 0} =
        System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true)

      assert Arbiter.Version.git_sha() == String.trim(expected_sha)
    end

    test "built_at is a valid ISO-8601 timestamp" do
      {:ok, _dt, _} = DateTime.from_iso8601(Arbiter.Version.built_at())
    end
  end

  describe "compile-time build paths" do
    # A release built in CI bakes the build machine's checkout path into any
    # runtime literal. Used as a spawn cwd it fails with
    # "spawn: Could not cd to /__w/arbiter/arbiter" on every call.
    test "no module that spawns processes embeds the umbrella build root" do
      root = Path.expand("../../../..", __DIR__)

      offenders =
        for beam <- Path.wildcard(Path.join(Application.app_dir(:arbiter), "ebin/*.beam")),
            baked_root?(beam, root),
            do: Path.basename(beam)

      assert offenders == []
    end

    test "Arbiter.Version still reports live git state from a source checkout" do
      {sha, 0} = System.cmd("git", ["rev-parse", "--short", "HEAD"])
      assert Arbiter.Version.git_sha() == String.trim(sha)
    end

    defp baked_root?(beam, root) do
      {:ok, {_, chunks}} = :beam_lib.chunks(String.to_charlist(beam), [:literals, :imports])

      # Ash/Spark DSL annotations legitimately record source file paths; only
      # modules that can spawn a process are at risk of using one as a cwd.
      spawns? = Enum.any?(chunks[:imports], &match?({Elixir.System, :cmd, _}, &1))

      literals =
        case chunks[:literals] do
          list when is_list(list) -> list
          _ -> []
        end

      spawns? and Enum.any?(literals, &contains_root?(&1, root))
    end

    defp contains_root?(term, root) when is_binary(term), do: String.contains?(term, root)

    defp contains_root?(term, root) when is_list(term) do
      # charlist paths and keyword/plain lists alike
      String.contains?(to_string_safe(term), root) or Enum.any?(term, &contains_root?(&1, root))
    end

    defp contains_root?(term, root) when is_tuple(term),
      do: term |> Tuple.to_list() |> Enum.any?(&contains_root?(&1, root))

    defp contains_root?(term, root) when is_map(term),
      do: term |> Map.to_list() |> Enum.any?(&contains_root?(&1, root))

    defp contains_root?(_, _), do: false

    defp to_string_safe(list) do
      List.to_string(list)
    rescue
      _ -> ""
    end
  end
end
