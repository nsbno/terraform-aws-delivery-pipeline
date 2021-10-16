import json
import logging

import boto3

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


def github_push(event):
    data = json.loads(event["body"])

    if not data["ref"] == "refs/heads/master":
        logger.info(f"Pushed data was not in master. It was in {data['ref']}.")
        return
    if data["before"] == data["after"]:
        logger.info("There were no changes in this push.")
        return

    print("Worked!")
    print(data)


def is_valid_signature(event):
    # TODO: Implement a check for the GiHub signature field to verify the origin
    return True


def handler(event, _):
    if not is_valid_signature(event):
        return json.dumps({
            "statusCode": 401,
            "body": "Request signature does not match GitHub's signature"
        })

    github_event = event["headers"]["X-GitHub-Event"]
    if github_event == "push":
        github_push(event)
    else:
        logger.info(f"No relevant event from GitHub. Event was {github_event}")

    return {
        "statusCode": 200,
        "body": "Deployment started"
    }
