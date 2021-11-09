data "archive_file" "check_for_changes" {
    type = "zip"
    source_dir = var.input_path
    output_path = "${path.module}/${replace(var.input_path, "/", "_")}.zip"
}

resource "null_resource" "lambda_exporter" {
    # (some local-exec provisioner blocks, presumably...)
    provisioner "local-exec" {
        working_dir = var.input_path
        command = "python3 -m pip install -r requirements.txt --target ./${var.input_path}"
    }

    triggers = {
        # Only build if there has been any changes to the input path
        index = data.archive_file.check_for_changes.output_base64sha256
    }
}

data "archive_file" "artifact" {
    type = "zip"
    source_dir  = var.input_path
    output_path = var.output_path

    depends_on = [null_resource.lambda_exporter]
}
