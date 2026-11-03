defmodule Arbiter.Test.ClaudeControlStub do
  @moduledoc """
  A POSIX-sh stand-in for `claude -p --input-format stream-json …` (bd-a2zrh0).

  Reads one JSON `control_request` per stdin line and answers `initialize` /
  `get_usage` according to the mode in `$1`:

  | mode              | behaviour |
  |-------------------|-----------|
  | `ok`              | initialize → `tokenSource: "claude.ai"`; get_usage → `usage_body/0` |
  | `no_token`        | initialize → `tokenSource: "none"` |
  | `init_unsupported`| initialize → error "Unsupported control request subtype" |
  | `init_hang`       | initialize never answered |
  | `no_usage`        | get_usage → error "Unsupported control request subtype" |
  | `usage_401`       | get_usage → error carrying a 401 |
  | `usage_429`       | get_usage → error carrying a 429 |
  | `usage_hang`      | get_usage never answered |
  | `usage_empty`     | get_usage → success with a body carrying no usage windows |
  | `exit`            | exits 3 immediately |
  | `hang`            | sleeps without reading |
  """

  @usage_body %{
    "five_hour" => %{"utilization" => 42.0, "resets_at" => "2030-01-01T05:00:00Z"},
    "seven_day" => %{"utilization" => 10.0, "resets_at" => "2030-01-07T00:00:00Z"}
  }

  @doc "The body the stub's `get_usage` returns (OAuth-usage shaped)."
  def usage_body, do: @usage_body

  @doc "Write the stub into `dir`; returns its path (run as `sh <path> <mode>`)."
  def write!(dir) do
    path = Path.join(dir, "claude-stub.sh")
    File.write!(path, script())
    path
  end

  defp error_reply(msg),
    do:
      ~s(printf '{"type":"control_response","response":{"subtype":"error","request_id":"%s","error":"#{msg}"}}\\n' "$id")

  defp script do
    """
    #!/bin/sh
    MODE="$1"
    [ "$MODE" = "exit" ] && exit 3
    [ "$MODE" = "hang" ] && exec sleep 30
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
      sub=$(printf '%s' "$line" | sed -n 's/.*"subtype":"\\([^"]*\\)".*/\\1/p')
      printf '{"type":"system","subtype":"noise"}\\n'
      case "$sub" in
        initialize)
          case "$MODE" in
            init_unsupported)
              #{error_reply("Unsupported control request subtype: initialize")} ;;
            no_token)
              printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"account":{"tokenSource":"none"}}}}\\n' "$id" ;;
            init_hang)
              sleep 30 ;;
            *)
              printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"account":{"tokenSource":"claude.ai","subscriptionType":"max"}}}}\\n' "$id" ;;
          esac ;;
        get_usage)
          case "$MODE" in
            no_usage)
              #{error_reply("Unsupported control request subtype: get_usage")} ;;
            usage_401)
              #{error_reply("Request failed with status code 401: invalid authentication credentials")} ;;
            usage_429)
              #{error_reply("Request failed with status code 429: rate limited")} ;;
            usage_hang)
              sleep 30 ;;
            usage_empty)
              printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\\n' "$id" ;;
            *)
              printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":%s}}\\n' "$id" '#{Jason.encode!(@usage_body)}' ;;
          esac ;;
      esac
    done
    """
  end
end
