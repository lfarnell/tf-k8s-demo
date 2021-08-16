variable "token" {
  description = "DigitalOcean API Token"
}

variable "region" {
  description = "Region to deploy infrastructure"
  default     = "tor1"
}

variable "github_owner" {
  type        = string
  description = "github owner"
}

variable "repository_name" {
  type        = string
  default     = "test-provider"
  description = "github repository name"
}

variable "branch" {
  type        = string
  default     = "main"
  description = "branch name"
}

variable "target_path" {
  type        = string
  default     = "clusters/production"
  description = "flux sync target path"
}
