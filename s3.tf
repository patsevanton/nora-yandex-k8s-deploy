resource "yandex_iam_service_account" "sa_storage_admin" {
  folder_id = local.folder_id
  name      = "sa-storage-admin"
}

resource "yandex_resourcemanager_folder_iam_member" "sa_storage_admin_permissions" {
  folder_id = local.folder_id
  role      = "storage.admin"
  member    = "serviceAccount:${yandex_iam_service_account.sa_storage_admin.id}"
}

resource "yandex_iam_service_account_static_access_key" "sa_storage_admin_static_key" {
  service_account_id = yandex_iam_service_account.sa_storage_admin.id
  description        = "static access key for object storage"
}

resource "yandex_storage_bucket" "nora_storage" {
  access_key = yandex_iam_service_account_static_access_key.sa_storage_admin_static_key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa_storage_admin_static_key.secret_key
  bucket     = "nora-storage-anton-patsev"
}

resource "local_file" "secret_for_bucket" {
  content = templatefile("${path.module}/secret_for_bucket.yaml.tpl", {
    access_key = yandex_iam_service_account_static_access_key.sa_storage_admin_static_key.access_key
    secret_key = yandex_iam_service_account_static_access_key.sa_storage_admin_static_key.secret_key
  })
  filename = "${path.module}/secret_for_bucket.yaml"
}

output "access_key_sa_storage_admin_for_bucket" {
  description = "access_key sa-storage-admin for nora-storage-anton-patsev"
  value       = yandex_iam_service_account_static_access_key.sa_storage_admin_static_key.access_key
  sensitive   = true
}

output "secret_key_sa_storage_admin_for_bucket" {
  description = "secret_key sa-storage-admin for nora-storage-anton-patsev"
  value       = yandex_iam_service_account_static_access_key.sa_storage_admin_static_key.secret_key
  sensitive   = true
}
