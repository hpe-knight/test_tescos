# =============================================================================
# Apache Spark + Kyuubi — enterprise-grade multi-stage image (POC target)
#   Stage "downloader": fetch & checksum-verify Spark and Kyuubi distributions
#   Stage "final":      minimal JRE runtime, non-root user, tini init, HEALTHCHECK
# Versions pinned (no `latest`) — enforced by Hadolint/Dockle and unit test TC-U01.
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

RUN KYUUBI_TGZ="apache-kyuubi-${KYUUBI_VERSION}-bin.tgz" && \
    curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors -C - -o "${KYUUBI_TGZ}" \
      "https://archive.apache.org/dist/kyuubi/kyuubi-${KYUUBI_VERSION}/${KYUUBI_TGZ}" && \
    curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors -o "${KYUUBI_TGZ}.sha512" \
      "https://archive.apache.org/dist/kyuubi/kyuubi-${KYUUBI_VERSION}/${KYUUBI_TGZ}.sha512" && \
    sha512sum -c "${KYUUBI_TGZ}.sha512" && \
    mkdir -p /opt/kyuubi && \
    tar -xzf "${KYUUBI_TGZ}" -C /opt/kyuubi --strip-components=1 && \
    rm -f "${KYUUBI_TGZ}" "${KYUUBI_TGZ}.sha512"

# ---------- Stage 2: final runtime ----------
FROM eclipse-temurin:17-jre-jammy AS final

LABEL org.opencontainers.image.title="spark-kyuubi" \
      org.opencontainers.image.description="Apache Spark + Kyuubi SQL gateway (TESCO image-testing POC)" \
      org.opencontainers.image.vendor="TESCO / HPE POC"

ENV SPARK_HOME=/opt/spark \
    KYUUBI_HOME=/opt/kyuubi \
    PATH=/opt/spark/bin:/opt/kyuubi/bin:$PATH

# hadolint ignore=DL3008
RUN apt-get update && \
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

EXPOSE 10009
EXPOSE 10099

HEALTHCHECK --interval=15s --timeout=5s --start-period=90s --retries=10 \
  CMD curl -sf http://localhost:10099/api/v1/ping || exit 1

ENTRYPOINT ["tini", "--"]
CMD ["/opt/kyuubi/bin/kyuubi", "run"]
