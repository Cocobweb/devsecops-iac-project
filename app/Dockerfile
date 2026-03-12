FROM nginx:alpine

# FIX CVE-2026-22184 + CVE-2026-27171 : mise à jour de zlib
RUN apk update && apk upgrade zlib

# FIX CKV_DOCKER_3 : créer un utilisateur non-root
RUN addgroup -S appgroup && adduser -S appuser -G appgroup \
    && chown -R appuser:appgroup /usr/share/nginx/html \
    && chown -R appuser:appgroup /var/cache/nginx \
    && touch /var/run/nginx.pid \
    && chown appuser:appgroup /var/run/nginx.pid

COPY index.html /usr/share/nginx/html/index.html

# FIX CKV_DOCKER_2 : healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget --quiet --tries=1 --spider http://localhost:80 || exit 1

USER appuser

EXPOSE 80
