# 0001. Per-service volume mounted at `/data` (implements adr#0008)

- Status: accepted
- Date: 2026-08-10
- Relates-to: adr#0008

See the canonical decision and rationale in `/opt/adi/adr/0008-per-service-volume-standardized-data-mount.md`.

wifi-connect's reconnect-history cache (recording the last successful connection time per saved WiFi network, used to order periodic reconnect attempts) is hardcoded to `/data/reconnect-history.json` per this decision. The `/data` mount comes from a dedicated named volume declared for the wifi-connect service in `loci-on-balena`'s `docker-compose.yml` — see that repo's `docs/adr/0001-per-service-volume-standardized-data-mount.md`.
