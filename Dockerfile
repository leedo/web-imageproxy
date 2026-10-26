FROM golang:1.27 AS builder

WORKDIR /src
COPY go.mod ./
COPY cmd cmd
COPY internal internal
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /imageproxy ./cmd/imageproxy

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /imageproxy /imageproxy
EXPOSE 5007
ENTRYPOINT ["/imageproxy"]
