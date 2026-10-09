defmodule ArbiterCli.Cmd.Account do
  @moduledoc """
  `arb account <verb>` — provider accounts (P11, `docs/provider-account-design.md`
  §2.5). An account is the identity a Claude/Codex/Antigravity
  credential, quota snapshot and concurrency ceiling all hang off (§2.4) — it
  survives credential rotation because none of them ever point at the
  credential itself.

      arb account list                              [--provider claude|codex|antigravity|grok]
                                     [--include-merged] [--include-deleted]
                                     By default merged-away and deleted
                                     accounts are hidden; pass --include-merged
                                     / --include-deleted to see them too.
      arb account show   <ref>
                                     <ref> is a uuid, "provider:slug", or a
                                     bare slug (only unambiguous if no other
                                     provider shares it)
      arb account create <provider> <slug> [--label ...] [--plan ...]
                                     [--max-concurrent N] [--disable]
                                     [--provider-account-ref ID]
                                     [--provider-org-ref ID]
                                     [<quota flags>, as for `set`]
                                     No credential is required at creation
                                     time (§2.4 — operator-asserted identity).
                                     The quota flags are validated by the same
                                     rules as `set`; a bad value creates
                                     nothing.
      arb account set    <ref> [--label TEXT] [--plan TEXT]
                                     [--enable | --disable]
                                     [--max-concurrent N|none]
                                     [--threshold-mode flat|paced]
                                     [--throttle-threshold F]
                                     [--weekly-threshold F] [--paced-floor F]
                                     [--weekly-paced-floor F]
                                     [--weekly-warning-policy ignore|hold]
                                     [--window-seconds LABEL=SECONDS[,...]]
                                     [--pace-exempt-priority 0..4|none]
                                     [--pace-exempt-threshold F]
                                     [--weekly-pace-exempt-threshold F]
                                     [--unset QUOTA_KEY]
                                     `--max-concurrent`: the account
                                     concurrency ceiling (P8, §4.2): at most N
                                     workers may run on this account across
                                     every workspace metered under it. `none`
                                     clears it — the ceiling is opt-in (§4.4)
                                     and an account without one behaves
                                     exactly as it did before P8.
                                     The remaining flags (bd-c7ll4t, bd-1kr3qf)
                                     are a partial merge into the account's
                                     `quota_config` — the gate settings
                                     `Arbiter.Quota.Gate` resolves as
                                     `min(account, workspace)`. Every key the
                                     gate reads from an account has a flag;
                                     only the given keys change. F is a
                                     fraction in (0, 1].
                                     `--window-seconds` replaces the account's
                                     whole window-length table (repeat the
                                     flag or comma-separate: 5h=18000,7d=604800).
                                     `--pace-exempt-priority none` and
                                     `--unset KEY` (repeatable; KEY is a quota
                                     key, e.g. weekly_threshold) clear a key so
                                     the built-in default applies again.
                                     `--label` / `--plan` / `--enable` /
                                     `--disable` (bd-8vkqd3): the display name,
                                     the plan, and whether the account is
                                     parked. An empty `--label ""` clears it.
                                     At least one flag is required. The whole
                                     edit is one write: a bad value changes
                                     nothing.
      arb account attach <workspace> <provider> <ref> [--share N]
                                     Points a workspace (name or id; with
                                     `-w`/ARB_WORKSPACE the workspace may be
                                     left out) at an account for a provider —
                                     writes/updates the
                                     workspace_provider_accounts row. A grok
                                     account cannot be attached: grok is
                                     routed by the workspace's own setting.
                                     `--share N` is this workspace's cap on
                                     its use of the account ceiling (§4.3) —
                                     a **cap, not a reservation**: shares may
                                     sum to more than the ceiling, and that is
                                     the useful configuration.
      arb account detach <workspace> <ref>
                                     Removes that workspace's link to the
                                     account (name or id; `-w` may stand in
                                     for the workspace). Other workspaces
                                     stay attached.
      arb account rotate <ref> --kind oauth_token|api_key|cli_credentials_file
                                     --env-var VAR (--secret VALUE | --secret-file PATH | -)
                                     [--scopes a,b]
                                     Inserts a new active credential and
                                     retires the previous one of the same
                                     kind. A data operation, not automated
                                     rotation (§11) — the secret is never
                                     printed or logged, by this command or any
                                     other.
      arb account rotate <ref> --kind cli_credentials_path --secret DIR
                                     Points the quota poller at a dedicated
                                     Claude grant by location (bd-b632tz):
                                     DIR is a CLAUDE_CONFIG_DIR logged in with
                                     `CLAUDE_CONFIG_DIR=DIR claude auth login`
                                     (or its .credentials.json). Only the
                                     path is stored; the server re-reads the
                                     token each poll and has the CLI refresh
                                     it. --env-var defaults to
                                     CLAUDE_CONFIG_DIR.
      arb account merge  <from-ref> --into <into-ref>
                                     Re-points usage_events, provider_credentials
                                     and workspace_provider_accounts from
                                     <from-ref> to <into-ref>, collapses the
                                     provider's quota snapshot, and soft-deletes
                                     <from-ref> (merged_into_id set). All-or-
                                     nothing (§2.5) — the operationally
                                     critical command in this design.
      arb account delete <ref>       [--detach] [--hard]
                                     Soft-deletes by default: hidden from
                                     `arb account list` and every account
                                     picker, but the row and its usage_events
                                     attribution are kept (`arb usage --by
                                     account` still resolves it). Every
                                     active credential is retired first,
                                     never printed. Refused, with a reason,
                                     while the account is attached to a
                                     workspace (pass --detach to detach as
                                     part of the delete), is required by a
                                     workspace's implementer/reviewer
                                     settings (not bypassed by --detach), or
                                     is pinned by a running task's provider
                                     routing. `--hard` destroys the row
                                     outright instead — only for an account
                                     with no usage rows and no credentials,
                                     ever.

      arb account login  <ref>       Log the account in through the provider
                                     CLI's own login, run by the server in a
                                     hidden tmux session (login relay). Prints
                                     the sign-in URL (and a device code when
                                     the flow has one); when the CLI waits for
                                     a pasted code it asks for it at a hidden
                                     prompt — never an argument, which `ps`
                                     would show. Exits non-zero on failure,
                                     timeout or cancel.

  All verbs go through the REST API at `/api/accounts`.
  """

  alias ArbiterCli.{ArgParser, Client, Output, SecretInput}
  alias ArbiterCli.Cmd.Account.Login

  # One flag per `quota_config` key (`Arbiter.Accounts.Fields.quota_keys/0`; a
  # test pins the two lists together). Values stay strings so the flag can say
  # `none`; each is parsed and range-checked by `quota_value!/2`.
  @quota_switches [
    threshold_mode: :string,
    throttle_threshold: :string,
    weekly_threshold: :string,
    paced_floor: :string,
    weekly_paced_floor: :string,
    weekly_warning_policy: :string,
    window_seconds: [:string, :keep],
    pace_exempt_priority: :string,
    pace_exempt_threshold: :string,
    weekly_pace_exempt_threshold: :string
  ]

  @quota_keys Enum.map(@quota_switches, fn {key, _} -> Atom.to_string(key) end)

  @doc "The `quota_config` keys `account create|set` has a flag for."
  @spec quota_keys() :: [String.t()]
  def quota_keys, do: @quota_keys

  @switches @quota_switches ++
              [
                provider: :string,
                label: :string,
                plan: :string,
                # :string, not :integer, so `--max-concurrent none` can clear the
                # ceiling — it is nullable and `nil` means "no ceiling" (§4.4).
                max_concurrent: :string,
                provider_account_ref: :string,
                provider_org_ref: :string,
                unset: [:string, :keep],
                share: :integer,
                kind: :string,
                env_var: :string,
                secret: :string,
                secret_file: :string,
                # refused by `login`: a code must never ride in argv
                code: :string,
                scopes: :string,
                into: :string,
                json: :boolean,
                include_merged: :boolean,
                include_deleted: :boolean,
                detach: :boolean,
                hard: :boolean,
                enable: :boolean,
                disable: :boolean
              ]

  @doc "Every switch `arb account` takes (read by the field-exposure guard test)."
  @spec switches() :: keyword()
  def switches, do: @switches

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _mode} = ArgParser.parse(argv, command: "arb account", switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      case rest do
        ["list" | _] ->
          list(opts, mode)

        ["show" | args] ->
          show(args, mode)

        ["create" | args] ->
          create(args, opts, mode)

        ["set" | args] ->
          set(args, opts, mode)

        ["attach" | args] ->
          attach(args, opts, mode)

        ["detach" | args] ->
          detach(args, opts, mode)

        ["rotate" | args] ->
          rotate(args, opts, mode)

        ["merge" | args] ->
          merge(args, opts, mode)

        ["delete" | args] ->
          delete(args, opts, mode)

        ["login" | args] ->
          Login.run(args, opts)

        [] ->
          Output.die(
            "account requires a subcommand",
            "verbs: list, show, create, set, attach, detach, rotate, merge, delete, login"
          )

        [unknown | _] ->
          Output.die("unknown account subcommand: #{unknown}")
      end
    end
  end

  # ---- list ----------------------------------------------------------------

  defp list(opts, mode) do
    params =
      []
      |> then(fn p -> if opts[:provider], do: [{:provider, opts[:provider]} | p], else: p end)
      |> then(fn p -> if opts[:include_merged], do: [{:include_merged, "true"} | p], else: p end)
      |> then(fn p ->
        if opts[:include_deleted], do: [{:include_deleted, "true"} | p], else: p
      end)

    case Client.get("/api/accounts", params) do
      {:ok, %{"data" => accounts}} -> emit_list(accounts, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_list(accounts, :json), do: IO.puts(Jason.encode!(%{data: accounts}))
  defp emit_list([], :text), do: IO.puts("(no accounts)")

  defp emit_list(accounts, :text) do
    Enum.each(accounts, fn a ->
      ceiling = if a["max_concurrent"], do: " max_concurrent=#{a["max_concurrent"]}", else: ""
      state = if a["enabled"], do: "", else: "  [disabled]"
      merged = if a["merged_into_id"], do: "  [merged -> #{a["merged_into_id"]}]", else: ""
      IO.puts("#{a["provider"]}:#{a["slug"]}  (#{a["id"]})#{ceiling}#{state}#{merged}")
    end)
  end

  # ---- show ------------------------------------------------------------

  defp show(args, mode) do
    ref = one_ref!(args, "show")

    case Client.get("/api/accounts/" <> URI.encode(ref)) do
      {:ok, account} -> emit_show(account, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_show(account, :json), do: IO.puts(Jason.encode!(account))

  defp emit_show(account, :text) do
    IO.puts("Provider:    #{account["provider"]}")
    IO.puts("Slug:        #{account["slug"]}")
    IO.puts("ID:          #{account["id"]}")
    IO.puts("Label:       #{account["label"] || "-"}")
    IO.puts("Plan:        #{account["plan"] || "-"}")
    IO.puts("Enabled:     #{account["enabled"]}")
    IO.puts("Max concurrent: #{account["max_concurrent"] || "(none)"}")

    emit_merged_into(account["merged_into_id"])

    IO.puts("")
    IO.puts("Credentials:")
    emit_show_section(account["credentials"], &emit_credential_line/1)

    IO.puts("")
    IO.puts("Workspaces:")
    emit_show_section(account["workspaces"], &emit_link_line/1)
  end

  defp emit_merged_into(nil), do: :ok
  defp emit_merged_into(id), do: IO.puts("Merged into: #{id}")

  defp emit_show_section(nil, _fun), do: IO.puts("  (none)")
  defp emit_show_section([], _fun), do: IO.puts("  (none)")
  defp emit_show_section(items, fun), do: Enum.each(items, fun)

  defp emit_credential_line(c) do
    status = if c["active"], do: "active", else: "retired #{c["retired_at"]}"
    IO.puts("  #{c["kind"]} (#{c["env_var"]}) fingerprint=#{c["fingerprint"]}  #{status}")
  end

  defp emit_link_line(l) do
    share = if l["share"], do: " share=#{l["share"]}", else: ""
    IO.puts("  workspace #{l["workspace_id"]}#{share}")
  end

  # ---- create ------------------------------------------------------------

  defp create(args, opts, mode) do
    {provider, slug} = provider_and_ref!(args, "create")

    payload =
      %{"provider" => provider, "slug" => slug}
      |> maybe_put("label", opts[:label])
      |> maybe_put("plan", opts[:plan])
      |> maybe_put("max_concurrent", max_concurrent!(opts))
      |> maybe_put("provider_account_ref", opts[:provider_account_ref])
      |> maybe_put("provider_org_ref", opts[:provider_org_ref])
      |> maybe_put("enabled", if(opts[:disable], do: false))
      |> maybe_put_quota_config(opts, create: true)

    case Client.post("/api/accounts", payload) do
      {:ok, account} -> emit_written(account, "created", mode)
      {:error, err} -> Output.die(err)
    end
  end

  # ---- set ---------------------------------------------------------------

  # P8 (`docs/provider-account-design.md` §4.2): the account concurrency
  # ceiling. A PATCH rather than its own verb endpoint — it edits one column
  # on an existing row.
  defp set(args, opts, mode) do
    ref = one_ref!(args, "set")

    payload =
      %{}
      |> maybe_put_attrs(opts)
      |> maybe_put_ceiling(opts)
      |> maybe_put_quota_config(opts, [])

    if payload == %{} do
      Output.die(
        "account set requires at least one of --label, --plan, --enable, --disable, " <>
          "--max-concurrent, --unset, " <>
          Enum.map_join(@quota_keys, ", ", &flag_name/1)
      )
    end

    case Client.patch("/api/accounts/" <> URI.encode(ref), payload) do
      {:ok, account} -> emit_set(account, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp maybe_put_attrs(payload, opts) do
    if opts[:enable] && opts[:disable], do: Output.die("--enable and --disable are exclusive")

    payload
    |> maybe_put("label", opts[:label])
    |> maybe_put("plan", opts[:plan])
    |> maybe_put("enabled", if(opts[:enable], do: true, else: if(opts[:disable], do: false)))
  end

  defp maybe_put_ceiling(payload, opts) do
    case Keyword.fetch(opts, :max_concurrent) do
      {:ok, _} ->
        ceiling =
          case max_concurrent!(opts) do
            :clear -> nil
            value -> value
          end

        Map.put(payload, "max_concurrent", ceiling)

      :error ->
        payload
    end
  end

  # The `quota_config` object for `create` / `set`: one entry per flag given,
  # plus a `nil` per `--unset` key (a clear). `create` has nothing to clear, so
  # `--unset` is refused there.
  defp maybe_put_quota_config(payload, opts, create_opts) do
    unsets = unset_keys!(opts)

    if create_opts[:create] && unsets != [] do
      Output.die("--unset only applies to `arb account set`")
    end

    given =
      Enum.reduce(@quota_keys, %{}, fn key, acc ->
        case quota_value!(key, quota_flag_values(opts, key)) do
          nil -> acc
          :clear -> Map.put(acc, key, nil)
          value -> Map.put(acc, key, value)
        end
      end)

    case Enum.find(unsets, &Map.has_key?(given, &1)) do
      nil -> :ok
      key -> Output.die("#{flag_name(key)} and --unset #{key} contradict each other")
    end

    quota_config = Enum.reduce(unsets, given, &Map.put(&2, &1, nil))
    if quota_config == %{}, do: payload, else: Map.put(payload, "quota_config", quota_config)
  end

  defp quota_flag_values(opts, "window_seconds"), do: Keyword.get_values(opts, :window_seconds)
  defp quota_flag_values(opts, key), do: opts[String.to_existing_atom(key)]

  defp flag_name(key), do: "--" <> String.replace(key, "_", "-")

  defp unset_keys!(opts) do
    opts
    |> Keyword.get_values(:unset)
    |> Enum.map(fn raw ->
      key = raw |> String.trim() |> String.replace("-", "_")

      if key in @quota_keys do
        key
      else
        Output.die(
          "--unset takes a quota key, got #{inspect(raw)}",
          "quota keys: #{Enum.join(@quota_keys, ", ")}"
        )
      end
    end)
    |> Enum.uniq()
  end

  # `nil` when the flag was not given (`maybe_put` drops it).
  defp quota_value!(_key, nil), do: nil
  defp quota_value!(_key, []), do: nil
  defp quota_value!("threshold_mode", value), do: value

  defp quota_value!("weekly_warning_policy", value) do
    if value in ~w(ignore hold) do
      value
    else
      Output.die("--weekly-warning-policy must be ignore or hold (got #{inspect(value)})")
    end
  end

  defp quota_value!("pace_exempt_priority", value) when value in ~w(none off), do: :clear

  defp quota_value!("pace_exempt_priority", value) do
    case Integer.parse(value) do
      {n, ""} when n in 0..4 ->
        n

      _ ->
        Output.die("--pace-exempt-priority must be 0..4 or `none` (got #{inspect(value)})")
    end
  end

  defp quota_value!("window_seconds", values), do: parse_window_seconds!(values)
  defp quota_value!(key, value), do: parse_fraction!(value, flag_name(key))

  defp parse_window_seconds!(values) do
    values
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Map.new(fn pair ->
      with [label, seconds] <- String.split(pair, "=", parts: 2),
           label when label != "" <- String.trim(label),
           {n, ""} when n > 0 <- Integer.parse(String.trim(seconds)) do
        {label, n}
      else
        _ ->
          Output.die(
            "--window-seconds takes LABEL=SECONDS with positive whole seconds, e.g. 5h=18000 " <>
              "(got #{inspect(pair)})"
          )
      end
    end)
  end

  defp parse_fraction!(value, flag) do
    case Float.parse(value) do
      {f, ""} when f > 0 and f <= 1 ->
        f

      _ ->
        Output.die("#{flag} must be a number in 0..1 (got #{inspect(value)})")
    end
  end

  defp emit_set(account, :json), do: IO.puts(Jason.encode!(account))

  defp emit_set(account, :text) do
    quota_config = account["quota_config"] || %{}

    IO.puts(
      "#{account["provider"]}:#{account["slug"]} max_concurrent=" <>
        "#{account["max_concurrent"] || "(none)"}" <>
        " threshold_mode=#{quota_config["threshold_mode"] || "flat"}" <>
        " enabled=#{account["enabled"]}"
    )
  end

  # ---- attach ------------------------------------------------------------

  defp attach(args, opts, mode) do
    {workspace, provider, ref} =
      case args do
        [workspace, provider, ref | _] ->
          {workspace, provider, ref}

        [provider, ref | _] ->
          {selected_workspace!("account attach requires <workspace> <provider> <ref>"), provider,
           ref}

        _ ->
          Output.die("account attach requires <workspace> <provider> <ref>")
      end

    payload =
      %{"workspace_id" => ArbiterCli.Workspace.id_or_halt(workspace), "provider" => provider}
      |> maybe_put("share", opts[:share])

    case Client.post("/api/accounts/" <> URI.encode(ref) <> "/attach", payload) do
      {:ok, link} -> emit_attach(link, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # `-w` / ARB_WORKSPACE stands in for the leading positional (D-A-17).
  defp selected_workspace!(usage) do
    case System.get_env("ARB_WORKSPACE") do
      ws when is_binary(ws) and ws != "" -> ws
      _ -> Output.die(usage)
    end
  end

  # ---- detach ------------------------------------------------------------

  defp detach(args, _opts, mode) do
    {workspace, ref} =
      case args do
        [workspace, ref | _] -> {workspace, ref}
        [ref] -> {selected_workspace!("account detach requires <workspace> <ref>"), ref}
        _ -> Output.die("account detach requires <workspace> <ref>")
      end

    workspace_id = ArbiterCli.Workspace.id_or_halt(workspace)

    case Client.delete(
           "/api/accounts/" <> URI.encode(ref) <> "/attach/" <> URI.encode(workspace_id)
         ) do
      {:ok, link} -> emit_detach(link, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_detach(link, :json), do: IO.puts(Jason.encode!(link))

  defp emit_detach(link, :text) do
    IO.puts(
      "detached workspace #{link["workspace_id"]} from account #{link["provider_account_id"]}"
    )
  end

  defp emit_attach(link, :json), do: IO.puts(Jason.encode!(link))

  defp emit_attach(link, :text) do
    share = if link["share"], do: " share=#{link["share"]}", else: ""

    IO.puts(
      "attached workspace #{link["workspace_id"]} -> account #{link["provider_account_id"]}#{share}"
    )
  end

  # ---- rotate ------------------------------------------------------------

  defp rotate(args, opts, mode) do
    ref = one_ref!(args, "rotate")
    kind = opts[:kind] || Output.die("account rotate requires --kind")
    env_var = opts[:env_var] || default_env_var(kind)
    secret = resolve_secret!(kind, opts, args)

    payload =
      %{"kind" => kind, "env_var" => env_var, "secret" => secret}
      |> maybe_put("scopes", split_scopes(opts[:scopes]))

    case Client.post("/api/accounts/" <> URI.encode(ref) <> "/rotate", payload) do
      {:ok, credential} -> emit_rotated(credential, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # Never prints the secret it just wrote — only shape/metadata a rotation
  # audit trail needs (P11 acceptance: never display or log the value).
  defp emit_rotated(credential, :json) do
    credential
    |> Map.drop(["secret"])
    |> Jason.encode!()
    |> IO.puts()
  end

  defp emit_rotated(credential, :text) do
    IO.puts("rotated #{credential["kind"]} credential (fingerprint=#{credential["fingerprint"]})")
  end

  # A `cli_credentials_path` names a location the server reads, so it gets a
  # default env var and is sent as an absolute path: the server's cwd is not
  # the caller's.
  defp default_env_var("cli_credentials_path"), do: "CLAUDE_CONFIG_DIR"
  defp default_env_var(_kind), do: Output.die("account rotate requires --env-var")

  defp resolve_secret!("cli_credentials_path", opts, _args) do
    case opts[:secret] do
      path when is_binary(path) and path != "" -> Path.expand(path)
      _ -> Output.die("account rotate --kind cli_credentials_path requires --secret DIR")
    end
  end

  defp resolve_secret!(_kind, opts, args), do: resolve_secret!(opts, args)

  defp resolve_secret!(opts, args) do
    cond do
      opts[:secret] && opts[:secret_file] ->
        Output.die("pass only one of --secret / --secret-file")

      is_binary(opts[:secret]) ->
        SecretInput.warn_argv("--secret-file <path> or - (stdin)")
        opts[:secret]

      is_binary(opts[:secret_file]) ->
        SecretInput.from_file!(opts[:secret_file], "--secret-file")

      "-" in args ->
        SecretInput.from_stdin!()

      true ->
        Output.die(
          "account rotate requires a secret: pass --secret, --secret-file <path>, or - (stdin)"
        )
    end
  end

  defp split_scopes(nil), do: nil
  defp split_scopes(str), do: str |> String.split(",") |> Enum.map(&String.trim/1)

  # ---- merge ------------------------------------------------------------

  defp merge(args, opts, mode) do
    from_ref = one_ref!(args, "merge")
    into_ref = opts[:into] || Output.die("account merge requires --into <ref>")

    case Client.post("/api/accounts/" <> URI.encode(from_ref) <> "/merge", %{"into" => into_ref}) do
      {:ok, account} -> emit_merged(account, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_merged(account, :json), do: IO.puts(Jason.encode!(account))

  defp emit_merged(account, :text),
    do:
      IO.puts("merged into account #{account["provider"]}:#{account["slug"]} (#{account["id"]})")

  # ---- delete --------------------------------------------------------------

  defp delete(args, opts, mode) do
    ref = one_ref!(args, "delete")

    params =
      []
      |> then(fn p -> if opts[:detach], do: [{:detach, "true"} | p], else: p end)
      |> then(fn p -> if opts[:hard], do: [{:hard, "true"} | p], else: p end)

    case Client.delete("/api/accounts/" <> URI.encode(ref), params) do
      {:ok, account} -> emit_deleted(account, opts[:hard], mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_deleted(account, _hard, :json), do: IO.puts(Jason.encode!(account))

  defp emit_deleted(account, true, :text),
    do: IO.puts("deleted account #{account["provider"]}:#{account["slug"]} (#{account["id"]})")

  defp emit_deleted(account, _hard, :text),
    do:
      IO.puts("soft-deleted account #{account["provider"]}:#{account["slug"]} (#{account["id"]})")

  # ---- output ------------------------------------------------------------

  defp emit_written(account, _verb, :json), do: IO.puts(Jason.encode!(account))

  defp emit_written(account, verb, :text),
    do: IO.puts("#{verb} account #{account["provider"]}:#{account["slug"]} (#{account["id"]})")

  # ---- helpers -----------------------------------------------------------

  defp one_ref!(args, verb) do
    case Enum.reject(args, &(&1 == "-")) do
      [ref | _] -> ref
      [] -> Output.die("account #{verb} requires a ref (uuid, provider:slug, or slug)")
    end
  end

  defp provider_and_ref!(args, verb) do
    case args do
      [provider, slug | _] -> {provider, slug}
      _ -> Output.die("account #{verb} requires <provider> <slug>")
    end
  end

  # `nil` when the flag was not given at all, so `maybe_put/3` drops it;
  # an explicit `none` is the sentinel that clears the ceiling.
  defp max_concurrent!(opts) do
    case opts[:max_concurrent] do
      nil -> nil
      value when value in ~w(none nil null clear unset) -> :clear
      value -> parse_max_concurrent(value)
    end
  end

  defp parse_max_concurrent(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 ->
        n

      _ ->
        Output.die(
          "--max-concurrent must be a non-negative integer, or `none` to clear it (got #{inspect(value)})"
        )
    end
  end

  defp maybe_put(map, key, :clear), do: Map.put(map, key, nil)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
