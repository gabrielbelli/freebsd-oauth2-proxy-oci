# Running this on FreeBSD with podman

A walkthrough for standing up one shared authentication gateway on a FreeBSD
host. It assumes nothing beyond a working FreeBSD install.

Everything here is about the **gateway**. The applications behind it are
deployed separately and have their own lifecycles — that separation is the point
of a shared gateway, and mixing the two is how each application ends up with its
own session.

## Why there is no compose file

`podman-compose` is not packaged for FreeBSD, and `podman compose` is only a
shim that calls an external provider which is also not packaged. The built-in
option is `podman kube play`, which reads a Kubernetes pod manifest.

That sounds heavier than it is. You are using Kubernetes' *file format*, not
Kubernetes: one `kind: Pod`, a list of containers and a list of volumes. No
Deployment, no Service, no Ingress, no cluster. The manifest in
[`examples/oauth2-proxy.pod.yaml`](../examples/oauth2-proxy.pod.yaml) is about
forty lines once the commentary is stripped, and most of them are flags you
would have written on a command line anyway.

The mapping from compose, if that is the shape in your head:

| compose | pod manifest |
|---|---|
| `services:` (a map) | `spec.containers:` (a list) |
| `image: x` | `image: x` |
| `KEY: value` under `environment:` | `- {name: KEY, value: value}` under `env:` |
| `- vol:/path` under `volumes:` | `- {name: vol, mountPath: /path}` under `volumeMounts:` |
| `network_mode: host` | `spec.hostNetwork: true` |
| `restart: always` | `spec.restartPolicy: always` |

## 0. Use sh, not csh

root's login shell on FreeBSD is `csh`, which does not understand `$( )`,
`VAR=value command`, or `2>/dev/null`. Several commands below use them. Start
every session with:

```sh
sh
```

Skipping this produces errors that look like the command is missing rather than
the shell being wrong — `Command not found`, `Ambiguous output redirect`,
`Bad : modifier`.

## 1. Packages and layout

```sh
pkg install -y podman ocijail catatonit
sysrc podman_enable=YES
```

Put the manifest and its secrets under `/usr/local/etc/<app>/`, which is where
`hier(7)` says third-party configuration belongs and what the `www/oauth2-proxy`
port itself uses:

```
/usr/local/etc/oauth2-proxy/
├── oauth2-proxy.pod.yaml
└── secrets/
    ├── client-id
    ├── client-secret
    └── cookie-secret
```

```sh
install -d -m 0755 /usr/local/etc/oauth2-proxy
install -d -m 0700 -o www /usr/local/etc/oauth2-proxy/secrets
```

Configuration and secrets stay together, and `/usr/local/etc` is already in
whatever backs this host up.

`ocijail` is the OCI runtime podman uses on FreeBSD — the equivalent of `runc`.

`catatonit` is the one that bites. `podman kube play` requires it, podman does
**not** depend on it, and without it you get:

```
Error: finding catatonit binary: exec: "catatonit": executable file not found in $PATH
```

which names a binary most people have never heard of and gives no hint that one
`pkg install` fixes it.

## 2. Networking, and why every example says `hostNetwork`

podman's default bridge network on FreeBSD needs the `pf` kernel module for its
NAT. If `pf` is not enabled, every container that touches the network fails
with:

```
cni plugin bridge failed: The pf kernel module must be loaded to support ipMasq networks
```

Two ways out. Either enable `pf` and let podman NAT, or use host networking and
bind the proxy to a loopback address. For a gateway that a local reverse proxy
talks to, host networking is simpler and removes NAT from the auth path
entirely — which is why every example here sets `hostNetwork: true` and
`--http-address=127.0.0.1:4180`.

If something else on the host already manages `pf`, do not enable it to suit
podman. Use host networking.

## 3. Pick the image tag

Check what you got, and do not be surprised if the Go version moves:

```sh
podman pull ghcr.io/gabrielbelli/oauth2-proxy-freebsd:freebsd15.0
podman run --rm --network=host ghcr.io/gabrielbelli/oauth2-proxy-freebsd:freebsd15.0 --version
```

FreeBSD's Go team rebuilds every Go port when the toolchain moves, bumping
`PORTREVISION` without the application version changing. These images rebuild
weekly for exactly that reason, so `7.15.3` may report `go1.26.6` one week and
`go1.26.7` the next. The application is the same; the runtime underneath it is
newer, and that is usually where a Go security fix arrives.

Match the tag to the host **kernel**:

```sh
freebsd-version -k
```

| Kernel | Tag |
|---|---|
| 15.1 or newer | `freebsd15.1` or `latest` |
| 15.0 | `freebsd15.0` |
| 14.4 | `freebsd14.4` |

FreeBSD runs older userland on a newer kernel and never the reverse, so a
15.1-based image on a 15.0 kernel is the unsupported direction.

## 4. Secrets

