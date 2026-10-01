defmodule Arbiter.Reviews.ConflictResolution do
  @moduledoc """
  What did a head that follows an approved commit add, once the target branch
  is accounted for? (bd-954ym8 / #134.)

  Every time the target branch moves under an approved PR the branch has to be
  rebased or merged, and every such head used to be a full ReviewGate re-review
  — a whole round, often premium-tier, to look at a mechanical integration of
  `origin/main`. This module answers the one question that decides whether that
  round is owed, with plain git in a checkout that has both commits:

    * `{:clean, info}` — the head is **exactly** what integrating the target
      into the approved commit produces. Nothing was authored, nothing was
      resolved: the approval still covers it, and no review is needed.
    * `{:resolution, info}` — the head is that same integration **except** in
      regions where the target's and the branch's edits collided and someone
      hand-resolved them. The only thing a reviewer has not seen is those
      resolutions, so that is all a reviewer needs to be shown (`render/2`).
    * `{:authored, reason}` / `{:unknown, reason}` — anything else: the head
      carries content that neither came from the target nor sits inside a
      conflicted region (a smuggled change, a fix-pass commit, a deleted
      file), or git could not say. Both mean the ordinary full review. The
      safety property of the whole feature lives here: **every doubt is
      `:authored`/`:unknown`, never `:clean`**.

  ## How it decides

  This is `git range-diff <base_old>..<approved> <base_new>..<head>` made
  stricter and tree-level instead of commit-series-level. `range-diff` pairs
  commits heuristically and reports each pair as `=` (same patch) or `!`
  (changed); it cannot say whether a changed pair is a conflict resolution or a
  smuggled edit, and it has nothing to say about a squash or a merge commit.
  Here instead:

    1. `base_new` is the target commit the head integrates
       (`merge-base(head, target)`) and `base_old` the one the approved commit
       was cut from (`merge-base(approved, base_new)`).
    2. `git merge-tree --write-tree --merge-base=<base_old> <base_new> <approved>`
       computes the mechanical result of replaying the approved change onto the
       new base. If it is conflict-free that tree is *the* clean integration;
       if not it is that tree with conflict markers in the collided files.
    3. The head's tree is compared with it, file by file. A file that differs
       and is not conflicted is authored content. A conflicted file's marker
       text is split at the markers into **anchors** (text the integration
       fixed) and **regions** (the collisions); the head's file must be the
       anchors in order, with anything between them. What lies between them is
       the resolution.

  The head's own history is irrelevant: a rebase, a merge, a squash or a
  hand-built tree all reduce to the same comparison. A rebase whose
  per-commit resolutions differ from the one-shot merge outside the conflict
  regions is reported `:authored` — more review, never less.
  """

  require Logger

  @type region :: %{
          ours: [String.t()],
          base: [String.t()] | nil,
          theirs: [String.t()],
          resolution: [String.t()]
        }

  @type file :: %{path: String.t(), regions: [region()]}

  @type info :: %{
          approved: String.t(),
          head: String.t(),
          base_old: String.t(),
          base_new: String.t(),
          files: [file()]
        }

  @type outcome ::
          {:clean, info()}
          | {:resolution, info()}
          | {:authored, term()}
          | {:unknown, term()}

  # Candidates tried per call: the newest covered heads. A PR rarely has more
  # than a few, and each costs a merge-tree.
  @max_candidates 5

  @doc """
  Classify `head` against the approved commits `approved` (newest first), with
  `target` naming the target branch tip (a rev git resolves, e.g.
  `origin/main`). Prefers `:clean` over `:resolution` over `:authored`.
  """
  @spec classify(String.t() | nil, [String.t()], String.t() | nil, String.t() | nil) :: outcome()
  def classify(repo, approved, head, target)
      when is_binary(repo) and is_list(approved) and is_binary(head) and is_binary(target) do
    results =
      approved
      |> Enum.reject(&(&1 == head))
      |> Enum.take(@max_candidates)
      |> Enum.map(&classify_one(repo, &1, head, target))

    Enum.find(results, &match?({:clean, _}, &1)) ||
      Enum.find(results, &match?({:resolution, _}, &1)) ||
      List.first(results) ||
      {:unknown, :no_approved_commit}
  end

  def classify(_repo, _approved, _head, _target), do: {:unknown, :bad_input}

  @doc "`classify/4` against one approved commit."
  @spec classify_one(String.t(), String.t(), String.t(), String.t()) :: outcome()
  def classify_one(repo, approved, head, target) do
    with {:ok, a} <- rev(repo, approved),
         {:ok, h} <- rev(repo, head),
         {:ok, tgt} <- rev(repo, target),
         {:ok, base_new} <- merge_base(repo, h, tgt),
         {:ok, base_old} <- merge_base(repo, a, base_new),
         {:ok, merged, conflicted} <- merge_tree(repo, base_old, base_new, a),
         {:ok, head_tree} <- tree_of(repo, h),
         {:ok, diffs} <- diff_trees(repo, merged, head_tree),
         info = %{approved: a, head: h, base_old: base_old, base_new: base_new, files: []},
         :ok <- no_authored_files(diffs, conflicted),
         {:ok, files} <- resolved_files(repo, merged, h, conflicted, diffs) do
      info = %{info | files: files}
      if files == [], do: {:clean, info}, else: {:resolution, info}
    end
  rescue
    e -> {:unknown, {:exception, Exception.message(e)}}
  end

  # ---- git ---------------------------------------------------------------

  defp rev(repo, ref) do
    if String.starts_with?(ref, "-") do
      {:unknown, {:bad_ref, ref}}
    else
      case git(repo, ["rev-parse", "--verify", "--quiet", "#{ref}^{commit}"]) do
        {out, 0} -> {:ok, String.trim(out)}
        _ -> {:unknown, {:unknown_commit, ref}}
      end
    end
  end

  defp merge_base(repo, a, b) do
    case git(repo, ["merge-base", a, b]) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> {:unknown, :no_merge_base}
    end
  end

  defp tree_of(repo, commit) do
    case git(repo, ["rev-parse", "--verify", "--quiet", "#{commit}^{tree}"]) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> {:unknown, :no_tree}
    end
  end

  # `--name-only -z --no-messages`: the tree id, then one NUL-terminated path
  # per conflicted file. Exit 0 is conflict-free, 1 is conflicted; the tree is
  # written either way (conflicted files carry their markers).
  defp merge_tree(repo, base_old, base_new, approved) do
    args = [
      "-c",
      "merge.conflictStyle=diff3",
      "merge-tree",
      "--write-tree",
      "-z",
      "--name-only",
      "--no-messages",
      "--merge-base=#{base_old}",
      base_new,
      approved
    ]

    case git(repo, args) do
      {out, code} when code in [0, 1] ->
        case String.split(out, <<0>>, trim: true) do
          [tree | paths] ->
            {:ok, String.trim(tree), paths |> Enum.uniq() |> Enum.sort()}

          [] ->
            {:unknown, :merge_tree_empty}
        end

      {out, code} ->
        {:unknown, {:merge_tree_failed, code, String.slice(String.trim(out), 0, 200)}}
    end
  end

  # `:<old mode> <new mode> <old sha> <new sha> <status>\0<path>\0`, per file.
  defp diff_trees(repo, left, right) do
    case git(repo, ["diff-tree", "-r", "-z", "--no-renames", "--no-abbrev", left, right]) do
      {out, 0} -> {:ok, parse_raw(String.split(out, <<0>>, trim: true), [])}
      {out, code} -> {:unknown, {:diff_tree_failed, code, String.slice(String.trim(out), 0, 200)}}
    end
  end

  defp parse_raw([meta, path | rest], acc) do
    case String.split(meta, " ") do
      [":" <> old_mode, new_mode, _old_sha, _new_sha, status] ->
        parse_raw(rest, [
          %{path: path, status: status, old_mode: old_mode, new_mode: new_mode} | acc
        ])

      _ ->
        parse_raw(rest, acc)
    end
  end

  defp parse_raw(_rest, acc), do: Enum.reverse(acc)

  defp blob(repo, treeish, path) do
    case git(repo, ["cat-file", "blob", "#{treeish}:#{path}"]) do
      {out, 0} -> {:ok, out}
      _ -> :error
    end
  end

  defp git(repo, args) do
    System.cmd("git", ["-C", repo | args],
      stderr_to_stdout: false,
      env: [{"GIT_TERMINAL_PROMPT", "0"}, {"LC_ALL", "C"}]
    )
  end

  # ---- comparing the head with the mechanical result -----------------------

  # A file the head changes relative to the integration, that is not one of the
  # integration's own conflicts, is authored content. This is the check that
  # catches a smuggled hunk — in a merge commit or a rebased commit alike.
  defp no_authored_files(diffs, conflicted) do
    case Enum.reject(diffs, &(&1.path in conflicted)) do
      [] -> :ok
      authored -> {:authored, {:outside_conflict, authored |> Enum.map(& &1.path) |> Enum.sort()}}
    end
  end

  defp resolved_files(repo, merged, head, conflicted, diffs) do
    Enum.reduce_while(conflicted, {:ok, []}, fn path, {:ok, acc} ->
      case resolved_file(repo, merged, head, path, diffs) do
        {:ok, file} -> {:cont, {:ok, acc ++ [file]}}
        {:halt, outcome} -> {:halt, outcome}
      end
    end)
  end

  defp resolved_file(repo, merged, head, path, diffs) do
    with :ok <- mode_unchanged(diffs, path),
         {:ok, marked} <- blob(repo, merged, path) |> or_unanalyzable(path),
         {:ok, resolved} <- blob(repo, head, path) |> or_unanalyzable(path),
         :ok <- text?(marked, resolved, path),
         {:ok, segments} <- parse_markers(String.split(marked, "\n"), path),
         {:ok, regions} <- align(segments, String.split(resolved, "\n"), path),
         :ok <- no_markers_left(regions, path) do
      {:ok, %{path: path, regions: regions}}
    else
      {:authored, _} = authored -> {:halt, authored}
    end
  end

  defp or_unanalyzable({:ok, _} = ok, _path), do: ok
  defp or_unanalyzable(:error, path), do: {:authored, {:unanalyzable, path}}

  defp mode_unchanged(diffs, path) do
    case Enum.find(diffs, &(&1.path == path)) do
      %{old_mode: old, new_mode: new} when old != new -> {:authored, {:mode_change, path}}
      _ -> :ok
    end
  end

  defp text?(marked, resolved, path) do
    if String.contains?(marked, <<0>>) or String.contains?(resolved, <<0>>),
      do: {:authored, {:binary, path}},
      else: :ok
  end

  # ---- conflict markers --------------------------------------------------

  # Split the merge-tree's file into `{:fixed, lines}` and
  # `{:conflict, ours, base, theirs}` segments, always starting and ending on a
  # (possibly empty) fixed one. A file with no marker at all (a modify/delete or
  # rename conflict git cannot mark) is not analyzable and falls back.
  defp parse_markers(lines, path) do
    case scan(lines, :fixed, [], [], [], [], []) do
      {:ok, segments} when is_list(segments) ->
        segments = merge_adjacent(segments)

        if Enum.any?(segments, &match?({:conflict, _, _, _}, &1)),
          do: {:ok, segments},
          else: {:authored, {:unanalyzable, path}}

      :error ->
        {:authored, {:unanalyzable, path}}
    end
  end

  # state: :fixed | :ours | :base | :theirs. `fixed` accumulates the current
  # anchor; `ours`/`base`/`theirs` the open conflict. All accumulators are
  # reversed.
  defp scan([], :fixed, fixed, _o, _b, _t, segs),
    do: {:ok, Enum.reverse([{:fixed, Enum.reverse(fixed)} | segs])}

  defp scan([], _state, _fixed, _o, _b, _t, _segs), do: :error

  defp scan([line | rest], :fixed, fixed, o, b, t, segs) do
    if marker?(line, "<<<<<<<"),
      do: scan(rest, :ours, [], [], nil, [], [{:fixed, Enum.reverse(fixed)} | segs]),
      else: scan(rest, :fixed, [line | fixed], o, b, t, segs)
  end

  defp scan([line | rest], :ours, fixed, o, b, t, segs) do
    cond do
      marker?(line, "|||||||") -> scan(rest, :base, fixed, o, [], t, segs)
      line == "=======" -> scan(rest, :theirs, fixed, o, b, t, segs)
      true -> scan(rest, :ours, fixed, [line | o], b, t, segs)
    end
  end

  defp scan([line | rest], :base, fixed, o, b, t, segs) do
    if line == "=======",
      do: scan(rest, :theirs, fixed, o, b, t, segs),
      else: scan(rest, :base, fixed, o, [line | b], t, segs)
  end

  defp scan([line | rest], :theirs, fixed, o, b, t, segs) do
    if marker?(line, ">>>>>>>") do
      conflict = {:conflict, Enum.reverse(o), b && Enum.reverse(b), Enum.reverse(t)}
      scan(rest, :fixed, [], [], nil, [], [conflict | segs])
    else
      scan(rest, :theirs, fixed, o, b, [line | t], segs)
    end
  end

  defp marker?(line, marker),
    do: line == marker or String.starts_with?(line, marker <> " ")

  # Two collisions with nothing between them have no anchor to split the
  # resolution on: treat them as one region.
  defp merge_adjacent(segments), do: collapse(segments, [])

  defp collapse(
         [{:conflict, o1, b1, t1}, {:fixed, []}, {:conflict, o2, b2, t2} | rest],
         acc
       ),
       do: collapse([{:conflict, o1 ++ o2, join_base(b1, b2), t1 ++ t2} | rest], acc)

  defp collapse([segment | rest], acc), do: collapse(rest, [segment | acc])
  defp collapse([], acc), do: Enum.reverse(acc)

  defp join_base(nil, nil), do: nil
  defp join_base(a, b), do: (a || []) ++ (b || [])

  # ---- aligning the head's file against the anchors -----------------------

  # `segments` is `[fixed, conflict, fixed, ..., conflict, fixed]`. The head's
  # lines must begin with the first anchor, end with the last, and contain each
  # middle anchor in order; the lines between are the resolutions. Leftmost
  # matching can only mis-attribute lines *between* regions — it can never
  # drop a head line out of every region and anchor, so everything not proven
  # to be the integration's own text is handed to the reviewer.
  defp align(segments, head_lines, path) do
    [{:fixed, first} | rest] = segments
    {middle, [{:fixed, last}]} = Enum.split(rest, -1)
    total = length(head_lines)
    limit = total - length(last)

    if limit < length(first) or not starts_with?(head_lines, first) or
         not ends_with?(head_lines, last) do
      {:authored, {:outside_conflict, [path]}}
    else
      walk(middle, head_lines, length(first), limit, [], path)
    end
  end

  # `middle` alternates conflict, fixed, conflict, ..., conflict.
  defp walk([{:conflict, o, b, t}], head, pos, limit, acc, _path) do
    {:ok, Enum.reverse([region(o, b, t, Enum.slice(head, pos, limit - pos)) | acc])}
  end

  defp walk([{:conflict, o, b, t}, {:fixed, anchor} | rest], head, pos, limit, acc, path) do
    case find(head, anchor, pos, limit) do
      nil ->
        {:authored, {:outside_conflict, [path]}}

      at ->
        walk(
          rest,
          head,
          at + length(anchor),
          limit,
          [
            region(o, b, t, Enum.slice(head, pos, at - pos)) | acc
          ],
          path
        )
    end
  end

  defp walk(_other, _head, _pos, _limit, _acc, path),
    do: {:authored, {:unanalyzable, path}}

  defp region(ours, base, theirs, resolution),
    do: %{ours: ours, base: base, theirs: theirs, resolution: resolution}

  # Leftmost index >= `from` where `anchor` lies wholly before `limit`.
  defp find(head, anchor, from, limit) do
    size = length(anchor)

    Enum.find(from..(limit - size)//1, fn i -> Enum.slice(head, i, size) == anchor end)
  end

  defp starts_with?(list, prefix), do: Enum.take(list, length(prefix)) == prefix

  defp ends_with?(list, suffix), do: Enum.take(list, -length(suffix)) == suffix

  # A resolution that still carries a marker is an unresolved conflict that
  # was committed, not a resolution.
  defp no_markers_left(regions, path) do
    markers? =
      Enum.any?(regions, fn %{resolution: lines} ->
        Enum.any?(lines, &(marker?(&1, "<<<<<<<") or marker?(&1, ">>>>>>>") or &1 == "======="))
      end)

    if markers?, do: {:authored, {:conflict_markers_left, path}}, else: :ok
  end

  # ---- what the reviewer is shown ------------------------------------------

  @doc """
  The review packet for a `{:resolution, info}`: every conflicted region of
  every file with both sides and the resolution chosen, and nothing else. Past
  `limit` bytes the remainder is named but not inlined.
  """
  @spec render(info(), pos_integer()) :: String.t()
  def render(%{files: files}, limit \\ 60_000) do
    packet = Enum.map_join(files, "\n", &render_file/1)

    if byte_size(packet) > limit do
      binary_part(packet, 0, limit) <>
        "\n(… truncated at #{limit} bytes — #{length(files)} conflicted file(s) in all: " <>
        "#{Enum.map_join(files, ", ", & &1.path)})\n"
    else
      packet
    end
  end

  defp render_file(%{path: path, regions: regions}) do
    regions
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {region, n} ->
      """
      ### #{path} — conflict region #{n} of #{length(regions)}

      TARGET side (what the target branch has here):
      #{fence(region.ours)}
      #{base_block(region.base)}BRANCH side (the approved change, as it stood when it was reviewed):
      #{fence(region.theirs)}
      RESOLUTION (what the head commit has here instead):
      #{fence(region.resolution)}
      """
    end)
  end

  defp base_block(nil), do: ""

  defp base_block(base),
    do: "COMMON ANCESTOR (before either side changed it):\n#{fence(base)}\n"

  defp fence([]), do: "```\n(empty)\n```"
  defp fence(lines), do: "```\n" <> Enum.join(lines, "\n") <> "\n```"

  @doc "A one-line, log-safe name for an `:authored` / `:unknown` reason."
  @spec reason_label(term()) :: String.t()
  def reason_label({:outside_conflict, paths}) when is_list(paths),
    do: "changes outside any conflicted region: " <> Enum.join(Enum.take(paths, 5), ", ")

  def reason_label({tag, path})
      when tag in [:unanalyzable, :binary, :mode_change, :conflict_markers_left],
      do: "#{tag} (#{path})"

  def reason_label(other), do: inspect(other, limit: 5, printable_limit: 120)
end
