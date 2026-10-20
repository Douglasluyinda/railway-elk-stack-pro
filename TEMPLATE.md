# Railway template composer settings

Create the template at **Workspace settings → Templates → New Template**, or deploy the three services into
a project and use **Settings → Generate Template from Project**. Service names matter: the reference
variables below use them exactly (`Elasticsearch`, `Logstash`, `Kibana`).

`ALNUM` below means the alphabet `abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789`.
Keep generated values to letters and digits so no YAML, JSON or URL quoting is needed.

## 1. Elasticsearch

| Setting | Value |
| --- | --- |
| Source | This repo (`Douglasluyinda/railway-elk-stack-pro`) |
| Root Directory | `/elasticsearch` |
| Config file path (optional) | `/elasticsearch/railway.json` (it does not follow the Root Directory) |
| Public networking | **Off** |
| Volume mount path | `/usr/share/elasticsearch/data` |

| Variable | Value |
| --- | --- |
| `ELASTIC_PASSWORD` | `${{secret(32, "ALNUM")}}` |
| `KIBANA_SYSTEM_PASSWORD` | `${{secret(32, "ALNUM")}}` |
| `LOGSTASH_WRITER_PASSWORD` | `${{secret(32, "ALNUM")}}` |
| `RAILWAY_RUN_UID` | `0` (the entrypoint drops to uid 1000 itself) |
| `ES_JAVA_OPTS` | `-Xms512m -Xmx512m` |
| `LOG_RETENTION_DAYS` | `14` |

## 2. Logstash

| Setting | Value |
| --- | --- |
| Source | Same repo |
| Root Directory | `/logstash` |
| Config file path (optional) | `/logstash/railway.json` |
| Public networking | **Off** |
| Volume | none |

| Variable | Value |
| --- | --- |
| `ES_URL` | `http://${{Elasticsearch.RAILWAY_PRIVATE_DOMAIN}}:9200` |
| `ES_USER` | `logstash_writer` |
| `ES_PASSWORD` | `${{Elasticsearch.LOGSTASH_WRITER_PASSWORD}}` |
| `INPUT_USER` | `shipper` |
| `INPUT_PASSWORD` | `${{secret(32, "ALNUM")}}` |
| `LS_JAVA_OPTS` | `-Xms256m -Xmx256m` |

## 3. Kibana

| Setting | Value |
| --- | --- |
| Source | Same repo |
| Root Directory | `/kibana` |
| Config file path (optional) | `/kibana/railway.json` |
| Public networking | **HTTP domain, target port 5601** |
| Volume | none |

| Variable | Value |
| --- | --- |
| `PORT` | `5601` |
| `ELASTICSEARCH_HOSTS` | `http://${{Elasticsearch.RAILWAY_PRIVATE_DOMAIN}}:9200` |
| `ELASTICSEARCH_USERNAME` | `kibana_system` |
| `ELASTICSEARCH_PASSWORD` | `${{Elasticsearch.KIBANA_SYSTEM_PASSWORD}}` |
| `XPACK_SECURITY_ENCRYPTIONKEY` | `${{secret(48, "ALNUM")}}` |
| `XPACK_ENCRYPTEDSAVEDOBJECTS_ENCRYPTIONKEY` | `${{secret(48, "ALNUM")}}` |
| `XPACK_REPORTING_ENCRYPTIONKEY` | `${{secret(48, "ALNUM")}}` |
| `SERVER_PUBLICBASEURL` | `https://${{RAILWAY_PUBLIC_DOMAIN}}` |

## 4. Grouping

In the project canvas, right-click a service and create a group, then add all three. Railway's docs
describe canvas groups as a visual feature. **Whether a group survives "Generate Template from Project"
is unverified**: generate the template, deploy it into a fresh project and check. If the group is lost,
say so in the template description rather than claiming it.

## 5. Publish checklist

- Deploy the template into a clean project and complete the README's "Verify the deployment" section.
- Confirm Elasticsearch starts with the volume attached (this is the least certain step).
- Add a description, the README content, and the license of your choice (this repo has none yet).
- Remember published templates are what earn kickbacks; unpublished ones do not.
