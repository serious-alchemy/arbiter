defmodule Arbiter.Machine.SensorsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Machine.Sensors

  @moduletag :tmp_dir

  defp write!(root, rel, body) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  describe "temperature (hwmon)" do
    test "reads the coretemp package sensor, not the per-core ones", %{tmp_dir: root} do
      write!(root, "sys/class/hwmon/hwmon3/name", "coretemp\n")
      write!(root, "sys/class/hwmon/hwmon3/temp1_label", "Package id 0\n")
      write!(root, "sys/class/hwmon/hwmon3/temp1_input", "88000\n")
      write!(root, "sys/class/hwmon/hwmon3/temp2_label", "Core 0\n")
      write!(root, "sys/class/hwmon/hwmon3/temp2_input", "91000\n")

      assert Sensors.temperature(root: root) == 88.0
    end

    test "k10temp: the hottest of Tctl/Tdie", %{tmp_dir: root} do
      write!(root, "sys/class/hwmon/hwmon1/name", "k10temp\n")
      write!(root, "sys/class/hwmon/hwmon1/temp1_label", "Tctl\n")
      write!(root, "sys/class/hwmon/hwmon1/temp1_input", "71500\n")
      write!(root, "sys/class/hwmon/hwmon1/temp2_label", "Tdie\n")
      write!(root, "sys/class/hwmon/hwmon1/temp2_input", "69000\n")

      assert Sensors.temperature(root: root) == 71.5
    end

    test "an unlabelled sensor on a CPU chip counts (max of its inputs)", %{tmp_dir: root} do
      write!(root, "sys/class/hwmon/hwmon0/name", "zenpower\n")
      write!(root, "sys/class/hwmon/hwmon0/temp1_input", "60000\n")
      write!(root, "sys/class/hwmon/hwmon0/temp2_input", "64000\n")

      assert Sensors.temperature(root: root) == 64.0
    end

    test "ignores hwmon chips that are not CPU sensors", %{tmp_dir: root} do
      write!(root, "sys/class/hwmon/hwmon0/name", "nvme\n")
      write!(root, "sys/class/hwmon/hwmon0/temp1_input", "99000\n")

      assert Sensors.temperature(root: root) == nil
    end

    test "drops implausible readings (0, negative, absurd)", %{tmp_dir: root} do
      write!(root, "sys/class/hwmon/hwmon0/name", "coretemp\n")
      write!(root, "sys/class/hwmon/hwmon0/temp1_label", "Package id 0\n")
      write!(root, "sys/class/hwmon/hwmon0/temp1_input", "-273150\n")

      assert Sensors.temperature(root: root) == nil
    end
  end

  describe "temperature (thermal_zone fallback)" do
    test "max over zones with a plausible type", %{tmp_dir: root} do
      write!(root, "sys/class/thermal/thermal_zone0/type", "acpitz\n")
      write!(root, "sys/class/thermal/thermal_zone0/temp", "55000\n")
      write!(root, "sys/class/thermal/thermal_zone1/type", "x86_pkg_temp\n")
      write!(root, "sys/class/thermal/thermal_zone1/temp", "83000\n")
      write!(root, "sys/class/thermal/thermal_zone2/type", "iwlwifi_1\n")
      write!(root, "sys/class/thermal/thermal_zone2/temp", "99000\n")

      assert Sensors.temperature(root: root) == 83.0
    end

    test "hwmon wins when both exist", %{tmp_dir: root} do
      write!(root, "sys/class/hwmon/hwmon0/name", "coretemp\n")
      write!(root, "sys/class/hwmon/hwmon0/temp1_label", "Package id 0\n")
      write!(root, "sys/class/hwmon/hwmon0/temp1_input", "70000\n")
      write!(root, "sys/class/thermal/thermal_zone1/type", "x86_pkg_temp\n")
      write!(root, "sys/class/thermal/thermal_zone1/temp", "90000\n")

      assert Sensors.temperature(root: root) == 70.0
    end

    test "no sensors at all is unknown, not zero", %{tmp_dir: root} do
      assert Sensors.temperature(root: root) == nil
    end

    test "garbage in the file is unknown", %{tmp_dir: root} do
      write!(root, "sys/class/thermal/thermal_zone0/type", "x86_pkg_temp\n")
      write!(root, "sys/class/thermal/thermal_zone0/temp", "n/a\n")

      assert Sensors.temperature(root: root) == nil
    end
  end

  describe "memory pressure" do
    test "parses PSI some/full avg10/avg60", %{tmp_dir: root} do
      write!(root, "proc/pressure/memory", """
      some avg10=12.50 avg60=3.25 avg300=0.40 total=123456
      full avg10=4.00 avg60=1.00 avg300=0.10 total=654321
      """)

      assert Sensors.psi(root: root) == %{
               some_avg10: 12.5,
               some_avg60: 3.25,
               full_avg10: 4.0,
               full_avg60: 1.0
             }
    end

    test "no PSI file (kernel without CONFIG_PSI) is unknown", %{tmp_dir: root} do
      assert Sensors.psi(root: root) == nil
    end

    test "reads MemAvailable in bytes", %{tmp_dir: root} do
      write!(root, "proc/meminfo", "MemTotal:       16000000 kB\nMemAvailable:    2048000 kB\n")
      assert Sensors.mem_available(root: root) == 2_048_000 * 1024
    end

    test "missing meminfo is unknown", %{tmp_dir: root} do
      assert Sensors.mem_available(root: root) == nil
    end
  end

  test "read/1 bundles all three, each independently unknown", %{tmp_dir: root} do
    write!(root, "proc/meminfo", "MemAvailable:    1024 kB\n")

    assert Sensors.read(root: root) == %{
             temp_c: nil,
             psi: nil,
             mem_available: 1024 * 1024
           }
  end

  # Regression: with the default root the paths must be the absolute /proc and /sys, not
  # relative to the working directory. The cwd is VM-wide, so it is never changed here; a
  # cwd-relative default would read nil where the real /proc exists.
  test "the default root reads the real /proc and /sys" do
    if File.exists?("/proc/meminfo") do
      assert is_integer(Sensors.mem_available())
    end

    if File.exists?("/proc/pressure/memory") do
      assert %{some_avg10: _} = Sensors.psi()
    end
  end
end
