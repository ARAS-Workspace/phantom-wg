FROM golang:1.23-alpine AS builder

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o dns-leak-server .

FROM alpine:3.21
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /build/dns-leak-server /usr/local/bin/
EXPOSE 53/udp
ENTRYPOINT ["dns-leak-server"]
