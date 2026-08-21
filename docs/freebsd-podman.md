# Running this on FreeBSD with podman

Three blocks to a running gateway. Copy them in order.

Everything here is the **gateway**. Applications behind it are deployed
separately — that separation is the point, and merging the two gives each
application its own session.

## 1. Install

```sh
sh                                       # root's shell is csh; these need sh
pkg install -y podman ocijail catatonit
sysrc podman_enable=YES
install -d -m 0755 /usr/local/etc/oauth2-proxy
install -d -m 0700 -o www /usr/local/etc/oauth2-proxy/secrets
install -d -m 0700 -o www /usr/local/etc/oauth2-proxy/tls
```

`catatonit` is required by `podman kube play` and is **not** a podman
dependency; without it you get an error naming a binary nobody has heard of.

`-o www` is not decoration: the container runs as uid 80 and cannot traverse a
root-owned `0700` directory. That failure presents as a configuration error.

## 2. Secrets and certificate

```sh
cd /usr/local/etc/oauth2-proxy/secrets
printf '%s' 'YOUR_CLIENT_SECRET' > client-secret
openssl rand -base64 32 | head -c 32 > cookie-secret

cd ../tls
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
  -keyout tls.key -out tls.crt \
  -subj '/CN=auth.example.com' \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'extendedKeyUsage=serverAuth' \
  -addext 'subjectAltName=DNS:auth.example.com,IP:10.0.0.10'

chmod 0400 /usr/local/etc/oauth2-proxy/secrets/* /usr/local/etc/oauth2-proxy/tls/*
chown www  /usr/local/etc/oauth2-proxy/secrets/* /usr/local/etc/oauth2-proxy/tls/*
su -m www -c 'cat /usr/local/etc/oauth2-proxy/tls/tls.key' >/dev/null && echo ok
```

`printf`, not `echo`: a trailing newline in a credential is rejected by the
provider with an error that never mentions whitespace.

The cookie secret must be exactly 16, 24 or 32 bytes. `head -c 32` gives 32.

Put **both** a DNS and an IP SAN in the certificate — whatever fronts this may
address the upstream either way, and a certificate is only valid for the
identifier actually used.

Skip the certificate entirely if something else terminates TLS and you are happy
for that last hop to be plain HTTP; use `--http-address` instead of the three
`--tls-*` flags below.

## 3. Manifest and start

Edit the five marked values, paste, and it runs.

```sh
cat > /usr/local/etc/oauth2-proxy/oauth2-proxy.pod.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: oauth2-proxy
spec:
  # Required: podman's bridge network needs the pf kernel module for NAT.
  hostNetwork: true
  restartPolicy: always
  volumes:
    - name: secrets
      hostPath: { path: /usr/local/etc/oauth2-proxy/secrets, type: Directory }
    - name: tls
      hostPath: { path: /usr/local/etc/oauth2-proxy/tls, type: Directory }
  containers:
    - name: oauth2-proxy
      image: ghcr.io/gabrielbelli/oauth2-proxy-freebsd:freebsd15.0   # <-- match freebsd-version -k
      args:
        - --provider=google
        # The client ID is not secret — it is sent to the provider in the
        # redirect the browser follows. There is no --client-id-file.
        - --client-id=YOUR_CLIENT_ID                                 # <--
        - --client-secret-file=/run/secrets/client-secret
        - --cookie-secret-file=/run/secrets/cookie-secret
        # A high port: the container runs as uid 80 and cannot bind 443.
        - --https-address=10.0.0.10:4443                             # <--
        - --tls-cert-file=/run/tls/tls.crt
        - --tls-key-file=/run/tls/tls.key
        - --tls-min-version=TLS1.2
        # The public URL the browser sees, exactly as registered with the
        # provider. A mismatch of one character fails every sign-in.
        - --redirect-url=https://auth.example.com/oauth2/callback    # <--
        # Scopes the session to the shared parent: one sign-in covers every
        # host under it. Applications on a different registrable domain
        # cannot share this cookie and need their own instance.
        - --cookie-domain=.example.com                               # <--
        # Must permit the same, or the ?rd= back to an application is refused
        # as an open redirect and sign-in dead-ends here.
        - --whitelist-domain=.example.com
        - --email-domain=example.com
        # Required for forward-auth: applications read the identity from the
        # X-Auth-Request-* headers this adds.
        - --set-xauthrequest
        - --reverse-proxy
        # Bounds who may set X-Forwarded-*. Without it every connecting IP is
        # trusted, and the sign-in redirect is built from those headers.
        # Repeat for each address the proxy in front may arrive on.
        - --trusted-proxy-ip=10.0.0.1                                # <--
        # Auth-only. Replace with --upstream=http://... to proxy a backend.
        - --upstream=static://202
      volumeMounts:
        - { name: secrets, mountPath: /run/secrets, readOnly: true }
        - { name: tls,     mountPath: /run/tls,     readOnly: true }
YAML

podman kube play /usr/local/etc/oauth2-proxy/oauth2-proxy.pod.yaml
sleep 5
podman logs oauth2-proxy-oauth2-proxy | tail -5
curl -sk -o /dev/null -w 'ping %{http_code}\n' https://10.0.0.10:4443/ping
```

