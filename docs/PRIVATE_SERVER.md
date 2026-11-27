# Private server

> Docs: [README](../README.md) · [INSTALL](INSTALL.md) · [ARCHITECTURE](ARCHITECTURE.md) · [ADMIN_GUIDE](ADMIN_GUIDE.md) · [PRIVATE_SERVER](PRIVATE_SERVER.md) · [AGENTS](../AGENTS.md)

This deployment is a **private server** for a small, trusted group: it talks to no other
Matrix server, every room is end-to-end encrypted, and as little as possible leaves the host.
This page lists every setting involved, what it changes, its trade-offs, and how to undo it.

The federation switch is a site setting (`FEDERATION_ENABLED` in `setup.config`, default
`true` for new installs, `false` here). The other settings are the project's defaults.

## Summary

| Setting | Where | Private value | Default for new installs |
| :--- | :--- | :--- | :--- |
| Federation | `FEDERATION_ENABLED` in `setup.config` → `conf.d/federation.yaml`, nginx, Element | off | on |
| Encrypt every new room | `encryption_enabled_by_default_for_room_type` (`homeserver.yaml`) | `all` | `all` |
| Push without message content | `push.include_content` (`homeserver.yaml`) | `false` | `false` |
| Profiles need sign-in | `require_auth_for_profile_requests` (`homeserver.yaml`) | `true` | `true` |
| Room directory not public | `allow_public_rooms_without_auth`, `allow_public_rooms_over_federation` | `false` | `false` |
| Element Web locked to this server | `disable_custom_urls`, `disable_guests`, `disable_3pid_login`, `room_directory`, no `jitsi` (`config.json`) | as listed | as listed |
| Invite-only registration | MAS `password_registration_token_required` + provider `registration_token_required`, `/register` invite page | on | on |
| No third-party services | no identity server, `trusted_key_servers: []`, `report_stats: false`, no integration manager / bug reports | — | — |

## Federation off

`FEDERATION_ENABLED="false"` makes `install.sh` render:

* `/etc/matrix-synapse/conf.d/federation.yaml` with `federation_domain_whitelist: []` —
  Synapse neither sends to nor accepts anything from another server ("Federation denied").
* nginx: `/.well-known/matrix/server`, `/_matrix/federation/*` and `/_matrix/key/*` return
  404 from outside. **One exception** stays open: `/_matrix/federation/v1/openid/userinfo`,
  which lk-jwt-service uses to validate MatrixRTC OpenID tokens on the legacy
  `/livekit/jwt/sfu/get` path. It only answers for a valid, short-lived token; without it
  that call path fails with `OpenIDUserInfo ... status=404`.
* Element Web: `default_federate: false` (new rooms are created local-only) and the room
  directory lists only this server.
* `monitor_services.sh` and `upgrade_services.sh --check` skip the federation probes.

**Pros**
* Nothing about your rooms — messages, membership, room names, read receipts, typing,
  presence, profile changes — is ever copied to another server.
* No unsolicited invites, DMs or spam from the wider Matrix network; nobody outside can
  look up your users.
* Smaller attack surface: the federation API is closed at nginx.

**Cons**
* Your users cannot talk to anyone on matrix.org or any other server, or join public rooms
  there (`#matrix:matrix.org` fails).
