# Contributing to zcov

## Prerequisites

Zig nightly (`0.17.0-dev` or later). Check with:

```sh
zig version
```

## Building

```sh
git clone https://github.com/cloudcell/zcov
cd zcov
zig build
# Produces: zig-out/bin/zig-cov  and  zig-out/lib/zig-cov-rt.o
```

## Testing

```sh
zig build test   # run all unit tests
zig build bench  # run performance benchmarks
```

All tests must pass before submitting a PR. New behaviour must be covered by tests.

## Project structure

```
src/
├── main.zig                  CLI entry point
├── build_orchestrator.zig    Invokes zig build test with coverage flags
├── coverage.zig              Unified coverage data model
├── dwarf/
│   └── resolver.zig          Batch PC → file:line resolver (ELF + Mach-O)
├── report/
│   ├── lcov.zig              LCOV tracefile writer
│   └── summary.zig           Terminal table writer
├── runtime/
│   ├── sancov.zig            __sanitizer_cov_trace_pc_guard callbacks
│   └── zcov_format.zig       .zcov binary format read/write
└── bench.zig                 Synthetic performance benchmarks
```

## Code style

Follow the [Zig style guide](https://ziglang.org/documentation/master/#Style-Guide). Run `zig fmt` before committing:

```sh
zig fmt src/
```

## Submitting a PR

1. Fork the repo and create a branch from `main`
2. Make your changes with tests
3. Ensure `zig build test` passes
4. Open a pull request — describe what changed and why

## Reporting bugs

Use the [bug report template](https://github.com/cloudcell/zcov/issues/new?template=bug_report.yml).

## Performance

The sancov hot path has a ≤5 ns target. If your change touches `src/runtime/sancov.zig`, run `zig build bench` and include the output in your PR.
