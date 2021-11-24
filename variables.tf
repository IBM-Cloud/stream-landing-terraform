variable "ibmcloud_api_key" {}

variable "region" {}

variable "ibmcloud_timeout" {
  default = 900
}

variable "basename" {
}

variable "tags" {
  default = ["terraform", "stream-landing"]
}