Want `200`, and a `Cookie settings:` line with no `--trusted-proxy-ip` warning.

To stop: `podman kube down <file>`. If the pod survives that,
`podman pod rm -f oauth2-proxy`.

## Who gets in

Two settings, and they are **OR'd** — with both set, the domain admits everyone
and the list buys nothing. Use exactly one.

```yaml
# Everyone in the Workspace domain:
- --email-domain=example.com

# ...or named people only. Remove --email-domain when you use this.
- --authenticated-emails-file=/run/secrets/allowed-emails.txt
```

One address per line. The file is re-read when it changes, so adding someone
needs no restart:

```sh
printf 'alice@example.com\nbob@example.com\n' \
  > /usr/local/etc/oauth2-proxy/secrets/allowed-emails.txt
chmod 0400 /usr/local/etc/oauth2-proxy/secrets/allowed-emails.txt
chown www  /usr/local/etc/oauth2-proxy/secrets/allowed-emails.txt
```

A refused user authenticates at the provider and is then rejected here — the
log shows `[AuthFailure] Invalid authentication via OAuth2: unauthorized` and
the browser gets a 403 at the callback. That is the allow-list working.

## Two ways to put an application behind it

One instance does both at once. `/oauth2/auth` is served whether or not any
`--upstream` is configured.

### Forward-auth — application on its own hostname

The application keeps serving itself and asks the gateway per request. Nothing
in the application changes. See
[`examples/forward-auth.nginx.conf`](../examples/forward-auth.nginx.conf) for
the nginx side.

Use this when the application cannot be served under a path prefix, which is
most of them.

### Full proxy — application under a path here

Add one `--upstream` per backend; routing is by path:

```yaml
- --upstream=http://127.0.0.1:9001/toolx/
- --upstream=http://127.0.0.1:9002/tooly/
- --upstream=static://202          # keep only if you also serve forward-auth
```

`https://auth.example.com/toolx/` now reaches `127.0.0.1:9001`, gated. The
backend receives the identity in `X-Forwarded-User` and `X-Forwarded-Email`.

**The application must support being served under that prefix.** It sees
`/toolx/...` and must build its own links, redirects and asset URLs with it.
Many have a `base-path` or `root-url` setting; those that do not will half-work
— the page loads and the CSS 404s. Where that is the case, give it a hostname
and use forward-auth instead.

## Reboots

`restartPolicy: always` is a **boot-time policy, not live supervision**. No
podman daemon persists, so a container that dies at run time stays dead until
the next boot or `service podman restart`. `podman_enable=YES` replays the
policy at boot.

## Health checking

The image carries no `HEALTHCHECK`: the OCI image spec has no field for one, so
anything declared in a Containerfile is dropped on publish. Passing
`--health-cmd` at run time does not help either — podman schedules periodic
healthchecks with systemd timers, which FreeBSD does not have, so the status
sits at `starting` forever.

Have whatever fronts this check `/ping` directly; it answers `200` without
authentication.

## When it does not work

| Symptom | Cause |
|---|---|
| `Command not found` on a line from this guide | you are in `csh`; run `sh` |
| `finding catatonit binary` | `pkg install catatonit` |
| `The pf kernel module must be loaded` | `hostNetwork: true` is missing |
| `provider missing setting: client-id` | there is no `--client-id-file`; pass `--client-id` directly |
| Exits, log mentions the cookie secret | not exactly 16, 24 or 32 bytes |
| `name "oauth2-proxy" is in use` | `podman pod rm -f oauth2-proxy` |
| Every sign-in fails at the provider | `--redirect-url` does not match what is registered, character for character |
| Sign-in loops back to sign-in forever | the request reached the proxy as plain HTTP, so a `Secure` cookie was set and never returned. Whatever fronts this must send `X-Forwarded-Proto: https` |
| Sign-in works, application refuses the redirect | the application's host is outside `--whitelist-domain` |
| `502` only for signed-in users | the proxy in front needs a larger header buffer; the session cookie carries the ID token |
| `exec: No such file or directory` on a binary that exists | a directory above it is not traversable by `www` |

## Why there is no compose file

`podman-compose` is not packaged for FreeBSD, and `podman compose` only shims
out to a provider that is not packaged either. `podman kube play` is built in.

It is lighter than the word "Kubernetes" suggests: one `kind: Pod`, a list of
containers, a list of volumes. No Deployment, no Service, no cluster. You are
using the file format, not the orchestrator.

| compose | pod manifest |
|---|---|
| `services:` (map) | `spec.containers:` (list) |
| `KEY: value` under `environment:` | `- {name: KEY, value: value}` under `env:` |
| `- vol:/path` under `volumes:` | `- {name: vol, mountPath: /path}` under `volumeMounts:` |
| `network_mode: host` | `spec.hostNetwork: true` |
| `restart: always` | `spec.restartPolicy: always` |

## A note on versions

`--version` reports the Go release the binary was built with, and it moves.
FreeBSD rebuilds every Go port when the toolchain does, and these images rebuild
weekly to follow, so `7.15.3` may report `go1.26.6` one week and `go1.26.7` the
next. Same application, newer runtime — which is usually where a Go security fix
arrives.
