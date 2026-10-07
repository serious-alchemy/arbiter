defmodule Arbiter.NodeAgent.RetainedTest do
  @moduledoc "RW12: the on-disk retained state of a quiesced run (§10.4)."
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.{Config, Retained}

  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:put, conn.request_path, byte_size(body)})
      status = if File.exists?(Path.join(home, "reject")), do: 422, else: 200

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, "{}")
    end

    config = %Config{
      node_home: home,
      credential: "arbn_x.y",
      primary_url: "http://127.0.0.1:1",
      node_id: "n1",
      req_options: [plug: plug]
    }

    %{config: config, home: home}
  end

  defp seed(config, run, manifest_extra \\ %{}) do
    dir = Retained.dir(config, run)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "checkout.bundle"), "bundle")
    File.write!(Path.join(dir, "transcripts.tar.gz"), "tar")

    manifest =
      Map.merge(
        %{
          "run" => run,
          "task" => "bd-1",
          "checkout" => %{"bytes" => 6, "snapshot" => "s", "tip" => "t"},
          "transcripts" => %{"files" => 1, "bytes" => 3},
          "pulled" => false
        },
        manifest_extra
      )

    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(manifest))
    manifest
  end

  test "list reports the unpulled runs and nothing else", %{config: config} do
    seed(config, "r1")
    seed(config, "r2", %{"pulled" => true})
    File.mkdir_p!(Path.join([config.node_home, "runs", "r3"]))

    assert [%{"run" => "r1"}] = Retained.list(config)

    assert Retained.report(hd(Retained.list(config))) |> Map.keys() |> Enum.sort() ==
             ["checkout", "run", "task", "transcripts"]
  end

  test "pull uploads transcripts first, then the bundle, and marks the run pulled", %{
    config: config
  } do
    seed(config, "r1")

    assert {:ok, %{"transcripts" => "ok", "checkout" => "ok"}} = Retained.pull(config, "r1")
    # the order matters: the transcript must be in place before the checkout ingest answers
    assert {:messages,
            [{:put, "/nodes/runs/r1/transcripts", 3}, {:put, "/nodes/runs/r1/checkout", 6}]} =
             Process.info(self(), :messages)

    assert Retained.list(config) == []
    refute File.exists?(Path.join(Retained.dir(config, "r1"), "checkout.bundle"))
  end

  test "a refused upload leaves the run retained", %{config: config, home: home} do
    seed(config, "r1")
    File.write!(Path.join(home, "reject"), "")

    assert {:ok, %{"transcripts" => "failed: " <> _}} = Retained.pull(config, "r1")
    assert [%{"run" => "r1"}] = Retained.list(config)
    assert File.exists?(Path.join(Retained.dir(config, "r1"), "checkout.bundle"))
  end

  test "a part that could not be taken is reported, not uploaded", %{config: config} do
    seed(config, "r1", %{"checkout" => %{"error" => "veto"}, "transcripts" => nil})

    assert {:ok, %{"transcripts" => "none", "checkout" => "failed: veto"}} =
             Retained.pull(config, "r1")

    assert [_] = Retained.list(config)
  end

  test "an unknown run is not retained", %{config: config} do
    assert {:error, :not_retained} = Retained.pull(config, "nope")
    assert :error = Retained.fetch(config, "nope")
  end

  test "drop forgets the retained files", %{config: config} do
    seed(config, "r1")
    assert :ok = Retained.drop(config, "r1")
    assert Retained.list(config) == []
  end
end
