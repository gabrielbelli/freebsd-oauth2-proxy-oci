# oauth2-proxy on FreeBSD, as an OCI image.
#
# There is deliberately no RUN instruction. RUN executes a binary inside the
# image, and a Linux kernel cannot execute FreeBSD binaries — qemu-user crosses
# architectures, not operating systems. FROM and COPY execute nothing, so with
# the package staged beforehand by ./fetch-pkg.sh this image builds on an
# ordinary Linux runner, for both architectures, in seconds.
#
# Build:
#   ./fetch-pkg.sh FreeBSD:15:amd64 oauth2-proxy rootfs
#   buildah bud --platform freebsd/amd64 -t oauth2-proxy-freebsd .

ARG FREEBSD_VERSION=15.1
FROM freebsd/freebsd-runtime:${FREEBSD_VERSION}

# Staged by fetch-pkg.sh: the contents of the www/oauth2-proxy package, minus
# pkg's own metadata. The port declares no RUN_DEPENDS and no LIB_DEPENDS, so
# no other package has to be fetched.
#
# The binary is NOT static, despite being Go: it is dynamically linked against
# libc.so.7 and libthr.so.3 with interpreter /libexec/ld-elf.so.1. All three
# come from the base runtime below, which is why this cannot be FROM scratch.
ARG ROOTFS=rootfs
COPY ${ROOTFS}/ /

# uid 80, present in the FreeBSD base image, and the account the port's rc
# script uses. The proxy listens above 1024, so nothing here wants root.
USER www

# oauth2-proxy's own default.
EXPOSE 4180

# No HEALTHCHECK instruction: the OCI image spec has no field for one, so
# buildah drops it when building --format oci and the published config simply
# would not contain it. (A Docker-format build keeps it, which is how this goes
# unnoticed — it appears to work locally and vanishes on publish.)
#
# Pass it at run time instead; /ping answers 200 without authentication and
# fetch(1) is already in the base image:
#
#   podman run --health-cmd "/usr/bin/fetch -qo /dev/null http://127.0.0.1:4180/ping" \
#              --health-interval 30s --health-retries 3 ...

ENTRYPOINT ["/usr/local/bin/oauth2-proxy"]
