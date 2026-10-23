#!/bin/sh
# Runs inside the ex-interop-nettools container (CAP_NET_ADMIN, CAP_NET_RAW).
# The Linux kernel talks over a veth pair, tcpdump on one end writes /out/cap.pcap:
# ARP requests (plain, 802.1Q vid 20, 802.1ad vid 30), UDP multicast (plain, tagged,
# with TTL 4), IGMPv3 membership reports for a join and the leave.
set -e
ip link add v0 type veth peer name v1
ip link set v0 up
ip link set v1 up
ip addr add 10.9.0.1/24 dev v0
ip addr add 10.9.0.2/24 dev v1
ip link add link v1 name v1.20 type vlan id 20
ip link add link v1 name v1.30 type vlan id 30 proto 802.1ad
ip link set v1.20 up
ip link set v1.30 up
ip addr add 10.20.0.2/24 dev v1.20
ip addr add 10.30.0.2/24 dev v1.30
# veth leaves partial (pseudo header only) checksums on transmit; make the kernel compute them
for d in v0 v1 v1.20 v1.30; do ethtool -K $d tx off >/dev/null 2>&1 || true; done
tcpdump -i v0 -U -s 0 -w /out/cap.pcap >/dev/null 2>&1 &
cap=$!
sleep 1
arping -c 1 -w 1 -I v1 10.9.0.77 >/dev/null 2>&1 || true
arping -c 1 -w 1 -I v1.20 10.20.0.77 >/dev/null 2>&1 || true
arping -c 1 -w 1 -I v1.30 10.30.0.77 >/dev/null 2>&1 || true
socat -u UDP4-RECV:5004,ip-add-membership=239.69.1.5:10.9.0.2 /dev/null &
rx=$!
sleep 1
for ifc in 10.9.0.2 10.20.0.2 10.30.0.2; do
  echo "interop $ifc" | socat -u - UDP4-DATAGRAM:239.69.1.1:5004,ip-multicast-if=$ifc,ip-multicast-ttl=4
done
sleep 1
kill $rx
sleep 2
kill $cap
sleep 1
chmod a+r /out/cap.pcap
