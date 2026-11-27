FROM alpine:3.20

RUN apk add --no-cache openssl

COPY entrypoint.sh /usr/local/bin/tls-entrypoint.sh
RUN chmod 755 /usr/local/bin/tls-entrypoint.sh

ENTRYPOINT ["/bin/sh", "/usr/local/bin/tls-entrypoint.sh"]
