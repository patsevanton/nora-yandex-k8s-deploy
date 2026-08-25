resource "yandex_vpc_address" "addr" {
  name = "nora-pip"

  external_ipv4_address {
    zone_id = local.subnet_a_zone
  }
}

resource "local_file" "helm_values" {
  content = templatefile("${path.module}/helm-values.yaml.tpl", {
    fqdn = local.nora_fqdn
  })
  filename = "${path.module}/helm-values.yaml"
}
