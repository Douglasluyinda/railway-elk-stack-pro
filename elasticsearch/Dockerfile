FROM docker.elastic.co/elasticsearch/elasticsearch:8.15.0

# Pre-configure lightweight single-node operational parameters
ENV discovery.type=single-node
ENV xpack.security.enabled=false
ENV ES_JAVA_OPTS="-Xms512m -Xmx512m"

# Mount point for Railway Volume persistence
VOLUME /usr/share/elasticsearch/data

EXPOSE 9200
