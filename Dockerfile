# GitHub Actions self-hosted runner, packaged for Railway.
#
# Base is GitHub's own runner image (Ubuntu 24.04, user `runner` uid 1001, the
# runner already installed under /home/runner). We add only what Railway needs:
#   tini    — the start command is not PID 1, so children need a subreaper
#   busybox — serves the /healthz file the Railway health check probes
FROM ghcr.io/actions/actions-runner:latest

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      tini \
      busybox-static \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER runner
WORKDIR /home/runner

# Railway overrides this, but keep the image runnable on its own.
ENTRYPOINT ["/usr/bin/tini", "-s", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
