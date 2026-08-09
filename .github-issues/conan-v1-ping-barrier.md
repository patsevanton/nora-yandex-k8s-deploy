# Conan 2.x client cannot use NORA as a remote: v1 ping barrier (`GET /conan/v1/ping` not implemented)

## Summary

The Conan 2.x client cannot use NORA v1.1.0 as a Conan remote. Any remote pointing at NORA fails with `ERROR: b''` / `Unable to find ... in remotes`, because the Conan 2.x client always sends `GET /conan/v1/ping` as the first request to a remote, and NORA only implements `/conan/v2/*` (returning 404 for v1). The v2 API is fully functional via curl, so the only missing piece is the v1 ping endpoint.

This is a `good first issue`-sized gap: a single route returning 200 with one header would unblock the Conan 2.x client.

## Environment

- NORA: v1.1.0 (helm chart `nora/nora` v0.4.4), deployed in Kubernetes, S3 backend (Yandex Object Storage)
- Conan client: 2.31.1 (also reproduced with 2.x in general — behavior is in the client, not the distribution method: `pipx`, `pip`, Docker all behave the same)
- Deploy repo with full repro steps + logs: https://github.com/patsevanton/nora-yandex-k8s-deploy

## Steps to reproduce

1. Deploy NORA v1.1.0 with all registries enabled (`registries.enable: "all"`) and `anonymous_read: true` (Conan discovery does not send Authorization on ping). Let `$NORA` be the public base URL, e.g. `https://nora.<IP>.sslip.io`.
2. Add NORA as a Conan remote and try to search:

   ```bash
   conan remote remove nora 2>/dev/null
   conan remote add nora "https://$NORA/conan"
   conan search zlib -r nora
   ```

3. Observe the failure:

   ```
   Connecting to remote 'nora' anonymously
   nora
     ERROR: b''. [Remote: nora]
   ```

   `conan install --remote=nora`, `conan remote update conancenter --url=https://$NORA/conan` (ConanCenter override), and `CONAN_CENTER_URL` (which does **not** exist in Conan 2.31.1 — 0 matches in `site-packages/conan/`) all fail the same way.

## Expected behavior

The Conan 2.x client completes discovery and uses NORA's already-functional v2 endpoints for search/recipe/package download (proxy/cache of ConanCenter `center2.conan.io`).

## Actual behavior

The client stops at the v1 ping and never reaches a v2 endpoint.

## curl evidence: v2 API works, v1 ping is the only gap

Basic auth `token:<nora_token>`. All v2 calls return 200; the v1 ping returns 404.

```bash
# v2 ping — OK
curl -sS -u "token:$TOKEN" -o /dev/null -w "HTTP %{http_code}\n" "https://$NORA/conan/v2/ping"
# HTTP 200

# v2 search — OK (real versions from ConanCenter proxy)
curl -sS -u "token:$TOKEN" "https://$NORA/conan/v2/conans/search?q=zlib"
# {"results":["zlib/1.2.11@_/_","zlib/1.2.12@_/_","zlib/1.2.13@_/_","zlib/1.3.1@_/_","zlib/1.3.2@_/_","zlib/1.3@_/"]}

# v2 latest recipe revision — OK
curl -sS -u "token:$TOKEN" "https://$NORA/conan/v2/conans/zlib/1.3.1/_/_/latest"
# {"revision":"cac0f6daea041b0ccf42934163defb20","time":"2025-12-09T12:51:39.337+0000"}

# v2 recipe revision list — OK
curl -sS -u "token:$TOKEN" "https://$NORA/conan/v2/conans/zlib/1.3.1/_/_/revisions"
# {"revisions":[...4 revisions...]}

# v2 recipe files — OK
curl -sS -u "token:$TOKEN" "https://$NORA/conan/v2/conans/zlib/1.3.1/_/_/revisions/cac0f6daea041b0ccf42934163defb20/files"
# {"files":{"conanfile.py":{},"conanmanifest.txt":{},"conan_export.tgz":{},"conan_sources.tgz":{}}}

# v2 download conanfile.py — OK (4160 bytes, real conanfile.py)
curl -sS -u "token:$TOKEN" -o conanfile.py \
  "https://$NORA/conan/v2/conans/zlib/1.3.1/_/_/revisions/cac0f6daea041b0ccf42934163defb20/files/conanfile.py"
# HTTP 200, 4160 bytes

# v1 ping — the gap
curl -sS -u "token:$TOKEN" -o /dev/null -w "HTTP %{http_code}\n" "https://$NORA/conan/v1/ping"
# HTTP 404
```

Source confirmation (`nora-registry/src/registry/conan.rs`, `pub fn routes`): all 10 routes are `get` and v2-only (`ping`, `search`, recipe/package file download, revisions, latest). There are no `/conan/v1/*` routes, and no PUT/POST for publication.

## Technical root cause (Conan 2.31.1 client source)

Studied `site-packages/conan/` for Conan 2.31.1. The v1 ping is not a bug in the client — it is an intentional workaround that NORA does not satisfy:

1. **`ClientV2Router.ping()` returns a v1 URL.** In `client_routes.py:29-31`:
   ```python
   def ping(self, remote_url):
       # FIXME: The v2 ping is not returning capabilities
       return "%s/v1/ping" % remote_url
   ```
   The comment is Conan's own: v2 ping does not return the `X-Conan-Server-Capabilities` header, so discovery always goes through v1 ping. After a successful v1 ping, Conan uses **only** v2 endpoints (search, recipe, package — all via `base_url = {root}/v2/`). v1 is needed exclusively for ping.

2. **`server_capabilities()` requires the header.** In `rest_client_v2.py:126-141`, `server_capabilities()` reads the `X-Conan-Server-Capabilities` header from the ping response. No header → `ConanException "Remote doesn't seem like a valid Conan remote"`. Non-200 status → `_raise_exception_from_error`.

3. **`_get_api()` requires the `revisions` capability.** In `rest_client.py:31-40`, `_get_api()` checks for the `revisions` capability (`internal/__init__.py:4`, `REVISIONS = "revisions"`). Without it → `"The remote doesn't support revisions. Conan 2.0 is no longer compatible with remotes that don't accept revisions."`

4. **There is no "v2-only" flag.** Conan 2.x has no client-side flag to skip v1 ping — the workaround is hard-coded in `ClientV2Router.ping()`.

## Proposed fix

Implement a single route — `GET /conan/v1/ping` — returning `200` with header:

```
X-Conan-Server-Capabilities: revisions
```

This is the minimum sufficient to unblock the Conan 2.x client: after a successful v1 ping, all subsequent requests go to the already-implemented v2 endpoints. No v1 routes other than ping are needed (v2 covers search, recipe/package file download, revisions, latest).

The body can be empty or a minimal capabilities JSON; the client only inspects the header and status code.

### Scope explicitly out (separate concerns)

- **Publication (`conan upload`)**: NORA v1.1.0 has no PUT/POST for `/conan/v2/*`. This issue is only about unblocking the Conan 2.x client for **pull/proxy-cache**. Publication is a separate feature.
- **Full v1 API**: not needed. Only `GET /conan/v1/ping` is required; the rest of v1 is unused by Conan 2.x after ping.

## Impact

Without this endpoint, the Conan 2.x client cannot use NORA as a Conan remote at all — even though NORA's v2 API fully works as a ConanCenter proxy/cache (proven by curl). On an air-gapped/laptop-without-internet host, Conan cannot download packages through NORA and fails at the very first request. This makes the Conan format effectively unusable for the standard client workflow, despite the v2 backend being complete.
