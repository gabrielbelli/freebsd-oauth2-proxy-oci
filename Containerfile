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
# pkg's own metadata. oauth2-proxy is a static Go binary and the port declares
# no run or library dependencies, so this really is base plus one program.
ARG ROOTFS=rootfs
COPY ${ROOTFS}/ /

# uid 80, present in the FreeBSD base image, and the account the port's rc
# script uses. The proxy listens above 1024, so nothing here wants root.
USER www

# oauth2-proxy's own default.
EXPOSE 4180

# /ping answers 200 without authentication and is the endpoint upstream
# documents for this. fetch(1) is in the base image, so no extra package.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD ["/usr/bin/fetch", "-qo", "/dev/null", "http://127.0.0.1:4180/ping"]

ENTRYPOINT ["/usr/local/bin/oauth2-proxy"]
