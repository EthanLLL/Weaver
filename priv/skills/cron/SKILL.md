---
name: cron
description: Schedule, list or delete Weaver's timed prompts — a fixed message submitted to a session at cron times, like the user typing it. Use when the user wants something done on a schedule or reminded later ("每天早上", "每周一", "定时", "提醒我", "every morning", "cron", "定时任务"), or asks what is scheduled.
---

# cron: scheduled prompts in Weaver

At each match of a cron expression, Weaver submits a fixed prompt to one of
this tenant's sessions. The reply lands in that session like any other turn,
marked ⏰ cron. Jobs are kept by Weaver, not in this VM, and fire even when
nobody has Weaver open: Weaver starts the session for it.

## Calling it

```sh
weaver cron.add - <<'EOF'
{"name": "Morning news", "cron": "0 1 * * *", "target": "a_xxx",
 "prompt": "The prompt, as it should arrive. JSON string: escape \" and newlines (\\n)."}
EOF
weaver cron.list
weaver cron.delete '{"id": "c_xxx"}'
```

For a long or multi-line prompt, build the JSON with Python instead of by
hand:

```sh
python3 - <<'EOF' | weaver cron.add -
import json
prompt = """The prompt, verbatim,
over as many lines as it needs."""
print(json.dumps({"name": "Weekly report", "cron": "0 1 * * MON", "target": "a_xxx", "prompt": prompt}))
EOF
```

`cron.add` prints the job with `next_at` (first fire, UTC); exit code 1 and a
reason on stderr if it was refused.

## Fields

- `cron`: five fields (minute hour day month weekday), **always UTC**. `*`,
  `a,b`, `a-b`, `*/n`, `a-b/n`, and names like `MON`, `JAN`. No `@daily`, no
  seconds. With both day and weekday set, either one matching fires.
- `target`: the id of an existing session. Find it by title with
  `weaver sessions.list`; your own is in your instructions. If it is unclear
  which session ("this one", "here"), confirm the title with the user.
- `name`: optional; defaults to the prompt's first line.
- `prompt`: what the target sees when it fires, with none of this
  conversation around it; write it to stand on its own.

## Time zones

The user speaks local time; cron is UTC. Convert it yourself (Beijing = UTC+8,
no DST: 9:00 there is `0 1 * * *`, and a weekday can shift across midnight). If
the zone is unclear, ask. After adding, tell the user the next fire time back
in their own zone so they can check it.

## Behaviour

- A fire missed while Weaver was down is skipped, not caught up.
- A busy target gets the prompt like a typed message: steered into the running
  turn, or queued.
- Deleting the target session leaves the job; it records `last_error` until
  deleted.
- `/cron` typed in any session lists every job.

## Waiting on long work

For work that runs for hours outside this conversation (a benchmark, a batch
job, a remote build), don't rely on background-task notifications: they die
with the backend process, which Weaver releases when idle. Add a job targeting
your own session whose prompt says it is a cron check-in, how to check
progress, what to do when done (report, clean up), and to delete this job
(give its id) once finished.
