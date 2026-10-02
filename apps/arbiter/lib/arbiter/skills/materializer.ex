defmodule Arbiter.Skills.Materializer do
  @moduledoc """
  Dispatch-time materialization + prompt advertisement of the resolved skill
  set (epic child 3, bd-d5hy7y).

  ## Materialization

  At dispatch, arbiter writes **only** the resolved effective set into the
  worker's isolated worktree as `.claude/skills/<name>/SKILL.md` — the same
  injection point as the per-worker `.mcp.json` in `Arbiter.Worker.Dispatch`.
  Claude Code auto-discovers project skills under `.claude/skills/` from the
  working directory, so the worker sees exactly the selected set and nothing
  more. We deliberately do **not** install to `~/.claude/skills/` — that would
  leak every skill into every worker on the box. The registry (DB) stays the
  sole source of truth and gatekeeper.

  The `.claude/skills/` tree is added to the worktree's `.git/info/exclude` so a
  worker's `git add -A` can never sweep arbiter-injected skills into the task's
  commit (mirrors the `.mcp.json` handling).

  ## Advertisement (DECISION C)

  A materialized skill is only *listed* to a `--print` worker — it is a slash
  command, not an auto-injected system prompt (spike bd-5tc1s0). So the caller
  splices `prompt_section/1` into the worker prompt:

    * `:always_on`   skills → an explicit "you MUST use `/<name>`" directive.
    * `:situational` skills → advertised as available, invocation left to the
      agent's judgement.
  """

  alias Arbiter.MCP.AgentConfig
  alias Arbiter.Skills.Selection

  require Logger

  @claude_skills_dir Path.join(".claude", "skills")
  @gemini_skills_dir Path.join(".agents", "skills")

  @doc """
  The worktree-relative directory skills are materialized under, keyed on the
  dispatch's provider (bd-bbbxvp / agy-parity T8):

    * `:gemini` (agy/Antigravity) — `.agents/skills`, agy's documented
      workspace discovery path.
    * everything else (`:claude`, `nil`) — `.claude/skills`, the historical
      default. `:codex` never reaches this: `materialize/3` writes nothing for
      it, because Codex reads no skills directory (bd-89z02x).
  """
  @spec skills_dir(atom()) :: String.t()
  def skills_dir(provider \\ :claude)
  def skills_dir(:gemini), do: @gemini_skills_dir
  def skills_dir(_provider), do: @claude_skills_dir

  @doc """
  Write each resolved skill into `worktree` at `<skills_dir(provider)>/<name>/SKILL.md`
  and exclude the tree from git. `resolved` is the list returned by
  `Arbiter.Skills.Selection.resolve/1`.

  Returns `{:ok, [written_name]}`. Best-effort per skill: a single write
  failure is logged and skipped rather than aborting the whole dispatch. An
  empty set is a no-op (`{:ok, []}`), and a `nil` worktree (a review / task-type
  dispatch with no isolated worktree) never touches the filesystem.
  """
  @spec materialize(Path.t() | nil, [Selection.resolved()], atom()) :: {:ok, [String.t()]}
  def materialize(worktree, resolved, provider \\ :claude)
  def materialize(nil, _resolved, _provider), do: {:ok, []}
  def materialize(_worktree, [], _provider), do: {:ok, []}
  # Codex reads no skills directory and has no `/skill` slash commands
  # (bd-89z02x / G16): writing `.claude/skills` would be dead files. Its skills
  # reach it inline via `prompt_section(_, false)` instead.
  def materialize(_worktree, _resolved, :codex), do: {:ok, []}

  def materialize(worktree, resolved, provider) when is_binary(worktree) and is_list(resolved) do
    dir = skills_dir(provider)

    written =
      resolved
      |> Enum.map(& &1.skill)
      |> Enum.flat_map(fn skill ->
        case write_skill(worktree, dir, skill) do
          :ok ->
            # Increment materialize_count (best-effort; don't let telemetry break the dispatch).
            _ = Arbiter.Skills.increment_usage(skill.id, :materialize_count)
            [skill.name]

          {:error, reason} ->
            Logger.warning(
              "Arbiter.Skills.Materializer: failed to write skill #{inspect(skill.name)}: " <>
                inspect(reason)
            )

            []
        end
      end)

    # Keep arbiter-injected skills out of the worker's commits regardless of the
    # target repo's tracked .gitignore. Best-effort — never blocks a dispatch.
    if written != [] do
      _ = AgentConfig.add_to_git_exclude(worktree, [dir <> "/"])
    end

    {:ok, written}
  end

  defp write_skill(worktree, dir, skill) do
    skill_dir = Path.join([worktree, dir, skill.name])

    with :ok <- File.mkdir_p(skill_dir) do
      File.write(Path.join(skill_dir, "SKILL.md"), skill.body)
    end
  end

  @doc """
  The worker-prompt section advertising the resolved skills, or `""` when the
  set is empty. always-on skills get an imperative "use `/<name>`" directive;
  situational skills are listed as available for the agent to invoke by
  judgement.

  `materialized?` (default `true`) says whether the skill set was actually
  written somewhere the target provider's CLI will discover as a slash
  command — see `materialize/3` / `skills_dir/1`. When `false` (bd-bbbxvp /
  agy-parity T8: a provider whose CLI never discovers a worktree-local skills
  directory in headless mode, verified live for agy), this section must never
  claim the skills are "available"/"materialized" in the worktree — that
  would be a lie the agent has no way to act on. Instead:

    * always-on skills — non-negotiable, so their full body is inlined
      directly into the prompt rather than just naming a slash command that
      does not exist for this provider (progressive disclosure is a nicety;
      a silently-missing required skill is not).
    * situational skills — dropped entirely rather than advertised as
      available when they are not; the agent was never going to be told to
      invoke one by name, so there is nothing honest left to say about it.
  """
  @spec prompt_section([Selection.resolved()], boolean()) :: String.t()
  def prompt_section(resolved, materialized? \\ true)
  def prompt_section([], _materialized?), do: ""

  def prompt_section(resolved, true) when is_list(resolved) do
    always_on = Selection.always_on(resolved)
    situational = Selection.situational(resolved)

    [always_on_block(always_on), situational_block(situational)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> case do
      "" -> ""
      body -> "\n" <> body <> "\n"
    end
  end

  def prompt_section(resolved, false) when is_list(resolved) do
    always_on = Selection.always_on(resolved)

    case inlined_always_on_block(always_on) do
      "" -> ""
      body -> "\n" <> body <> "\n"
    end
  end

  defp always_on_block([]), do: ""

  defp always_on_block(resolved) do
    directives =
      resolved
      |> Enum.map_join("\n", fn %{skill: s} -> "  * `/#{s.name}`#{skill_desc(s)}" end)

    """
    Required skills — you MUST use each of these for this task. Invoke it as a
    slash command at the point it applies (they are available in this worktree):
    #{directives}
    """
  end

  defp situational_block([]), do: ""

  defp situational_block(resolved) do
    listing =
      resolved
      |> Enum.map_join("\n", fn %{skill: s} -> "  * `/#{s.name}`#{skill_desc(s)}" end)

    """
    Available skills — invoke the relevant one via its slash command when it
    applies; skip any that don't. They are materialized in this worktree:
    #{listing}
    """
  end

  defp inlined_always_on_block([]), do: ""

  defp inlined_always_on_block(resolved) do
    bodies =
      resolved
      |> Enum.map_join("\n\n", fn %{skill: s} -> "### #{s.name}#{skill_desc(s)}\n\n#{s.body}" end)

    """
    Required skills — you MUST follow each of these for this task. They are
    NOT available as slash commands in this environment, so their full
    content is inlined below:

    #{bodies}
    """
  end

  # A short description from the skill's metadata, if present, else "".
  defp skill_desc(%{metadata: %{"description" => desc}}) when is_binary(desc) and desc != "",
    do: " — " <> desc

  defp skill_desc(_), do: ""
end
