# =============================================================================
# Apache Spark + Kyuubi — production-grade multi-stage image (POC target)
# - Stage "downloader": fetches & verifies Spark and Kyuubi distributions
# - Stage "final": minimal JRE runtime, non-root user, HEALTHCHECK
#
# Versions are pinned (no `latest`) — Dockle/Hadolint enforce this.
# TBD-TESTING-TEAM: confirm exact Spark/Kyuubi versions used in production.
# =============================================================================

# ---------- Stage 1: downloader ----------
FROM eclipse-temurin:17-jdk-jammy AS downloader

ARG SPARK_VERSION=3.5.1
ARG HADOOP_PROFILE=3
ARG KYUUBI_VERSION=1.9.0

WORKDIR /opt

# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Download and verify Spark (checksums published alongside the archives).
# archive.apache.org throttles CI traffic and can cut large transfers mid-stream,
# so retry and resume (-C -) instead of failing on the first truncated download.
# The .sha512 file references the original archive filename, so the download
# must keep that name for `sha512sum -c` to find it.
RUN SPARK_TGZ="spark-${SPARK_VERSION}-bin-hadoop${HADOOP_PROFILE}.tgz" && \
    curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors -C - -o "${SPARK_TGZ}" \
      "https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/${SPARK_TGZ}" && \
    curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors -o "${SPARK_TGZ}.sha512" \
      "https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/${SPARK_TGZ}.sha512" && \
    sha512sum -c "${SPARK_TGZ}.sha512" && \
    mkdir -p /opt/spark && \
    tar -xzf "${SPARK_TGZ}" -C /opt/spark --strip-components=1 && \
    rm -f "${SPARK_TGZ}" "${SPARK_TGZ}.sha512"

# Download and verify Kyuubi (same retry strategy as the Spark download above)
RUN KYUUBI_TGZ="apache-kyuubi-${KYUUBI_VERSION}-bin.tgz" && \
    curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors -C - -o "${KYUUBI_TGZ}" \
      "https://archive.apache.org/dist/kyuubi/kyuubi-${KYUUBI_VERSION}/${KYUUBI_TGZ}" && \
    curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors -o "${KYUUBI_TGZ}.sha512" \
      "https://archive.apache.org/dist/kyuubi/kyuubi-${KYUUBI_VERSION}/${KYUUBI_TGZ}.sha512" && \
    sha512sum -c "${KYUUBI_TGZ}.sha512" && \
    mkdir -p /opt/kyuubi && \
    tar -xzf "${KYUUBI_TGZ}" -C /opt/kyuubi --strip-components=1 && \
    rm -f "${KYUUBI_TGZ}" "${KYUUBI_TGZ}.sha512" && \
    # Strip demo/sample content shipped in the upstream distributions: the
    # Kyuubi docker playground includes a sample .env that trips Dockle's
    # CIS-DI-0010 credential check, and the Spark/Kyuubi Dockerfiles are
    # flagged as unnecessary files. None of it is needed at runtime.
    rm -rf /opt/kyuubi/docker /opt/spark/kubernetes

# ---------- Stage 2: final runtime ----------
FROM eclipse-temurin:17-jre-jammy AS final

LABEL org.opencontainers.image.title="spark-kyuubi" \
      org.opencontainers.image.description="Apache Spark + Kyuubi SQL gateway (TESCO POC)" \
      org.opencontainers.image.vendor="TESCO / HPE POC"

ENV SPARK_HOME=/opt/spark \
    KYUUBI_HOME=/opt/kyuubi \
    PATH=/opt/spark/bin:/opt/kyuubi/bin:$PATH

# hadolint ignore=DL3008
# `apt-get upgrade` pulls in pending Ubuntu security fixes (e.g. the openssl
# high-severity CVE fixed in 3.0.2-0ubuntu1.30) so the quality gate's
# OS-vulnerability thresholds can be met without allowlisting.
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends procps curl tini && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd -r -g 1099 kyuubi && \
    useradd -r -u 1099 -g kyuubi -d /home/kyuubi -m kyuubi

COPY --from=downloader --chown=kyuubi:kyuubi /opt/spark  ${SPARK_HOME}
COPY --from=downloader --chown=kyuubi:kyuubi /opt/kyuubi ${KYUUBI_HOME}

COPY --chown=kyuubi:kyuubi conf/spark-defaults.conf  ${SPARK_HOME}/conf/spark-defaults.conf
COPY --chown=kyuubi:kyuubi conf/kyuubi-defaults.conf ${KYUUBI_HOME}/conf/kyuubi-defaults.conf

RUN mkdir -p /opt/kyuubi/work /opt/kyuubi/logs /tmp/spark-events && \
    chown -R kyuubi:kyuubi /opt/kyuubi/work /opt/kyuubi/logs /tmp/spark-events

USER kyuubi
WORKDIR /home/kyuubi

# Kyuubi Thrift/JDBC frontend
EXPOSE 10009
# Kyuubi REST frontend (also serves /api/v1/ping for health checks)
EXPOSE 10099

# Used by Stage 3 dynamic testing and by orchestrators in production
HEALTHCHECK --interval=15s --timeout=5s --start-period=90s --retries=10 \
  CMD curl -sf http://localhost:10099/api/v1/ping || exit 1

ENTRYPOINT ["tini", "--"]
CMD ["/opt/kyuubi/bin/kyuubi", "run"]
