# Pepper

Runtime control for iOS simulator apps. Dylib injected at launch via `DYLD_INSERT_LIBRARIES` — no source modifications needed.

```bash
make setup         # prereqs, deps, git hooks
make test-deploy   # build test app + inject Pepper
make ping          # verify
```

See `CLAUDE.md` for development docs.
