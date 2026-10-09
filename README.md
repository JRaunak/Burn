# Burn

Burn is a macOS menu-bar app that shows how much you've spent on Claude Code today, in USD. Click the total for a breakdown of today and this month by project, model, and main agent vs subagents. The history window filters by date range, project, model, and main agent vs subagents, has a daily cost chart split by model, and lists sessions (click a session ID to filter to it). Burn makes no network requests unless you turn on the Bedrock source, and it uses no AI tokens.

## Install

On an Apple Silicon Mac with macOS 14 or later:

```sh
curl -fsSL https://raw.githubusercontent.com/JRaunak/Burn/master/install.sh | bash
```

This downloads the latest release into `~/Applications/Burn.app` and opens it. Releases are ad-hoc signed, not notarized. Files fetched with `curl` don't get the quarantine attribute, so Gatekeeper doesn't block the app. Downloading the same archive in a browser does set it, and macOS will then refuse to open it.

To build from source instead, you need the Xcode Command Line Tools. Full Xcode and an Apple developer account aren't needed.

```sh
./build.sh           # builds release and writes an ad-hoc signed build/Burn.app
./build.sh install   # also copies it to ~/Applications/Burn.app and opens it
```

`install` quits a running Burn first.

The first time Burn runs from `/Applications` or `~/Applications`, it adds itself as a login item. macOS shows a notification when it does. Turn it off with "Open at login" in Burn's Settings, or under System Settings > General > Login Items. A managed Mac can block login items by policy; Settings shows the error if it does.

## Menu bar

The flame next to the total is monochrome while nothing is being spent. It turns terracotta while usage is landing, and stays that way until two minutes after the last spend. Each new charge plays one short flicker. Burn doesn't animate continuously, because on macOS 26 every status-item image change redraws the item on each menu bar, which cost about 8% CPU.

## Icon

`FlameGlyph.swift` draws both the menu-bar flame and the app icon. After changing it, run `scripts/make-icon.sh` to regenerate `Resources/Burn.icns` and the layers in `Resources/Burn.icon`.

`Burn.icon` is a Liquid Glass icon with light and dark appearances. Compiling it needs `actool` from full Xcode, so release builds use it and builds made with the Command Line Tools fall back to the dark `Burn.icns`.

## Releasing

Push a tag starting with `v`:

```sh
git tag v0.2
git push origin v0.2
```

`.github/workflows/release.yml` builds on a `macos-26` runner with Xcode 26.2, stamps the version from the tag, and attaches `Burn.tar.gz` to a GitHub release. `install.sh` always fetches the latest release.

## How cost is computed

Claude Code transcripts and Bedrock logs record tokens, not dollars, so Burn prices each assistant message itself. Streaming writes the same `message.id` more than once while `output_tokens` grows, so Burn keeps one row per id with the largest `output_tokens`.

Prices come from `~/Library/Application Support/Burn/pricing.json`, in USD per million tokens with `input`, `output`, `cacheWrite`, and `cacheRead` per model. Open it from Settings with "Open pricing.json". Burn re-reads it when its modification time changes, which it checks on each refresh (new usage, opening the popover, or every 5 minutes). Model keys are matched after stripping region prefixes, `anthropic.`, `[1m]`, date suffixes, and `-v1:0`, so `us.anthropic.claude-haiku-4-5-20251001-v1:0` matches `claude-haiku-4-5`.

The bundled copy is only copied there on first run. Rebuilding Burn with a new `Resources/pricing.json` doesn't change the file you already have; edit it or delete it to get the new one.

The shipped prices for Opus 5.5, Opus 4.8, Sonnet 5 and Haiku 4.5 were fitted from Claude Code's own cost-state records, so they match the cost in Claude Code's statusline. The rest come from Anthropic's pricing page, and the fitted ones match it too. All of them are list prices. Haiku 5.5 costs more for prompts over 100,000 tokens; an `above` block in `pricing.json` gives those prices, and Burn applies them per request using input plus cache tokens. A model with no price (missing, or set to `null`) is never counted as $0: its tokens are reported as unpriced, the menu-bar total and session costs get a "+", and the popover names the models to add.

Regional and US-only endpoints cost 10% more than list price, and Burn works out per message whether one was used:

- **Bedrock:** the inference profile prefix (`us.`, `eu.`, `apac.` and so on) versus `global.`. Transcripts only carry the short model name, so Burn learns the full profile IDs from `~/.claude/settings.json` (`model` and the `ANTHROPIC_*_MODEL` env vars) and from Claude Code's `cost-state` records.
- **Claude API:** `usage.inference_geo` set to `us`.
- **Vertex:** `CLOUD_ML_REGION` set to anything other than `global`.

The provider comes from the message ID (`msg_bdrk_`, `msg_vrtx_`, otherwise the Claude API). Those messages are charged `regionalPremium` (1.1) times the list price; set it to 1 to price everything at list. Settings lists the Bedrock profiles Burn found.

All cache writes are priced at the `cacheWrite` rate. 1-hour cache writes aren't priced separately.

## Sources

Pick a source in the popover or the history window. Burn never adds sources together, because Bedrock logs already include Claude Code's own calls.

### Claude Code transcripts (default)

Burn reads `~/.claude/projects/**/*.jsonl` and never writes to `~/.claude`. It watches the folder with FSEvents and reads only what was appended since the byte offset it stored for each file. Files under a `subagents/` folder, or messages marked as sidechain, count as subagent usage.

Claude Code deletes old transcripts after its retention period, so history from before Burn's first run is limited to what was still on disk. Rows already in Burn's database stay after the files are deleted. Calls Claude Code doesn't write to transcripts are missing, and they're real money. In one session Claude Code's own records counted 470,208 uncached Opus input tokens that its transcripts showed as 376, so Burn read about 18% under the statusline. The telemetry source receives those calls.

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

- Burn adds the 10% for Bedrock regional profiles such as `us.`, which Claude Code's own cost, and so its statusline, leaves out.
- Enterprise discounts aren't modelled.
- Bedrock is billed by AWS at its own published rates (https://aws.amazon.com/bedrock/pricing/), which Burn hasn't been checked against.
