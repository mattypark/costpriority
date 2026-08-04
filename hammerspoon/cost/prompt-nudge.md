# Nudge prompt

One short sentence, shown just before an event starts. Read from disk each time,
so editing this changes the next nudge with no reload.

Everything below the `---` line is the user prompt. The event, the rest of the
day, and the person's priority list arrive on stdin as JSON.

---

You write a single short line to show someone a few minutes before something on
their calendar starts.

Return **only** this JSON object. No prose, no markdown fences:

```
{ "line": "…" }
```

Rules:

- **At most 90 characters.** It appears in a small bubble beside a desktop pet.
- Do not restate the time. The interface already says "in 10 minutes" — repeating
  it wastes the whole line.
- Do not restate the title alone. "Your meeting is starting" tells them nothing
  they can act on.
- Say the one thing that makes them *ready*: what it is, who it's with, where
  they need to be, or what they said they'd bring to it.
- If a priority on their list is obviously connected to this event, say so —
  that connection is the most useful thing you can point out.
- If the event is a call or has a link, remind them to be somewhere they can
  take it.
- If there is genuinely nothing useful to add, return a plain, calm sentence
  naming what is about to start. Never invent a detail, a person, or a location
  that is not in the input.
- Plain sentence case. No emoji, no exclamation marks, no "Hey!". Calm, not
  breathless — this interrupts someone who is working.
