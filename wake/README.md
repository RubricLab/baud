# wake

baud's wake relay. Only Apple can wake a sleeping iPhone, so a friend's device that can't reach
your phone hands this relay the sealed ticket your phone gave it, and the relay asks Apple to wake
the phone. That's all it does.

It has no accounts, no database and no request log, and it never sees a message. It opens the
ticket for the push token inside, checks the ticket's expiry and the rate limits, sends Apple the
same content-free push it sends everyone, and forgets. Its limits live in memory and die with the
process. [docs/protocol.md](../docs/protocol.md#waking-an-iphone) explains where it fits.

```text
POST /v1/wake   {"ticket": base64url, "kind": "message" | "call"}
                202 sent (or folded into a wake just sent)
                400 not a ticket · 403 the ticket doesn't allow that kind
                410 expired, unknown key, or the phone's gone: ask it for a fresh one
                413 too big · 429 too many · 503 Apple unavailable
GET  /v1/key    {"id": 1, "key": base64url}: the key tickets are sealed to (pinned in the app)
GET  /health    ok
```

## Run it

```sh
cargo test
cargo run -- keygen    # a new key pair: WAKE_KEYS for the relay, the public key for the apps
```

| Variable | |
| --- | --- |
| `WAKE_KEYS` | `1:<base64 private key>`, comma-separated; the highest id is current, older ones still open old tickets |
| `APNS_KEY` | the APNs auth key (`.p8` PEM) |
| `APNS_KEY_ID`, `APNS_TEAM_ID` | its key id and your Apple team id |
| `APNS_TOPIC` | the iPhone app's bundle id |
| `PORT` | default 8080 |

The [Dockerfile](Dockerfile) builds one static binary on a distroless image, with Apple's roots
of trust compiled in.
