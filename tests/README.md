# Tests

Headless test scenes. Each `tests/*.tscn` has a root `Node` script that runs in
`_ready()`, prints `PASS`/`FAIL` lines and quits with a non-zero exit code on
failure. They run as scenes (not `godot --script`) so autoloads (`Tuning`,
`Bindings`, `Game`) are registered.

```sh
tests/run_all.sh               # run everything
tests/run_all.sh combat        # run tests whose name contains "combat"
GODOT=/path/to/godot tests/run_all.sh
```

Adding a test: create `tests/<name>_test.gd` (extends Node) + a minimal
`tests/<name>_test.tscn` pointing at it. Drive matches deterministically with
`MatchDirector.auto_step = false` and `director.step()`; script inputs with an
`InputSource` subclass (see `scripted_input.gd`).
