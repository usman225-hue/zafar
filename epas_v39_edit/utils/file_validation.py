"""File validation compatibility helpers."""

from __future__ import annotations


def validate_uploaded_file(uploaded_file, allowed: set[str], max_bytes: int):
    if uploaded_file is None:
        return False, "No file uploaded."
    content = getattr(uploaded_file, "getvalue", None)
    if callable(content):
        data = content()
    else:
        data = uploaded_file
    if isinstance(data, (bytes, bytearray)):
        size = len(data)
    else:
        size = 0
    if size > max_bytes:
        return False, f"File exceeds {max_bytes} bytes."
    return True, "OK"


def validate_upload_descriptor(uploaded_file, allowed: set[str], max_bytes: int):
    if uploaded_file is None:
        return False, "File is required."
    try:
        ok, msg = validate_uploaded_file(uploaded_file, allowed, max_bytes)
        if not ok:
            return False, msg
    except Exception as exc:
        return False, str(exc)
    return True, "OK"


def validated_upload_metadata(uploaded_file, allowed: set[str], max_bytes: int):
    ok, msg = validate_uploaded_file(uploaded_file, allowed, max_bytes)
    return {"ok": ok, "message": msg}


def materialize_upload(uploaded_file, allowed: set[str], max_bytes: int):
    class _Materialized:
        def __init__(self, content: bytes, file_name: str, mime_type: str):
            self.content = content
            self.file_name = file_name
            self.mime_type = mime_type
            self.size_bytes = len(content)
            self.sha256 = "stub-sha256"

    if uploaded_file is None:
        raise ValueError("No file uploaded.")
    data = uploaded_file.getvalue() if hasattr(uploaded_file, "getvalue") else uploaded_file
    if isinstance(data, str):
        data = data.encode("utf-8")
    return _Materialized(bytes(data), getattr(uploaded_file, "name", "upload.bin"), "application/octet-stream")


MAX_PDF_BYTES = 10 * 1024 * 1024
MAX_IMAGE_BYTES = 5 * 1024 * 1024


__all__ = [
    "validate_uploaded_file", "validate_upload_descriptor", "validated_upload_metadata",
    "materialize_upload", "MAX_PDF_BYTES", "MAX_IMAGE_BYTES",
]
