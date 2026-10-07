defmodule ArbiterCli.Cmd.Doctor.Formatter do
  @moduledoc """
  Text/JSON rendering for `arb doctor` (bd-7pnat1).

  Default text output is a header, one summary line and only the `warn`/`fail`
  checks (each with its hint). `all: true` (`--all`, `-v`) prints every check,
  grouped, with `n/a` for the ones that do not apply; a composite whose
  sub-checks all pass (the agy jail) collapses to one line and expands to the
  failing sub-check otherwise. `--json` always carries every check.
  """

  alias ArbiterCli.{Client, Output}

  @group_titles [
    core: "core",
    auth: "auth & providers",
    sandboxes: "sandboxes",
    security: "security posture"
  ]

  @composites %{"agy_jail" => "agy jail"}

  @spec emit_text([struct()], keyword()) :: :ok
  def emit_text(results, opts \\ []) do
    all? = Keyword.get(opts, :all, false)

    IO.puts(header(results))
    IO.puts("")
    IO.puts(summary_line(results))

    shown = if all?, do: results, else: Enum.filter(results, &(&1.status in [:warn, :fail]))

    for {group, title} <- @group_titles, rows = Enum.filter(shown, &(&1.group == group)), rows != [] do
      IO.puts("")
      IO.puts(title)
      rows |> collapse(all?) |> Enum.each(&print_row/1)
    end

    :ok
  end

  @doc "`27 ok · 1 warn · 0 fail`, plus `· 3 n/a` when any check does not apply."
  @spec summary_line([struct()]) :: String.t()
  def summary_line(results) do
    %{ok: ok, warn: warn, fail: fail, na: na} = summary(results)
    base = "#{ok} ok · #{warn} warn · #{fail} fail"
    if na > 0, do: base <> " · #{na} n/a", else: base
  end

  @spec summary([struct()]) :: %{ok: non_neg_integer(), warn: non_neg_integer(), fail: non_neg_integer(), na: non_neg_integer()}
  def summary(results) do
    counts = Enum.frequencies_by(results, & &1.status)
    Map.new([:ok, :warn, :fail, :na], &{&1, Map.get(counts, &1, 0)})
  end

  @doc "The overall verdict, which is also the exit code: `:fail` iff any check failed."
  @spec overall([struct()]) :: :ok | :warn | :fail
  def overall(results) do
    statuses = Enum.map(results, & &1.status)

    cond do
      :fail in statuses -> :fail
      :warn in statuses -> :warn
      true -> :ok
    end
  end

  def emit_json(results) do
    overall = overall(results)

    payload = %{
      base_url: Client.base_url(),
      ok: overall != :fail,
      result: Atom.to_string(overall),
      exit_code: if(overall == :fail, do: 1, else: 0),
      summary: summary(results),
      checks: Enum.map(results, &json_check/1)
    }

    Output.emit_json(payload)
  end

  @doc "The map `--json` (and `arb start` / `arb server deploy`'s `--json`) carries for one check."
  @spec json_check(struct()) :: map()
  def json_check(r) do
    r
    |> Map.from_struct()
    |> Map.put(:severity, severity(r.status))
    |> Map.put(:status, severity(r.status))
  end

  defp severity(:na), do: "n/a"
  defp severity(status), do: Atom.to_string(status)

  # -- text ------------------------------------------------------------------

  defp header(results) do
    version = Enum.find_value(results, fn r -> r.meta[:server_version] end)
    workspaces = Enum.find_value(results, fn r -> r.meta[:workspaces] end)
    bind = Enum.find_value(results, fn r -> r.meta[:bind] end)

    parts =
      [
        version && "server #{version}",
        workspaces && workspaces != [] && "workspace#{plural(workspaces)}: #{Enum.join(workspaces, ", ")}",
        bind && "bind #{bind}",
        Client.base_url()
      ]
      |> Enum.filter(& &1)

    "arb doctor — " <> Enum.join(parts, " · ")
  end

  defp plural([_]), do: ""
  defp plural(_), do: "s"

  # A composite's sub-checks (`parent`) become one line while they all pass (or
  # are all n/a); otherwise only the sub-checks that are not ok are listed.
  defp collapse(rows, true = _all?), do: do_collapse(rows)
  defp collapse(rows, false = _all?), do: rows

  defp do_collapse(rows) do
    {children, plain} = Enum.split_with(rows, & &1.parent)

    composites =
      children
      |> Enum.group_by(& &1.parent)
      |> Enum.flat_map(fn {parent, subs} -> composite(parent, subs) end)

    # keep the original order: composites sit where their first sub-check was
    order = Enum.map(rows, &(&1.parent || &1.id))

    (plain ++ composites)
    |> Enum.sort_by(fn r -> Enum.find_index(order, &(&1 == (r.parent || r.id))) end)
  end

  defp composite(parent, subs) do
    title = Map.get(@composites, parent, parent)

    cond do
      Enum.all?(subs, &(&1.status == :na)) ->
        [%{hd(subs) | id: parent, name: title, parent: nil, hint: nil}]

      Enum.all?(subs, &(&1.status in [:ok, :na])) ->
        ran = Enum.count(subs, &(&1.status == :ok))

        [
          %{
            hd(subs)
            | id: parent,
              name: "#{title} (#{ran} checks)",
              parent: nil,
              status: :ok,
              detail: nil,
              hint: nil
          }
        ]

      true ->
        Enum.reject(subs, &(&1.status in [:ok, :na]))
    end
  end

  defp print_row(r) do
    IO.puts("#{marker(r.status)} #{r.name}")
    if r.detail, do: IO.puts("        #{r.detail}")
    if r.status in [:warn, :fail] and r.hint, do: IO.puts("        hint: #{r.hint}")
  end

  defp marker(:ok), do: "[ ok ]"
  defp marker(:warn), do: "[warn]"
  defp marker(:fail), do: "[fail]"
  defp marker(:na), do: "[n/a ]"
end
