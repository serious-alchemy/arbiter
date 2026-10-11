defmodule Arbiter.Machine.Sensors do
  @moduledoc """
  Best-effort, Linux-only readings of how hard this machine is working: the CPU
  package temperature, memory pressure (PSI) and `MemAvailable`. Shared by the
  node agent and the primary (`Arbiter.Machine.Monitor`), which feed them to
  `Arbiter.Machine.Derate`.

  Every reading is `nil` when it cannot be taken (no sensor, no `CONFIG_PSI`,
  not Linux, an unreadable or implausible value). **Unknown never derates**: a
  `nil` is carried through and the derate rule treats it as healthy.

  ## Temperature

    1. `/sys/class/hwmon/hwmon*` chips named `coretemp`, `k10temp` or `zenpower`:
       the hottest `temp*_input` whose label names the package (`Package id N`,
       `Tctl`, `Tdie`); a chip with no such label contributes the hottest of its
       inputs. Per-core and per-CCD sensors are not preferred over the package.
    2. Failing that, the hottest `/sys/class/thermal/thermal_zone*/temp` whose
       `type` looks like a CPU/package/SoC sensor (`x86_pkg_temp`, `acpitz`,
       `cpu-thermal`, …).

  Readings at or below 0 °C or at or above 150 °C are dropped as implausible
  (a broken sensor reports 0 or −273).

  ## Testing

  Every function takes `root:` (default `""`), a prefix put in front of the absolute `/sys` and `/proc`,
  so a fixture tree stands in for the kernel.
  """

  @type psi :: %{
          some_avg10: float(),
          some_avg60: float(),
          full_avg10: float(),
          full_avg60: float()
        }

  @type readings :: %{
          temp_c: float() | nil,
          psi: psi() | nil,
          mem_available: non_neg_integer() | nil
        }

  @cpu_chips ~w(coretemp k10temp zenpower)
  @package_label ~r/^(package id \d+|tctl|tdie)$/i
  @zone_type ~r/^(x86_pkg_temp|acpitz|cpu|soc|tcpu|k10temp|coretemp)/i
  @min_c 0.0
  @max_c 150.0

  @doc "All three readings; each is `nil` independently when unavailable."
  @spec read(keyword()) :: readings()
  def read(opts \\ []) do
    %{temp_c: temperature(opts), psi: psi(opts), mem_available: mem_available(opts)}
  end

  @doc "The CPU package temperature in °C, or `nil`."
  @spec temperature(keyword()) :: float() | nil
  def temperature(opts \\ []) do
    root = root(opts)
    hwmon_temp(root) || thermal_zone_temp(root)
  end

  @doc "Memory PSI (`/proc/pressure/memory`), or `nil`."
  @spec psi(keyword()) :: psi() | nil
  def psi(opts \\ []) do
    with {:ok, body} <- File.read(root(opts) <> "/proc/pressure/memory"),
         %{"some" => some, "full" => full} <- parse_psi(body),
         {:ok, s10} <- Map.fetch(some, "avg10"),
         {:ok, s60} <- Map.fetch(some, "avg60"),
         {:ok, f10} <- Map.fetch(full, "avg10"),
         {:ok, f60} <- Map.fetch(full, "avg60") do
      %{some_avg10: s10, some_avg60: s60, full_avg10: f10, full_avg60: f60}
    else
      _ -> nil
    end
  end

  @doc "`MemAvailable` in bytes, or `nil`."
  @spec mem_available(keyword()) :: non_neg_integer() | nil
  def mem_available(opts \\ []) do
    with {:ok, body} <- File.read(root(opts) <> "/proc/meminfo"),
         [_, kb] <- Regex.run(~r/^MemAvailable:\s+(\d+) kB/m, body) do
      String.to_integer(kb) * 1024
    else
      _ -> nil
    end
  end

  # ---- temperature ---------------------------------------------------------

  defp hwmon_temp(root) do
    root
    |> Kernel.<>("/sys/class/hwmon/hwmon*")
    |> Path.wildcard()
    |> Enum.filter(&(chip_name(&1) in @cpu_chips))
    |> Enum.flat_map(&chip_temps/1)
    |> max_or_nil()
  end

  defp chip_name(dir), do: read_trim(Path.join(dir, "name"))

  # The package-labelled inputs if the chip has any, else every input it has.
  defp chip_temps(dir) do
    inputs =
      for path <- Path.wildcard(Path.join(dir, "temp*_input")),
          temp = milli_c(path),
          temp != nil do
        label = path |> String.replace_suffix("_input", "_label") |> read_trim()
        {label, temp}
      end

    case Enum.filter(inputs, fn {label, _} -> label && Regex.match?(@package_label, label) end) do
      [] -> Enum.map(inputs, &elem(&1, 1))
      packages -> Enum.map(packages, &elem(&1, 1))
    end
  end

  defp thermal_zone_temp(root) do
    root
    |> Kernel.<>("/sys/class/thermal/thermal_zone*")
    |> Path.wildcard()
    |> Enum.filter(fn dir ->
      type = read_trim(Path.join(dir, "type"))
      type != nil and Regex.match?(@zone_type, type)
    end)
    |> Enum.map(&milli_c(Path.join(&1, "temp")))
    |> Enum.reject(&is_nil/1)
    |> max_or_nil()
  end

  defp milli_c(path) do
    with body when is_binary(body) <- read_trim(path),
         {milli, ""} <- Integer.parse(body),
         celsius = milli / 1000,
         true <- celsius > @min_c and celsius < @max_c do
      celsius
    else
      _ -> nil
    end
  end

  defp max_or_nil([]), do: nil
  defp max_or_nil(temps), do: Enum.max(temps)

  # ---- PSI -----------------------------------------------------------------

  defp parse_psi(body) do
    for line <- String.split(body, "\n", trim: true),
        [kind | fields] = String.split(line),
        kind in ["some", "full"],
        into: %{} do
      {kind,
       for(
         field <- fields,
         [key, value] <- [String.split(field, "=", parts: 2)],
         {number, _} <- [Float.parse(value)],
         into: %{},
         do: {key, number}
       )}
    end
  end

  defp read_trim(path) do
    case File.read(path) do
      {:ok, body} -> String.trim(body)
      _ -> nil
    end
  end

  defp root(opts), do: Keyword.get(opts, :root, "")
end
