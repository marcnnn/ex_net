#!/bin/sh
# Runs inside the ex-interop-tap container: a TAP interface with 10.0.0.1/24, then the :tap tests
# (test/tap_test.exs) on it. The kernel is the one of the host, the network namespace is the container's.
set -e
ip tuntap add dev tap0 mode tap
ip addr add 10.0.0.1/24 dev tap0
ip link set tap0 up
cd /work/ex_net
export EX_NET_TAP=tap0 MIX_BUILD_PATH=/build
mix test --only tap test/tap_test.exs
