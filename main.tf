terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

variable "do_token" {}

# Configure the DigitalOcean Provider
provider "digitalocean" {
  token = var.do_token
}

################################# DOCKER REGISTRY #################################


resource "digitalocean_container_registry_docker_credentials" "iskra-registry" {
  registry_name = "iskra-registry"
}

################################# CLUSTER #################################

variable "do_cluster_name" {
  default = "iskra"
}

resource "digitalocean_kubernetes_cluster" "iskra_cluster" {
  name    = var.do_cluster_name
  region  = "fra1"
  version = "1.22.8-do.1"

  node_pool {
    name       = "worker-pool"
    size       = "s-1vcpu-2gb"
    node_count = 2
  }
}

provider "kubernetes" {
  host                   = digitalocean_kubernetes_cluster.iskra_cluster.endpoint
  token                  = digitalocean_kubernetes_cluster.iskra_cluster.kube_config.0.token
  cluster_ca_certificate = base64decode(digitalocean_kubernetes_cluster.iskra_cluster.kube_config.0.cluster_ca_certificate)
}

resource "kubernetes_secret" "iskra-registry" {
  metadata {
    name = "docker-cfg"
  }

  data = {
    ".dockerconfigjson" = digitalocean_container_registry_docker_credentials.iskra-registry.docker_credentials
  }

  type = "kubernetes.io/dockerconfigjson"
}


################################# CLIENT #################################

resource "kubernetes_deployment" "client-deployment" {
  metadata {
    name = "client-deployment"
    labels = {
      test = "MyExampleApp"
    }
  }

  spec {
    replicas = 1

    selector {
       match_labels = {
        component = "web"
      }
    }
    template {
      metadata {
        labels = {
          component = "web"
        }
      }
      spec {
        container {
          name = "client"
          image = "registry.digitalocean.com/iskra-registry/project-client@sha256:4c112a478887e655865298dd6516f1c53f1dfdce3ec7e0ccc7ddbc96c6dc8083"
            port {
              container_port = 3000
            }
        }
      }
    }
  }
}

resource "kubernetes_service" "client-cluster-ip-service" {
  metadata {
    name = "client-cluster-ip-service"
  }
  spec {
    type = "ClusterIP"
    selector = {
      component = "web"
    }
    port {
      port = 3000
      target_port = 3000
    }
  }
}

########################## PERSISTENT VOLUME CLAIM #########################
resource "kubernetes_persistent_volume_claim" "database-persistent-volume-claim" {
  metadata {
    name = "database-persistent-volume-claim"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

################################ POSTGRES ###########################################

resource "kubernetes_deployment" "postgres-deployment" {
  metadata {
    name = "postgres-deployment"
  }
  spec {
    replicas = 1
    selector {
      match_labels ={
        component = "postgres"
      }
    }
    template {
      metadata {
        labels = {
          component = "postgres"
        }
      }
      spec {
        volume {
          name = "postgres-storage"
            persistent_volume_claim {
              claim_name = "database-persistent-volume-claim"
            }
        }
        container {
          name = "postgres"
          image = "postgres"
          port {
            container_port = 5432
          }
          volume_mount {
            name = "postgres-storage"
            mount_path = "/var/lib/postgresql/data"
            sub_path = "postgres"
          }
            env {
              name = "POSTGRES_PASSWORD"
              value_from {
                secret_key_ref {
                  name = "pgpassword"
                  key = "PGPASSWORD"
                }
              } 
            }
        }
      }
    }
  }
}

resource "kubernetes_service" "postgres-cluster-ip-service" {
  metadata {
    name = "postgres-cluster-ip-service"
  }
  spec {
    type = "ClusterIP"
    selector = {
      component = "postgres"
    }
    port {
      port = 5432
      target_port = 5432
    }
  }
}



################################# SERVER #################################
resource "kubernetes_deployment" "server-deployment" {
  metadata {
    name = "server-deployment"
  }
  spec {
    replicas = 1
    selector {
       match_labels = {
        component = "server"
      }
    }
    template {
      metadata {
        labels = {
          component = "server"
        }
      }
      spec {
        container {
          name = "server"
          image = "registry.digitalocean.com/iskra-registry/project-api@sha256:eac661b8433a200dbec3957579a849b4d60a9893d8a425beac99fdc39ec024e4"
          port {
            container_port = 5000
          }
          env {
            name = "PGUSER"
            value = "postgres"
          }
          env {
            name = "PGHOST"
            value = "postgres-cluster-ip-service"
          }
          env {
            name = "PGPORT"
            value = "5432"
          }
          env {
            name = "PGDATABASE"
            value = "postgres"
          }
          env {
            name = "PGPASSWORD"
              value_from {
                secret_key_ref {
                  name = "pgpassword"
                  key = "PGPASSWORD"
                }
              }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "server-cluster-ip-service" {
  metadata {
    name = "server-cluster-ip-service"
  }
  spec {
    type = "ClusterIP"
    selector = {
      component = "server"
    }
    port {
      port = 5000
      target_port = 5000
    }
  }
}

################################# INGRESS #################################

module nginx-ingress-controller {
  source  = "byuoitav/nginx-ingress-controller/kubernetes"
  version = "0.2.1"
}

resource "kubernetes_ingress" "ingress-service" {

  metadata {
    name = "ingress-service"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "nginx.ingress.kubernetes.io/use-regex" = "true"
      "nginx.ingress.kubernetes.io/rewrite-target" = "/$1"
    }
  }
  spec {
    rule {
      http {
        path {
          path = "/?(.*)"
          backend {
              service_name = "client-cluster-ip-service"
              service_port = 3000
          }
        }
        path {
          path = "/api/?(.*)"
          backend {
              service_name = "server-cluster-ip-service"
              service_port = 5000
          }
        }
      }
    }
  }
}