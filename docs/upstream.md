# Upstream Integration

SentinelFCC is based on:

- Repository: `https://github.com/flare-foundation/fce-extension-scaffold.git`
- Bootstrap commit: `f48cafb889441a62e47c083f4be8dd7d3f456f83`
- Read-only remote: `flare-upstream`

The push URL for `flare-upstream` is intentionally disabled to reduce accidental pushes.

## Sync procedure

```bash
git switch main
git fetch flare-upstream
git merge --ff-only flare-upstream/main
git push origin main

git switch develop
git merge main
git push origin develop
```

When upstream changes conflict with Sentinel protocol code, resolve them on a dedicated maintenance branch and run the complete verification suite before merging.
