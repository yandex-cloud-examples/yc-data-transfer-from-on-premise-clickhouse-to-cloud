# Infrastructure for the Yandex Cloud Managed Service for ClickHouse cluster and Data Transfer
#
# RU: https://yandex.cloud/ru/docs/managed-clickhouse/tutorials/data-migration
# EN: https://yandex.cloud/en/docs/managed-clickhouse/tutorials/data-migration
#
# Specify the following settings:
locals {
  # Source ClickHouse server settings:
  source_user        = ""     # ClickHouse server username
  source_db_name     = ""     # ClickHouse server database name
  source_pwd         = ""     # ClickHouse server password
  source_host        = ""     # ClickHouse server IP address or FQDN
  source_shard       = ""     # ClickHouse server shard name
  source_http_port   = "8123" # TCP port number for the HTTP interface of the ClickHouse server
  source_native_port = "9000" # TCP port number for the native interface of the ClickHouse server
  # Target cluster settings:
  target_clickhouse_version = "" # Desired version of ClickHouse. For available versions, see the documentation main page: https://yandex.cloud/en/docs/managed-clickhouse/.
  target_user               = "" # Username of the ClickHouse cluster
  target_password           = "" # ClickHouse user's password
  # Setting for the YC CLI that allows running CLI command to activate the transfer
  profile_name = "" # Name of the YC CLI profile
}

resource "yandex_vpc_network" "network" {
  description = "Network for the Managed Service for ClickHouse cluster"
  name        = "network"
}

resource "yandex_vpc_subnet" "subnet-a" {
  description    = "Subnet in the ru-central1-a availability zone"
  name           = "subnet-a"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["10.1.0.0/16"]
}

resource "yandex_vpc_security_group" "security-group" {
  description = "Security group for the Managed Service for ClickHouse cluster"
  name        = "ch-mch-sg"
  network_id  = yandex_vpc_network.network.id

  ingress {
    description    = "Allow connections to the cluster from the Internet"
    protocol       = "TCP"
    port           = local.source_http_port
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Allow connections to the cluster from the Internet"
    protocol       = "TCP"
    port           = local.source_native_port
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Allow incoming traffic on port 8443 from any IP address"
    protocol       = "TCP"
    port           = "8443"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Allow incoming traffic on port 9440 from any IP address"
    protocol       = "TCP"
    port           = "9440"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_mdb_clickhouse_cluster" "clickhouse-cluster" {
  name               = "clickhouse-cluster"
  description        = "Managed Service for ClickHouse cluster"
  version            = local.target_clickhouse_version
  environment        = "PRODUCTION"
  network_id         = yandex_vpc_network.network.id
  security_group_ids = [yandex_vpc_security_group.security-group.id]

  clickhouse {
    resources {
      resource_preset_id = "s2.micro" # 2 vCPU, 8 GB RAM
      disk_type_id       = "network-hdd"
      disk_size          = 10 # GB
    }
  }

  host {
    type      = "CLICKHOUSE"
    zone      = "ru-central1-a"
    subnet_id = yandex_vpc_subnet.subnet-a.id
  }

  database {
    name = local.source_db_name
  }

  user {
    name     = local.target_user
    password = local.target_password
    permission {
      database_name = local.source_db_name
    }
  }
}

resource "yandex_datatransfer_endpoint" "clickhouse-source" {
  description = "Source endpoint for ClickHouse server"
  name        = "clickhouse-source"
  settings {
    clickhouse_source {
      connection {
        connection_options {
          on_premise {
            shards {
              name  = local.source_shard
              hosts = [local.source_host]
            }
            http_port   = local.source_http_port
            native_port = local.source_native_port
          }
          database = local.source_db_name
          user     = local.source_user
          password {
            raw = local.source_pwd
          }
        }
      }
    }
  }
}

resource "yandex_datatransfer_endpoint" "managed-clickhouse-target" {
  description = "Target endpoint for the Managed Service for ClickHouse cluster"
  name        = "managed-clickhouse-target"
  settings {
    clickhouse_target {
      connection {
        connection_options {
          mdb_cluster_id = yandex_mdb_clickhouse_cluster.clickhouse-cluster.id
          database       = local.source_db_name
          user           = local.target_user
          password {
            raw = local.target_password
          }
        }
      }
    }
  }
}

resource "yandex_datatransfer_transfer" "clickhouse-transfer" {
  description = "Transfer from ClickHouse server to the Managed Service for ClickHouse cluster"
  name        = "transfer-from-onpremise-clickhouse-to-managed-clickhouse"
  source_id   = yandex_datatransfer_endpoint.clickhouse-source.id
  target_id   = yandex_datatransfer_endpoint.managed-clickhouse-target.id
  type        = "SNAPSHOT_ONLY" # Copy all data from the source server
  provisioner "local-exec" {
    command = "yc --profile ${local.profile_name} datatransfer transfer activate ${yandex_datatransfer_transfer.clickhouse-transfer.id}"
  }
}
