defmodule Arbiter.Test.FakeLoginCli do
  @moduledoc """
  Fake provider login CLIs replaying the output recorded by spike bd-29ycw1
  (placeholder URLs/codes), so login-relay tests never touch real OAuth.

  Scripts live in `test/support/fake_login_cli/<provider>` and are selected by
  the `FAKE_LOGIN_MODE` env var:

    * `success` — print the flow, wait for input/signal, succeed (exit 0)
    * `failure` — print the flow, wait for input/signal, fail (exit 1)
    * `hang`    — print the flow and never finish (for timeout tests); exits
      only when signalled

  claude waits for a stdin line (the pasted code) before finishing; codex
  finishes after `FAKE_LOGIN_DELAY` seconds (default 0.2), or on SIGUSR1,
  since a device-code login is approved out of band. SIGTERM/SIGINT exit 130.
  """

  @placeholder_url "https://claude.com/cai/oauth/authorize?code=true&client_id=FAKE&state=FAKE"
  @device_url "https://auth.openai.com/codex/device"
  @device_code "ABCD-12345"

  @doc "Absolute path of the fake CLI script for `provider` (`:claude | :codex`)."
  @spec script(:claude | :codex) :: String.t()
  def script(provider) when provider in [:claude, :codex] do
    Path.join([__DIR__, "fake_login_cli", Atom.to_string(provider)])
  end

  @doc "Env list selecting `mode` (`:success | :failure | :hang`)."
  @spec env(:success | :failure | :hang) :: [{String.t(), String.t()}]
  def env(mode), do: [{"FAKE_LOGIN_MODE", Atom.to_string(mode)}]

  @doc "The placeholder claude auth URL the fake prints."
  def claude_url, do: @placeholder_url

  @doc "The placeholder codex device URL the fake prints."
  def codex_url, do: @device_url

  @doc "The placeholder codex one-time code the fake prints."
  def codex_code, do: @device_code
end
