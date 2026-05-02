Watch the active session and advise on what the user is doing.

Steps:
1. Call focus_session() once to read the current session state. Note the returned byte_offset — this is your cursor.
2. Wait approximately 60 seconds.
3. Call read_session_since(byte_offset=<last_offset>) to fetch only new output.
   - If the response contains rewound: true, reset your cursor to 0 and call focus_session() to get a fresh view.
   - Update your cursor to the new byte_offset returned.
4. If there is new output, write a brief (1–3 line) summary of what the user did or what happened. Flag anything noteworthy:
   - Non-zero exit codes or error messages
   - Stack traces or panics
   - OOM / out-of-memory indicators
   - Suspicious high load, thrashing, or network errors
   - Anything that looks like it needs attention
   If there is nothing new or nothing interesting, stay silent — do not post an empty or "nothing happened" message.
5. Go to step 2.

Keep summaries short and factual. Avoid repeating what was already reported.
