# Documentation

## Use the released Mac app

- [English quick start](../README.md) / [中文快速开始](../README.zh-CN.md)
- [English manual](wiki.en.md) / [中文手册](wiki.md)
- [Release history](../CHANGELOG.md)

The repository-hosted manuals are the project's Wiki. A separate GitHub Wiki is
not maintained. Downloaded releases describe the features in their tagged source;
development documentation may describe features not yet released.

## Build and maintain

- [Release and verification procedure](releasing.md)
- [Runtime state contract](../CONTEXT.md)
- [Output recovery architecture decision](adr/0001-state-diff-driven-output-recovery.md)

Keep the runtime contract at its current path: release-tree validation requires
it. A future move must update all links and the validator together.

## Historical engineering evidence

- [Idle CPU and presentation lifecycle](engineering-logs/2026-07-22-idle-cpu.md)
- [Output recovery and diagnostic rotation](engineering-logs/2026-07-23-output-recovery.md)

Engineering records contain methods, limitations and design evidence. They are
not installation instructions or promises of current performance. Preserve
useful evidence and ADRs; keep one-time machine maintenance out of user-facing
release notes. New measurements should record commit, hardware, macOS, toolchain,
command, sample method and limitations.

## Development material

Windows synchronization, observers and calibration prototypes are experimental
work outside the v0.3.13 release. Their source and documentation must be reviewed
and included together before publication. A working-tree file is not necessarily
part of a Git commit or downloadable release. Do not publish local diagnostic
logs, recordings or private session data as part of a documentation cleanup.
