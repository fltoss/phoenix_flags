# TODO

## Robustness

### Retry logic for seed_flags DB errors
If the database is temporarily unavailable during `seed_flags/1`, the current
code logs a warning and moves on. Consider a bounded retry (e.g. 3 attempts
with backoff) before giving up, so transient connection blips don't leave flags
out of sync.

### Cluster notification acknowledgment
`notify_peers/1` uses fire-and-forget `send/2`. For stronger consistency
guarantees, consider a `GenServer.call` with a short timeout, or at minimum
log when a peer node is unreachable.
