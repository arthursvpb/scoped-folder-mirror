# Privacy

Scoped Folder Mirror has no telemetry, analytics, advertising, crash-upload, account, or network service.

The app stores security-scoped bookmark data, the selected destination volume identifier, a random mirror identifier, the encryption-warning acknowledgement, and the Boolean ejection preference in its sandbox container. These values are needed to restore the two user-selected grants, validate the destination, and apply the selected post-sync behavior.

Activity history contains only a typed result code, timestamp, file count, and byte count. It never stores raw error descriptions, file contents, paths, folder names, volume names, volume identifiers, or bookmark bytes.

The destination ownership marker contains only its schema version and a random mirror identifier. Temporary transaction markers contain only a schema version, random run name, phase, and two transaction booleans. They contain no source or destination path, file name, volume identity, or user identity. Revoke and reset controls remove the corresponding local configuration and restore the ejection preference default.
