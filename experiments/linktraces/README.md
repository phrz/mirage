# linktraces — recorded real-world links, replayable on any Mac

`record.sh HOST MINUTES NAME` records ICMP RTT/loss at 5 Hz and a 1 MB scp throughput probe
each direction every 3 minutes into `NAME/`. `sudo replay.sh NAME TARGET_IP` replays it with
macOS dummynet (`dnctl` + `pfctl`), stepping delay, loss and bandwidth every 10 s, so a trace
taken on a moving bus becomes a repeatable test against loopback or a LAN host.

| trace | where | what it is |
|---|---|---|
| `2026-10-17-japan-bus-4g` | MacBook on a moving bus in rural Japan, one bar of 4G, to mac-daddy in Dallas over the tailnet | ~400 ms RTT, ~5 Mbps nominal, cellular handoffs and drop-outs |

`mirage-datagram-probe.raw` in a trace is the output of `mirage connect --interval 200` for the
same period: QUIC stream and datagram RTT/loss through Mirage's own transport, which on
cellular can differ from ICMP.
