FROM debian:11-slim

USER root
ENV DEBIAN_FRONTEND=noninteractive

# 安装基础工具、curl、unzip 以及用于诊断的 ps 和 htop
RUN apt-get update && apt-get install -y \
    wget \
    sudo \
    curl \
    unzip \
    procps \
    htop \
    && rm -rf /var/lib/apt/lists/*

# 下载并一键安装 Tailscale 官方客户端
RUN curl -fsSL https://tailscale.com/install.sh | sh

# 提前在镜像中创建好日志文件并赋予读写权限
RUN touch /tmp/komari.log && chmod 666 /tmp/komari.log

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

COPY komari-agent-linux-amd64 /usr/local/bin/komari-agent
RUN chmod +x /usr/local/bin/komari-agent

COPY xray /usr/local/bin/xray
RUN chmod +x /usr/local/bin/xray && mkdir -p /etc/xray

CMD ["/entrypoint.sh"]
