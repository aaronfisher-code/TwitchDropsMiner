FROM debian:bookworm-slim

ARG TDM_UID=1000
ARG TDM_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TDM_DATA_DIR=/data \
    DISPLAY=:99 \
    DISPLAY_WIDTH=1280 \
    DISPLAY_HEIGHT=800 \
    DISPLAY_DEPTH=24

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        ca-certificates \
        dbus-x11 \
        gir1.2-gtk-3.0 \
        novnc \
        openbox \
        python3 \
        python3-cairo \
        python3-gi \
        python3-pip \
        python3-tk \
        python3-venv \
        tini \
        websockify \
        x11-utils \
        x11vnc \
        xvfb \
    && rm -rf /var/lib/apt/lists/*

# Debian keeps Pillow's Tk bindings in a separate package.
RUN apt-get update \
    && apt-get install --no-install-recommends -y python3-pil.imagetk \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid "${TDM_GID}" tdm \
    && useradd --create-home --uid "${TDM_UID}" --gid "${TDM_GID}" tdm \
    && install -d -o tdm -g tdm /app /data \
    && install -d -m 1777 /tmp/.X11-unix

WORKDIR /app

COPY --chown=tdm:tdm requirements.txt ./
RUN python3 -m venv --system-site-packages /opt/tdm-venv \
    && /opt/tdm-venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/tdm-venv/bin/pip install --no-cache-dir -r requirements.txt

COPY --chown=tdm:tdm . ./
# Windows Jenkins agents may have core.autocrlf enabled. Normalize the Linux
# entrypoint in the image as a safeguard even when checkout attributes are ignored.
RUN sed -i 's/\r$//' /app/docker/entrypoint.sh \
    && chmod 0755 /app/docker/entrypoint.sh

ARG SOURCE_TREE=unknown
LABEL org.opencontainers.image.revision="${SOURCE_TREE}"

ENV PATH=/opt/tdm-venv/bin:$PATH \
    PYSTRAY_BACKEND=xorg

USER tdm

EXPOSE 6080 18473
VOLUME ["/data"]

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=4 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:18473/api/health', timeout=3)" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/app/docker/entrypoint.sh"]
CMD ["--log"]
