FROM golang:1.23-alpine AS builder

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o acme-dns .

FROM alpine:3.21
RUN apk add --no-cache certbot
COPY --from=builder /build/acme-dns /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
COPY auth-hook.sh /auth-hook.sh
RUN chmod +x /entrypoint.sh /auth-hook.sh
ENTRYPOINT ["/entrypoint.sh"]
