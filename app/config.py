import os

from kombu import Exchange, Queue

if os.environ.get('VCAP_SERVICES'):
    # on cloudfoundry, config is a json blob in VCAP_SERVICES - unpack it, and populate
    # standard environment variables from it
    from app.cloudfoundry_config import extract_cloudfoundry_config

    extract_cloudfoundry_config()


class QueueNames(object):
    LETTERS = 'letter-tasks'
    ANTIVIRUS = 'antivirus-tasks'


class Config(object):
    # Hosted graphite statsd prefix
    STATSD_PREFIX = os.getenv('STATSD_PREFIX')
    STATSD_ENABLED = True
    STATSD_HOST = os.getenv('STATSD_HOST')
    STATSD_PORT = 8125

    NOTIFICATION_QUEUE_PREFIX = os.getenv('NOTIFICATION_QUEUE_PREFIX')

    # Logging
    DEBUG = False
    LOGGING_STDOUT_JSON = os.getenv('LOGGING_STDOUT_JSON') == '1'

    ###########################
    # Default config values ###
    ###########################

    NOTIFY_APP_NAME = 'antivirus'
    AWS_REGION = os.getenv('AWS_REGION', 'eu-west-1')
    NOTIFY_LOG_PATH = os.getenv('NOTIFY_LOG_PATH')

    ANTIVIRUS_API_KEY = os.getenv('ANTIVIRUS_API_KEY')

    BROKER_URL = 'sqs://'
    BROKER_TRANSPORT_OPTIONS = {
        'region': AWS_REGION,
        'polling_interval': 1,
        'visibility_timeout': 310,
        'queue_name_prefix': NOTIFICATION_QUEUE_PREFIX
    }
    CELERY_ENABLE_UTC = True
    CELERY_TIMEZONE = 'Europe/London'
    CELERY_ACCEPT_CONTENT = ['json']
    CELERY_TASK_SERIALIZER = 'json'
    CELERY_IMPORTS = ('app.celery.tasks', )
    CELERY_QUEUES = [
        Queue(QueueNames.ANTIVIRUS, Exchange('default'), routing_key=QueueNames.ANTIVIRUS)
    ]

    LETTERS_SCAN_BUCKET_NAME = None


######################
# Config overrides ###
######################


class Development(Config):
    NOTIFICATION_QUEUE_PREFIX = 'development'
    DEBUG = True

    ANTIVIRUS_API_KEY = 'test-key'

    LETTERS_SCAN_BUCKET_NAME = 'development-letters-scan'


class Test(Config):
    DEBUG = True
    STATSD_HOST = "localhost"
    STATSD_PORT = 1000

    ANTIVIRUS_API_KEY = 'test-key'

    LETTERS_SCAN_BUCKET_NAME = 'test-letters-pdf'


class Preview(Config):

    LETTERS_SCAN_BUCKET_NAME = 'preview-letters-scan'


class Staging(Config):

    LETTERS_SCAN_BUCKET_NAME = 'staging-letters-scan'


class Production(Config):

    LETTERS_SCAN_BUCKET_NAME = 'production-letters-scan'


configs = {
    'development': Development,
    'test': Test,
    'preview': Preview,
    'staging': Staging,
    'production': Production,
}
