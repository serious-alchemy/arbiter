defmodule Arbiter.Usage.GeminiSessionFile do
  @moduledoc """
  Locate an agy (Antigravity / Gemini CLI) run's on-disk conversation
  database — the agy analogue of `Arbiter.Usage.ClaudeSessionFile`, for
  `Arbiter.Worker.SessionArchive`'s gemini archive branch (bd-6nupvc / T9).

  ## On-disk layout

  agy persists one SQLite database per conversation at

      <home>/.gemini/antigravity-cli/conversations/<session_id>.db

  where `<home>` is the effective `$HOME` the worker spawned under —
  `Arbiter.Agents.Gemini.ConfigDir`'s isolated per-worktree directory when
  worker config isolation is enabled (the default), else the operator's own
  `$HOME`. Unlike Claude Code's session JSONL (named for a slugified project
  path, found by globbing), the filename here is exactly `<session_id>.db` —
  no wildcard needed.

  This module only locates the file. It does not parse the database: the
  format is opaque SQLite, not line-oriented JSON, so there is no per-record
  redaction choke-point the way there is for JSONL (see
  `Arbiter.Worker.SessionArchive`'s moduledoc for how that shapes the archive
  path). Reading structured content back out of it, if ever needed, is a
  separate concern from locating and archiving the raw bytes.
  """

  @doc "Deterministic on-disk path of `session_id`'s conversation db under `home`."
  @spec path(String.t(), String.t()) :: String.t()
  def path(home, session_id) when is_binary(home) and is_binary(session_id) do
    Path.join([home, ".gemini", "antigravity-cli", "conversations", session_id <> ".db"])
  end

  @doc """
  Locate `session_id`'s conversation db under `home`. Returns `{:ok, path}` or
  `:not_found` (including when `home` / `session_id` is blank, or the file
  isn't there — pruned, never created, or this wasn't an agy run at all).
  """
  @spec locate(String.t() | nil, String.t() | nil) :: {:ok, String.t()} | :not_found
  def locate(home, session_id)
      when is_binary(home) and home != "" and
             is_binary(session_id) and session_id != "" do
    candidate = path(home, session_id)

    if File.regular?(candidate) do
      {:ok, candidate}
    else
      :not_found
    end
  end

  def locate(_home, _session_id), do: :not_found
end
