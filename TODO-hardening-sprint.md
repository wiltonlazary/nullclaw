# Hardening Sprint TODO

- [x] 1. Add real TTL to runtime-issued pairing bearer tokens and surface `expires_in` in `/pair`.
- [x] 2. Apply provider SSRF protections uniformly through `http_util` resolution/pinning.
- [x] 3. Warn loudly when WebChannel runs with `allowed_origins = []` in risky local/public setups.
