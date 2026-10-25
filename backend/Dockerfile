# Build stage
FROM golang:1.27.3-alpine AS build
RUN apk add --no-cache ca-certificates openssl
COPY scripts/distrust-compromised-cas.sh /usr/local/bin/distrust-compromised-cas
RUN sh /usr/local/bin/distrust-compromised-cas && update-ca-certificates --fresh
WORKDIR /src

# An explicit ref may be passed by scripts/upgrade.sh. For ordinary `docker compose up
# --build`, resolve HEAD from the small .git metadata included in the build
# context so the API never falls back to a misleading "dev" version.
ARG GIT_COMMIT=

# Cache dependencies.
COPY backend/go.mod backend/go.sum ./
RUN go mod download

# Build a static binary (migrations are embedded via go:embed).
COPY backend/ ./
COPY .git/ /git/
RUN resolved_ref="${GIT_COMMIT}"; \
    if [ -z "${resolved_ref}" ] || [ "${resolved_ref}" = "dev" ]; then \
      head_value="$(cat /git/HEAD)"; \
      case "${head_value}" in \
        "ref: "*) ref_path="${head_value#ref: }"; \
          resolved_ref="$(cat "/git/${ref_path}" 2>/dev/null || awk -v ref="${ref_path}" '$2 == ref { print $1 }' /git/packed-refs 2>/dev/null)" ;; \
        *) resolved_ref="${head_value}" ;; \
      esac; \
    fi; \
    short_ref="$(printf '%s' "${resolved_ref}" | cut -c1-7)"; \
    test -n "${short_ref}"; \
    CGO_ENABLED=0 GOOS=linux go build -trimpath \
      -ldflags="-s -w -X github.com/wheresfrank/openfamily/backend/internal/config.buildVersion=${short_ref}" \
      -o /out/server ./cmd/server

# Runtime stage
FROM alpine:3.22
RUN apk add --no-cache ca-certificates openssl tzdata
COPY scripts/distrust-compromised-cas.sh /usr/local/bin/distrust-compromised-cas
RUN sh /usr/local/bin/distrust-compromised-cas && update-ca-certificates --fresh
COPY --from=build /out/server /usr/local/bin/server
# Run as an unprivileged user; /data/apk is the (volume-backed) APK cache.
RUN adduser -D -H -u 10001 openfamily \
 && mkdir -p /data/apk && chown -R openfamily /data
USER 10001
EXPOSE 8080
ENTRYPOINT ["server"]

