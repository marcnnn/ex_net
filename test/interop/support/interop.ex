defmodule Interop.Podman do
  @moduledoc false
  # Thin wrapper around the podman CLI for the interop tests. Images are built
  # by containers/build.sh; a missing image fails the test with that hint.

  def image(name), do: "ex-interop-#{name}"

  def image?(name) do
    System.find_executable("podman") != nil and
      match?({_, 0}, System.cmd("podman", ["image", "exists", image(name)]))
  end

  def require_image!(name) do
    unless image?(name) do
      raise ExUnit.AssertionError,
        message: "podman image #{image(name)} missing, run containers/build.sh #{name}"
    end
  end

  @doc "Runs `podman run --rm` and returns `{output, status}` (stderr merged unless `stderr: false`)."
  def run(args, opts \\ []) do
    cmd_opts = if Keyword.get(opts, :stderr, true), do: [stderr_to_stdout: true], else: []
    System.cmd("podman", ["run", "--rm"] ++ args, cmd_opts)
  end
end

defmodule Interop.Tshark do
  @moduledoc false
  # Dissects frames with tshark in a container and returns one flat field map
  # per packet (every key of every layer, `--no-duplicate-keys` so repeated
  # fields are lists).

  # Wireshark expert severities: chat 0x200000, note 0x400000, warn 0x600000, error 0x800000
  @warn 0x00600000

  @doc "Writes frames as a classic pcap (little endian, microseconds, Ethernet)."
  def pcap(frames, linktype \\ 1) do
    recs =
      for {f, i} <- Enum.with_index(frames), into: <<>> do
        n = byte_size(f)
        <<1_700_000_000::little-32, i::little-32, n::little-32, n::little-32, f::binary>>
      end

    <<0xA1B2C3D4::little-32, 2::little-16, 4::little-16, 0::little-32, 0::little-32,
      65535::little-32, linktype::little-32, recs::binary>>
  end

  @doc """
  Dissects `frames` (binaries) in the tshark container. Options: `:dir` (a
  scratch directory), `:prefs` (extra `-o` strings), `:args` (extra tshark args).
  """
  def dissect(frames, opts \\ []) do
    Interop.Podman.require_image!("tshark")
    dir = Keyword.get_lazy(opts, :dir, &tmp_dir/0)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "in.pcap"), pcap(frames))
    dissect_file(dir, "in.pcap", opts)
  end

  @doc "Dissects `file` inside `dir` (mounted read only at /data)."
  def dissect_file(dir, file, opts \\ []) do
    Interop.Podman.require_image!("tshark")

    prefs =
      ["ip.check_checksum:TRUE", "udp.check_checksum:TRUE", "tcp.check_checksum:TRUE"] ++
        Keyword.get(opts, :prefs, [])

    args =
      ["--userns=keep-id", "-v", "#{Path.expand(dir)}:/data:ro,z", Interop.Podman.image("tshark")] ++
        ["-2", "-r", "/data/" <> file, "-n", "-T", "json", "--no-duplicate-keys"] ++
        Enum.flat_map(prefs, &["-o", &1]) ++ Keyword.get(opts, :args, [])

    {out, status} = Interop.Podman.run(args, stderr: false)
    if status != 0, do: raise("tshark failed (#{status}): #{out}")

    out
    |> JSON.decode!()
    |> Enum.map(fn %{"_source" => %{"layers" => layers}} -> flatten(layers) end)
  end

  @doc "A field of a packet as a string (first element if repeated), or nil."
  def get(pkt, key) do
    case Map.get(pkt, key) do
      [h | _] -> h
      v -> v
    end
  end

  @doc "All values of a field as a list."
  def all(pkt, key), do: pkt |> Map.get(key, []) |> List.wrap()

  @doc """
  Expert infos of warning severity or worse, and malformed markers. Messages matching
  a regex of `ignore` (known benign, stateful ones) are dropped.
  """
  def problems(pkt, ignore \\ []) do
    sev = all(pkt, "_ws.expert.severity")
    msgs = all(pkt, "_ws.expert.message")

    warn =
      for {s, m} <- Enum.zip(sev, msgs),
          String.to_integer(s) >= @warn,
          not Enum.any?(ignore, &Regex.match?(&1, m)),
          do: m

    malformed = if Map.has_key?(pkt, "_ws.malformed"), do: ["malformed"], else: []
    warn ++ malformed
  end

  @doc "Raises unless no packet has warnings, errors or malformed markers."
  def assert_clean(pkts, ignore \\ []) do
    bad =
      for {p, i} <- Enum.with_index(pkts), pr = problems(p, ignore), pr != [], do: {i, pr}

    if bad != [] do
      raise ExUnit.AssertionError, message: "tshark reports problems: #{inspect(bad)}"
    end

    :ok
  end

  def tmp_dir do
    d = Path.join(System.tmp_dir!(), "interop-#{System.unique_integer([:positive])}")
    File.mkdir_p!(d)
    d
  end

  defp flatten(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc -> add(acc, k, v) end)
  end

  defp add(acc, _k, v) when is_map(v),
    do: Map.merge(acc, flatten(v), fn _, a, b -> merge(a, b) end)

  defp add(acc, k, vs) when is_list(vs) do
    if Enum.any?(vs, &is_map/1),
      do: Enum.reduce(vs, acc, fn v, a -> add(a, k, v) end),
      else: Map.update(acc, k, vs, &merge(&1, vs))
  end

  defp add(acc, k, v), do: Map.update(acc, k, v, &merge(&1, v))

  defp merge(a, b), do: List.wrap(a) ++ List.wrap(b)
