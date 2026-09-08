# FlagDash Ruby SDK

Feature flags, remote config, AI configs, translations and experiments for
Ruby 3.1+.

Standard library only — no runtime dependencies.

## Installation

```ruby
gem "flagdash"
```

Or straight from GitHub, pinned to an immutable tag:

```ruby
gem "flagdash", github: "flagdash/flagdash-ruby", tag: "v0.1.0"
```

## Quick start

```ruby
require "flagdash"

client = FlagDash::Client.new(sdk_key: ENV.fetch("FLAGDASH_SDK_KEY"))

if client.flag("checkout-v2", default: false, context: {user_id: "alice"})
  # new checkout
end

client.close
```

## API key tiers

The key decides which project and environment you read, and what you may
reach. There is no `environment` argument anywhere in this SDK — the key
carries it.

| Key | Prefix | Reaches |
|---|---|---|
| Client | `pk_` | Flag values and configs. Safe in a browser or mobile app. |
| Server | `sk_` | The above, plus targeting rules, translations and experiments. Keep it server-side. |

## Configuration

```ruby
client = FlagDash::Client.new(
  sdk_key:   ENV.fetch("FLAGDASH_SDK_KEY"),
  base_url:  "https://flagdash.io",  # self-hosted? point it here
  timeout:   5,                      # seconds per request
  cache_ttl: 60,                     # seconds; 0 disables caching
  region:    "eu-west-1",            # omit to auto-detect
  transport: nil                     # inject for tests
)
```

`region` is detected from `FLY_REGION`, `AWS_REGION` and friends when omitted,
so region-scoped targeting works with no wiring.

## Feature flags

```ruby
# One flag, with the fallback used whenever FlagDash cannot be reached.
client.flag("checkout-v2", default: false, context: {user_id: "alice"})

# Every flag for this context in one request.
client.all_flags(context: {user_id: "alice", country: "GB"})

# Why did it resolve that way?
detail = client.flag_detail("checkout-v2", context: {user_id: "alice"})
detail.value      # => true
detail.reason     # => "rule_match"
detail.variation  # => "treatment"

# Flag metadata without evaluating anything.
client.list_flags
```

### Context

Both shapes work. A nested `user:` hash is flattened — `id` becomes `user_id`
and every other key becomes `user_<key>`:

```ruby
client.flag("beta", context: {user_id: "alice", country: "GB"})
client.flag("beta", context: {user: {id: "alice", plan: "premium"}})
```

**Send an identifier** (`user_id`, `unit_id`, or `user: {id:}`) whenever you
want a stable answer. Percentage rollouts and A/B variations hash it, so an
anonymous context re-rolls on every call by design.

Note that `flag` without a context serves from the cached `all_flags` payload;
with a context it asks for a fresh evaluation.

## Remote config

```ruby
client.config("rate_limit", default: 100)
client.get_config("rate_limit")   # full record, not just the value
client.list_configs
```

## AI configs

Prompts, agents, skills and rules, versioned per environment and editable
without a deploy.

```ruby
client.ai_config("support-agent.md")
client.list_ai_configs(file_type: "agent")
client.list_ai_configs(folder: "support")   # :any for every folder
```

## Translations

```ruby
client.translation("checkout.greeting", locale: "fr", default: "Hello",
                   variables: {name: "Alice"})
```

The key is `namespace.message`. `{placeholders}` come from `variables`, and the
default is returned whenever the catalogue, namespace or message is missing — a
lookup never raises.

## Experiments

```ruby
assignment = client.experiment("checkout-redesign", context: {user_id: "alice"})

if assignment && assignment["variant"] == "treatment"
  # ...
end

client.track_experiment_metric(
  experiment_key: "checkout-redesign",
  event_name:     "purchase",
  user_id:        "alice",
  value:          42.50,
  properties:     {currency: "GBP"}
)
```

`experiment` returns `nil` for a context with no identifier — an assignment
that cannot be stable is worse than none.

Metrics are buffered in memory and only touch the network on `flush` or
`close`:

```ruby
client.flush  # send now
client.close  # flush and release the connection
```

In a long-running process call `flush` periodically; in a request/response
cycle, `close` at the end is enough.

## Caching

Reads are cached in memory for `cache_ttl` seconds (60 by default), so a burst
of `flag` calls costs one request.

```ruby
client.clear_cache
```

## Failure behaviour

This SDK deliberately splits the two cases:

- **Evaluation reads return your default.** `flag`, `config` and `translation`
  degrade to the fallback rather than raising, so an outage cannot take a
  request path down with it.
- **Metadata lists raise.** `list_flags`, `list_configs` and `list_ai_configs`
  are operational calls, and swallowing their failure would hide a bad key or a
  wrong base URL behind an empty array.

## Security

Keep the server key out of anything you ship to a browser or a phone. Grant a
key only the read scopes it needs; a client key never receives targeting rules,
so the client cannot see who else you are targeting.

## License

MIT
## Backend session replay

```ruby
replay = FlagDash::BackendReplay.new(sdk_key: ENV.fetch("FLAGDASH_REPLAY_KEY"), release: "2026.08")
if replay.start
  replay.event("checkout_started", attributes: {items: 2})
  replay.breadcrumb("payment requested")
  replay.stop
end
```

This records an explicit event timeline, never logs or request bodies automatically. Sensitive attribute keys are redacted. Use `context_headers` to propagate the opaque replay ID and a key scoped only to `replays:write`.

## AI releases

Create a release in **Manage → AI Releases**, select the environment, then set
a baseline, candidate and rollout. With your initialized client, evaluate it using
an environment-bound key with `ai_configs:read`:

```ruby
release = client.ai_config_release("support-agent", user_id: "usr_123")
```

The result includes `key`, `version`, `config`, `reason`, `variation_key`, and
`rollout_percentage` (idiomatic field names for typed SDKs). Pass a stable user
identity. Decisions are fetched afresh; verify baseline, rollout and paused
behavior in development before ramping production. Your backend calls the AI
provider. Ordinary evaluation leaves secret references unresolved; never put
provider credentials in a configuration delivered to browsers or mobile apps.
See the [release guide](../../docs/ai-config-releases.md) for lifecycle and cleanup.
