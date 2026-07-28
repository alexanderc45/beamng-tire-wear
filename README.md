# Realistic Tire Wear — BeamNG.drive mod

Simulates progressive tire wear: friction/slip energy and temperature build up over
time, gradually reducing grip, and eventually the tire pops when a wear/overheat
threshold is crossed — like real life.

## Download

**[⬇ Download latest mod zip](https://github.com/alexanderc45/beamng-tire-wear/releases/latest/download/realistic_tire_wear.zip)**

That link always points at the newest build — re-download it any time a new version
is pushed.

## Install

1. Download `realistic_tire_wear.zip` from the link above.
2. Drop it (still zipped) into your BeamNG mods folder:
   `%LocalAppData%\BeamNG.drive\<version>\mods\` (Windows)
3. Launch BeamNG — the mod auto-loads on every vehicle.

## Repo layout

- `mod/` — the mod source (zipped as-is into the release artifact)
- `.github/workflows/release.yml` — builds the zip and updates the `latest` release on every push to `main`
