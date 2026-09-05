# ReleaseMemory benchmark

This opt-in benchmark runs only in a disposable Windows GitHub Actions runner. It measures the application's own-process `ReleaseMemory` stages; it never invokes global cleaners or runs on a contributor's PC.

## CI-only quick path

1. Dispatch **Internal Memory Validation** with `run_benchmark=true`, or push a commit whose message contains `[benchmark]`.
2. Wait for the 17 safe native-memory tests to pass; only then can the benchmark job start.
3. Download the `release-memory-benchmark-*` artifact for `release-memory-raw.csv` and `release-memory-summary.json`.

Normal pushes skip the benchmark job.

## Method

Each variant (`None`, `GCOnly`, `TrimOnly`, and `Combined`) runs in a fresh NUnit process. The script uses a recorded seed to randomize variant order inside three blocks, with ten samples per invocation (30 samples per variant). Every sample retains a fixed 32 MiB allocation, creates bounded transient garbage, invokes the same internal GC and own-process working-set stages used by public `ReleaseMemory`, then touches retained pages to measure recovery work.

The raw CSV records process ID, runtime configuration, operation and process-CPU deltas, working-set and private-byte measurements, GC-count deltas, and recovery time. The script rejects skipped or failed operations, unexpected NUnit selection, malformed row counts, and non-finite metrics. Its summary contains metadata and medians only; it makes no causal or performance verdict.

## Limits and decision rule

This is a synthetic own-process measurement, not a user-experience benchmark. It does **not** claim CLR pause time, WPF/UI latency, hard faults, system-wide memory recovery, or an effect on other processes. Those require representative WPF scenarios and ETW-based evidence in future work.

Keep the production GC sequence until representative evidence demonstrates a safer change. Compare raw artifacts across equivalent runner images and runtime settings; do not infer a release decision from one benchmark run or from the median summary alone.
