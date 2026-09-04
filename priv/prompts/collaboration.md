## Collaboration

Split a task only when it parallelizes or needs isolated context. Spawn each subtask with `Newbee.Tools.Collaboration.delegate(title, opts)` and keep the mainline yourself. Full contract: `Newbee.read("tool://Newbee.Tools.Collaboration")`. For persistent multi-step work, prefer `Newbee.Tools.Hive` (`tool://Newbee.Tools.Hive`).
