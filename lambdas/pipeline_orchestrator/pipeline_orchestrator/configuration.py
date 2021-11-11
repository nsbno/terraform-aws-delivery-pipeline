import json
from dataclasses import dataclass, field
from io import BytesIO
from zipfile import ZipFile

import boto3
import yaml


@dataclass
class DeploymentInfo:
    """The info we expect from any provider to be able to start the pipeline."""
    git_owner: str
    git_repo: str
    git_branch: str
    git_user: str
    git_sha1: str
    artifact_bucket: str
    artifact_key: str = field(init=False)

    def __post_init__(self):
        self.artifact_key = "/".join([
            self.artifact_bucket,
            self.git_owner,
            self.git_repo,
            "branches",
            self.git_branch,
            f"{self.git_sha1}.zip"
        ])

    @classmethod
    def from_s3(cls, bucket: str, key: str, version_id: str) -> object:
        """Get the data from S3"""
        s3_client = boto3.resource("s3")

        trigger_file = s3_client.Object(bucket, key)
        data = trigger_file.get()["Body"].read()

        return cls(**json.loads(data), artifact_bucket=bucket)


def get_deployment_config(bucket: str, key: str) -> dict:
    """Loads"""
    s3_client = boto3.resource("s3")

    with BytesIO(s3_client.Object(bucket, key).get()["Body"].read()) as stream:
        stream.seek(0)

        with ZipFile(stream, 'r') as artifact:
            with artifact.open(".deployment/config.yaml") as yaml_config:
                return yaml.safe_load(yaml_config)
