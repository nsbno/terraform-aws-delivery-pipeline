variable "input_path" {
    description = "The directory to build"
    type = string
}

variable "output_path" {
    description = "Where to place the built artifact"
    type = string
}

variable "no_dependencies" {
    description = "Make pip not install dependencies"
    type = bool
    default = false
}
