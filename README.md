# hq-booking-source

Corresponding source (AGPL-3.0, section 13) of the booking pages served at `rdv.gxb-advisory.com`.

- Upstream: [Tymeslot @ 0ae102c](https://github.com/Tymeslot/tymeslot/tree/0ae102c8f89f744f712e7139e72de7f6284b9179), image `luka1thb/tymeslot:1.15.7`.
- Our modifications (see also `facade-longpoll.md`): `preparer_correctifs.py` patches the upstream modules (booking lock, CalDAV checks, per-page sender identity); `pont_hq.ex` and `identites.ex` are added; `compiler.exs` and `Dockerfile.correctifs` rebuild the release.

Build: `python3 preparer_correctifs.py <tymeslot checkout at 0ae102c> build/sources`, copy `compiler.exs` and `Dockerfile.correctifs` into `build/`, then `docker build -f build/Dockerfile.correctifs build`.
