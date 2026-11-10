---
name: sessions
description: Run work in parallel as new Weaver sessions the user can watch in the sidebar — start one per task, hand each a prompt, check on them and collect their answers. Use when the user asks for parallel work ("并行", "同时跑", "开几个会话", "分头", "in parallel", "spawn sessions"), instead of background agents or background shell tasks.
---

# sessions: parallel work as Weaver sessions

Default to working in the foreground. When the user asks for parallel work, start
new Weaver sessions rather than background agents: they show up in the sidebar,
the user can read and steer them, and they outlive this turn. A background
agent or shell task does not — Weaver lets an idle backend go after its last
turn, and anything it was waiting on is lost.

The exception is a short subagent job run in the foreground, such as
transcribing a batch of images: it finishes within the turn, so nothing is
left waiting.

## Calling it

Sessions are reached with the `weaver` command, which calls Weaver from this
machine; it needs no credentials, since Weaver knows which machine is asking.
Arguments are one JSON object, inline or on stdin with `-`. Build it with
Python, so a long prompt needs no escaping by hand:

```sh
python3 - <<'PY' | weaver sessions.new -
import json
print(json.dumps({"title": "Short title", "prompt": """
The task, written to stand on its own.
"""}))
PY
# → {"id":"a_…"}

weaver sessions.status '{"id": "a_xxx"}'   # status: running, starting, idle, interrupted
weaver sessions.reply '{"id": "a_xxx"}'    # {"status": …, "reply": the newest reply or null}
weaver sessions.list                       # every session: id, title, directory, status
```

Also `sessions.submit` (`{"id", "text"}`, a follow-up message),
`sessions.interrupt` (`{"id"}`) and `sessions.delete` (`{"id"}`).

- `"backend"` in `sessions.new` is `"claude_code"` (the default) or `"codex"`,
  fixed for the session's life. Codex needs `codex` installed and configured
  on this machine.
- The new session knows nothing of this conversation: put the goal, inputs,
  paths, constraints and what "done" means in the prompt, and say where to
  write results (a file both can read beats parsing replies).
- Tell the user the titles you started. Each new session costs a fresh context
  (~20k tokens before it does anything), so start as many as the work needs.
- To wait for them, don't poll in a loop: check once when the user asks.
- `sessions.delete` discards one and its history (to the trash in
  `~/.loom/sessions/.trash/`); only when the user asks.
