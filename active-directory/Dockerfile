FROM debian:bookworm-slim

LABEL maintainer="xixtu" \
      description="Samba 4 Active Directory Domain Controller" \
      version="4.17"

# Installation des paquets Samba AD DC
RUN apt-get update && apt-get install -y --no-install-recommends \
    samba \
    samba-common \
    winbind \
    libnss-winbind \
    libpam-winbind \
    krb5-config \
    krb5-user \
    dnsutils \
    bind9utils \
    net-tools \
    iproute2 \
    iputils-ping \
    ntp \
    ntpdate \
    attr \
    acl \
    tdb-tools \
    ldb-tools \
    python3-setproctitle \
    supervisor \
    && rm -rf /var/lib/apt/lists/*

# Supprimer la config Samba par défaut (sera créée par samba-tool domain join)
RUN rm -f /etc/samba/smb.conf \
    && mkdir -p /var/lib/samba/private \
    && mkdir -p /var/lib/samba/sysvol \
    && mkdir -p /var/log/samba

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Ports AD DS :
# 53   DNS (TCP/UDP)
# 88   Kerberos (TCP/UDP)
# 135  RPC Endpoint Mapper
# 139  NetBIOS Session
# 389  LDAP (TCP/UDP)
# 445  SMB/CIFS
# 464  kpasswd (TCP/UDP)
# 636  LDAPS
# 3268 Global Catalog LDAP
# 3269 Global Catalog LDAPS
# 49152-49200 RPC dynamique (plage restreinte)
EXPOSE 53/tcp 53/udp \
       88/tcp 88/udp \
       135/tcp \
       139/tcp \
       389/tcp 389/udp \
       445/tcp \
       464/tcp 464/udp \
       636/tcp \
       3268/tcp \
       3269/tcp \
       49152-49200/tcp

VOLUME ["/var/lib/samba", "/etc/samba", "/var/log/samba"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD samba-tool domain info 127.0.0.1 || exit 1

ENTRYPOINT ["/entrypoint.sh"]
