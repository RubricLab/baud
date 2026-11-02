# The wake relay: one static binary, nothing else on the box. Roots of trust for Apple's push
# service are compiled in (webpki), so the image carries no certificate store either.
FROM rust:1-slim AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src src
COPY tests tests
RUN cargo build --release --locked

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /src/target/release/wake /wake
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/wake"]
