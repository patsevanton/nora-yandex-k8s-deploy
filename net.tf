resource "yandex_vpc_network" "nora" {
  name      = "nora-vpc"
}

resource "yandex_vpc_subnet" "nora-a" {
  v4_cidr_blocks = ["10.0.1.0/24"]
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.nora.id
}
