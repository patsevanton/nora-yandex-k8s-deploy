image:
  # NORA v1.2.0; чарт 0.4.4 ещё имеет appVersion 1.1.0, поэтому пиним тег вручную.
  # Когда выйдет чарт 0.4.5 (appVersion 1.2.0), строку можно удалить.
  tag: "1.2.0"

ingress:
  enabled: true
  className: nginx
  hosts:
    - host: ${fqdn}
      paths:
        - path: /
          pathType: Prefix
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "600"
    cert-manager.io/cluster-issuer: letsencrypt-prod
  tls:
    - secretName: nora-tls
      hosts:
        - ${fqdn}

persistence:
  enabled: false

config:
  server:
    public_url: "https://${fqdn}"
  storage:
    mode: s3
    path: /data/storage
    s3_url: https://storage.yandexcloud.net
    bucket: nora-storage-anton-patsev
    s3_region: ru-central1
  registries:
    enable: "all"
  auth:
    enabled: true
    anonymous_read: true # Для terraform
    htpasswd:
      existingSecret: nora-htpasswd
      secretKey: users.htpasswd

extraEnv:
  - name: NORA_STORAGE_S3_ACCESS_KEY
    valueFrom:
      secretKeyRef:
        name: nora-s3-credentials
        key: S3_ACCESS_KEY
  - name: NORA_STORAGE_S3_SECRET_KEY
    valueFrom:
      secretKeyRef:
        name: nora-s3-credentials
        key: S3_SECRET_KEY
  - name: HTTPS_PROXY
    value: "http://mihomo-proxy.nora.svc.cluster.local:1080"
  - name: https_proxy
    value: "http://mihomo-proxy.nora.svc.cluster.local:1080"
  - name: NO_PROXY
    value: "127.0.0.1,localhost,.svc,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  - name: no_proxy
    value: "127.0.0.1,localhost,.svc,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  - name: NORA_TRUST_UPSTREAM_DATES
    value: "true"

resources:
  limits:
    memory: 512Mi
    cpu: "1"
  requests:
    memory: 128Mi
    cpu: "0.25"
