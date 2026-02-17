import functions_framework
from google.cloud import storage, pubsub_v1, logging as cloud_logging

storage_client = storage.Client()
publisher = pubsub_v1.PublisherClient()
logging_client = cloud_logging.Client()
logger = logging_client.logger("service-1")

PROJECT_ID = "lateral-shore-485121-i1"
TOPIC_ID = "forbidden"
BUCKET_NAME = "alan-assign2"
FORBIDDEN_COUNTRIES = ["North Korea", "Iran", "Cuba", "Myanmar", "Iraq", "Libya", "Sudan", "Zimbabwe", "Syria"]

@functions_framework.http
def handle_request(request):
    if request.method != 'GET':
        msg = f"Method {request.method} not implemented"
        print(msg) 
        logger.log_struct({"message": msg, "status": 501}, severity="ERROR")
        return "Not Implemented", 501

    country = request.headers.get('X-country')
    if country in FORBIDDEN_COUNTRIES:
        err_msg = f"Forbidden: Export to {country} is prohibited."
        topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)
        publisher.publish(topic_path, data=err_msg.encode("utf-8"))
        return "Permission Denied", 400

    filename = request.path.split('/')[-1]

    if not filename: 
        return "No filename provided", 400

    if not filename.endswith('.html'):
        filename += '.html'

    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(f"pages/{filename}")

    if not blob.exists():
        msg = f"File pages/{filename} not found"
        logger.log_struct({"message": msg, "status": 404}, severity="WARNING")
        return "Not Found", 404

    return blob.download_as_text(), 200