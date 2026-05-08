curl -sk -X GET -H "Authorization: Bearer ${TEMP}" \
  "https://10.10.10.20/api/v2.0/iscsi/targetextent" \
  | jq '.[].id' \
  | xargs -P 10 -I{} curl -sk -X DELETE \
    -H "Authorization: Bearer ${TEMP}" \
    -H "Content-Type: application/json" \
    "https://10.10.10.20/api/v2.0/iscsi/targetextent/id/{}"

curl -sk -X GET -H "Authorization: Bearer ${TEMP}" \
  "https://10.10.10.20/api/v2.0/iscsi/target" \
  | jq '.[].id' \
  | xargs -P 10 -I{} curl -sk -X DELETE \
    -H "Authorization: Bearer ${TEMP}" \
    -H "Content-Type: application/json" \
    "https://10.10.10.20/api/v2.0/iscsi/target/id/{}"

curl -sk -X GET -H "Authorization: Bearer ${TEMP}" \
  "https://10.10.10.20/api/v2.0/iscsi/extent" \
  | jq '.[].id' \
  | xargs -P 10 -I{} curl -sk -X DELETE \
    -H "Authorization: Bearer ${TEMP}" \
    -H "Content-Type: application/json" \
    "https://10.10.10.20/api/v2.0/iscsi/extent/id/{}"
