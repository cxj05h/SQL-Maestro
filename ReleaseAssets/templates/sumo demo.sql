-- sumo demo.sql


_index=spot_prod "{{resource-id}}" AND "{{logMessage}}"
| json field=_raw "log.message" as message

