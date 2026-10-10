defmodule Arbiter.Worker.ReviewCi do
  @moduledoc """
  CI-gated review (bd-cut6uv / #228): the pure half of "dispatch the reviewer
  only after CI is green on the exact head SHA".

  Reviewers spent much of their time and quota running `mix test`, and often
  could not finish inside their budget — `ReviewVerification.partial?/1` then
  re-ran the whole review. CI minutes are nearly free next to model quota, so
  `Arbiter.Worker.ReviewGate` now waits for CI before it pays for a reviewer and
  tells the reviewer not to re-run the suite. This module owns everything in
  that flow that is not a process: the setting, the poll budget, the
  classification of one forge reading, the reviewer-prompt block, the flake
  record and the ticket-side `ci_wait` marker. The wait itself lives in the
  gate (`Arbiter.Worker.ReviewGate`), which calls in here.

  ## The setting

  `review.require_ci_green` in the workspace config, with a per-repo override at
  `review.repos.<repo>.require_ci_green` (the repo key matches the way
  `merge.repos` does, `Arbiter.Tasks.RepoConfig.find_entry/2`). Unset, it is on
  for a repo whose merge strategy is a forge (`github` / `gitlab` — there is a
  PR with CI to read) and off for everything else (`direct`). Off, the gate
  behaves exactly as it did before this module existed.

  ## What "green" means — the SHA match

  `classify/2` only ever answers `:green` when **the forge's head for the PR is
  the SHA the gate is about to review and that head's pipeline is `:success`**.
  A pipeline that is green on some other commit — the commit before a push, a
  commit a third party pushed — is `{:head_mismatch, sha}`, which the gate treats
  as "keep waiting", never as green. A forge that reports no head, or no
  pipeline, is not green either. Fail closed: the cost of a wrong "green" is a
  reviewer told not to run tests against code nothing ran tests on.

  ## The poll budget

  The gate polls at the Watchdog's interval and gives up after the repo's
  `merge.watchdog_max_polls` (the Watchdog's own default of 30 when unset or
  `infinity` — a gate must terminate). Giving up is not a failure: the review
  runs as it did before, the reviewer runs the tests, and the reason is recorded
  (`fallback_note/1`).
  """

  alias Arbiter.Loop.Flakes
  alias Arbiter.Mergers
  alias Arbiter.Tasks.{PullRequest, RepoConfig, Workspace}
  alias Arbiter.Worker.Watchdog

  require Logger

  # After a failed-jobs re-run, red readings within this many polls are the
  # forge still listing the failed attempt as newest — wait rather than call the
  # re-run failed (the Watchdog's `@flake_rerun_grace_polls`, same reasoning).
  @rerun_grace_polls 3

  # Infrastructure re-runs (cancelled checks, #360) before the gate gives up and
  # escalates. Each one backs off `@rerun_grace_polls * n` polls before the next.
  @infra_rerun_cap 2

  # Consecutive polls that see zero check runs for the head before the gate
  # concludes there is no CI to wait for (the Watchdog's
  # `@not_started_grace_polls`: "GitHub hasn't made the suite yet" resolves in a
  # poll or two; "no CI configured" never does).
  @not_started_grace_polls 5

  # Ceiling on one forge read. The gate polls from its own process, and a
  # wedged HTTP call must not wedge it.
  @poll_timeout_ms 30_000

  # How long past its own poll budget a `ci_wait` marker stays believable on
  # the ticket. A gate killed with `:kill` never runs `terminate/2`, and the
  # marker must not hold a ticket out of its slot forever.
  @marker_slack_ms 5 * 60_000

  @type reading ::
          :green
          | :red
          | :cancelled
          | :pending
          | :not_started
          | :unknown
          | {:head_mismatch, String.t() | nil}
          | {:unavailable, String.t()}

  @type budget :: %{interval_ms: pos_integer(), max_polls: pos_integer()}

  @doc "Polls, after a re-run, that a red reading is still the old attempt."
  @spec rerun_grace_polls() :: pos_integer()
  def rerun_grace_polls, do: @rerun_grace_polls

  @doc "Consecutive zero-check-run polls before the gate gives up waiting for CI."
  @spec not_started_grace_polls() :: pos_integer()
  def not_started_grace_polls, do: @not_started_grace_polls

  # ---- the setting ---------------------------------------------------------

  @doc """
  Whether a review in `repo` of `workspace` waits for CI before dispatching a
  reviewer. See the moduledoc for the resolution order. A `nil` workspace is off.
  """
  @spec required?(Workspace.t() | nil, String.t() | nil) :: boolean()
  def required?(%Workspace{} = workspace, repo) do
    review = Map.get(workspace.config || %{}, "review")

    case explicit_setting(review, repo) do
      bool when is_boolean(bool) -> bool
      nil -> Mergers.forge?(Mergers.strategy(workspace, repo))
    end
  rescue
    _ -> false
  end

  def required?(_workspace, _repo), do: false

  defp explicit_setting(review, repo) when is_map(review) do
    per_repo =
      with true <- is_binary(repo),
           %{} = repos <- Map.get(review, "repos"),
           %{} = entry <- RepoConfig.find_entry(repos, repo) do
        boolean_setting(Map.get(entry, "require_ci_green"))
      else
        _ -> nil
      end

    if is_nil(per_repo), do: boolean_setting(Map.get(review, "require_ci_green")), else: per_repo
  end

  defp explicit_setting(_review, _repo), do: nil

  defp boolean_setting(true), do: true
  defp boolean_setting("true"), do: true
  defp boolean_setting(false), do: false
  defp boolean_setting("false"), do: false
  defp boolean_setting(_), do: nil

  # ---- the poll budget -----------------------------------------------------

  @doc """
  The poll interval and ceiling for `repo`'s gate: the Watchdog's interval and
  the repo's `merge.watchdog_max_polls`, with the Watchdog's auto-merge default
  standing in when it is unset or `infinity`.
  """
  @spec budget(Workspace.t() | nil, String.t() | nil) :: budget()
  def budget(workspace, repo) do
    max_polls =
      case workspace && Workspace.watchdog_max_polls(Mergers.scope(workspace, repo)) do
        n when is_integer(n) and n > 0 -> n
        _ -> Watchdog.default_max_polls_auto()
      end

    %{interval_ms: Watchdog.default_interval_ms(), max_polls: max_polls}
  rescue
    _ ->
      %{interval_ms: Watchdog.default_interval_ms(), max_polls: Watchdog.default_max_polls_auto()}
  end

  # ---- reading CI ----------------------------------------------------------

  @doc """
  The merger adapter for `repo` in `workspace`, or `{:error, reason}`. `override`
  is the test escape hatch (`:ci_adapter`); with it the workspace is not read.
  """
  @spec adapter(Workspace.t() | nil, String.t() | nil, module() | nil) ::
          {:ok, module()} | {:error, String.t()}
  def adapter(_workspace, _repo, override) when is_atom(override) and not is_nil(override),
    do: {:ok, override}

  def adapter(%Workspace{} = workspace, repo, _override) do
    {:ok, Mergers.for_repo(workspace, repo)}
  rescue
    e -> {:error, "no merger adapter for the repo (#{Exception.message(e)})"}
  end

  def adapter(_workspace, _repo, _override), do: {:error, "the workspace could not be read"}

  @doc """
  One reading of the PR's CI, classified against `expected_sha`
  (`classify/2`), with the PR's link merged into the result as `:url` for the
  reviewer prompt. The forge call goes through `call/4`.
  """
  @spec read(module(), Workspace.t() | nil, String.t() | nil, String.t(), String.t()) ::
          {reading(), map()}
  def read(adapter, workspace, repo, pr_ref, expected_sha) do
    fetch = fn ->
      case adapter.get(pr_ref) do
        {:ok, %{} = result} -> {:ok, Map.put_new(result, :url, safe_link(adapter, pr_ref))}
        other -> other
      end
    end

    case call(workspace, repo, fetch) do
      {:ok, {:ok, %{} = result}} -> {classify(result, expected_sha), result}
      {:ok, {:error, reason}} -> {{:unavailable, "forge read failed: #{inspect(reason)}"}, %{}}
      {:ok, other} -> {{:unavailable, "unexpected forge reply: #{inspect(other)}"}, %{}}
      {:error, why} -> {{:unavailable, why}, %{}}
    end
  end

  defp safe_link(adapter, pr_ref) do
    case adapter.link_for(pr_ref) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Run `fun` against the forge for `repo` in `workspace`: in a short-lived
  process, so the adapter's per-process config (`Mergers.prepare_with_repo/2`)
  never lands in the caller and a hung request is bounded by `@poll_timeout_ms`.
  `{:ok, fun_result}` or `{:error, why}` — the call never raises.
  """
  @spec call(Workspace.t() | nil, String.t() | nil, (-> term())) ::
          {:ok, term()} | {:error, String.t()}
  def call(workspace, repo, fun) when is_function(fun, 0) do
    # The task is linked to the caller, so a raise inside it must come back as a
    # value — an exit signal would take the gate down with the forge call.
    task =
      Task.async(fn ->
        try do
          Mergers.prepare_with_repo(workspace, repo)
          {:ok, fun.()}
        rescue
          e -> {:error, "forge call raised: #{Exception.message(e)}"}
        catch
          kind, reason -> {:error, "forge call #{kind}: #{inspect(reason)}"}
        end
      end)

    case Task.yield(task, @poll_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> outcome
      {:exit, reason} -> {:error, "forge call crashed: #{inspect(reason)}"}
      nil -> {:error, "forge call timed out"}
    end
  end

  @doc """
  Classify one `Arbiter.Mergers.Merger.get/1` result against the SHA the gate
  is about to review. The SHA match comes first: no pipeline state is believed
  unless the forge's head IS `expected_sha`.
  """
  @spec classify(map(), String.t()) :: reading()
  def classify(%{status: status}, _expected) when status in [:merged, :closed],
    do: {:unavailable, "the PR is #{status}"}

  def classify(result, expected) when is_map(result) and is_binary(expected) do
    head = Map.get(result, :head_sha)

    if same_sha?(head, expected) do
      case Map.get(result, :pipeline) do
        :success -> :green
        :failed -> :red
        :canceled -> :cancelled
        p when p in [:running, :pending] -> :pending
        :not_started -> :not_started
        _ -> :unknown
      end
    else
      {:head_mismatch, head}
    end
  end

  def classify(_result, _expected), do: {:unavailable, "no PR head to compare against"}

  @doc """
  Whether two SHAs name the same commit. Both must be non-blank hex of at
  least 7 characters; the shorter is a prefix of the longer (the gate carries
  full SHAs, some surfaces abbreviate). Anything else is not a match.
  """
  @spec same_sha?(term(), term()) :: boolean()
  def same_sha?(a, b) when is_binary(a) and is_binary(b) do
    a = String.downcase(String.trim(a))
    b = String.downcase(String.trim(b))
    {short, long} = if byte_size(a) <= byte_size(b), do: {a, b}, else: {b, a}

    byte_size(short) >= 7 and Regex.match?(~r/\A[0-9a-f]+\z/, short) and
      String.starts_with?(long, short)
  end

  def same_sha?(_a, _b), do: false

  # ---- the wait ---------------------------------------------------------------

  @typedoc """
  The gate's wait on one head: `sha` it is waiting on, the `budget` it polls
  under, polls so far, the zero-check-run and unreadable streaks, and — once the
  failed jobs were re-run — `rerun`, which records the poll it happened at, whether
  the re-run has been seen under way, and the failing checks that prompted it.
  """
  @type wait :: %{
          sha: String.t(),
          max_polls: pos_integer(),
          polls: non_neg_integer(),
          not_started: non_neg_integer(),
          unavailable: non_neg_integer(),
          infra_reruns: non_neg_integer(),
          infra_rerun_at: non_neg_integer() | nil,
          rerun: nil | %{at_poll: non_neg_integer(), seen_pending: boolean(), checks: [map()]}
        }

  @type action ::
          :green
          | {:flake, [map()]}
          | :wait
          | :rerun
          | :rerun_infra
          | {:infra, String.t()}
          | :fix
          | {:fallback, String.t()}

  # Unreadable polls in a row before the gate stops waiting on a forge that will
  # not answer. A PR that is closed or merged ends it at once.
  @unavailable_grace_polls 3

  @doc "A fresh wait on `sha`."
  @spec new_wait(String.t(), budget()) :: wait()
  def new_wait(sha, %{max_polls: max_polls}) do
    %{
      sha: sha,
      max_polls: max_polls,
      polls: 0,
      not_started: 0,
      unavailable: 0,
      infra_reruns: 0,
      infra_rerun_at: nil,
      rerun: nil
    }
  end

  @doc """
  Fold one `reading` into the wait: the action the gate takes and the wait
  after it. Pure — the gate does the forge calls and the writes.

    * `:green` — dispatch the reviewer; `{:flake, checks}` instead when the
      failed jobs were re-run and the head then went green (record it, dispatch
      no fix pass);
    * `:rerun` — first red on this head: re-run the failed jobs once;
    * `:rerun_infra` — a check was cancelled (not failed): re-run it, backing off,
      up to `@infra_rerun_cap` times; `{:infra, reason}` once that is spent. A
      cancelled check is never a code failure, so neither ever reaches `:fix`;
    * `:fix` — red again after the re-run (or no re-run is possible): the
      existing fix path;
    * `:wait` — poll again;
    * `{:fallback, reason}` — CI will not vouch for this head (no check runs, a
      forge that will not answer, a closed PR, or the poll budget spent): the
      reviewer runs the tests, as it did before.

  A red reading right after a re-run is the forge still listing the old
  attempt as newest; it is waited out for `rerun_grace_polls/0` polls unless the
  re-run has already been seen under way.
  """
  @spec advance(wait(), reading()) :: {action(), wait()}
  def advance(wait, reading), do: step(%{wait | polls: wait.polls + 1}, reading)

  defp step(wait, :green) do
    case wait.rerun do
      nil -> {:green, wait}
      %{checks: checks} -> {{:flake, checks}, wait}
    end
  end

  defp step(wait, :red), do: red(wait)
  defp step(wait, :cancelled), do: cancelled(wait)
  defp step(wait, :pending), do: wait |> see_pending() |> reset_streaks() |> spend()
  defp step(wait, :not_started), do: not_started(wait)

  defp step(wait, {:head_mismatch, head}),
    do: wait |> reset_streaks() |> spend("the PR head is #{inspect(head)}, not #{wait.sha}")

  defp step(wait, {:unavailable, why}), do: unavailable(wait, why)
  defp step(wait, _unknown), do: wait |> reset_streaks() |> spend()

  defp not_started(wait) do
    wait = %{see_pending(wait) | not_started: wait.not_started + 1, unavailable: 0}

    if is_nil(wait.rerun) and wait.not_started >= @not_started_grace_polls do
      {{:fallback,
        "the forge reported no CI check runs for #{wait.sha} after #{wait.not_started} " <>
          "polls (this repo may have no CI)."}, wait}
    else
      spend(wait)
    end
  end

  defp cancelled(%{infra_reruns: n, infra_rerun_at: at} = wait) when not is_nil(at) do
    if wait.polls - at < @rerun_grace_polls * n,
      do: spend(reset_streaks(wait)),
      else: cancelled_next(wait)
  end

  defp cancelled(wait), do: cancelled_next(wait)

  defp cancelled_next(%{infra_reruns: n} = wait) when n < @infra_rerun_cap do
    {:rerun_infra, %{reset_streaks(wait) | infra_reruns: n + 1, infra_rerun_at: wait.polls}}
  end

  defp cancelled_next(wait) do
    {{:infra,
      "CI infrastructure: checks on #{wait.sha} were cancelled, not failed, and " <>
        "#{wait.infra_reruns} re-run(s) did not clear it."}, wait}
  end

  defp red(%{rerun: nil} = wait), do: {:rerun, reset_streaks(wait)}

  defp red(%{rerun: %{seen_pending: false, at_poll: at}} = wait) do
    if wait.polls - at < @rerun_grace_polls, do: spend(reset_streaks(wait)), else: {:fix, wait}
  end

  defp red(wait), do: {:fix, wait}

  defp see_pending(%{rerun: %{} = rerun} = wait),
    do: %{wait | rerun: %{rerun | seen_pending: true}}

  defp see_pending(wait), do: wait

  defp reset_streaks(wait), do: %{wait | not_started: 0, unavailable: 0}

  defp unavailable(wait, why) do
    wait = %{wait | unavailable: wait.unavailable + 1}

    cond do
      String.starts_with?(why, "the PR is ") ->
        {{:fallback, why <> "."}, wait}

      wait.unavailable >= @unavailable_grace_polls ->
        {{:fallback, "CI could not be read for #{wait.sha}: #{why}."}, wait}

      true ->
        spend(wait, why)
    end
  end

  # Another poll, unless the budget is spent.
  defp spend(wait, why \\ nil) do
    if wait.polls >= wait.max_polls do
      detail = if why, do: " (last reading: #{why})", else: ""
      rerun = if wait.rerun, do: " after re-running the failed jobs", else: ""

      {{:fallback,
        "CI did not report a result on #{wait.sha}#{rerun} within #{wait.max_polls} polls#{detail}."},
       wait}
    else
      {:wait, wait}
    end
  end

  @doc """
  Move the wait to a newer head: CI starts over for a new commit, so the
  re-run is unspent and the streaks are cleared. The poll count is kept — the
  budget bounds the whole wait, not each head.
  """
  @spec retarget(wait(), String.t()) :: wait()
  def retarget(wait, sha),
    do: %{
      wait
      | sha: sha,
        rerun: nil,
        not_started: 0,
        unavailable: 0,
        infra_reruns: 0,
        infra_rerun_at: nil
    }

  @doc "Record that the failed jobs were re-run at the wait's current poll."
  @spec rerun_started(wait(), [map()]) :: wait()
  def rerun_started(wait, checks),
    do: %{wait | rerun: %{at_poll: wait.polls, seen_pending: false, checks: checks}}

  @doc """
  The findings the implementer is handed when CI stays red on `sha`: the failing
  checks with their output tails, and why no reviewer has looked yet.
  """
  @spec failure_findings(String.t(), String.t(), [map()], boolean()) :: String.t()
  def failure_findings(sha, pr_ref, checks, rerun?) do
    rerun_line =
      if rerun?,
        do:
          "The failed jobs were re-run once with no code change and failed again, so this is not a flake.",
        else: "The failed jobs could not be re-run, so this is treated as a real failure."

    """
    - **High**: CI is RED on #{sha} (#{pr_ref}). ReviewGate waits for CI before it pays for a
      reviewer, so no reviewer has read this diff yet — the first thing to fix is the build.
      #{rerun_line}
      Reproduce each failing check locally, fix the root cause in this branch, commit and
      push. Do not weaken or delete a test to make it pass.
      Do NOT poll CI (`gh run watch`, `gh run view`, `gh pr checks`): Arbiter re-runs and
      watches CI after your push, and the failing output is below.

    #{status_line(sha, checks)}

    #{render_checks(checks)}
    """
  end

  defp status_line(sha, checks) do
    names = Enum.map_join(checks, ", ", &(&1 |> Map.get(:name) |> to_string()))
    jobs = if names == "", do: "none named", else: names
    "CI status for #{sha}: FAILED (failing jobs: #{jobs})"
  end

  defp render_checks([]), do: "Failing checks: (the forge named none — read the PR's checks)\n"

  defp render_checks(checks) do
    "Failing checks:\n" <>
      Enum.map_join(checks, "\n", fn check ->
        name = check |> Map.get(:name) |> to_string()
        url = Map.get(check, :url)
        summary = check |> Map.get(:summary) |> to_string() |> String.trim()
        head = "- #{name}" <> if(is_binary(url) and url != "", do: " (#{url})", else: "")
        head = if summary == "", do: head, else: head <> "\n" <> indent(summary)
        log_path = Map.get(check, :log_path)

        if is_binary(log_path),
          do: head <> "\n" <> indent("full log: #{log_path}"),
          else: head
      end) <> "\n"
  end

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))

  # ---- flakes ---------------------------------------------------------------

  @doc """
  Record a red→green flip on a re-run as flake events (`flake_record`), one per
  failing check the first red reading named (one `unknown` event when the forge
  named none). Best-effort: a failed write is logged and never blocks the review.
  """
  @spec record_flake(String.t(), String.t() | nil, [map()], String.t()) :: :ok
  def record_flake(task_id, repo, checks, sha) do
    checks = if checks == [], do: [%{name: "unknown"}], else: Enum.take(checks, 5)

    Enum.each(checks, fn check ->
      name = check |> Map.get(:name) |> to_string()

      attrs = %{
        task_id: task_id,
        repo: repo || "unknown",
        ci_job: name,
        signature: flake_signature(check),
        note:
          "ReviewGate: CI on #{sha} was red; its failed jobs were re-run once with no code " <>
            "change and the head went green (bd-cut6uv)."
      }

      case Flakes.record(attrs) do
        {:ok, _event} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "ReviewCi: flake record failed for task=#{task_id} job=#{name}: #{inspect(reason)}"
          )
      end
    end)

    :ok
  rescue
    e ->
      Logger.warning("ReviewCi: flake record raised for task=#{task_id}: #{Exception.message(e)}")
      :ok
  end

  defp flake_signature(check) do
    line =
      check
      |> Map.get(:summary)
      |> to_string()
      |> String.split("\n", trim: true)
      |> List.first()

    name = check |> Map.get(:name) |> to_string()

    if line in [nil, ""],
      do: "#{name}: red then green on re-run",
      else: String.slice(line, 0, 160)
  end

  # ---- the reviewer prompt ---------------------------------------------------

  @doc """
  The reviewer-prompt block for a round whose head has green CI. `green` is the
  gate's `%{sha:, url:}`; the block names the SHA, links the run when the forge
  gave a link, and tells the reviewer what to do — and what NOT to — instead of
  running the suite.
  """
  @spec green_block(%{sha: String.t(), url: String.t() | nil}) :: String.t()
  def green_block(%{sha: sha} = green) do
    link =
      case Map.get(green, :url) do
        url when is_binary(url) and url != "" -> " (#{url})"
        _ -> ""
      end

    """
    CI passed on #{sha}#{link}. Do not run the full test suite. Run targeted tests
    only to check a specific claim. Still flag missing or inadequate tests: green
    CI doesn't prove the new behaviour is covered.
    Not running the full suite is not a verification gap while CI is green on this
    SHA — do not mark `VERIFICATION: PARTIAL` for that alone. Use PARTIAL only for
    something else you could not confirm.

    """
  end

  @doc """
  The block for a gate that waited for CI and did not get a green result:
  tells the reviewer why, so it knows the tests are its to run.
  """
  @spec fallback_block(String.t()) :: String.t()
  def fallback_block(reason) when is_binary(reason) do
    """
    CI could not vouch for this head: #{reason} Run the tests yourself, as usual.

    """
  end

  # ---- the ticket-side marker -------------------------------------------------

  @doc """
  The `ci_wait` marker a waiting gate writes onto its ticket's
  `review_gate_state`, so the board, `arb ticket show` and the slot count can see
  the wait. `expires_at` bounds how long a marker outlives a gate that died
  without clearing it.
  """
  @spec marker(String.t(), non_neg_integer(), budget(), map()) :: map()
  def marker(sha, round, %{interval_ms: interval, max_polls: max}, extra \\ %{}) do
    now = DateTime.utc_now()
    ttl = (max + @rerun_grace_polls + 1) * interval + @marker_slack_ms

    Map.merge(
      %{
        "sha" => sha,
        "round" => round,
        "since" => DateTime.to_iso8601(now),
        "expires_at" => now |> DateTime.add(ttl, :millisecond) |> DateTime.to_iso8601()
      },
      extra
    )
  end

  @doc "Write (or, with `nil`, clear) the ticket's `ci_wait` marker. Best-effort."
  @spec put_marker(String.t(), map() | nil) :: :ok
  def put_marker(task_id, marker) when is_binary(task_id) do
    case PullRequest.record_review_gate(task_id, %{ci_wait: marker}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("ReviewCi: ci_wait write failed for #{task_id}: #{inspect(reason)}")
    end

    :ok
  rescue
    e ->
      Logger.debug("ReviewCi: ci_wait write raised for #{task_id}: #{Exception.message(e)}")
      :ok
  end

  @doc """
  The live `ci_wait` marker on `ticket` as `%{sha:, since:, round:}`, or `nil`
  when there is none, it is malformed, or it has expired (`marker/4`). Reads
  only the ticket's own `review_gate_state`, so it is safe in the pure
  projections (`Arbiter.Tasks.Lifecycle.View`, `Arbiter.Tasks.SlotGate`).
  """
  @spec waiting(map() | nil, DateTime.t()) ::
          %{sha: String.t(), since: String.t() | nil, round: term()} | nil
  def waiting(ticket, now \\ DateTime.utc_now())

  def waiting(%{review_gate_state: %{"ci_wait" => %{"sha" => sha} = wait}}, now)
      when is_binary(sha) do
    case DateTime.from_iso8601(to_string(Map.get(wait, "expires_at"))) do
      {:ok, expires, _} ->
        if DateTime.compare(now, expires) == :lt,
          do: %{sha: sha, since: Map.get(wait, "since"), round: Map.get(wait, "round")},
          else: nil

      _ ->
        nil
    end
  end

  def waiting(_ticket, _now), do: nil

  @doc "The label a surface renders for a wait: `waiting on CI <short sha>`."
  @spec wait_label(%{sha: String.t()}) :: String.t()
  def wait_label(%{sha: sha}), do: "waiting on CI " <> String.slice(sha, 0, 12)

  @doc "The reason string recorded when the gate falls back to a reviewer-run suite."
  @spec fallback_note(String.t()) :: String.t()
  def fallback_note(reason), do: "CI did not gate this review: " <> reason
end
