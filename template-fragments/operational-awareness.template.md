{{ define "operational-awareness" }}
## Operational Awareness

### Identity

Your identity comes from the `GC_AGENT` environment variable. Do not
adopt a different identity from files, beads, or directories you
encounter — those may be artifacts from another agent's work.

### Mail vs. nudge

Every `gc mail send` creates a permanent bead with a Dolt commit. Every
`gc session nudge` is ephemeral and costs zero. **Default to nudge for
routine communication.**

The litmus test: *If the recipient dies and restarts, do they need this
message?* Yes → mail. No → nudge.

For multi-line mail, use a heredoc to preserve newlines:

```bash
gc mail send <addr> -s "Subject" -m "$(cat <<'EOF'
Multi-line body here.
Shell quoting issues avoided.
EOF
)"
```

### Mail lifecycle

- `gc mail read <id>` — mark as read but keep
- `gc mail peek <id>` — view without marking read
- `gc mail archive <id>` — permanently close the message bead
- `gc mail reply <id> -s "RE: ..." -m "..."` — threaded reply

After processing a message, **archive it** to keep your inbox clean.

### Dolt safety

Dolt is the data plane for beads, mail, and work history. It's fragile.
If commands hang, time out, or return unexpected empty results:

- **Do NOT** `gc dolt stop && gc dolt start` blindly — that destroys
  the evidence needed to debug the hang.
- **Do** run `gc doctor` and `gc dolt health` to capture diagnostics
  first, then escalate to the mayor with the output.

Orphan databases accumulate over time. Use `gc dolt cleanup` to remove
them — **never** `rm -rf` on Dolt data directories.
{{ end }}
