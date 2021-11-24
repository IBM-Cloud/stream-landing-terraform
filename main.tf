#######################################################################
# Create a new resource group and provision resources under the group
######################################################################
resource "ibm_resource_group" "group" {
  name = "${var.basename}-analytics"
  tags = var.tags
}

#######################################################################
# Key management service: Create a key protect service with a root key
#######################################################################
resource "ibm_resource_instance" "keyprotect" {
  name              = "${var.basename}-kms"
  resource_group_id = ibm_resource_group.group.id
  service           = "kms"
  plan              = "tiered-pricing"
  location          = var.region
  tags              = concat(var.tags, ["service"])
}

resource "ibm_kms_key" "key" {
  instance_id  = ibm_resource_instance.keyprotect.guid
  key_name     = "root_key"
  standard_key = false
  force_delete = true
}

########################################################################
# Event streams service: Provision an event streams service with a topic
########################################################################

resource "ibm_resource_instance" "es_instance" {
  name              = "${var.basename}-es"
  service           = "messagehub"
  plan              = "standard" # "lite","standard","enterprise-3nodes-2tb"
  location          = var.region # "us-east", "eu-gb", "eu-de", "jp-tok", "au-syd"
  resource_group_id = ibm_resource_group.group.id
  tags              = concat(var.tags, ["service"])
}


resource "ibm_event_streams_topic" "es_topic" {
  resource_instance_id = ibm_resource_instance.es_instance.id
  name                 = "${var.basename}-es-topic"
  partitions           = 1
  config = {
    "cleanup.policy"  = "delete"
    "retention.ms"    = "86400000"
    "retention.bytes" = "1073741824"
    "segment.bytes"   = "536870912"
  }
}

resource "ibm_resource_key" "es_resource_key" {
  name                 = "${var.basename}-es-resourcekey"
  role                 = "Manager"
  resource_instance_id = ibm_resource_instance.es_instance.id
  //User can increase timeouts
  timeouts {
    create = "15m"
    delete = "15m"
  }
}

########################################################################
# Cloud Object Storage: Provision a COS service with a bucket
########################################################################
resource "ibm_resource_instance" "cos" {
  name              = "${var.basename}-cos"
  resource_group_id = ibm_resource_group.group.id
  service           = "cloud-object-storage"
  plan              = "standard"
  location          = "global"
  tags              = concat(var.tags, ["service"])
}

resource "ibm_resource_key" "cos_key" {
  name                 = "${var.basename}-cos-key"
  resource_instance_id = ibm_resource_instance.cos.id
  role                 = "Writer"

  parameters = {
    service-endpoints = "private"
    HMAC              = true
  }
}

resource "ibm_iam_authorization_policy" "cos_policy" {
  source_service_name         = "cloud-object-storage"
  source_resource_instance_id = ibm_resource_instance.cos.guid
  target_service_name         = ibm_kms_key.key.type
  target_resource_instance_id = ibm_resource_instance.keyprotect.guid
  roles                       = ["Reader"]
}

resource "random_uuid" "uuid" {
}

resource "ibm_cos_bucket" "bucket" {
  bucket_name          = "${var.basename}-${random_uuid.uuid.result}-bucket"
  key_protect          = ibm_kms_key.key.crn
  resource_instance_id = ibm_resource_instance.cos.id
  region_location      = var.region
  storage_class        = "smart"
  force_delete         = true

  depends_on = [ibm_iam_authorization_policy.cos_policy]
}


########################################################################
# SQL query: Provision a SQL query service for stream landing
########################################################################

resource "ibm_resource_instance" "sql_query" {
  name              = "${var.basename}-sql-query"
  service           = "sql-query"
  plan              = "standard"
  location          = var.region
  resource_group_id = ibm_resource_group.group.id
  tags              = concat(var.tags, ["service"])

}

########################################################################
# Stream landing permissions and authorizations 
########################################################################

resource "ibm_iam_service_id" "serviceID" {
  name        = "${var.basename}-sl-serviceid"
  description = "Cloud user identity used by the stream landing job to connect to the Event Streams, SQL Query and Object Storage instances"
  tags        = var.tags
}

resource "ibm_iam_authorization_policy" "policy_sql_kms" {
  source_service_name         = "sql-query"
  source_resource_instance_id = ibm_resource_instance.sql_query.guid
  target_service_name         = ibm_kms_key.key.type
  target_resource_instance_id = ibm_resource_instance.keyprotect.guid
  roles                       = ["ReaderPlus"]
}

resource "ibm_iam_service_policy" "policy_es_cluster" {
  iam_service_id = ibm_iam_service_id.serviceID.id
  roles          = ["Reader"]

  resources {
    service              = "messagehub"
    resource_instance_id = element(split(":", ibm_resource_instance.es_instance.id), 7)
    resource_type        = "cluster"
  }
}

resource "ibm_iam_service_policy" "policy_es_group" {
  iam_service_id = ibm_iam_service_id.serviceID.id
  roles          = ["Reader"]

  resources {
    service              = "messagehub"
    resource_instance_id = element(split(":", ibm_resource_instance.es_instance.id), 7)
    resource_type        = "group"
  }
}

resource "ibm_iam_service_policy" "policy_es_topic" {
  iam_service_id = ibm_iam_service_id.serviceID.id
  roles          = ["Reader"]

  resources {
    service              = "messagehub"
    resource_instance_id = element(split(":", ibm_resource_instance.es_instance.id), 7)
    resource_type        = "topic"
    resource             = element(split(":", ibm_event_streams_topic.es_topic.name), 7)
  }
}


resource "ibm_iam_service_policy" "policy_cos" {
  iam_service_id = ibm_iam_service_id.serviceID.id
  roles          = ["Writer"]

  resources {
    service              = "cloud-object-storage"
    resource_instance_id = element(split(":", ibm_resource_instance.cos.id), 7)
    resource_type        = "bucket"
    resource             = element(split(":", ibm_cos_bucket.bucket.bucket_name), 7)
  }
}

resource "ibm_iam_service_api_key" "serviceID_apiKey" {
  name           = "${var.basename}-sl-serviceid-api-key"
  iam_service_id = ibm_iam_service_id.serviceID.iam_id
}

resource "ibm_kms_key" "standard_key" {
  instance_id  = ibm_resource_instance.keyprotect.id
  key_name     = "${var.basename}-sl-kms-key"
  standard_key = true
  payload      = base64encode(ibm_iam_service_api_key.serviceID_apiKey.apikey)
}
