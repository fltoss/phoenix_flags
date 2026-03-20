# TODO

## Performance

### Incremental cache update on single-entry writes
Currently `load_cache/1` does `repo.all(Entry)` after every `update_entry` call,
rebuilding the entire persistent_term map. For large flag tables this blocks the
GenServer unnecessarily. Instead, update only the changed key in the cached
`{values, entries}` tuple and skip the DB round-trip.

### Pre-compute flag ordering in init
`all_grouped/1` rebuilds the declaration-order index on every call via
`config.name.flags() |> Enum.with_index()`. This could be computed once in
`init/1` and stored alongside the config in persistent_term.

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

## Testing

### Concurrent seed tests
Add tests for two servers starting simultaneously against the same database,
verifying that `on_conflict: :nothing` correctly handles the race without
errors or data loss.

### Server init without DB
Test that the server handles a database connection failure during `init/1`
gracefully (e.g. crashes cleanly so the supervisor can retry).