* Rooms created while federation is off carry `m.federate: false` in their creation event
  (Element's default here). Those rooms **can never be federated later**, even if you turn
  federation back on — only rooms created afterwards can.
* https://federationtester.matrix.org/ reports failures — expected.

**Undo**: set `FEDERATION_ENABLED="true"` in `setup.config`, delete
`/etc/matrix-synapse/conf.d/federation.yaml`, restore the nginx `.well-known/matrix/server`
location (or re-render with `./install.sh --render-only DIR` and copy the site file), set
`default_federate: true` in Element's `config.json`, restart `matrix-synapse` and reload nginx.

## Every new room is encrypted

`encryption_enabled_by_default_for_room_type: all` — Synapse adds `m.room.encryption` to every
new room, including public ones (Element alone only encrypts DMs and private rooms).

**Pros**
* Message content is unreadable to anyone with access to the server or its backups —
  including the admin.
* Nobody has to remember to turn encryption on.

**Cons**
* **Search**: Synapse cannot search encrypted messages. Element Desktop builds a local search
  index; Element Web and Element X only search what the device has loaded.
* **Link previews**: Element does not request server-side previews in encrypted rooms (the
  Maubot `urlpreview` plugin posts them instead).
* **Bots** must support encryption (Maubot does).
* **Lost keys = lost history**: users must set up key backup / recovery (Element prompts for
  it); QR sign-in hands keys to a new device automatically.
* Existing rooms keep their current state; encryption can be enabled per room
  (*Room settings → Security*) but never disabled.

**Undo**: `encryption_enabled_by_default_for_room_type: invite` (DMs and private rooms only —
Element's own default) or `off`; restart `matrix-synapse`.

## Push notifications without message content

`push.include_content: false` — the notification Synapse sends to the push gateway carries
only the event and room IDs, not the sender or text. The app wakes up, fetches the event from
this server and shows it.

**Pros**: no message text or sender names pass through Element's push gateway (matrix.org)
or Google/Apple. (In encrypted rooms the text is ciphertext anyway; this also covers names,
room names and unencrypted rooms.)

**Cons**: practically none — Element's apps already register their pushers with
`format: event_id_only` and fetch the event themselves. An app that cannot fetch at that moment
shows a generic "new message" notification.

**Undo**: `push: include_content: true`; restart `matrix-synapse`.

## Profiles only for signed-in users

`require_auth_for_profile_requests: true` — `/_matrix/client/v3/profile/<user>` requires a
signed-in user (otherwise `401`).

**Pros**: display names and avatars cannot be scraped by anyone who merely guesses user IDs.
**Cons**: none for a private server (all clients are signed in).
**Undo**: set to `false`; restart `matrix-synapse`.

Left as is, deliberately: `limit_profile_requests_to_users_who_share_rooms` (off) and the user
directory — every user can find every other user, which suits a group of friends.

## Element Web locked to this server

In `/var/www/element-web/config.json` (rendered by `install.sh`, preserved by upgrades):

| Key | Value | Effect |
| :--- | :--- | :--- |
| `disable_custom_urls` | `true` | The login screen cannot switch to another homeserver |
| `disable_guests` | `true` | No guest access |
| `disable_3pid_login` | `true` | No email/phone login options (there is no identity server) |
| `room_directory.servers` | this server only | *Explore rooms* never queries matrix.org |
| `default_federate` | `false` when federation is off | New rooms are local-only |
| `jitsi` | removed | No fallback to Element's Jitsi; all calls use your Element Call/LiveKit |

**Cons**: someone who also has an account elsewhere must use another client (or Element
Desktop/X) for it — this web client is for this server only.

## Already private before this page

* Registration is invite-only: MAS requires a registration token (from the `/register` page)
  for password **and** Google sign-up (`registration_token_required: true` on the provider —
  its default `false` would let anyone with a Google account register).
* No identity server (`vector.im` removed): no email/phone lookups leave the server.
* `trusted_key_servers: []`, `report_stats: false`, no integration manager, no bug-report
  upload, no analytics.
* The public room directory is not browsable without login or over federation.

## Deliberately unchanged

* **URL previews** stay on: Synapse fetches the link, so the linked site sees the server's
  IP, not the user's. Internal/private addresses are blocked (`url_preview_ip_range_blacklist`).
* **Presence, typing notifications, read receipts**: on (they never leave the server now).
* **Google sign-in** (upstream OAuth in MAS): Google learns who signs in, by design.
* **MAS consent screen** for third-party clients: the guard against web clients hosted by
  someone else (see [ARCHITECTURE → Trust boundaries](ARCHITECTURE.md#trust-boundaries--client-ips)).

## Verify

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://chat.example.com/.well-known/matrix/server        # 404
curl -s -o /dev/null -w '%{http_code}\n' https://chat.example.com/_matrix/federation/v1/version    # 404
curl -s -o /dev/null -w '%{http_code}\n' https://chat.example.com/_matrix/client/v3/profile/@u:chat.example.com  # 401
./upgrade_services.sh --check
```

Signed in, a lookup of a remote user returns `403 Federation denied`, and a newly created room
has an `m.room.encryption` state event.
