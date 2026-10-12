FROM docker.elastic.co/logstash/logstash:8.15.0

COPY config/logstash.conf /usr/share/logstash/pipeline/logstash.conf
ENV LS_JAVA_OPTS="-Xms256m -Xmx256m"

EXPOSE 5044 8080
