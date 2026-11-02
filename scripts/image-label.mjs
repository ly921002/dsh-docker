#!/usr/bin/env node
/**
 * Inspect a published OCI/Docker image without pulling it.
 *
 *   node scripts/image-label.mjs ghcr.io/OWNER/IMAGE:TAG io.dsh.dsh-version
 *   node scripts/image-label.mjs --tags ghcr.io/OWNER/IMAGE
 *
 * `--tags` lists the repository's tags, one per line (useful for rollback).
 * Otherwise it prints one label value (empty output + exit 0 when the label is
 * absent) and exits non-zero only when the registry itself could not be read.
 *
 * Why this exists instead of `docker buildx imagetools inspect --format ...`:
 * multi-arch images are published as an *index* (manifest list), and an index
 * has no `config` object at all. Reaching a label therefore means walking
 * index -> platform manifest -> config blob. Doing that here keeps the workflow
 * readable and makes the lookup testable on any machine with node, with no
 * Docker daemon involved.
 *
 * Auth: GHCR issues an anonymous pull token for public packages. For private
 * ones, set GHCR_USER + GHCR_TOKEN (any token with read:packages); they are
 * used as basic auth when exchanging for the pull token.
 */

const argv = process.argv.slice(2);
const tagsMode = argv[0] === '--tags';
const ref = tagsMode ? argv[1] : argv[0];
const label = tagsMode ? null : argv[1];

if (!ref || (!tagsMode && !label)) {
  console.error('usage: node scripts/image-label.mjs <registry/repo:tag> <label>');
  console.error('       node scripts/image-label.mjs --tags <registry/repo>');
  process.exit(2);
}

const INDEX_ACCEPT = [
  'application/vnd.oci.image.index.v1+json',
  'application/vnd.docker.distribution.manifest.list.v2+json',
].join(', ');

const MANIFEST_ACCEPT = [
  'application/vnd.oci.image.manifest.v1+json',
  'application/vnd.docker.distribution.manifest.v2+json',
].join(', ');

/** Split `registry/repo:tag` into registry, repo and tag. */
function parseRef(value) {
  const slash = value.indexOf('/');
  if (slash === -1) throw new Error(`no registry in ${value}`);
  const registry = value.slice(0, slash);
  const rest = value.slice(slash + 1);
  const colon = rest.lastIndexOf(':');
  const repo = colon === -1 ? rest : rest.slice(0, colon);
  const tag = colon === -1 ? 'latest' : rest.slice(colon + 1);
  return { registry, repo, tag };
}

async function registryToken(registry, repo) {
  const url = `https://${registry}/token?scope=repository:${repo}:pull&service=${registry}`;
  const headers = {};
  if (process.env.GHCR_TOKEN && process.env.GHCR_USER) {
    const basic = Buffer.from(
      `${process.env.GHCR_USER}:${process.env.GHCR_TOKEN}`,
      'utf8',
    ).toString('base64');
    headers.Authorization = `Basic ${basic}`;
  }
  const res = await fetch(url, { headers });
  if (!res.ok) throw new Error(`token request failed: ${res.status} ${res.statusText}`);
  const body = await res.json();
  if (!body.token) throw new Error('token response carried no token');
  return body.token;
}

async function getJson(url, token, accept) {
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}`, Accept: accept },
  });
  if (!res.ok) throw new Error(`GET ${url} -> ${res.status} ${res.statusText}`);
  return res.json();
}

async function main() {
  const { registry, repo, tag } = parseRef(ref);
  const token = await registryToken(registry, repo);
  const base = `https://${registry}/v2/${repo}`;

  if (tagsMode) {
    const body = await getJson(`${base}/tags/list`, token, 'application/json');
    return (body.tags ?? []).join('\n');
  }

  let manifest = await getJson(`${base}/manifests/${tag}`, token, INDEX_ACCEPT);

  // An index lists per-platform manifests; any of them carries the same
  // labels, so the first entry is enough.
  if (Array.isArray(manifest.manifests) && manifest.manifests.length > 0) {
    const digest = manifest.manifests[0].digest;
    manifest = await getJson(`${base}/manifests/${digest}`, token, MANIFEST_ACCEPT);
  }

  const configDigest = manifest?.config?.digest;
  if (!configDigest) {
    // Single-arch images store the labels inline in the manifest blob.
    const inline = manifest?.config?.Labels ?? manifest?.config?.labels;
    if (inline) return inline[label] ?? '';
    throw new Error('manifest carried neither a config digest nor inline labels');
  }

  const config = await getJson(`${base}/blobs/${configDigest}`, token, 'application/json');
  const labels = config?.config?.Labels ?? config?.config?.labels ?? {};
  return labels[label] ?? '';
}

main()
  .then((value) => {
    // Always succeed with an explicit newline so shell callers can use the
    // empty string as "label absent" without tripping `set -e`.
    process.stdout.write(`${value}\n`);
  })
  .catch((error) => {
    console.error(`image-label: ${error.message}`);
    process.exit(1);
  });
