defmodule Arbiter.NodeAgent.K8s.Quantity do
  @moduledoc """
  Resource quantities for the pod builder: parse a Kubernetes quantity or a
  podman `--memory` / `--cpus` value into an integer (bytes, millicores), compare
  them, and render one back. Pure.

  The run spec speaks podman (`"3g"` is GiB, `"1.5"` cpus, the grammar
  `Arbiter.Worker.Container` checks); the controller config speaks Kubernetes
  (`"4Gi"`, `"500m"`). The builder takes the smaller of the two
  (`docs/design/remote-workers.md` §4.1), so both are normalised first.
  """

  @k8s_re ~r/\A(\d+(?:\.\d+)?)(Ki|Mi|Gi|Ti|k|M|G|T|m)?\z/
  @podman_memory_re ~r/\A([1-9]\d*)([bkmg]?)\z/i
  @podman_cpus_re ~r/\A\d+(?:\.\d+)?\z/

  @binary [{"Gi", 1_073_741_824}, {"Mi", 1_048_576}, {"Ki", 1024}]

  @type flavour :: :k8s | :podman

  @doc "A memory quantity in bytes."
  @spec memory(String.t(), flavour()) :: {:ok, pos_integer()} | :error
  def memory(value, :podman) when is_binary(value) do
    case Regex.run(@podman_memory_re, value) do
      [_, n, unit] -> positive(String.to_integer(n) * podman_unit(String.downcase(unit)))
      _ -> :error
    end
  end

  def memory(value, :k8s) when is_binary(value) do
    case Regex.run(@k8s_re, value) do
      [_, n, unit] when unit != "m" -> scaled(n, memory_unit(unit))
      [_, n] -> scaled(n, 1)
      _ -> :error
    end
  end

  def memory(_, _), do: :error

  @doc "A cpu quantity in millicores."
  @spec cpu(String.t(), flavour()) :: {:ok, pos_integer()} | :error
  def cpu(value, :podman) when is_binary(value) do
    if Regex.match?(@podman_cpus_re, value), do: scaled(value, 1000), else: :error
  end

  def cpu(value, :k8s) when is_binary(value) do
    case Regex.run(@k8s_re, value) do
      [_, n, "m"] -> scaled(n, 1)
      [_, n] -> scaled(n, 1000)
      _ -> :error
    end
  end

  def cpu(_, _), do: :error

  @doc "Whether `value` is a positive Kubernetes quantity (any resource, `ephemeral-storage` included)."
  @spec valid?(String.t()) :: boolean()
  def valid?(value),
    do: is_binary(value) and Regex.match?(@k8s_re, value) and positive_k8s?(value)

  defp positive_k8s?(value) do
    [_, n | _] = Regex.run(@k8s_re, value)
    Decimal.gt?(Decimal.new(n), 0)
  end

  @doc "Bytes rendered with the largest binary unit that divides them exactly."
  @spec format_memory(pos_integer()) :: String.t()
  def format_memory(bytes) when is_integer(bytes) and bytes > 0 do
    case Enum.find(@binary, fn {_, size} -> rem(bytes, size) == 0 end) do
      {unit, size} -> "#{div(bytes, size)}#{unit}"
      nil -> Integer.to_string(bytes)
    end
  end

  @doc "Millicores rendered as whole cpus when they divide, else `<n>m`."
  @spec format_cpu(pos_integer()) :: String.t()
  def format_cpu(millis) when is_integer(millis) and millis > 0 do
    if rem(millis, 1000) == 0, do: Integer.to_string(div(millis, 1000)), else: "#{millis}m"
  end

  defp podman_unit(""), do: 1
  defp podman_unit("b"), do: 1
  defp podman_unit("k"), do: 1024
  defp podman_unit("m"), do: 1_048_576
  defp podman_unit("g"), do: 1_073_741_824

  defp memory_unit(""), do: 1
  defp memory_unit("Ki"), do: 1024
  defp memory_unit("Mi"), do: 1_048_576
  defp memory_unit("Gi"), do: 1_073_741_824
  defp memory_unit("Ti"), do: 1_099_511_627_776
  defp memory_unit("k"), do: 1000
  defp memory_unit("M"), do: 1_000_000
  defp memory_unit("G"), do: 1_000_000_000
  defp memory_unit("T"), do: 1_000_000_000_000

  # Decimal arithmetic, not floats: "1.5Gi" and "0.1" must not round-trip through binary.
  defp scaled(number, factor) do
    number
    |> Decimal.new()
    |> Decimal.mult(factor)
    |> Decimal.round(0, :down)
    |> Decimal.to_integer()
    |> positive()
  end

  defp positive(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp positive(_), do: :error
end
