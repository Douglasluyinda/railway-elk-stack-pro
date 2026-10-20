# Elasticsearch for Railway: single node, security on, private network only.
# Build from the repo with Root Directory = /elasticsearch.
ARG ELASTIC_VERSION=8.19.21
FROM docker.elastic.co/elasticsearch/elasticsearch:${ELASTIC_VERSION}

# Start as root so the entrypoint can fix ownership of the Railway volume
# (mounted root-owned), then drop to the elasticsearch user (uid 1000).
USER root

COPY --chown=1000:0 --chmod=0660 config/elasticsearch.yml /usr/share/elasticsearch/config/elasticsearch.yml
COPY --chmod=0755 scripts/entrypoint.sh /usr/local/bin/railway-es-entrypoint.sh
COPY --chmod=0755 scripts/setup.sh /usr/local/bin/railway-es-setup.sh

# Default heap; override with the ES_JAVA_OPTS service variable.
ENV ES_JAVA_OPTS="-Xms512m -Xmx512m"

# No VOLUME instruction: attach a Railway volume at /usr/share/elasticsearch/data instead.
EXPOSE 9200

ENTRYPOINT ["/usr/local/bin/railway-es-entrypoint.sh"]