end

defmodule Interop.Captures do
  @moduledoc false
  # Sample captures from the Wireshark wiki, cached under the system temp dir
  # (never inside the repository). Anything that is not a classic little endian
  # microsecond pcap (pcapng, NetMon, gz, zip) is converted by the tshark container.
  # Tests skip with a message when the download fails.

  @base "https://wiki.wireshark.org/uploads/__moin_import__/attachments/SampleCaptures/"

  def cache_dir do
    d = Path.join(System.tmp_dir!(), "ex_interop_captures")
    File.mkdir_p!(d)
    d
  end

  @doc "Returns `{:ok, path_to_classic_pcap}` or `{:skip, reason}`. `name` is a file below SampleCaptures or a full URL."
  def fetch(name) do
    url = if String.starts_with?(name, "http"), do: name, else: @base <> name
    base = Path.basename(url)
    out = Path.join(cache_dir(), Path.rootname(Path.rootname(base, ".gz"), ".zip") <> ".pcap")

    cond do
      File.exists?(out) ->
        {:ok, out}

      true ->
        with {:ok, body} <- download(url),
             {:ok, body} <- unpack(base, body),
             do: convert(body, out)
    end
  end

  defp download(url) do
    tmp = Path.join(cache_dir(), "dl-#{System.unique_integer([:positive])}")

    with curl when curl != nil <- System.find_executable("curl"),
         {_, 0} <- System.cmd(curl, ["-sfL", "-m", "60", "-o", tmp, url], stderr_to_stdout: true) do
      {:ok, File.read!(tmp)} |> tap(fn _ -> File.rm(tmp) end)
    else
      _ -> {:skip, "cannot fetch #{url} (no network or no curl)"}
    end
  end

  defp unpack(base, body) do
    cond do
      String.ends_with?(base, ".gz") ->
        {:ok, :zlib.gunzip(body)}

      String.ends_with?(base, ".zip") ->
        {:ok, [{_, data} | _]} = :zip.unzip(body, [:memory])
        {:ok, data}

      true ->
        {:ok, body}
    end
  end

  # classic pcap, little endian, microseconds: use as is
  defp convert(<<0xA1B2C3D4::little-32, _::binary>> = body, out) do
    File.write!(out, body)
    {:ok, out}
  end

  defp convert(body, out) do
    unless Interop.Podman.image?("tshark"), do: throw({:skip, "tshark image missing"})
    dir = Interop.Tshark.tmp_dir()
    File.write!(Path.join(dir, "raw"), body)
    File.chmod!(dir, 0o777)

    {log, status} =
      Interop.Podman.run([
        "--userns=keep-id",
        "-v",
        "#{dir}:/data:z",
        Interop.Podman.image("tshark"),
        "-r",
        "/data/raw",
        "-F",
        "pcap",
        "-w",
        "/data/out.pcap"
      ])

    if status == 0 do
      File.cp!(Path.join(dir, "out.pcap"), out)
      {:ok, out}
    else
      {:skip, "tshark conversion failed: #{log}"}
    end
  catch
    {:skip, _} = s -> s
  end

  @doc "Frames of a classic little endian pcap as `{linktype, [binary]}`."
  def frames(path) do
    <<0xA1B2C3D4::little-32, _::binary-size(16), link::little-32, rest::binary>> =
      File.read!(path)

    {link, records(rest, [])}
  end

  defp records(<<_::64, n::little-32, _::32, f::binary-size(n), rest::binary>>, acc),
    do: records(rest, [f | acc])

  defp records(_, acc), do: Enum.reverse(acc)
end
