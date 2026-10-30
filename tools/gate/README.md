# Gate harness

`tools/gate/gate.sh HOST [profiles] [scenarios]` runs scripted sessions through a production host with the headless viewer
and prints one table: fps, motion fps, key-to-pixel latency, time to crisp, and the truth metric (partial frames, cells wrong
per frame, the longest a region stayed wrong, the first whole frame).

- **Profiles:** LAN (no shaping), cafe (5 Mbit/s down, 1 up, 40 ms, 0.5 % loss), 4G (Fast 4G), bus (Japan bus 4G). The host
  shapes the stream (the request's throttle), so one machine pair covers all four.
- **Cases:** connect (the first seconds), typing (`selecttype`: typing with select-all every 5 s), scroll, drag (the bench's
  title bar), and video (the bench started with `--motion`, measured idle).
- **Gate before a run:** the host unlocked and idle, nobody else connected, the "Mirage Test Bench" window open
  (experiments/testbench; the scenarios abort if focus leaves it). The person's OK for each live run.
- **Truth reference:** turned on for the run's own stream only (`--truth`: `truthReference` on the stream request), never in
  the host's tunables.json. It ends with the stream.
- **Lock and unlock:** by hand. Connect with `mirage-viewer HOST --headless --truth --duration 20` while the host is locked
  (capture-only), and for unlock, the person unlocks with Touch ID from their own viewer while the headless one runs. Then
  `truth` on that run's frames.
- **Modes:** run the same table with `wholeDisplayOnly` 0 and 1 (the host's tunables.json, the person's OK) to compare.
