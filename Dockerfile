# GitHub Actions self-hosted runner, packaged for Railway.
#
# Base is GitHub's own runner image (Ubuntu 24.04, user `runner` uid 1001, the
# runner already installed under /home/runner). We add only what Railway needs:
#   tini    — the start command is not PID 1, so children need a subreaper
#   busybox — serves the /healthz file the Railway health check probes
#   build-essential, libatomic1 — parity with GitHub-hosted runners (cgo builds, Node 26 binaries)
# Pinned so a rebuild is reproducible; Dependabot bumps it.
FROM ghcr.io/actions/actions-runner:2.337.0

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini \
      busybox-static \
      ca-certificates \
      build-essential \
      libatomic1 \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER runner
WORKDIR /home/runner

# Outside RUNNER_WORK, so the per-job workspace wipe keeps setup-* downloads for the next job.
ENV RUNNER_TOOL_CACHE=/home/runner/_tool
RUN mkdir -p "$RUNNER_TOOL_CACHE"

# Railway overrides this, but keep the image runnable on its own.
ENTRYPOINT ["/usr/bin/tini", "-s", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
