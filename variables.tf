variable "name_prefix" {
    type = string
}

variable "account_id" {
  description = "The ID of the account this is being published to"
  type = string
}

variable "slack_channel" {
  description = "A slack channel you send notifications to"
  type = string
}

variable "deployment_accounts" {
    description = "A list of all accounts that we can deploy to"
    type = object({
        service = string
        dev = optional(string)
        test = optional(string)
        stage = optional(string)
        prod = string
    })
}

variable "central_account" {
  description = "The central account that can start a deployment."
  type = string
}

variable "deployment_role" {
    description = "The name of the deployment role in our accounts."
    type = string
}

variable "subnets" {
    description = "Subnet to deploy Fargate container in."
    type = list
}

variable "vpc_id" {
    description = "VPC that the subnets are in"
    type = string
}
