variable "name_prefix" {
    type = string
}

variable "service_account_id" {
    description = <<-EOF
        The account ID for the service account.
        This is the account where the pipeline lives.
    EOF
    type = string
}
