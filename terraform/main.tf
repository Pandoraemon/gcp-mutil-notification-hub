/**
 * Provider 配置 + API 启用。
 *
 * backend.tf 由 deploy-terraform.sh 生成（GCS + versioning），不纳入版本控制。
 * 直接 `terraform apply` 而不经脚本时会使用本地 state —— 仅适合临时验证。
 */

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    # google-beta：Notification Channel 的 pubsub 类型与 SCC 通知配置需要
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {
  project_id = var.project_id
}

# Gen2 函数依赖 run / eventarc / artifactregistry，缺任何一个部署都会失败。
# deploy-terraform.sh 已用 gcloud 启用过一遍；此处声明是为了让"只跑 terraform"的
# 场景也能自愈，并把依赖关系写进图里（函数 depends_on 这些 service）。
locals {
  required_apis = concat([
    "pubsub.googleapis.com",
    "cloudfunctions.googleapis.com",
    "run.googleapis.com",
    "eventarc.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "secretmanager.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "servicehealth.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    ],
    var.enable_scc ? ["securitycenter.googleapis.com"] : [],
    var.enable_billing ? ["billingbudgets.googleapis.com"] : [],
  )
}

resource "google_project_service" "required" {
  for_each = toset(local.required_apis)

  project = var.project_id
  service = each.value

  # destroy 时不停用 API：同项目的其它工作负载可能正依赖它们，
  # 停用会造成远超本项目范围的连带故障。
  disable_on_destroy         = false
  disable_dependent_services = false
}
