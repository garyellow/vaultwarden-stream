snapshot:
  interval: ${LITESTREAM_SNAPSHOT_INTERVAL}
  retention: ${LITESTREAM_RETENTION}

dbs:
  - path: ${LITESTREAM_DB_PATH}
    replica:
      type: s3
      bucket: ${S3_BUCKET}
      path: ${LITESTREAM_REPLICA_PATH}
      endpoint: ${S3_ENDPOINT}
      region: ${S3_REGION}
      access-key-id: ${S3_ACCESS_KEY_ID}
      secret-access-key: ${S3_SECRET_ACCESS_KEY}
      sync-interval: ${LITESTREAM_SYNC_INTERVAL}
      validation-interval: ${LITESTREAM_VALIDATION_INTERVAL}
      force-path-style: ${LITESTREAM_FORCE_PATH_STYLE}
      skip-verify: ${LITESTREAM_SKIP_VERIFY}
