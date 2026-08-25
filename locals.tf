locals {
  network_id    = yandex_vpc_network.nora.id
  subnet_a_id   = yandex_vpc_subnet.nora-a.id
  subnet_a_zone = yandex_vpc_subnet.nora-a.zone
  subnet_b_id   = yandex_vpc_subnet.nora-b.id
  subnet_b_zone = yandex_vpc_subnet.nora-b.zone
  subnet_d_id   = yandex_vpc_subnet.nora-d.id
  subnet_d_zone = yandex_vpc_subnet.nora-d.zone
  ingress_ip    = yandex_vpc_address.addr.external_ipv4_address[0].address
  nora_fqdn     = "nora.${local.ingress_ip}.sslip.io"
}
