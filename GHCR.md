## Using the published image

Instead of building locally, pull the image that GitHub Actions pushes to
ghcr.io on every push to `main`:

```bash
# log in once (any token with read:packages works, incl. a classic PAT)
echo "$CR_PAT" | docker login ghcr.io -u ly921002 --password-stdin

# pull
docker pull ghcr.io/ly921002/dsh-docker:latest
```

Tags published: `latest` (default branch), the branch name, the short commit
sha, and `v<version>` / `v<major>.<minor>` for `v*` tags. Pin the sha in
production if you want reproducible pulls.

On the Oracle VPS this replaces the `build:` section entirely:

```yaml
services:
  dsh:
    image: ghcr.io/ly921002/dsh-docker:latest
    # ... same environment / volumes / ports as before
```

Everything else in this repo (compose file, entrypoint, nginx config, DEPLOY.md)
is unchanged; the entrypoint is already baked into the image.

### Package visibility

ghcr.io creates new packages as **private**. After the first successful run,
open the package settings and make it public if you want anonymous pulls:

https://github.com/users/ly921002/packages/ghcr.io%2Fdsh-docker/settings
