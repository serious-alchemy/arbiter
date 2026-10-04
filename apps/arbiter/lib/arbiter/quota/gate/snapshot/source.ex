defmodule Arbiter.Quota.Gate.Snapshot.Source do
  @moduledoc """
  Behaviour for the `:quota_snapshot` seam (`Arbiter.Extension`): projects one
  provider's persisted quota row onto the provider-neutral
  `Arbiter.Quota.Gate.Snapshot`.

  A source is registered under the **quota struct's module name**, as the
  string `Atom.to_string(MyApp.FooQuota)` (the registry atom is then the struct
  module itself). `Arbiter.Quota.Gate.Snapshot.normalize/2` looks a row's
  `__struct__` up in the registry, so a package that adds a provider with its
  own quota table needs no change to core to have its rows gated, projected by
  `Headroom` / `History`, and staleness-checked.

      {:quota_snapshot, Atom.to_string(MyApp.FooQuota), MyApp.FooQuota.Source}

  The three in-tree sources register through `Arbiter.Extensions.Core` the same
  way.
  """

  alias Arbiter.Quota.Gate.Snapshot

  @doc """
  Project `quota` (a row of the struct this source is registered for) onto
  `Arbiter.Quota.Gate.Snapshot`, or return `nil` to fail open. `opts` is what
  the caller passed to `Snapshot.normalize/2` (today only `:model`).
  """
  @callback normalize(quota :: struct(), opts :: keyword()) :: Snapshot.t() | nil
end
