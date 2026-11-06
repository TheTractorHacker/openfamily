# Build stage
FROM golang:1.27.3-alpine@sha256:dbaa054703263d06c8b49576667418473b6231f8c0fa69dee103207fdb8e3654 AS build
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
    case "${resolved_ref}" in \
      *[!0-9a-f]*) short_ref="${resolved_ref}" ;; \
      *) short_ref="$(printf '%s' "${resolved_ref}" | cut -c1-7)" ;; \
    esac; \
    test -n "${short_ref}"; \
    CGO_ENABLED=0 GOOS=linux go build -trimpath \
      -ldflags="-s -w -X github.com/TheTractorHacker/openfamily/backend/internal/config.buildVersion=${short_ref}" \
      -o /out/server ./cmd/server

# Runtime stage
FROM alpine:3.22@sha256:bfe7ceb9f09ec0566c48fb93356e45a47a00be5a1dd14fa5b909e7709c66b034
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

