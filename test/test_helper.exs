# :verilator - co-simulation, needs verilator in PATH
# :tshark / :tcpdump - independent dissection of generated pcaps
# :interop - runs real implementations in podman containers, `mix test --only interop`
# :resources - Yosys size budgets of the RTL designs (minutes); `mix test --include resources`
tools = [verilator: "verilator", tshark: "tshark", tcpdump: "tcpdump", yosys: "yosys"]
exclude = for {tag, exe} <- tools, is_nil(System.find_executable(exe)), do: {tag, true}
Code.require_file("interop/support/interop.ex", __DIR__)
ExUnit.start(exclude: [{:resources, true}, {:interop, true} | exclude])
