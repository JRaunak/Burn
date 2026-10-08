# Burn

Burn is a macOS menu-bar app that shows how much you've spent on Claude Code today, in USD. Click the total for a breakdown of today and this month by project, model, and main agent vs subagents. The history window filters by date range, project, model, and main agent vs subagents, has a daily cost chart split by model, and lists sessions (click a session ID to filter to it). Burn makes no network requests unless you turn on the Bedrock source, and it uses no AI tokens.

## Install

You need the Xcode Command Line Tools and macOS 14 or later. Burn has been built with Swift 6.4. Full Xcode and an Apple developer account aren't needed.

```sh
./build.sh           # builds release and writes an ad-hoc signed build/Burn.app
./build.sh install   # also copies it to ~/Applications/Burn.app and opens it
```

`install` quits a running Burn first. Because the app is built on your Mac it carries no quarantine attribute, so Gatekeeper doesn't block it.

Burn doesn't register itself to launch at login. Add it under System Settings > General > Login Items.

## How cost is computed

Claude Code transcripts and Bedrock logs record tokens, not dollars, so Burn prices each assistant message itself. Streaming writes the same `message.id` more than once while `output_tokens` grows, so Burn keeps one row per id with the largest `output_tokens`.

Prices come from `~/Library/Application Support/Burn/pricing.json`, in USD per million tokens with `input`, `output`, `cacheWrite`, and `cacheRead` per model. Open it from Settings with "Open pricing.json". Burn re-reads it when its modification time changes, which it checks on each refresh (new usage, opening the popover, or every 5 minutes). Model keys are matched after stripping region prefixes, `anthropic.`, `[1m]`, date suffixes, and `-v1:0`, so `us.anthropic.claude-haiku-4-5-20251001-v1:0` matches `claude-haiku-4-5`.

The bundled copy is only copied there on first run. Rebuilding Burn with a new `Resources/pricing.json` doesn't change the file you already have; edit it or delete it to get the new one.

The shipped prices were fitted from Claude Code's own cost-state records, so they match the cost in Claude Code's statusline. They are list prices. A model with no price (missing, or set to `null`) is never counted as $0: its tokens are reported as unpriced, the menu-bar total and session costs get a "+", and the popover names the models to add.

All cache writes are priced at the `cacheWrite` rate. 1-hour cache writes aren't priced separately.

## Sources

Pick a source in the popover or the history window. Burn never adds sources together, because Bedrock logs already include Claude Code's own calls.

### Claude Code transcripts (default)

Burn reads `~/.claude/projects/**/*.jsonl` and never writes to `~/.claude`. It watches the folder with FSEvents and reads only what was appended since the byte offset it stored for each file. Files under a `subagents/` folder, or messages marked as sidechain, count as subagent usage.

Claude Code deletes old transcripts after its retention period, so history from before Burn's first run is limited to what was still on disk. Rows already in Burn's database stay after the files are deleted. Calls Claude Code doesn't write to transcripts are missing.

### Bedrock invocation logs (opt-in, uses the network)

Turn on "Enabled" under Bedrock in Settings. Every 15 minutes Burn runs the installed `aws` CLI:

```sh
aws logs filter-log-events --log-group-name /aws/bedrock/modelinvocations \
  --filter-pattern '{ $.identity.arn = "*<identity>*" }' ...
```

The log group defaults to `/aws/bedrock/modelinvocations`. "Identity contains" is matched against `identity.arn`; "Detect" fills it from `aws sts get-caller-identity`. The AWS profile and region default to the `bedrock` block in `~/.claude/settings.json` if it has one, otherwise `default` and `us-east-1`. The first sync looks back 7 days (1 to 90 in Settings).

Burn looks for `aws` only at `/opt/homebrew/bin/aws`, `/usr/local/bin/aws`, and `/usr/bin/aws`. Your identity needs read access to the log group, and an admin has to have turned on Bedrock invocation logging to it.

The log records contain full prompts and responses. Burn keeps only the token counts and discards the rest. CloudWatch Logs may charge for `filter-log-events` calls; this hasn't been checked, so look at your AWS pricing.

### Claude Code telemetry (opt-in, localhost only)

Turn on "Listen on 127.0.0.1:4318" in Settings. Burn accepts OTLP http/json logs on that address and records the `cost_usd` of each `api_request` event, so this source uses Claude Code's own per-request cost rather than `pricing.json`. Burn doesn't change your Claude Code config. Add these to the `env` block of `~/.claude/settings.json` yourself:

```json
"env": {
  "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
  "OTEL_LOGS_EXPORTER": "otlp",
  "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
  "OTEL_EXPORTER_OTLP_ENDPOINT": "http://127.0.0.1:4318"
}
```

It covers only the time since telemetry was turned on. The field names come from the Claude Code monitoring docs and haven't been tested against a live export.

## Data and reset

Everything is stored in `~/Library/Application Support/Burn/usage.db`, a SQLite database with the tables `messages`, `sessions`, `prices`, `files`, and `state`.

"Re-read all transcripts" in Settings clears the stored file offsets and reads every transcript again. Existing rows are kept, so nothing is counted twice.

To start over, quit Burn and delete `usage.db` (and `usage.db-wal` and `usage.db-shm` if present). Burn rebuilds it from the transcripts still on disk. Usage from deleted transcripts and from the Bedrock and telemetry sources is lost.

## Check against your AWS bill

- Cross-region `us.` inference profiles may cost about 10% more than list price. The fitted table doesn't include that.
- Enterprise discounts aren't modelled.
- Sonnet 4.5 and Opus 5 ship unpriced.
- The Sonnet 5 price was fitted from a single record.
