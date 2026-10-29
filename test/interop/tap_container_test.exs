defmodule ExNet.Interop.TapContainerTest do
  @moduledoc """
  Runs `test/tap_test.exs` (the `:tap` tests) in the `ex-interop-tap` container with a TAP
  interface it creates itself (rootless podman, `--cap-add NET_ADMIN --device /dev/net/tun`;
  `label=disable` because SELinux hosts deny containers access to the tun device).
  The repository and its sibling path dependencies are mounted at `/work`; the compiled
  tree lives in the named volume `ex-net-tap-build`.
  """
  use ExUnit.Case, async: false

  @moduletag :tap_container
  @moduletag timeout: 900_000

  test "ExNet.Tap against a kernel TAP: ARP, ICMP echo, IGMP and the interface helpers" do
    Interop.Podman.require_image!("tap")
    root = Path.expand("../..", __DIR__)
    script = Path.join(__DIR__, "support/tap_container.sh")

    siblings =
      for dep <- ["exhdl", "ex_hdl_cores", "nx_fixed"],
          dir = Path.expand("../" <> dep, root),
          File.dir?(dir),
          arg <- ["-v", "#{dir}:/work/#{dep}:ro,z"],
          do: arg

    {out, status} =
      Interop.Podman.run(
        [
          "--network=none",
          "--security-opt=label=disable",
          "--cap-add=NET_ADMIN",
          "--device=/dev/net/tun",
          "-v",
          "#{root}:/work/ex_net:z"
        ] ++
          siblings ++
          [
            "-v",
            "ex-net-tap-build:/build",
            "-v",
            "#{script}:/tap_container.sh:ro,z",
            Interop.Podman.image("tap"),
            "sh",
            "/tap_container.sh"
          ]
      )

    assert status == 0, out
    assert out =~ ~r/\d+ tests?, 0 failures/
  end
end
