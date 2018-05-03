import io
import json


def test_scan_document_no_auth(client, mocker):
    mocker.patch('app.views.clamav_scan', return_value=True)

    response = client.post(
        '/scan',
        content_type='multipart/form-data',
        data={
            'document': (io.BytesIO(b'pdf file contents'), 'file.pdf')
        }
    )

    assert response.status_code == 401


def test_scan_no_document(client, mocker):
    response = client.post(
        '/scan',
        headers={
            'Authorization': 'Bearer test-key',
        },
    )

    assert response.status_code == 400


def test_scan_document_invalid_auth(client, mocker):
    mocker.patch('app.views.clamav_scan', return_value=True)

    response = client.post(
        '/scan',
        content_type='multipart/form-data',
        headers={
            'Authorization': 'Bearer invalid-key',
        },
        data={
            'document': (io.BytesIO(b'pdf file contents'), 'file.pdf')
        }
    )

    assert response.status_code == 401


def test_scan_document(client, mocker):
    mocker.patch('app.views.clamav_scan', return_value=True)

    response = client.post(
        '/scan',
        content_type='multipart/form-data',
        headers={
            'Authorization': 'Bearer test-key',
        },
        data={
            'document': (io.BytesIO(b'pdf file contents'), 'file.pdf')
        }
    )

    assert response.status_code == 200
    assert json.loads(response.get_data(as_text=True)) == {'ok': True}


def test_scan_virus_document(client, mocker):
    mocker.patch('app.views.clamav_scan', return_value=False)

    response = client.post(
        '/scan',
        content_type='multipart/form-data',
        headers={
            'Authorization': 'Bearer test-key',
        },
        data={
            'document': (io.BytesIO(b'pdf file contents'), 'file.pdf')
        }
    )

    assert response.status_code == 200
    assert json.loads(response.get_data(as_text=True)) == {'ok': False}