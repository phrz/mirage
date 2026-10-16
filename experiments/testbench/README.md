# testbench — a window to measure against

`make.sh` builds `.build/MirageTestBench.app`: one window titled "Mirage Test Bench", 1100×750 pt
near the top-left of the main display, holding a monospaced NSTextView with 600 lines of text,
caret at the end, focused. Copy it to the host and `open` it there (over SSH is fine: `open`
attaches to the logged-in GUI session). `mirage-viewer --headless --scenario typing:30|scroll:40|
drag:30|idle:20` finds the window in the host's window list and drives it with the same input
messages and local predictions the GUI would send: 6 keys/s into the text, 30 Hz wheel bursts
of 30 pt, title-bar drags of 6×3 px per 16 ms. The JSON gets `watchedKbps` (lossless bytes that
landed inside that window), `crispMs` per burst (last lossless tile touching the window after
the burst, provided no video touched it later), copy-rect and prediction counters.
