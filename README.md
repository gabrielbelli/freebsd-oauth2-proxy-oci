# oauth2-proxy for FreeBSD, as an OCI image

[oauth2-proxy](https://github.com/oauth2-proxy/oauth2-proxy) built from the
FreeBSD `www/oauth2-proxy` package, on top of `freebsd/freebsd-runtime`, so it
can run in a FreeBSD jail under `podman` without pulling in a Linux userland.

```sh
podman pull ghcr.io/gabrielbelli/oauth2-proxy-freebsd:latest
```

Multi-architecture: `freebsd/amd64` and `freebsd/arm64`.

## Why

FreeBSD 14.2 added OCI-image support to `podman`, and jails can now run images
directly. The upstream oauth2-proxy images are Linux-only, so a FreeBSD host
either has to install the port into every jail by hand or run a Linux VM. This
publishes the FreeBSD package as an image instead: the same `pkg` bits the
ports tree ships, in a form `podman` can pull.

The image is the base runtime plus one static Go binary — no shell needed to
run it, no package manager at run time, no dependencies (the port declares
neither `RUN_DEPENDS` nor `LIB_DEPENDS`).

## It builds on Linux, without FreeBSD

The build has **no `RUN` instruction**, and that is the whole trick.

`RUN` would execute a binary inside the image, and a Linux kernel cannot
execute FreeBSD binaries — `binfmt_misc` plus `qemu-user` crosses
*architectures*, not *operating systems*. `FROM` and `COPY` execute nothing at
all: they only move bytes between layers. So if the package is unpacked
*before* the build, the image assembles on a stock `ubuntu-latest` runner in
seconds, for both architectures, with no FreeBSD VM anywhere in CI.

`fetch-pkg.sh` does the unpacking. A `.pkg` file is a zstd-compressed tar and
`pkg.freebsd.org` publishes a plain index, so resolving and extracting a
package is ordinary tar work that any host can do:

```mermaid
flowchart LR
    A["pkg.freebsd.org<br/>packagesite.pkg"] -->|"curl + tar"| B["index<br/>(JSON per line)"]
    B -->|"name → version,<br/>repopath, sum"| C["oauth2-proxy-*.pkg"]
    C -->|"blake2b<br/>+ z-base-32"| D{"checksum<br/>matches?"}
    D -->|no| E["abort"]
    D -->|yes| F["tar x --exclude '+*'<br/>→ rootfs/"]
    F -->|"COPY"| G["freebsd/freebsd-runtime<br/>+ oauth2-proxy"]
```

Two things the script refuses to paper over:

- **Dependencies.** It fetches exactly the package you name and does not
  resolve a graph. oauth2-proxy has no dependencies today; if that ever
  changes, the build **aborts** rather than shipping an image missing a shared
  library. (Verified: pointing it at `nginx` stops on `pcre2`.)
- **Checksums.** pkg's index `sum` field is `2$<digest>`, where the digest is
  **blake2b-512 in z-base-32** (alphabet `ybndrfg8ejkmcpqxot1uwisza345h769`,
  least-significant-bit-first within each byte) — not hex, which is the obvious
  wrong guess. The check is real and the build fails if it does not match.

### Building it yourself

```sh
./fetch-pkg.sh FreeBSD:15:amd64 oauth2-proxy rootfs
buildah bud --platform freebsd/amd64 -t oauth2-proxy-freebsd .
```

`docker buildx build --platform freebsd/amd64 ...` works too — verified on
macOS, producing an image whose config reads `Os=freebsd`, 22 MB over two
layers. Needs `curl`, `tar` and `python3` besides the builder.

## Running it

The image sets no configuration. Every flag is oauth2-proxy's own, so
[upstream's documentation](https://oauth2-proxy.github.io/oauth2-proxy/)
applies unchanged.

### Forward-auth (nginx `auth_request`)

nginx keeps serving the application and asks the proxy, per request, whether
the caller is signed in. One instance can serve any number of applications and
any number of hostnames, as long as they share a cookie domain.

```sh
podman run -d --name oauth2-proxy -p 4180:4180 \
  -e OAUTH2_PROXY_CLIENT_ID=... \
  -e OAUTH2_PROXY_CLIENT_SECRET=... \
  -e OAUTH2_PROXY_COOKIE_SECRET=... \
  ghcr.io/gabrielbelli/oauth2-proxy-freebsd:latest \
    --provider=google \
    --http-address=0.0.0.0:4180 \
    --email-domain=example.com \
    --cookie-domain=.example.com \
    --whitelist-domain=.example.com \
    --reverse-proxy \
    --set-xauthrequest \
    --upstream=static://202
```

`--upstream=static://202` is what makes it auth-only: it never proxies
anything, it only answers "yes" or "no" at `/oauth2/auth`.

### Full proxy

Drop `--upstream=static://202` and point `--upstream` at the application. In
this mode the proxy sits in front of one upstream, so a second application on a
different hostname needs a second instance.

### Configuration file instead of flags

The package's sample config is at `/usr/local/etc/oauth2-proxy.cfg.sample`
inside the image. Mount your own and pass `--config`:

```sh
podman run -d -p 4180:4180 \
  -v /usr/local/etc/oauth2-proxy.cfg:/usr/local/etc/oauth2-proxy.cfg:ro \
  ghcr.io/gabrielbelli/oauth2-proxy-freebsd:latest --config=/usr/local/etc/oauth2-proxy.cfg
```

Secrets belong in the config file or in environment files, not on the command
line — `podman inspect` and the process table both show arguments.

The container runs as `www` (uid 80), the same account the FreeBSD rc script
uses, and listens on 4180.

### Health checking

The image deliberately carries no built-in healthcheck: the OCI image spec has
no field for one, so anything declared in the Containerfile is dropped on
publish. Pass it at run time:

```sh
podman run --health-cmd "/usr/bin/fetch -qo /dev/null http://127.0.0.1:4180/ping" \
           --health-interval 30s --health-retries 3 ...
```

`/ping` answers 200 without authentication, and `fetch(1)` is already in the
base image.

## Tags and updates

| Tag | Meaning |
|---|---|
| `latest` | Newest build from `main`. |
| `7.15.3_2` | The exact FreeBSD package version, including `PORTREVISION`. |
| `7.15.3_2-amd64` | Single-architecture image, if you need to pin one. |

The version tag carries the package revision (`_2`) deliberately. FreeBSD's Go
team bumps `PORTREVISION` and rebuilds every Go port whenever the toolchain
moves — the application version does not change, but the binary does, and those
rebuilds are usually where a Go runtime security fix arrives. CI rebuilds
weekly for the same reason.

Port health, as of the last check: `www/oauth2-proxy` tracked upstream 7.15.1
and 7.15.2 within **three days** each, and 7.15.3 within 24 days. It is
currently level with upstream.

## Licence

The build files in this repository are **BSD 2-Clause** — see [LICENSE](LICENSE).

oauth2-proxy itself is **MIT**, and the FreeBSD base runtime carries its own
licences; both are redistributed unmodified as published by their projects.
This repository packages them, it does not fork them.
