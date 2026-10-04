defmodule ArbiterCli.Cmd.Account.Login do
  @moduledoc """
  `arb account login <ref>` (login relay 6/6, bd-bh50vs): drive the provider
  CLI's own login for an account through the server's login relay.

  Starts the login (`POST /api/accounts/:ref/login`), polls it
  (`GET /api/account_logins/:id`), prints the sign-in URL and — for a
  device-code flow — the code, and when the provider CLI is waiting for a
  pasted code reads it from a **hidden prompt**: terminal echo off, never an
  argument (`ps` is world-readable), and sent in the JSON body of
  `POST /api/account_logins/:id/paste`. An empty answer cancels the login.

  Exits 0 once the login is verified; anything else — failed, timed out,
  cancelled, or a server error — exits non-zero with the reason.

  Test seams (process dictionary, like the rest of the CLI): `:bd2_login_poll_ms`
  and `:bd2_login_prompt` (`fn prompt -> code end`).
  """

  alias ArbiterCli.{Client, Output}

  @poll_ms 1_000
  # The server gives a login ten minutes; a little more here so its own
  # `timed_out` is what the operator sees.
  @deadline_ms 11 * 60_000
  @terminal ~w(succeeded failed timed_out cancelled)

  @spec run([String.t()], keyword()) :: :ok
  def run(args, opts) do
    ref = ref!(args)
    refuse_argv_code!(opts)

    case Client.post("/api/accounts/" <> URI.encode(ref) <> "/login", %{}) do
      {:ok, state} -> watch(state, %{url_shown?: false, pasted?: false}, deadline())
      {:error, err} -> Output.die(err)
    end
  end

  defp ref!(args) do
    case Enum.reject(args, &(&1 == "-")) do
      [ref | _] -> ref
      [] -> Output.die("account login requires a ref (uuid, provider:slug, or slug)")
    end
  end

  defp refuse_argv_code!(opts) do
    flag = Enum.find([:code, :secret, :secret_file], &opts[&1])

    if flag do
      Output.die(
        "account login does not take --#{flag |> to_string() |> String.replace("_", "-")}: " <>
          "a code on the command line shows up in `ps`",
        "run it without; it prompts (hidden) when the provider CLI asks for a code"
      )
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @deadline_ms

  defp watch(state, shown, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      cancel(state)
      Output.die("login timed out waiting for the provider")
    end

    {state, shown} = step(state, shown)

    if state["status"] in @terminal do
      finish(state)
    else
      Process.sleep(Process.get(:bd2_login_poll_ms, @poll_ms))

      case Client.get("/api/account_logins/" <> URI.encode(state["id"])) do
        {:ok, next} -> watch(next, shown, deadline)
        {:error, err} -> Output.die(err)
      end
    end
  end

  # What the operator needs at `awaiting_user`: where to sign in, the device
  # code, and — once — the paste prompt.
  defp step(%{"status" => "awaiting_user"} = state, shown) do
    shown = show_instructions(state, shown)

    if state["needs_paste"] and not shown.pasted? do
      paste(state)
      {state, %{shown | pasted?: true}}
    else
      {state, shown}
    end
  end

  defp step(state, shown), do: {state, shown}

  defp show_instructions(state, %{url_shown?: false} = shown) do
    if url = state["url"], do: IO.puts("Open this page and sign in:\n  #{url}")
    if code = state["device_code"], do: IO.puts("Enter this code there:\n  #{code}")
    %{shown | url_shown?: true}
  end

  defp show_instructions(_state, shown), do: shown

  defp paste(state) do
    code = prompt("Paste the code from the sign-in page (input hidden): ")

    if code == "" do
      cancel(state)
      Output.die("no code entered — login cancelled")
    end

    path = "/api/account_logins/" <> URI.encode(state["id"]) <> "/paste"

    case Client.post(path, %{"code" => code}) do
      {:ok, _} ->
        :ok

      {:error, err} ->
        cancel(state)
        Output.die(err)
    end
  end

  defp cancel(state),
    do: Client.post("/api/account_logins/" <> URI.encode(state["id"]) <> "/cancel", %{})

  defp finish(%{"status" => "succeeded", "provider" => provider, "account" => account}),
    do: IO.puts("logged in #{provider}:#{account}")

  defp finish(%{"status" => status} = state) do
    reason = if state["reason"], do: " (#{state["reason"]})", else: ""
    Output.die("login #{String.replace(status, "_", " ")}#{reason}")
  end

  # ---- the hidden prompt ------------------------------------------------------

  defp prompt(text) do
    answer =
      case Process.get(:bd2_login_prompt) do
        fun when is_function(fun, 1) -> fun.(text)
        nil -> read_hidden(text)
      end

    answer |> to_string() |> String.trim()
  end

  # Echo is switched off on the controlling terminal for the one read and
  # restored in `after`, so a Ctrl-C mid-prompt cannot leave the shell silent.
  # No tty (piped stdin) just reads the line.
  defp read_hidden(text) do
    tty? = File.exists?("/dev/tty") and :os.cmd(~c"stty -echo < /dev/tty 2>/dev/null") == []

    try do
      IO.write(:stderr, text)
      line = IO.gets("")
      if tty?, do: IO.write(:stderr, "\n")
      line
    after
      if tty?, do: :os.cmd(~c"stty echo < /dev/tty 2>/dev/null")
    end
  end
end
