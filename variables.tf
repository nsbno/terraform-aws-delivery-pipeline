variable "name_prefix" {
    type = string
}

variable "tags" {
    type = map(string)
    default = {}
}

variable "docker_image" {
    description = "The docker image that the ECS task will be running (without a version number)"
    type = string
    default = "vydev/terraform"
}

variable "deployment_accounts" {
    description = "A list of all accounts that we can deploy to"
    type = list(string)
}

variable "deployment_role" {
    description = "The name of the deployment role in our accounts."
    type = string
}

variable "subnets" {
    description = "Subnet to deploy Fargate container in."
    type = list
}