Keep the client secret and the cookie secret out of the manifest, out of
`podman inspect` and out of the process table:

```sh
install -d -m 0700 -o www /usr/local/etc/oauth2-proxy/secrets
cd /usr/local/etc/oauth2-proxy/secrets

printf '%s' 'YOUR_CLIENT_ID'     > client-id
printf '%s' 'YOUR_CLIENT_SECRET' > client-secret
openssl rand -base64 32 | head -c 32 > cookie-secret

chmod 0400 client-id client-secret cookie-secret
chown www client-id client-secret cookie-secret
```

`-o www` on the directory is not decoration. The container runs as `www`, and a
`0700` root-owned directory it cannot traverse produces a failure that reads as
a configuration error rather than a permissions one. Prove it before moving on:

```sh
su -m www -c 'cat /usr/local/etc/oauth2-proxy/secrets/client-id' >/dev/null && echo ok
```

The cookie secret must be **exactly 16, 24 or 32 bytes**. `head -c 32` on
base64 output gives 32 characters; anything else and oauth2-proxy refuses to
start with a message about the cookie secret length.

## 5. Edit the manifest

Copy [`examples/oauth2-proxy.pod.yaml`](../examples/oauth2-proxy.pod.yaml) and
change four things:

1. `image:` — the tag matching your kernel from step 3
2. `--redirect-url` — `https://<gateway-host>/oauth2/callback`, exactly as
   registered with your identity provider
3. `--cookie-domain` and `--whitelist-domain` — the shared parent domain
4. `--email-domain` — who is allowed in

## 6. Start it

```sh
podman kube play /usr/local/etc/oauth2-proxy/oauth2-proxy.pod.yaml
podman ps
podman logs oauth2-proxy-oauth2-proxy
```

A healthy start logs OIDC discovery and the cookie settings:

```
[provider.go:55] Performing OIDC Discovery...
[oauthproxy.go:180] OAuthProxy configured for Google Client ID: ...
[oauthproxy.go:186] Cookie settings: name:_oauth2_proxy secure(https):true ...
```

Check it answers:

```sh
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4180/ping        # 200
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4180/oauth2/auth # 401
```

`200` then `401` means the gateway is up and refusing anonymous callers, which
is exactly right.

> `--config-test` is not a substitute for starting it. In 7.15.3 it reports
> `configuration is valid` for an issuer with nothing listening, because it
> performs no OIDC discovery. Only a real start-up proves the issuer is
> reachable.

## 7. Stop, restart, and reboots

```sh
podman kube down /usr/local/etc/oauth2-proxy/oauth2-proxy.pod.yaml
```

`restartPolicy: always` on FreeBSD is a **boot-time policy, not live
supervision**. No podman daemon persists, so a container that dies at run time
stays dead until the next boot or `service podman restart`. `podman_enable=YES`
from step 1 is what replays the policy at boot. If you need a crashed gateway
revived promptly, supervise it yourself.

## 8. Point applications at it

Each application is deployed separately and needs three things to agree with the
gateway:

| Setting | Value |
|---|---|
| Where to ask | `https://<gateway-host>` + `/oauth2/auth` |
| Where to send a signed-out visitor | `https://<gateway-host>/oauth2/start?rd=` |
| Which headers carry the identity | the `X-Auth-Request-*` set, so the gateway needs `--set-xauthrequest` |

The application's host must fall inside `--whitelist-domain`, or the `rd=` back
to it is refused as an open redirect and sign-in dead-ends at the gateway. It
must also share the `--cookie-domain` parent, or each application gets its own
session and there is no single sign-on.

## Health checking

The image carries no `HEALTHCHECK` — the OCI image spec has no field for one, so
anything declared in a Containerfile is dropped on publish. Worse, podman
schedules periodic healthchecks with systemd timers, which FreeBSD does not
have, so a `--health-cmd` passed at run time never fires on its own and the
status sits at `starting` forever.

Have your reverse proxy check `/ping` directly — it answers `200` without
authentication — or drive `podman healthcheck run` from cron.

## When it does not work

| Symptom | Cause |
|---|---|
| `create: Command not found` or similar on a line from this guide | you are in `csh`; run `sh` first (step 0) |
| `finding catatonit binary` | `pkg install catatonit` (step 1) |
| `The pf kernel module must be loaded` | not using `hostNetwork: true` (step 2) |
| Container exits, logs mention the cookie secret | not exactly 16, 24 or 32 bytes (step 4) |
| Starts, but every sign-in fails at the provider | `--redirect-url` does not match what is registered, character for character |
| Sign-in completes then bounces back to sign-in | over plain HTTP the session cookie is set but never returned — `--cookie-secure=false` for a non-TLS test only, never in production |
| Sign-in completes, application refuses the redirect | the application's host is outside `--whitelist-domain` |
| `exec: No such file or directory` on a binary that exists | a directory above it is not traversable by `www` |
