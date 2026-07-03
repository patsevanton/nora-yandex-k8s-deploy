apiVersion: v1
kind: Secret
metadata:
  name: nora-s3-credentials
type: Opaque
stringData:
  S3_ACCESS_KEY: ${access_key}
  S3_SECRET_KEY: ${secret_key}
