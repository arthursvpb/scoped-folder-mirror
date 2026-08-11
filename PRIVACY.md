# Privacy

Scoped Folder Mirror has no telemetry, analytics, advertising, crash-upload, account, or network service.

The app stores security-scoped bookmark data, the selected destination volume identifier, a random mirror identifier, and the encryption-warning acknowledgement in its sandbox container. These values are needed to restore the two user-selected grants and validate the destination.

Activity history contains only a typed result code, timestamp, file count, and byte count. It never stores raw error descriptions, file contents, paths, folder names, volume names, volume identifiers, or bookmark bytes.

The destination ownership marker contains only its schema version and a random mirror identifier. Revoke and reset controls remove the corresponding local configuration.
