FROM gcc:14 AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends cmake && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY CMakeLists.txt ./
COPY src/ ./src/

RUN cmake -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build -j"$(nproc)"

FROM debian:bookworm-slim

RUN useradd --create-home --shell /usr/sbin/nologin app
COPY --from=builder /src/build/app /usr/local/bin/app

USER app
ENTRYPOINT ["/usr/local/bin/app"]