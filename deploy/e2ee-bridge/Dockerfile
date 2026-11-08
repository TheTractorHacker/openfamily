# Build from the repository root:
#   docker build -f deploy/e2ee-bridge/Dockerfile -t e2ee-bridge .
# RUN THE RESULT OFF THE OPENFAMILY SERVER HOST (see backend/cmd/e2ee-bridge/README.md).
FROM golang:1.27@sha256:e519d3b0a5b285e5aa53ab9eef02bc6bbb9cb04608389b743a136a9ce75f0d1e AS build
WORKDIR /src
COPY backend/go.mod backend/go.sum ./
RUN go mod download
COPY backend/ ./
RUN CGO_ENABLED=0 GOFLAGS=-trimpath go build -ldflags="-s -w" -o /out/e2ee-bridge ./cmd/e2ee-bridge

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /out/e2ee-bridge /usr/local/bin/e2ee-bridge
# The state directory is a volume owned by the non-root user (uid 65532).
ENV E2EE_BRIDGE_STATE=/state
VOLUME ["/state"]
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/e2ee-bridge"]
CMD ["run", "--config", "/config/config.json"]
