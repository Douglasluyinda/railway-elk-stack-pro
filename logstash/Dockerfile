# Logstash for Railway: authenticated HTTP intake -> Elasticsearch, private network only.
# Build from the repo with Root Directory = /logstash.
ARG ELASTIC_VERSION=8.19.21
FROM docker.elastic.co/logstash/logstash:${ELASTIC_VERSION}

COPY --chown=1000:0 pipeline/logstash.conf /usr/share/logstash/pipeline/logstash.conf
COPY --chown=1000:0 config/logstash.yml /usr/share/logstash/config/logstash.yml

# Default heap; override with the LS_JAVA_OPTS service variable.
ENV LS_JAVA_OPTS="-Xms256m -Xmx256m"

# 8080 = authenticated JSON intake, 9600 = Logstash monitoring API.
EXPOSE 8080 9600
