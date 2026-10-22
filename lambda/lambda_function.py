import base64
import json
import os
import time

import boto3
from botocore.exceptions import ClientError

s3 = boto3.client("s3")

BUCKET = os.environ["BUCKET"]
PREFIX = os.environ["PREFIX"]

# request path -> (key under PREFIX, content type, is_binary)
ROUTES = {
    "/": ("index.html", "text/html; charset=utf-8", False),
    "/index.html": ("index.html", "text/html; charset=utf-8", False),
    "/style.css": ("style.css", "text/css; charset=utf-8", False),
    "/cv.pdf": ("cv.pdf", "application/pdf", True),
}

NOT_FOUND_PAGE = (
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>404 Not Found</title></head>"
    "<body><h1>404 - Not Found</h1><p>This page does not exist. "
    "<a href=\"/\">Go to the CV</a>.</p></body></html>"
)


def lambda_handler(event, context):
    start = time.time()
    path = event.get("rawPath") or event.get("requestContext", {}).get("http", {}).get("path") or "/"

    route = ROUTES.get(path)
    if route is None:
        response = {
            "statusCode": 404,
            "headers": {"Content-Type": "text/html; charset=utf-8"},
            "body": NOT_FOUND_PAGE,
        }
    else:
        key, content_type, is_binary = route
        try:
            obj = s3.get_object(Bucket=BUCKET, Key=PREFIX + key)
            data = obj["Body"].read()
            headers = {"Content-Type": content_type}
            if is_binary:
                body = base64.b64encode(data).decode("ascii")
            else:
                body = data.decode("utf-8")
                if key == "index.html":
                    body = body.replace("{{HOSTED_ON}}", "Lambda " + context.function_name)
                    headers["Cache-Control"] = "public, max-age=60"
            response = {
                "statusCode": 200,
                "headers": headers,
                "body": body,
                "isBase64Encoded": is_binary,
            }
        except ClientError as err:
            print(json.dumps({"error": str(err)}))
            response = {
                "statusCode": 500,
                "headers": {"Content-Type": "text/plain"},
                "body": "Could not load the CV right now.",
            }

    # One JSON log line per request: fn, path, status, ms
    print(json.dumps({
        "fn": context.function_name,
        "path": path,
        "status": response["statusCode"],
        "ms": round((time.time() - start) * 1000, 1),
    }))
    return response
