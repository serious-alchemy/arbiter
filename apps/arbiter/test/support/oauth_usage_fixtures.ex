defmodule Arbiter.Quota.OAuthUsageFixtures do
  @moduledoc false
  # Recorded `/api/oauth/usage` bodies (ids and tokens redacted), as the string
  # keyed maps `Req` decodes. `five_hour_null/0` is the live shape observed
  # 2026-11-01 after Anthropic retired the 5h window; `legacy/0` is the
  # pre-retirement shape (see bd-3uwku6). Both are pure data: callers merge
  # overrides with `Map.merge/2`.

  @doc "Live shape, 2026-11-01 (operator login): `five_hour: null`, weekly only."
  @spec five_hour_null() :: map()
  def five_hour_null do
    %{
      "five_hour" => nil,
      "seven_day" => %{"utilization" => 61.0, "resets_at" => "2026-11-02T15:59:59.560724+00:00"},
      "seven_day_opus" => nil,
      "seven_day_sonnet" => nil,
      "limits" => [
        %{
          "kind" => "weekly_all",
          "group" => "weekly",
          "percent" => 61,
          "severity" => "normal",
          "resets_at" => "2026-11-02T15:59:59.560724+00:00",
          "scope" => nil,
          "is_active" => true
        },
        %{
          "kind" => "weekly_scoped",
          "group" => "weekly",
          "percent" => 0,
          "severity" => "normal",
          "resets_at" => "2026-11-02T15:59:59.560724+00:00",
          "scope" => %{"model" => %{"id" => nil, "display_name" => "Fable"}, "surface" => nil},
          "is_active" => false
        }
      ],
      "spend" => %{
        "used" => %{"amount_minor" => 0, "currency" => "USD", "exponent" => 2},
        "limit" => nil,
        "percent" => 0,
        "severity" => "normal",
        "enabled" => false
      },
      "seven_day_breakdown" => %{
        "as_of" => "2026-11-01T12:00:00+00:00",
        "window_started_at" => "2026-10-26T16:00:00+00:00",
        "rows" => [%{"key" => "redacted", "display_name" => "Fable", "percent" => 0}]
      },
      "extra_usage" => %{"is_enabled" => false, "user_disabled" => true}
    }
  end

  @doc """
  `five_hour_null/0` with Fable's weekly scoped limit exhausted: `percent: 100`,
  `severity: "rejected"`, `is_active: true`. Derived from the recorded body by
  changing only those scoped fields (the exhausted shape itself has not been
  recorded); `weekly_all` stays at 61%, so the account still serves other models.
  """
  @spec scoped_exhausted() :: map()
  def scoped_exhausted do
    body = five_hour_null()

    limits =
      Enum.map(body["limits"], fn
        %{"kind" => "weekly_scoped"} = l ->
          %{l | "percent" => 100, "severity" => "rejected", "is_active" => true}

        l ->
          %{l | "is_active" => false}
      end)

    %{body | "limits" => limits}
  end

  @doc "Legacy shape: both 5h and 7d windows present, session limit active."
  @spec legacy() :: map()
  def legacy do
    %{
      "five_hour" => %{
        "utilization" => 42,
        "resets_at" => "2026-07-06T12:00:00Z",
        "locked_reason" => nil
      },
      "seven_day" => %{
        "utilization" => 10,
        "resets_at" => "2026-07-10T00:00:00Z",
        "locked_reason" => nil
      },
      "seven_day_sonnet" => %{"utilization" => 55},
      "seven_day_opus" => %{"utilization" => 5},
      "limits" => [
        %{
          "kind" => "session",
          "group" => "session",
          "percent" => 42,
          "severity" => "normal",
          "resets_at" => "2026-07-06T12:00:00Z",
          "is_active" => true,
          "scope" => "account"
        },
        %{
          "kind" => "weekly_all",
          "group" => "weekly",
          "percent" => 10,
          "severity" => "normal",
          "resets_at" => "2026-07-10T00:00:00Z",
          "is_active" => false,
          "scope" => "account"
        }
      ],
      "extra_usage" => %{"is_enabled" => true, "spend_limit_reached" => false}
    }
  end
end
