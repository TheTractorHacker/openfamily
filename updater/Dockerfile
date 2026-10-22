# Build stage
FROM golang:1.27.3-alpine AS build
RUN apk add --no-cache ca-certificates openssl
COPY distrust-compromised-cas.sh /usr/local/bin/distrust-compromised-cas
RUN sh /usr/local/bin/distrust-compromised-cas && update-ca-certificates --fresh
WORKDIR /src

COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/updater .

# Runtime stage. git applies updates to the mounted clone; docker CLI +
# compose plugin talk to the mounted host daemon socket.
FROM alpine:3.22
RUN apk add --no-cache ca-certificates openssl tzdata git docker-cli docker-cli-compose
COPY distrust-compromised-cas.sh /usr/local/bin/distrust-compromised-cas
RUN sh /usr/local/bin/distrust-compromised-cas && update-ca-certificates --fresh
COPY --from=build /out/updater /usr/local/bin/updater
EXPOSE 8081
ENTRYPOINT ["updater"]

