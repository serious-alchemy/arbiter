defmodule Arbiter.SecretRefs.ExternalTest do
  use ExUnit.Case, async: false

  alias Arbiter.SecretRefs.External

  @stub Arbiter.SecretRefs.ExternalTest.HTTP

  @env_defaults [
    {"AWS_ACCESS_KEY_ID", "AKIDEXAMPLE"},
    {"AWS_SECRET_ACCESS_KEY", "secretexample"},
    {"AWS_SESSION_TOKEN", nil},
    {"AWS_REGION", "us-east-1"},
    {"AWS_DEFAULT_REGION", nil},
    {"AWS_ENDPOINT_URL", nil},
    {"AWS_ENDPOINT_URL_SECRETS_MANAGER", nil},
    {"AWS_ENDPOINT_URL_SSM", nil},
    {"AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", nil},
    {"AWS_CONTAINER_CREDENTIALS_FULL_URI", nil},
    {"AWS_EC2_METADATA_DISABLED", "true"},
    {"AWS_SHARED_CREDENTIALS_FILE", "/nonexistent/credentials"},
    {"ARBITER_SECRET_CACHE_TTL", nil}
  ]

  setup do
    prev = Application.get_env(:arbiter, External)
    Application.put_env(:arbiter, External, req_options: [plug: {Req.Test, @stub}, retry: false])

    saved = for {k, _} <- @env_defaults, do: {k, System.get_env(k)}

    for {k, v} <- @env_defaults do
      if v, do: System.put_env(k, v), else: System.delete_env(k)
    end

    # The application tree owns the cache table; start from an empty one.
    Arbiter.SecretRefs.Cache.clear()

    on_exit(fn ->
      Arbiter.SecretRefs.Cache.clear()

      if prev,
        do: Application.put_env(:arbiter, External, prev),
        else: Application.delete_env(:arbiter, External)

      for {k, v} <- saved do
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end
    end)

    :ok
  end

  describe "parse/1" do
    test "recognises the external schemes" do
      assert {:ok, %{scheme: :aws_sm, target: "prod/cloak", key: nil}} =
               External.parse("aws-sm:prod/cloak")

      assert {:ok, %{scheme: :aws_sm, target: "prod/app", key: "token"}} =
               External.parse("aws-sm:prod/app#token")

      assert {:ok, %{scheme: :aws_ssm, target: "/arbiter/key", key: nil}} =
               External.parse("aws-ssm:/arbiter/key")

      assert {:ok, %{scheme: :file, target: "/run/credentials/x", key: nil}} =
               External.parse("file:/run/credentials/x")
    end

    test "env:/secret:/literals are not external" do
      for ref <- ["env:X", "secret:k", "ghp_literal", "", nil, 5] do
        assert :error = External.parse(ref)
        refute External.external?(ref)
      end
    end

    test "an empty target is invalid" do
      assert :error = External.parse("aws-sm:")
      assert :error = External.parse("aws-sm:#key")
    end
  end

  describe "resolve/1 aws-sm" do
    test "fetches SecretString and signs the request" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.host == "secretsmanager.us-east-1.amazonaws.com"
        assert Plug.Conn.get_req_header(conn, "x-amz-target") == ["secretsmanager.GetSecretValue"]

        assert [<<"AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/", _::binary>>] =
                 Plug.Conn.get_req_header(conn, "authorization")

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"SecretId" => "prod/cloak"} = Jason.decode!(body)
        Req.Test.json(conn, %{"SecretString" => "s3cr3t-value"})
      end)

      assert {:ok, "s3cr3t-value"} = External.resolve("aws-sm:prod/cloak")
    end

    test "extracts a JSON key" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"SecretString" => Jason.encode!(%{"token" => "abc", "n" => 1})})
      end)

      assert {:ok, "abc"} = External.resolve("aws-sm:prod/app#token")
      assert {:error, {:json_key_missing, "nope"}} = External.resolve("aws-sm:prod/app#nope")
      assert {:error, {:json_key_missing, "n"}} = External.resolve("aws-sm:prod/app#n")
    end

    test "a non-JSON secret with a key is an error" do
      Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"SecretString" => "plain"}) end)
      assert {:error, :not_json} = External.resolve("aws-sm:prod/app#token")
    end

    test "takes the region from an ARN" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.host == "secretsmanager.eu-west-2.amazonaws.com"
        Req.Test.json(conn, %{"SecretString" => "v"})
      end)

      assert {:ok, "v"} =
               External.resolve(
                 "aws-sm:arn:aws:secretsmanager:eu-west-2:123456789012:secret:x-AbCdEf"
               )
    end

    test "an HTTP error never carries the response body" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/x-amz-json-1.1")
        |> Plug.Conn.send_resp(400, ~s({"__type":"ResourceNotFoundException","message":"nope"}))
      end)

      assert {:error, {:http, 400, "ResourceNotFoundException"}} =
               External.resolve("aws-sm:missing")
    end

    test "no credentials anywhere" do
      System.delete_env("AWS_ACCESS_KEY_ID")
      assert {:error, :no_aws_credentials} = External.resolve("aws-sm:x")
    end

    test "no region" do
      System.delete_env("AWS_REGION")
      assert {:error, :no_aws_region} = External.resolve("aws-sm:x")
    end
  end

  describe "resolve/1 aws-ssm" do
    test "fetches a decrypted parameter" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.host == "ssm.us-east-1.amazonaws.com"
        assert Plug.Conn.get_req_header(conn, "x-amz-target") == ["AmazonSSM.GetParameter"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"Name" => "/arbiter/skb", "WithDecryption" => true} = Jason.decode!(body)
        Req.Test.json(conn, %{"Parameter" => %{"Value" => "skb-value"}})
      end)

      assert {:ok, "skb-value"} = External.resolve("aws-ssm:/arbiter/skb")
    end
  end

  describe "resolve/1 file" do
    @describetag :tmp_dir

    test "reads and trims a trailing newline", %{tmp_dir: dir} do
      path = Path.join(dir, "cred")
      File.write!(path, "from-file\n")
      assert {:ok, "from-file"} = External.resolve("file:" <> path)
    end

    test "missing and empty files are errors", %{tmp_dir: dir} do
      assert {:error, {:file, :enoent}} = External.resolve("file:" <> Path.join(dir, "nope"))
      empty = Path.join(dir, "empty")
      File.write!(empty, "\n")
      assert {:error, :empty} = External.resolve("file:" <> empty)
    end
  end

  describe "caching" do
    test "serves from cache within the TTL and registers values for redaction" do
      counter = :counters.new(1, [])

      Req.Test.stub(@stub, fn conn ->
        :counters.add(counter, 1, 1)
        Req.Test.json(conn, %{"SecretString" => "cached-value"})
      end)

      assert {:ok, "cached-value"} = External.resolve("aws-sm:c")
      assert {:ok, "cached-value"} = External.resolve("aws-sm:c")
      assert :counters.get(counter, 1) == 1
      assert "cached-value" in External.cached_values()
      assert Arbiter.Redaction.redact("x cached-value y", []) == "x [REDACTED] y"
    end

    test "ARBITER_SECRET_CACHE_TTL=0 disables the cache" do
      System.put_env("ARBITER_SECRET_CACHE_TTL", "0")
      counter = :counters.new(1, [])

      Req.Test.stub(@stub, fn conn ->
        :counters.add(counter, 1, 1)
        Req.Test.json(conn, %{"SecretString" => "v"})
      end)

      External.resolve("aws-sm:c")
      External.resolve("aws-sm:c")
      assert :counters.get(counter, 1) == 2
    end

    test "serves the stale value when a refresh fails" do
      # An entry whose TTL has already elapsed.
      :ok = Arbiter.SecretRefs.Cache.put(External.cache_key("aws-sm:s"), "old", 0)
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)
      assert {:ok, "old"} = External.resolve("aws-sm:s")
    end
  end

  describe "env_or_ref/1" do
    setup do
      on_exit(fn ->
        System.delete_env("ZZ_SECRET")
        System.delete_env("ZZ_SECRET_REF")
      end)
    end

    test "inline value" do
      System.put_env("ZZ_SECRET", "inline")
      assert {:ok, "inline"} = External.env_or_ref("ZZ_SECRET")
    end

    test "unset" do
      assert :unset = External.env_or_ref("ZZ_SECRET")
    end

    test "the _REF pointer wins over an inline value" do
      System.put_env("ZZ_SECRET", "inline")
      System.put_env("ZZ_SECRET_REF", "aws-sm:zz")
      Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"SecretString" => "from-sm"}) end)
      assert {:ok, "from-sm"} = External.env_or_ref("ZZ_SECRET")
    end

    test "a failing pointer is an error, not a silent fallback" do
      System.put_env("ZZ_SECRET", "inline")
      System.put_env("ZZ_SECRET_REF", "aws-sm:zz")
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)
      assert {:error, "aws-sm:zz", {:http, 403, _}} = External.env_or_ref("ZZ_SECRET")
    end

    test "a non-external _REF value is rejected" do
      System.put_env("ZZ_SECRET_REF", "just-a-literal")
      assert {:error, "just-a-literal", :invalid_ref} = External.env_or_ref("ZZ_SECRET")
    end

    test "env_or_ref!/1 raises with the pointer but no value" do
      System.put_env("ZZ_SECRET_REF", "aws-sm:zz")
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 403, "") end)

      e = assert_raise RuntimeError, fn -> External.env_or_ref!("ZZ_SECRET") end
      assert e.message =~ "ZZ_SECRET_REF"
      assert e.message =~ "aws-sm:zz"
    end
  end
end
