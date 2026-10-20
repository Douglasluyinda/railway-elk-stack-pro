# Kibana for Railway: the only public service. Configured entirely by environment variables.
# Build from the repo with Root Directory = /kibana.
ARG ELASTIC_VERSION=8.19.21
FROM docker.elastic.co/kibana/kibana:${ELASTIC_VERSION}

# Non-secret defaults. Secrets and the Elasticsearch address come from Railway variables
# (see TEMPLATE.md): ELASTICSEARCH_HOSTS, ELASTICSEARCH_USERNAME, ELASTICSEARCH_PASSWORD,
# XPACK_SECURITY_ENCRYPTIONKEY, XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY,
# XPACK_REPORTING_ENCRYPTIONKEY, SERVER_PUBLICBASEURL.
ENV SERVER_HOST="::" \
    SERVER_NAME="kibana"

EXPOSE 5601
