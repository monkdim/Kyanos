FROM debian:bookworm-slim AS build

# Install Bun, curl, and Python for the bootstrap fallback
RUN apt-get update && apt-get install -y curl unzip python3 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"

WORKDIR /build

# Copy source
COPY . .

# Bootstrap: the latest release's binary rebuilds the toolchain. When no
# release carries a binary the Python bundler does the same job. Either way
# the bundle is written into an empty native/dist.
RUN rm -rf native/dist \
    && if curl -fsSL https://github.com/monkdim/Kyanos/releases/latest/download/clarity-linux-x64.tar.gz -o clarity-bootstrap.tar.gz \
         && tar xzf clarity-bootstrap.tar.gz \
         && chmod +x clarity \
         && mv clarity /usr/local/bin/clarity-bootstrap \
         && clarity-bootstrap transpile --bundle \
         && test -f native/dist/clarity-entry.js; then \
         echo "bootstrapped from the latest release"; \
       else \
         echo "no usable release binary; bundling with the Python transpiler"; \
         rm -rf native/dist && python3 native/transpile.py --bundle; \
       fi

# Compile native binary
RUN cd native/dist && bun build --compile clarity-entry.js --outfile clarity

# ── Runtime stage ─────────────────────────────────────
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*

COPY --from=build /build/native/dist/clarity /usr/local/bin/clarity
COPY --from=build /build/stdlib/registry.clarity /usr/local/bin/registry.clarity

RUN mkdir -p /data
VOLUME /data

ENV REGISTRY_PORT=8080
ENV REGISTRY_DATA=/data

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD curl -f http://localhost:8080/health || exit 1

ENTRYPOINT ["clarity", "run", "/usr/local/bin/registry.clarity"]
CMD ["--port", "8080", "--data", "/data"]
